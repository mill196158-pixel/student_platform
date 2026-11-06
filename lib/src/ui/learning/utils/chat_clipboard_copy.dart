import 'dart:typed_data';

/// Serializes native writes started here. A newer copy invalidates older work
/// that has not reached the platform, and wins after an in-flight write.
class ChatClipboardCopyCoordinator {
  int _revision = 0;
  Future<void> _queue = Future<void>.value();

  Future<void> copyFile({
    required bool Function() isCurrent,
    required Future<Uint8List> Function() readBytes,
    required Future<void> Function(Uint8List) write,
  }) async {
    final revision = ++_revision;
    bool current() => revision == _revision && isCurrent();
    if (!current()) throw StateError('Сессия изменилась.');
    final bytes = await readBytes();
    if (!current()) throw StateError('Сессия изменилась.');
    await _serialize(() async {
      if (!current()) throw StateError('Сессия изменилась.');
      await write(bytes);
      if (!current()) throw StateError('Сессия изменилась.');
    });
  }

  Future<void> copyText({
    required bool Function() isCurrent,
    required Future<void> Function() write,
  }) {
    final revision = ++_revision;
    bool current() => revision == _revision && isCurrent();
    return _serialize(() async {
      if (!current()) throw StateError('Сессия изменилась.');
      await write();
      if (!current()) throw StateError('Сессия изменилась.');
    });
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }
}
