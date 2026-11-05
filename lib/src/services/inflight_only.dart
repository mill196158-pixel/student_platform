import 'dart:async';

/// Joins only work currently running. Settled values are never retained.
class InflightOnly<K, V> {
  final Map<K, Future<V>> _pending = {};

  Future<V> run(K key, Future<V> Function() action) {
    final existing = _pending[key];
    if (existing != null) return existing;
    final result = Completer<V>();
    final published = result.future;
    _pending[key] = published;
    Future<V>.sync(action).then<void>((value) {
      if (identical(_pending[key], published)) _pending.remove(key);
      result.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (identical(_pending[key], published)) _pending.remove(key);
      result.completeError(error, stack);
    });
    return published;
  }

  /// Does not cancel running work; callers must still fence its result.
  void clear() => _pending.clear();
}
