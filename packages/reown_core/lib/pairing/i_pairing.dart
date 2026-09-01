import 'package:event/event.dart';
import 'package:reown_core/crypto/crypto_models.dart';
import 'package:reown_core/models/json_rpc_models.dart';
import 'package:reown_core/models/tvf_data.dart';

import 'package:reown_core/pairing/i_pairing_store.dart';
import 'package:reown_core/pairing/utils/pairing_models.dart';
import 'package:reown_core/relay_client/relay_client_models.dart';

abstract class IPairing {
  abstract final Event<PairingEvent> onPairingCreate;
  abstract final Event<PairingActivateEvent> onPairingActivate;
  abstract final Event<PairingEvent> onPairingPing;
  abstract final Event<PairingInvalidEvent> onPairingInvalid;
  abstract final Event<PairingEvent> onPairingDelete;
  abstract final Event<PairingEvent> onPairingExpire;

  /// Emits after the relay acknowledges a relay-mode [sendRequest].
  ///
  /// This does not mean the wallet received or answered the request. Link Mode
  /// requests do not emit this event.
  abstract final Event<RelayRequestPublishedEvent> onRelayRequestPublished;

  Future<void> init();
  Future<PairingInfo> pair({required Uri uri, bool activatePairing});
  Future<CreateResponse> create({
    List<List<String>>? methods,
    TransportType transportType = TransportType.relay,
  });
  Future<void> activate({required String topic});
  void register({
    required String method,
    required Function(String, JsonRpcRequest, [String?, TransportType])
    function,
    required ProtocolType type,
  });
  Future<void> setReceiverPublicKey({
    required String topic,
    required String publicKey,
    int? expiry,
  });
  Future<void> updateExpiry({required String topic, required int expiry});
  Future<void> updateMetadata({
    required String topic,
    required PairingMetadata metadata,
  });
  Future<void> checkAndExpire();
  List<PairingInfo> getPairings();
  PairingInfo? getPairing({required String topic});
  Future<void> ping({required String topic});
  Future<void> disconnect({required String topic});
  IPairingStore getStore();

  Future<dynamic> sendRequest(
    String topic,
    String method,
    Map<String, dynamic> params, {
    int? id,
    int? ttl,
    EncodeOptions? encodeOptions,
    String? appLink,
    bool openUrl = true,
    TVFData? tvf,
  });

  /// Restores the response waiter for an already-published request.
  ///
  /// This never publishes a request. Calling it repeatedly for the same topic,
  /// request ID, and method returns the same response future. A conflicting
  /// request identity throws instead of attaching to the wrong response.
  Future<dynamic> restorePendingResponse({
    required String topic,
    required int requestId,
    required String method,
  });

  /// Returns valid JSON-RPC envelopes recorded for [topic].
  ///
  /// Storage access and decryption stay inside Reown. Invalid or undecryptable
  /// history entries are logged and omitted without blocking valid entries.
  Future<List<Map<String, dynamic>>> getDecodedMessageHistory({
    required String topic,
  });

  /// Whether a peer error proves that its pending request has settled.
  bool isTerminalPendingResponseError(JsonRpcError error);

  /// Removes only the pending response waiter matching the exact request.
  ///
  /// This does not cancel or publish anything. It is intended for callers that
  /// have independently proved the original request terminal.
  bool forgetPendingResponse({
    required String topic,
    required int requestId,
    required String method,
  });

  Future<dynamic> sendProposeSessionRequest(
    String topic,
    Map<String, dynamic> params, {
    int? id,
    EncodeOptions? encodeOptions,
  });

  Future<void> sendResult(
    int id,
    String topic,
    String method,
    dynamic result, {
    EncodeOptions? encodeOptions,
    String? appLink,
    TVFData? tvf,
  });

  Future<void> sendError(
    int id,
    String topic,
    String method,
    JsonRpcError error, {
    EncodeOptions? encodeOptions,
    RpcOptions? rpcOptions,
    String? appLink,
    TVFData? tvf,
  });

  Future<dynamic> sendApproveSessionRequest(
    String sessionTopic,
    String pairingTopic, {
    required int responseId,
    required Map<String, dynamic> sessionProposalResponse,
    required Map<String, dynamic> sessionSettlementRequest,
    EncodeOptions? encodeOptions,
    List<String>? approvedChains,
    List<String>? approvedMethods,
    List<String>? approvedEvents,
    Map<String, String>? sessionProperties,
  });

  Future<void> isValidPairingTopic({required String topic});

  void dispatchEnvelope({required String topic, required String envelope});
}
