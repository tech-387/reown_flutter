import 'package:event/event.dart';
import 'package:reown_core/reown_core.dart';
import 'package:reown_sign/i_sign_common.dart';
import 'package:reown_sign/reown_sign.dart';

abstract class IReownSignDapp extends IReownSignCommon {
  abstract final Event<SessionUpdate> onSessionUpdate;
  abstract final Event<SessionExtend> onSessionExtend;
  abstract final Event<SessionEvent> onSessionEvent;
  abstract final Event<SessionAuthResponse> onSessionAuthResponse;

  Future<ConnectResponse> connect({
    @Deprecated(
      'requiredNamespaces are automatically assigned to optionalNamespaces. Considering using only optionalNamespaces',
    )
    Map<String, RequiredNamespace>? requiredNamespaces,
    Map<String, RequiredNamespace>? optionalNamespaces,
    Map<String, String>? sessionProperties,
    String? pairingTopic,
    List<Relay>? relays,
    List<SessionAuthRequestParams>? authentication,
    List<List<String>>? methods,
    RequestPublicationController? publication,
    int? requestId,
  });

  /// Requests a wallet operation. Use a fresh [requestId] for each operation,
  /// or omit it to generate one. [publication] is single-use and relay-only;
  /// its optional expiry is an absolute Unix timestamp in seconds.
  /// Cancelling after sending retains the original response future and does
  /// not undo a wallet or blockchain operation.
  Future<dynamic> request({
    int? requestId,
    RequestPublicationController? publication,
    required String topic,
    required String chainId,
    required SessionRequestParams request,
  });

  void registerEventHandler({
    required String chainId,
    required String event,
    dynamic Function(String, dynamic)? handler,
  });
  Future<void> ping({required String topic});

  Future<SessionAuthRequestResponse> authenticate({
    required SessionAuthRequestParams params,
    String? walletUniversalLink,
    String? pairingTopic,
    List<List<String>>? methods,
  });

  Future<bool> redirectToWallet({
    required String topic,
    required Redirect? redirect,
  });
}
