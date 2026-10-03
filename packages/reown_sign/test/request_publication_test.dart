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
    requests.add(request);
    sent.add(request);
    return acknowledge?.call() ?? Future.value(true);
  }
}

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

  void respond(
    int id,
    dynamic result, {
    String topic = TEST_SESSION_VALID_TOPIC,
  }) {
    relay.onRelayClientMessage.broadcast(
      MessageEvent(
        topic,
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        0,
        null,
        TransportType.relay,
      ),
    );
  }

  Future<dynamic> send(int id, RequestPublicationController publication) {
    return client.request(
      requestId: id,
      topic: TEST_SESSION_VALID_TOPIC,
      chainId: TEST_ETHEREUM_CHAIN,
      request: const SessionRequestParams(method: 'personal_sign', params: []),
      publication: publication,
    );
  }

  test(
    'Sign forwards cancellation to the existing Core publication boundary',
    () async {
      final publication = RequestPublicationController()..cancel();
      await expectLater(
        send(1, publication),
        throwsA(isA<RequestPublicationCancelled>()),
      );
      expect(peer.requests, isEmpty);
    },
  );

  test(
    'Core cancellation during persistence prevents transport send',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      when(tracker.recordMessageEvent(any, any)).thenAnswer((_) async {
        entered.complete();
        await release.future;
      });
      final publication = RequestPublicationController();
      final result = core.pairing.sendRequest(
        TEST_SESSION_VALID_TOPIC,
        MethodConstants.WC_SESSION_REQUEST,
        {},
        id: 2,
        publication: publication,
      );
      final expectation = expectLater(
        result,
        throwsA(isA<RequestPublicationCancelled>()),
      );
      await entered.future;
      expect(publication.cancel(), isTrue);
      release.complete();
      await expectation;
      expect(peer.requests, isEmpty);
      expect((core.pairing as Pairing).pendingRequests, isEmpty);
    },
  );

  test(
    'Core retains the original response after cancellation following send',
    () async {
      final acknowledgement = Completer<bool>();
      peer.acknowledge = () => acknowledgement.future;
      final sent = peer.sent.stream.first;
      final publication = RequestPublicationController();
      final result = core.pairing.sendRequest(
        TEST_SESSION_VALID_TOPIC,
        MethodConstants.WC_SESSION_REQUEST,
        {},
        id: 3,
        publication: publication,
      );
      await sent;
      expect(publication.hasStarted, isTrue);
      expect(publication.cancel(), isFalse);
      expect(publication.isCancellationRequested, isTrue);
      expect(publication.throwIfCancelled, returnsNormally);
      respond(3, 'original response');
      expect(await result, 'original response');
      acknowledgement.complete(true);
    },
  );

  test(
    'Core late response and wrong-topic response cannot finish newer request',
    () async {
      final firstPublished = peer.sent.stream.first;
      final first = core.pairing.sendRequest(
        TEST_SESSION_VALID_TOPIC,
        MethodConstants.WC_SESSION_REQUEST,
        {},
        id: 4,
        publication: RequestPublicationController(),
      );
      await firstPublished;
      final secondPublished = peer.sent.stream.first;
      var secondFinished = false;
      final second = core.pairing
          .sendRequest(
            TEST_SESSION_VALID_TOPIC,
            MethodConstants.WC_SESSION_REQUEST,
            {},
            id: 5,
            publication: RequestPublicationController(),
          )
          .then((value) {
            secondFinished = true;
            return value;
          });
      await secondPublished;
      respond(5, 'wrong topic', topic: 'other-session');
      respond(4, 'first');
      expect(await first, 'first');
      expect(secondFinished, isFalse);
      respond(5, 'second');
      expect(await second, 'second');
    },
  );

  test('Sign deadline stops publication after awaited persistence', () async {
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2;
    final publication = RequestPublicationController(expiryTimestamp: expiry);
    final entered = Completer<void>();
    final release = Completer<void>();
    when(tracker.recordMessageEvent(any, any)).thenAnswer((_) async {
      entered.complete();
      await release.future;
    });
    final result = send(6, publication);
    final expectation = expectLater(result, throwsA(isA<TimeoutException>()));
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

  test(
    'Sign forwards exact request identity, deadline and bounded relay TTL',
    () async {
      final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60;
      final publication = RequestPublicationController(expiryTimestamp: expiry);
      final sent = peer.sent.stream.first;
      final result = send(7, publication);
      final relayRequest = await sent;
      await publication.acknowledged;
      final relayParams = relayRequest['params'] as Map<String, dynamic>;
      final payload = jsonDecode(relayParams['message'] as String);
      expect(payload['id'], 7);
      expect(payload['method'], MethodConstants.WC_SESSION_REQUEST);
      expect(payload['params']['chainId'], TEST_ETHEREUM_CHAIN);
      expect(payload['params']['request'], {
        'method': 'personal_sign',
        'params': [],
        'expiryTimestamp': expiry,
      });
      expect(relayParams['ttl'], inInclusiveRange(1, 60));
      respond(7, 'result');
      expect(await result, 'result');
    },
  );

  test(
    'Sign legacy request still publishes and completes without controls',
    () async {
      final sent = peer.sent.stream.first;
      final result = client.request(
        requestId: 8,
        topic: TEST_SESSION_VALID_TOPIC,
        chainId: TEST_ETHEREUM_CHAIN,
        request: const SessionRequestParams(
          method: 'personal_sign',
          params: [],
        ),
      );
      final relayRequest = await sent;
      final payload = jsonDecode(relayRequest['params']['message'] as String);
      expect(
        payload['params']['request'].containsKey('expiryTimestamp'),
        isFalse,
      );
      respond(8, 'legacy result');
      expect(await result, 'legacy result');
    },
  );

  test(
    'Sign cancellation during encoding prevents any transport send',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      when(crypto.encode(any, any, options: anyNamed('options'))).thenAnswer((
        invocation,
      ) async {
        entered.complete();
        await release.future;
        return jsonEncode(invocation.positionalArguments[1]);
      });
      final publication = RequestPublicationController();
      final result = send(9, publication);
      final expectation = expectLater(
        result,
        throwsA(isA<RequestPublicationCancelled>()),
      );
      await entered.future;
      expect(publication.cancel(), isTrue);
      release.complete();
      await expectation;
      expect(peer.requests, isEmpty);
      expect((core.pairing as Pairing).pendingRequests, isEmpty);
    },
  );

  test('Sign rejects expired publication before encoding', () async {
    final publication = RequestPublicationController(expiryTimestamp: 0);
    await expectLater(send(10, publication), throwsA(isA<TimeoutException>()));
    verifyNever(crypto.encode(any, any, options: anyNamed('options')));
    expect(peer.requests, isEmpty);
  });

  test('Sign uncertain publication retains the original response', () async {
    peer.acknowledge = () async => false;
    final sent = peer.sent.stream.first;
    final publication = RequestPublicationController();
    final result = send(11, publication);
    await sent;
    expect(publication.hasStarted, isTrue);
    expect(publication.cancel(), isFalse);
    respond(11, 'late result');
    expect(await result, 'late result');
    expect(peer.requests, hasLength(1));
  });

  test(
    'Sign refuses duplicate active request ID without replacing its owner',
    () async {
      final sent = peer.sent.stream.first;
      final original = send(12, RequestPublicationController());
      await sent;
      await expectLater(
        send(12, RequestPublicationController()),
        throwsA(isA<ReownCoreError>()),
      );
      respond(12, 'original');
      expect(await original, 'original');
      expect(peer.requests, hasLength(1));
    },
  );

  for (final expire in [false, true]) {
    test(
      'Sign ${expire ? 'expiry' : 'cancellation'} during reconnect prevents transport send',
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
        final result = send(13, publication);
        final expectation = expectLater(
          result,
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
}
