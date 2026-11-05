import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Serializes calls to an existing SDK storage without changing its format.
/// This does not associate SDK events with owners or authorize a session.
class SerialAuthLocalStorage extends LocalStorage {
  SerialAuthLocalStorage(this.delegate);
  final LocalStorage delegate;
  Future<void> _tail = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  /// Waits for calls already enqueued; it does not stop future SDK events.
  Future<void> drain() => _enqueue(() async {});

  @override
  Future<void> initialize() => _enqueue(delegate.initialize);
  @override
  Future<bool> hasAccessToken() => _enqueue(delegate.hasAccessToken);
  @override
  Future<String?> accessToken() => _enqueue(delegate.accessToken);
  @override
  Future<void> removePersistedSession() =>
      _enqueue(delegate.removePersistedSession);
  @override
  Future<void> persistSession(String persistSessionString) =>
      _enqueue(() => delegate.persistSession(persistSessionString));
}
