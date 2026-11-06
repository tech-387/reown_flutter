import 'package:reown_core/reown_core.dart';
import 'package:reown_sign/i_sign_dapp.dart';
import 'package:reown_sign/i_sign_wallet.dart';
import 'package:reown_sign/reown_sign.dart';

abstract class IReownSign implements IReownSignWallet, IReownSignDapp {
  Future<void> checkAndExpire();

  /// [publication] can stop the proposal before its relay send and reports
  /// the relay's acknowledgement; [requestId] sets the proposal's ID.
  @override
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

  /// [publication] can stop the request before its relay send and reports the
  /// relay's acknowledgement. Its expiry is also sent to the wallet as the
  /// request's `expiryTimestamp`. Cancelling after the send started keeps the
  /// original response future.
  @override
  Future<dynamic> request({
    int? requestId,
    required String topic,
    required String chainId,
    required SessionRequestParams request,
    RequestPublicationController? publication,
  });
}
