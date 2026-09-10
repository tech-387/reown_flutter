import 'package:event/event.dart';
import 'package:reown_core/models/basic_models.dart';
import 'package:reown_core/relay_client/relay_client_models.dart';
import 'package:reown_core/relay_client/request_publication_controller.dart';

abstract class IRelayClient {
  /// Relay Client Events
  abstract final Event onRelayClientConnect;
  abstract final Event onRelayClientDisconnect;
  abstract final Event<ErrorEvent> onRelayClientError;
  abstract final Event<MessageEvent> onRelayClientMessage;

  /// LinkMode Events
  abstract final Event<MessageEvent> onLinkModeMessage;

  /// JSON RPC Events
  // Event<EventArgs> onJsonRpcPayload();
  // Event<EventArgs> onJsonRpcConnect();
  // Event<EventArgs> onJsonRpcDisconnect();
  // Event<ErrorEvent> onJsonRpcError();

  /// Subscriber Events
  abstract final Event<SubscriptionEvent> onSubscriptionCreated;
  abstract final Event<SubscriptionDeletionEvent> onSubscriptionDeleted;
  // Event<EventArgs> onSubscriptionExpired();
  // Event<EventArgs> onSubscriptionDisabled();
  abstract final Event onSubscriptionSync;
  abstract final Event onSubscriptionResubscribed;

  /// Returns true if the client is connected to a relay server
  bool get isConnected;

  Future<void> init();

  Future<void> publish({
    required String topic,
    required String message,
    required PublishOptions options,
  });
  // TODO we should consider having just one publish method and parse topic/message or payload based on options.publishMethod
  Future<void> publishPayload({
    required Map<String, dynamic> payload,
    required PublishOptions options,
  });

  Future<String> subscribe({required SubscribeOptions options});

  Future<void> unsubscribe({required String topic});

  Future<void> connect({String? relayUrl});

  Future<bool> handleLinkModeMessage(String topic, String message);

  Future<void> disconnect();
}

/// Optional relay capability that reports whether publication was accepted.
///
/// It is separate from [IRelayClient] so existing custom relay implementations
/// remain source-compatible.
abstract interface class IAcknowledgedRelayClient {
  /// Publishes [message] and waits for the relay's JSON-RPC acknowledgement.
  ///
  /// Returns `true` only for a successful relay acknowledgement. A `true`
  /// result does not mean that a wallet received or answered the request.
  Future<bool> publishAcknowledged({
    required String topic,
    required String message,
    required PublishOptions options,
  });
}

/// Optional relay capability for cancellation at the actual transport boundary.
/// Existing custom relay implementations remain source-compatible.
abstract interface class ICancellableRelayClient {
  Future<bool> publishCancellable({
    required String topic,
    required String message,
    required PublishOptions options,
    required RequestPublicationController publication,
  });

  Future<void> publishPayloadCancellable({
    required Map<String, dynamic> payload,
    required PublishOptions options,
    required RequestPublicationController publication,
  });
}
