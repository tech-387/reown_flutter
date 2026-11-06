import 'dart:async';

/// Controls one outgoing relay request up to its transport send: it can stop
/// the request before the send starts, and reports the relay's acknowledgement.
/// Neither a started send nor an acknowledgement proves that the wallet
/// received, approved or submitted anything. Use a fresh controller per request.
final class RequestPublicationController {
  RequestPublicationController({this.expiryTimestamp});

  /// Unix time in seconds from which the send must not start.
  final int? expiryTimestamp;

  bool _cancelled = false;
  bool _started = false;
  final _acknowledged = Completer<void>();

  /// Whether the transport send started, so the request may have been sent.
  bool get hasStarted => _started;

  /// Completes when the relay positively acknowledges the request.
  Future<void> get acknowledged => _acknowledged.future;

  /// Stops a send that has not started. Returns true when the request can no
  /// longer be sent, false when it may already have been.
  bool cancel() {
    _cancelled = true;
    return !_started;
  }

  /// Marks the send as started. Call it right before the transport send, with
  /// no await in between. Throws when the request was cancelled or expired.
  void beginSend() {
    if (_cancelled) throw const RequestPublicationCancelled();
    final expiry = expiryTimestamp;
    if (expiry != null &&
        DateTime.now().millisecondsSinceEpoch >= expiry * 1000) {
      throw TimeoutException('Request expired before its transport send.');
    }
    _started = true;
  }

  /// Records the relay's positive acknowledgement.
  void acknowledge() {
    if (!_acknowledged.isCompleted) _acknowledged.complete();
  }
}

/// The request was stopped before its transport send started.
final class RequestPublicationCancelled implements Exception {
  const RequestPublicationCancelled();

  @override
  String toString() => 'Request publication cancelled before transport send.';
}
