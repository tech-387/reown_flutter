import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reown_appkit/reown_appkit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ReownAppKit appKit;
  late _Sign sign;

  setUp(() {
    appKit = ReownAppKit(
      core: ReownCore(projectId: '', memoryStore: true),
      metadata: const PairingMetadata(
        name: 'Test',
        description: '',
        url: 'https://example.com',
        icons: [],
      ),
    );
    sign = _Sign();
    appKit.reOwnSign = sign;
  });

  test('connect already forwards publication and request ID', () async {
    final publication = RequestPublicationController();
    final response = await appKit.connect(
      publication: publication,
      requestId: 123,
    );
    expect(response, same(sign.connection));
    expect(sign.publication, same(publication));
    expect(sign.requestId, 123);
  });

  test('request forwards publication, ID, and original arguments', () async {
    final publication = RequestPublicationController();
    const request = SessionRequestParams(method: 'personal_sign', params: []);
    final IReownAppKit client = appKit;
    final result = await client.request(
      publication: publication,
      requestId: 456,
      topic: 'original-topic',
      chainId: 'eip155:1',
      request: request,
    );
    expect(result, 'original-response');
    expect(sign.publication, same(publication));
    expect(sign.requestId, 456);
    expect(sign.topic, 'original-topic');
    expect(sign.chainId, 'eip155:1');
    expect(sign.params, same(request));
  });
}

class _Sign extends Fake implements IReownSign {
  final connection = ConnectResponse(
    pairingTopic: 'pairing',
    session: Completer<SessionData>(),
  );
  RequestPublicationController? publication;
  int? requestId;
  String? topic;
  String? chainId;
  SessionRequestParams? params;

  @override
  Future<ConnectResponse> connect({
    Map<String, RequiredNamespace>? requiredNamespaces,
    Map<String, RequiredNamespace>? optionalNamespaces,
    Map<String, String>? sessionProperties,
    String? pairingTopic,
    List<Relay>? relays,
    List<SessionAuthRequestParams>? authentication,
    List<List<String>>? methods,
    RequestPublicationController? publication,
    int? requestId,
  }) async {
    this.publication = publication;
    this.requestId = requestId;
    return connection;
  }

  @override
  Future<dynamic> request({
    int? requestId,
    required String topic,
    required String chainId,
    required SessionRequestParams request,
    RequestPublicationController? publication,
  }) async {
    this.publication = publication;
    this.requestId = requestId;
    this.topic = topic;
    this.chainId = chainId;
    params = request;
    return 'original-response';
  }
}
