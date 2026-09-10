import 'dart:async';

/// Owns the last cancellable boundary of one outgoing relay request.
///
/// Cancellation only prevents publication before the transport send starts.
/// Neither a started send nor a relay acknowledgement proves wallet receipt,
/// approval, or transaction submission.
final class RequestPublicationController {
  bool _cancelled = false;
  bool _started = false;
  final Completer<void> _acknowledgement = Completer<void>();

  bool get hasStarted => _started;
  Future<void> get acknowledged => _acknowledgement.future;

  /// Returns true when this request can no longer be published.
  /// Returns false once a transport send may have made it remotely actionable.
  bool cancel() {
    if (_started) return false;
    _cancelled = true;
    return true;
  }

  void throwIfCancelled() {
    if (_cancelled) throw const RequestPublicationCancelled();
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
