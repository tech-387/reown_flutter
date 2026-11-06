import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:reown_core/pairing/pairing.dart';
import 'package:reown_core/relay_client/json_rpc_2/src/peer.dart';
import 'package:reown_core/relay_client/relay_client.dart';
import 'package:reown_core/reown_core.dart';
import 'package:reown_sign/reown_sign.dart';

import 'shared/shared_test_utils.dart';
import 'shared/shared_test_utils.mocks.dart';
import 'shared/shared_test_values.dart';
import 'utils/sign_client_constants.dart';

/// Records what reaches the transport and answers with [acknowledge].
class _ControlledPeer extends Fake implements Peer {
  final requests = <Map<String, dynamic>>[];
  final sent = StreamController<Map<String, dynamic>>.broadcast();
  Future<dynamic> Function()? acknowledge;

  @override
  bool get isClosed => false;

  @override
  Future<dynamic> sendRequest(String method, [dynamic parameters, int? id]) {
    final request = <String, dynamic>{
      'method': method,
      'params': parameters,
      'id': id,
    };
    // Subscriptions are setup, not requests under test.
    if (method == 'irn_subscribe') return Future.value('subscription-id');
    requests.add(request);
    sent.add(request);
    return acknowledge?.call() ?? Future.value(true);
  }
}

/// A relay whose reconnect waits for [reconnect] before restoring [peer].
class _ReconnectRelay extends RelayClient {
  final Future<void> reconnect;
  final Peer peer;
  final entered = Completer<void>();

  _ReconnectRelay({
    required super.core,
    required super.messageTracker,
    required super.topicMap,
    required super.socketHandler,
    required this.reconnect,
    required this.peer,
  });

  @override
  Future<void> connect({String? relayUrl}) async {
    entered.complete();
    await reconnect;
    jsonRPC = peer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  mockPackageInfo();
  mockConnectivity();

  late ReownCore core;
  late ReownSignClient client;
  late RelayClient relay;
  late MockCrypto crypto;
  late MockMessageTracker tracker;
  late _ControlledPeer peer;

  setUp(() async {
    final socket = MockWebSocketHandler();
    when(socket.connect()).thenThrow(StateError('Controlled transport only'));
    core = ReownCore(
      projectId: 'controlled-test',
      memoryStore: true,
      httpClient: getHttpWrapper(),
    );
    crypto = MockCrypto();
    when(crypto.signJWT(any)).thenAnswer((_) async => 'controlled-jwt');
    when(crypto.encode(any, any, options: anyNamed('options'))).thenAnswer(
      (invocation) async => jsonEncode(invocation.positionalArguments[1]),
    );
    when(crypto.decode(any, any, options: anyNamed('options'))).thenAnswer(
      (invocation) async => invocation.positionalArguments[1] as String,
    );
    core.crypto = crypto;
    tracker = MockMessageTracker();
    relay = RelayClient(
      core: core,
      messageTracker: tracker,
      topicMap: getTopicMap(core: core),
      socketHandler: socket,
    );
    core.relayClient = relay;
    await core.storage.init();
    await core.linkModeStore.init();
    await relay.init();
    peer = _ControlledPeer();
    relay.jsonRPC = peer;
    core.connectivity.isOnline.value = true;
    client = ReownSignClient(core: core, metadata: PROPOSER);
    await client.engine.init();
    await client.sessions.set(
      TEST_SESSION_VALID_TOPIC,
      testSessionValid.copyWith(
        namespaces: const {
          'eip155': Namespace(
            accounts: [TEST_ETHEREUM_ACCOUNT],
            methods: ['personal_sign'],
            events: [],
          ),
        },
      ),
    );
  });

  tearDown(() async {
    await peer.sent.close();
  });

  void deliver(String topic, Map<String, dynamic> message) {
    relay.onRelayClientMessage.broadcast(
      MessageEvent(
        topic,
        jsonEncode({'jsonrpc': '2.0', ...message}),
        0,
        null,
        TransportType.relay,
      ),
    );
  }

  void respond(int id, dynamic result) =>
      deliver(TEST_SESSION_VALID_TOPIC, {'id': id, 'result': result});

  /// Lets connect() create real pairings, proposals and session topics.
  void stubConnectCrypto() {
    var created = 0;
    final utils = MockCryptoUtils();
    when(utils.generateRandomBytes32()).thenAnswer((_) => 'sym-${++created}');
    when(
      utils.hashMessage(any),
    ).thenAnswer((invocation) => invocation.positionalArguments[0] as String);
    when(crypto.getUtils()).thenReturn(utils);
    when(crypto.getClientId()).thenAnswer((_) async => 'client-id');
    when(
      crypto.setSymKey(any, overrideTopic: anyNamed('overrideTopic')),
    ).thenAnswer((invocation) async => 'pairing-$created');
    when(crypto.generateKeyPair()).thenAnswer((_) async => 'self-$created');
    when(
      crypto.generateSharedKey(
        any,
        any,
        overrideTopic: anyNamed('overrideTopic'),
      ),
    ).thenAnswer(
      (invocation) async => 'session-${invocation.positionalArguments[1]}',
    );
  }

  Future<ConnectResponse> connect(
    int id, [
    RequestPublicationController? publication,
  ]) => client.connect(
    optionalNamespaces: const {
      'eip155': RequiredNamespace(
        chains: [TEST_ETHEREUM_CHAIN],
        methods: ['personal_sign'],
        events: [],
      ),
    },
    publication: publication ?? RequestPublicationController(),
    requestId: id,
  );

  Future<dynamic> send(int id, RequestPublicationController? publication) {
    return client.request(
      requestId: id,
      topic: TEST_SESSION_VALID_TOPIC,
      chainId: TEST_ETHEREUM_CHAIN,
      request: const SessionRequestParams(method: 'personal_sign', params: []),
      publication: publication,
    );
  }

  test('cancelled before the request starts, nothing is sent', () async {
    final publication = RequestPublicationController()..cancel();
    await expectLater(
      send(1, publication),
      throwsA(isA<RequestPublicationCancelled>()),
    );
    expect(peer.requests, isEmpty);
    expect(publication.hasStarted, isFalse);
    expect((core.pairing as Pairing).pendingRequests, isEmpty);
  });

  test('cancelled while persisting, the transport send never starts', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    when(tracker.recordMessageEvent(any, any)).thenAnswer((_) async {
      entered.complete();
      await release.future;
    });
    final publication = RequestPublicationController();
    final expectation = expectLater(
      send(2, publication),
      throwsA(isA<RequestPublicationCancelled>()),
    );
    await entered.future;
    expect(publication.cancel(), isTrue);
    release.complete();
    await expectation;
    expect(peer.requests, isEmpty);
    expect((core.pairing as Pairing).pendingRequests, isEmpty);
  });

  test(
    'cancelled after the send started, the response still arrives',
    () async {
      final acknowledgement = Completer<bool>();
      peer.acknowledge = () => acknowledgement.future;
      final sent = peer.sent.stream.first;
      final publication = RequestPublicationController();
      final result = send(3, publication);
      await sent;
      expect(publication.hasStarted, isTrue);
      expect(publication.cancel(), isFalse);
      acknowledgement.complete(true);
      respond(3, 'original response');
      expect(await result, 'original response');
    },
  );

  test('past its expiry, the transport send never starts', () async {
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2;
    final publication = RequestPublicationController(expiryTimestamp: expiry);
    final entered = Completer<void>();
    final release = Completer<void>();
    when(tracker.recordMessageEvent(any, any)).thenAnswer((_) async {
      entered.complete();
      await release.future;
    });
    final expectation = expectLater(
      send(4, publication),
      throwsA(isA<TimeoutException>()),
    );
    await entered.future;
    final remaining = expiry * 1000 - DateTime.now().millisecondsSinceEpoch;
    if (remaining > 0) {
      await Future<void>.delayed(Duration(milliseconds: remaining));
    }
    release.complete();
    await expectation;
    expect(publication.hasStarted, isFalse);
    expect(peer.requests, isEmpty);
    expect((core.pairing as Pairing).pendingRequests, isEmpty);
  });

  test('a positive relay reply acknowledges the exact request', () async {
    final sent = peer.sent.stream.first;
    final publication = RequestPublicationController();
    final result = send(5, publication);
    final relayRequest = await sent;
    await publication.acknowledged;
    final payload = jsonDecode(relayRequest['params']['message'] as String);
    expect(payload['id'], 5);
    expect(payload['method'], MethodConstants.WC_SESSION_REQUEST);
    respond(5, 'result');
    expect(await result, 'result');
  });

  for (final failure in ['false', 'error']) {
    test(
      'a relay $failure reply does not acknowledge, the response is kept',
      () async {
        peer.acknowledge = () async {
          if (failure == 'error') throw StateError('relay failure');
          return false;
        };
        final sent = peer.sent.stream.first;
        final publication = RequestPublicationController();
        var acknowledged = false;
        publication.acknowledged.then((_) => acknowledged = true);
        final result = send(6, publication);
        await sent;
        await pumpEventQueue();
        expect(acknowledged, isFalse);
        expect(publication.cancel(), isFalse);
        respond(6, 'late result');
        expect(await result, 'late result');
        expect(acknowledged, isFalse);
        expect(peer.requests, hasLength(1));
      },
    );
  }

  test('a reply from another topic does not settle the request', () async {
    final sent = peer.sent.stream.first;
    var settled = false;
    final result = send(9, null).whenComplete(() => settled = true);
    await sent;
    deliver('other-topic', {
      'id': 9,
      'error': {'code': 4001, 'message': 'User rejected.'},
    });
    await pumpEventQueue();
    expect(settled, isFalse);
    respond(9, 'result');
    expect(await result, 'result');
  });

  test('without a relay connection, the request fails as not sent', () async {
    // The reconnect fails, as the controlled socket always refuses.
    relay.jsonRPC = null;
    final publication = RequestPublicationController();
    await expectLater(send(10, publication), throwsA(isA<ReownCoreError>()));
    expect(publication.hasStarted, isFalse);
    expect(publication.cancel(), isTrue);
    expect(peer.requests, isEmpty);
    expect((core.pairing as Pairing).pendingRequests, isEmpty);
  });

  test('a request without a controller still sends and completes', () async {
    final sent = peer.sent.stream.first;
    final result = send(7, null);
    await sent;
    respond(7, 'legacy result');
    expect(await result, 'legacy result');
  });

  for (final expire in [false, true]) {
    test(
      '${expire ? 'expiry' : 'cancellation'} during a reconnect stops the send',
      () async {
        final release = Completer<void>();
        final socket = MockWebSocketHandler();
        when(socket.connect()).thenThrow(StateError('Controlled reconnect'));
        final reconnecting = _ReconnectRelay(
          core: core,
          messageTracker: tracker,
          topicMap: getTopicMap(core: core),
          socketHandler: socket,
          reconnect: release.future,
          peer: peer,
        );
        await reconnecting.init();
        core.relayClient = reconnecting;
        final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2;
        final publication = RequestPublicationController(
          expiryTimestamp: expire ? expiry : null,
        );
        final expectation = expectLater(
          send(8, publication),
          throwsA(
            expire
                ? isA<TimeoutException>()
                : isA<RequestPublicationCancelled>(),
          ),
        );
        await reconnecting.entered.future;
        if (expire) {
          final remaining =
              expiry * 1000 - DateTime.now().millisecondsSinceEpoch;
          if (remaining > 0) {
            await Future<void>.delayed(Duration(milliseconds: remaining));
          }
        } else {
          expect(publication.cancel(), isTrue);
        }
        release.complete();
        await expectation;
        expect(peer.requests, isEmpty);
        expect(publication.hasStarted, isFalse);
        expect((core.pairing as Pairing).pendingRequests, isEmpty);
      },
    );
  }

  test(
    'connect sends its proposal with the given ID and acknowledges it',
    () async {
      stubConnectCrypto();
      final publication = RequestPublicationController();
      final sent = peer.sent.stream.first;
      await connect(40, publication);
      final relayRequest = await sent;
      await publication.acknowledged;
      expect(relayRequest['method'], 'wc_proposeSession');
      final proposal = jsonDecode(
        relayRequest['params']['sessionProposal'] as String,
      );
      expect(proposal['id'], 40);
    },
  );

  test('a late approval settles only the proposal it answers', () async {
    stubConnectCrypto();
    final older = await connect(41);
    final newer = await connect(42);
    await pumpEventQueue();
    var newerSettled = false;
    newer.session.future.then((_) => newerSettled = true, onError: (_) {});

    // MetaMask approves the older proposal after the newer one was sent.
    deliver(older.pairingTopic, {
      'id': 41,
      'result': {'responderPublicKey': 'wallet-41'},
    });
    await pumpEventQueue();
    deliver('session-wallet-41', {
      'id': 4100,
      'method': MethodConstants.WC_SESSION_SETTLE,
      'params': WcSessionSettleRequest(
        relay: Relay('irn'),
        namespaces: const {
          'eip155': Namespace(
            accounts: [TEST_ETHEREUM_ACCOUNT],
            methods: ['personal_sign'],
            events: [],
          ),
        },
        expiry: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        controller: const ConnectionMetadata(
          publicKey: 'wallet-41',
          metadata: PairingMetadata(
            name: 'Wallet',
            description: '',
            url: 'https://wallet.example',
            icons: [],
          ),
        ),
      ).toJson(),
    });

    final session = await older.session.future;
    expect(session.topic, 'session-wallet-41');
    expect(session.pairingTopic, older.pairingTopic);
    await pumpEventQueue();
    expect(newerSettled, isFalse);
  });
}
