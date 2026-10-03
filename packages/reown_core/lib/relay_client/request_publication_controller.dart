import 'dart:async';

/// Owns the last cancellable boundary of one outgoing relay request.
/// Create a fresh controller for each request.
///
/// Cancellation only prevents publication before the transport send starts.
/// Neither a started send nor a relay acknowledgement proves wallet receipt,
/// approval, or transaction submission.
final class RequestPublicationController {
  /// Absolute Unix timestamp in seconds after which publication must not start.
  final int? expiryTimestamp;

  RequestPublicationController({this.expiryTimestamp});

  bool _cancelled = false;
  bool _started = false;
  final Completer<void> _acknowledgement = Completer<void>();

  bool get hasStarted => _started;

  /// Local cancellation intent, including cancellation after publication.
  bool get isCancellationRequested => _cancelled;
  Future<void> get acknowledged => _acknowledgement.future;

  /// Returns true when this request can no longer be published.
  /// Returns false once a transport send may have made it remotely actionable.
  bool cancel() {
    _cancelled = true;
    return !_started;
  }

  void throwIfCancelled() {
    if (_started) return;
    if (_cancelled) throw const RequestPublicationCancelled();
    final expiry = expiryTimestamp;
    if (expiry != null &&
        DateTime.now().millisecondsSinceEpoch >= expiry * 1000) {
      throw TimeoutException('Request expired before transport send.');
    }
  }

  /// Called synchronously immediately before the transport send, without any
  /// intervening await. Public for custom relay implementations.
  void beginSend() {
    throwIfCancelled();
    _started = true;
  }

  void acknowledge() {
    if (!_acknowledgement.isCompleted) _acknowledgement.complete();
  }
}

/// This request was stopped before its transport send could begin.
final class RequestPublicationCancelled implements Exception {
  const RequestPublicationCancelled();

  @override
  String toString() => 'Request publication cancelled before transport send.';
}
