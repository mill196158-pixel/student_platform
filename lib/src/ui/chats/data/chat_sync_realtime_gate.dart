/// Serializes Realtime mutations against an in-flight page sync for one chat.
///
/// While [runExclusiveSync] (or a flush) is active, upsert/delete ops are
/// queued. After the sync body finishes (success or error), the queue is
/// drained; events that arrive during the drain are kept and drained again
/// until empty.
class ChatSyncRealtimeGate {
  ChatSyncRealtimeGate({
    required this.applyUpsert,
    required this.applyDelete,
  });

  final Future<void> Function(String messageId) applyUpsert;
  final Future<void> Function(String messageId) applyDelete;

  bool _syncing = false;
  bool _flushing = false;
  final List<_BufferedOp> _buffer = <_BufferedOp>[];

  bool get isSyncing => _syncing;
  bool get isFlushing => _flushing;
  bool get isBusy => _syncing || _flushing;

  /// Message ids whose latest buffered op is DELETE (page must not resurrect).
  Set<String> get pendingDeleteTombstones {
    final tombs = <String>{};
    for (final op in _buffer) {
      if (op.isDelete) {
        tombs.add(op.messageId);
      } else {
        tombs.remove(op.messageId);
      }
    }
    return tombs;
  }

  /// Ordered buffer snapshot (for tests).
  List<({bool isDelete, String messageId})> get debugBuffer => _buffer
      .map((op) => (isDelete: op.isDelete, messageId: op.messageId))
      .toList(growable: false);

  Future<T> runExclusiveSync<T>(Future<T> Function() body) async {
    if (_syncing) {
      throw StateError('nested runExclusiveSync is not supported');
    }
    _syncing = true;
    try {
      return await body();
    } finally {
      _syncing = false;
      await _drainBuffer();
    }
  }

  Future<void> handleUpsert(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    if (isBusy) {
      _buffer.add(_BufferedOp.upsert(id));
      return;
    }
    await applyUpsert(id);
  }

  Future<void> handleDelete(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    if (isBusy) {
      // Tombstone is recorded immediately in the ordered buffer.
      _buffer.add(_BufferedOp.delete(id));
      return;
    }
    await applyDelete(id);
  }

  Future<void> _drainBuffer() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_buffer.isNotEmpty) {
        final batch = List<_BufferedOp>.from(_buffer);
        _buffer.clear();
        for (final op in batch) {
          if (op.isDelete) {
            await applyDelete(op.messageId);
          } else {
            await applyUpsert(op.messageId);
          }
        }
      }
    } finally {
      _flushing = false;
    }
    // Events that arrived after the last batch check but while still flushing
    // remain in the buffer — drain again until idle.
    if (_buffer.isNotEmpty) {
      await _drainBuffer();
    }
  }
}

class _BufferedOp {
  const _BufferedOp._(this.messageId, this.isDelete);

  factory _BufferedOp.upsert(String messageId) =>
      _BufferedOp._(messageId, false);

  factory _BufferedOp.delete(String messageId) =>
      _BufferedOp._(messageId, true);

  final String messageId;
  final bool isDelete;
}
