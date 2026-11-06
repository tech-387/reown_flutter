import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:reown_core/relay_client/json_rpc_2/src/peer.dart';
import 'package:reown_core/relay_client/relay_client.dart';
import 'package:reown_core/reown_core.dart';

import 'shared/shared_test_utils.dart';
import 'shared/shared_test_utils.mocks.dart';

/// Accepts every relay publish; the test plays the wallet's replies.
class _AcceptingPeer extends Fake implements Peer {
  @override
  bool get isClosed => false;

  @override
  Future<dynamic> sendRequest(
    String method, [
    dynamic parameters,
    int? id,
  ]) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  mockPackageInfo();
  mockConnectivity();

  const topic = 'pending-response-topic';
  late ReownCore core;
  late RelayClient relay;

  setUp(() async {
    final socket = MockWebSocketHandler();
    when(socket.connect()).thenThrow(StateError('Controlled transport only'));
    core = ReownCore(
      projectId: 'controlled-test',
      memoryStore: true,
      httpClient: getHttpWrapper(),
    );
    final crypto = MockCrypto();
    when(crypto.signJWT(any)).thenAnswer((_) async => 'controlled-jwt');
    when(crypto.encode(any, any, options: anyNamed('options'))).thenAnswer(
      (invocation) async => jsonEncode(invocation.positionalArguments[1]),
    );
    when(crypto.decode(any, any, options: anyNamed('options'))).thenAnswer(
      (invocation) async => invocation.positionalArguments[1] as String,
    );
    core.crypto = crypto;
    relay = RelayClient(
      core: core,
      messageTracker: MockMessageTracker(),
      topicMap: getTopicMap(core: core),
      socketHandler: socket,
    );
    core.relayClient = relay;
    await core.storage.init();
    await relay.init();
    relay.jsonRPC = _AcceptingPeer();
    await core.pairing.init();
  });

  void reply(int id, Map<String, dynamic> body) {
    relay.onRelayClientMessage.broadcast(
      MessageEvent(
        topic,
        jsonEncode({'jsonrpc': '2.0', 'id': id, ...body}),
        0,
        null,
        TransportType.relay,
      ),
    );
  }

  Map<String, dynamic> error(int code, String message) => {
    'error': {'code': code, 'message': message},
  };

  final spuriousErrors = {
    'code 1': error(1, 'Invalid Id'),
    'code -32002': error(-32002, 'Request already pending'),
    'code 1 in a 5000 envelope': error(
      5000,
      jsonEncode({'code': 1, 'message': 'Invalid Id'}),
    ),
    'code -32002 in a 5000 envelope': error(
      5000,
      jsonEncode({'code': -32002, 'message': 'Request already pending'}),
    ),
  };

  for (final MapEntry(key: name, value: spurious) in spuriousErrors.entries) {
    test('$name before the real answer leaves the request pending', () async {
      const id = 1001;
      var settled = false;
      final response = core.pairing
          .sendRequest(topic, MethodConstants.WC_SESSION_REQUEST, {}, id: id)
          .whenComplete(() => settled = true);
      await pumpEventQueue();

      reply(id, spurious);
      await pumpEventQueue();
      expect(settled, isFalse);

      reply(id, {'result': '0xhash'});
      expect(await response, '0xhash');
    });
  }

  test('a rejection after a spurious error still ends the request', () async {
    const id = 1002;
    final response = core.pairing.sendRequest(
      topic,
      MethodConstants.WC_SESSION_REQUEST,
      {},
      id: id,
    );
    await pumpEventQueue();

    reply(id, error(-32002, 'Request already pending'));
    await pumpEventQueue();
    // A 5000 error whose message is plain text keeps its terminal code.
    reply(id, error(5000, 'User rejected.'));
    await expectLater(
      response,
      throwsA(isA<JsonRpcError>().having((e) => e.code, 'code', 5000)),
    );
  });
}
