import 'dart:async';

/// Tracks operations dispatched by one verified online session. Closing is
/// synchronous; a timed-out drain never reopens the barrier or forgets work.
class OnlineSideEffectBarrier {
  OnlineSideEffectBarrier({required bool Function() ownerIsCurrent})
      : _ownerIsCurrent = ownerIsCurrent;
  final bool Function() _ownerIsCurrent;
  bool _closed = false;
  int _active = 0;
  final List<Completer<void>> _drainers = [];
  final List<void Function()> _closeHooks = [];
  bool _teardownFailed = false;
  bool _drainSealed = false;

  bool get isOpen {
    if (_closed) return false;
    try {
      final current = _ownerIsCurrent();
      if (!current) close();
      return current;
    } catch (_) {
      close();
      return false;
    }
  }

  int get activeCount => _active;

  /// Returns null without dispatch if access is no longer valid.
  Future<T?> run<T>(Future<T> Function() dispatch) async {
    if (!isOpen) return null;
    _active++;
    try {
      final result = await dispatch();
      return isOpen ? result : null;
    } finally {
      _active--;
      if (_active == 0) {
        final waiters = List<Completer<void>>.of(_drainers);
        _drainers.clear();
        for (final waiter in waiters) {
          waiter.complete();
        }
      }
    }
  }

  /// Register teardown synchronously before the owner calls closeAndDrain.
  /// Unlike new work, teardown may be registered after the permit is revoked.
  Future<void> trackTeardown(Future<void> Function() teardown) async {
    if (_drainSealed) {
      _teardownFailed = true;
      return;
    }
    _active++;
    try {
      await teardown();
    } catch (_) {
      _teardownFailed = true;
    } finally {
      _active--;
      if (_active == 0) {
        final waiters = List<Completer<void>>.of(_drainers);
        _drainers.clear();
        for (final waiter in waiters) {
          waiter.complete();
        }
      }
    }
  }

  /// Close hooks must synchronously register their asynchronous teardown.
  void Function() onClose(void Function() hook) {
    if (_closed) {
      try {
        hook();
      } catch (_) {
        _teardownFailed = true;
      }
      return () {};
    }
    _closeHooks.add(hook);
    return () => _closeHooks.remove(hook);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final hooks = List<void Function()>.of(_closeHooks);
    _closeHooks.clear();
    for (final hook in hooks) {
      try {
        hook();
      } catch (_) {
        _teardownFailed = true;
      }
    }
  }

  Future<bool> closeAndDrain({required Duration timeout}) async {
    close();
    final clock = Stopwatch()..start();
    while (_active > 0) {
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) return false;
      final done = Completer<void>();
      _drainers.add(done);
      try {
        await done.future.timeout(remaining);
      } on TimeoutException {
        _drainers.remove(done);
        return false;
      }
    }
    _drainSealed = true;
    return !_teardownFailed;
  }
}
