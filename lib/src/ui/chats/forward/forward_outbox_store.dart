import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

import '../../../core/auth_session_scope.dart';
import '../core/forward_payload.dart';

/// A storage adapter may have changed its in-memory value even on failure.
abstract class ForwardOutboxStorage {
  Future<String?> read(String key);
  Future<bool> write(String key, String value);
  Future<bool> remove(String key);
}

class ForwardOutboxStorageFailure implements Exception {
  const ForwardOutboxStorageFailure();
}

class ForwardOutboxOccupied implements Exception {
  const ForwardOutboxOccupied();
}

enum ForwardAcknowledgeResult { removed, changed, missing }

class ForwardOutboxCoordinator {
  ForwardOutboxCoordinator(this.storage);
  final ForwardOutboxStorage storage;
  bool? _durableMode;
  void bindMode(bool durableMode) {
    if (_durableMode != null && _durableMode != durableMode) {
      throw StateError('Forward mode cannot change during process lifetime');
    }
    _durableMode = durableMode;
  }

  final _pending = <String, Future<void>>{};
  final _epochs = <String, int>{};
  final _quarantined = <String>{};
  final _autoApprovals = <String, (AuthOperationScope, bool Function())>{};

  void clearAutoApprovals() => _autoApprovals.clear();

  String _approvalKey(
          String backend, AuthOperationScope owner, String chat, String op) =>
      jsonEncode([backend, owner.userId, chat, op]);

  void recordAutoApproval(String backend, AuthOperationScope owner, String chat,
      String op, bool Function() sourceCurrent) {
    _autoApprovals[_approvalKey(backend, owner, chat, op)] =
        (owner, sourceCurrent);
    // An evicted proof only requires manual confirmation; it never drops the
    // persisted forward. Avoid retaining abandoned source screens indefinitely.
    while (_autoApprovals.length > 128) {
      _autoApprovals.remove(_autoApprovals.keys.first);
    }
  }

  bool Function()? consumeAutoApproval(
      String backend, AuthOperationScope owner, String chat, String op) {
    final proof = _autoApprovals.remove(_approvalKey(backend, owner, chat, op));
    if (proof == null || proof.$1 != owner) return null;
    bool current() {
      try {
        return proof.$2();
      } catch (_) {
        return false;
      }
    }

    return current() ? current : null;
  }

  Future<T> serial<T>(String key, Future<T> Function() work) {
    final result = Completer<T>();
    final prior = _pending[key] ?? Future<void>.value();
    late final Future<void> next;
    next = prior.then((_) async {
      try {
        result.complete(await work());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }).whenComplete(() {
      if (identical(_pending[key], next)) _pending.remove(key);
    });
    _pending[key] = next;
    return result.future;
  }
}

class ForwardOutboxEntry {
  const ForwardOutboxEntry._(
      this.text, this.files, this.fileIds, this._receipt);
  final String text;
  final List<String> files;
  final List<String> fileIds;
  final _ForwardReceipt _receipt;

  /// Fingerprints the exact serialized legacy version, including its nonce.
  String get migrationFingerprint =>
      sha256.convert(utf8.encode(_receipt.raw)).toString();
}

class _ForwardReceipt {
  const _ForwardReceipt(
      this.issuer, this.owner, this.key, this.raw, this.epoch);
  final Object issuer;
  final AuthOperationScope owner;
  final String key;
  final String raw;
  final int epoch;
}

/// Standalone single-slot store. All writers must share one coordinator;
/// this does not yet change composer or message sending behavior.
class ForwardOutboxStore {
  ForwardOutboxStore(this.scope, this.coordinator);
  final AuthSessionScope scope;
  final ForwardOutboxCoordinator coordinator;
  final Object _issuer = Object();
  final Random _random = Random.secure();
  bool _disposed = false;

  void dispose() => _disposed = true;

  bool _isCurrent(AuthOperationScope owner) =>
      !_disposed && scope.isCurrent(owner);

  String _key(AuthOperationScope owner, String chatId) =>
      'forward_outbox_${owner.userId}_$chatId';

  void _check(AuthOperationScope owner, String key) {
    if (!_isCurrent(owner)) throw StateError('Session changed');
    if (coordinator._quarantined.contains(key)) {
      throw const ForwardOutboxStorageFailure();
    }
  }

  String _newVersion() => List.generate(24, (_) => _random.nextInt(256))
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join();

  /// Reserves an empty slot without replacing even an unreadable old entry.
  /// This is an isolated preparation API; it does not start uploads or send.
  Future<void> putIfVacant(AuthOperationScope owner, String chatId,
      {required String text,
      List<String> files = const [],
      List<String> fileIds = const []}) {
    if (chatId.trim().isEmpty) throw const FormatException('Missing chat');
    if (ForwardPayload.isForwardText(text) &&
        ForwardPayload.tryParse(text) == null) {
      throw const FormatException('Invalid forward payload');
    }
    final capturedFiles = List<String>.of(files);
    final capturedIds = List<String>.of(fileIds);
    final key = _key(owner, chatId.trim());
    return coordinator.serial(key, () async {
      _check(owner, key);
      final previous = await _read(key);
      _check(owner, key);
      if (previous != null) throw const ForwardOutboxOccupied();
      final raw = jsonEncode({
        'version': _newVersion(),
        'text': text,
        'files': capturedFiles,
        'file_ids': capturedIds,
      });
      await _mutate(key, null, () => coordinator.storage.write(key, raw));
      if (!_isCurrent(owner)) {
        await _restore(key, null);
        throw StateError('Session changed');
      }
    });
  }

  Future<void> put(AuthOperationScope owner, String chatId,
      {required String text,
      List<String> files = const [],
      List<String> fileIds = const []}) {
    if (ForwardPayload.isForwardText(text) &&
        ForwardPayload.tryParse(text) == null) {
      throw const FormatException('Invalid forward payload');
    }
    final capturedFiles = List<String>.of(files);
    final capturedIds = List<String>.of(fileIds);
    final key = _key(owner, chatId);
    return coordinator.serial(key, () async {
      _check(owner, key);
      final previous = await _read(key);
      _check(owner, key);
      final raw = jsonEncode({
        'version': _newVersion(),
        'text': text,
        'files': capturedFiles,
        'file_ids': capturedIds
      });
      await _mutate(key, previous, () => coordinator.storage.write(key, raw));
      if (!_isCurrent(owner)) {
        await _restore(key, previous);
        throw StateError('Session changed');
      }
    });
  }

  Future<ForwardOutboxEntry?> peek(AuthOperationScope owner, String chatId) {
    final key = _key(owner, chatId);
    return coordinator.serial(key, () async {
      _check(owner, key);
      final raw = await _read(key);
      _check(owner, key);
      if (raw == null || raw.isEmpty) return null;
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        if (!map.containsKey('text') &&
            !map.containsKey('files') &&
            !map.containsKey('file_ids')) return null;
        if (map.containsKey('version') &&
            (map['version'] is! String ||
                !RegExp(r'^[0-9a-f]{48}$').hasMatch(map['version'] as String)))
          return null;
        final text = (map['text'] as String?) ?? '';
        if (ForwardPayload.isForwardText(text) &&
            ForwardPayload.tryParse(text) == null) return null;
        List<String> values(String name) => (map[name] as List? ?? const [])
            .map((e) => (e ?? '').toString())
            .where((e) => e.isNotEmpty)
            .toList();
        return ForwardOutboxEntry._(
            text,
            List.unmodifiable(values('files')),
            List.unmodifiable(values('file_ids')),
            _ForwardReceipt(
                _issuer, owner, key, raw, coordinator._epochs[key] ?? 0));
      } catch (_) {
        return null;
      }
    });
  }

  /// An unreadable entry is still occupied and must never be overwritten.
  Future<bool> hasAny(AuthOperationScope owner, String chatId) {
    final key = _key(owner, chatId);
    return coordinator.serial(key, () async {
      _check(owner, key);
      final raw = await _read(key);
      _check(owner, key);
      return raw != null;
    });
  }

  Future<ForwardAcknowledgeResult> acknowledge(ForwardOutboxEntry entry) {
    final receipt = entry._receipt;
    if (!identical(receipt.issuer, _issuer))
      return Future.value(ForwardAcknowledgeResult.changed);
    return coordinator.serial(receipt.key, () async {
      _check(receipt.owner, receipt.key);
      if ((coordinator._epochs[receipt.key] ?? 0) != receipt.epoch)
        return ForwardAcknowledgeResult.changed;
      final previous = await _read(receipt.key);
      _check(receipt.owner, receipt.key);
      if (previous == null) return ForwardAcknowledgeResult.missing;
      if (previous != receipt.raw) return ForwardAcknowledgeResult.changed;
      await _mutate(
          receipt.key, previous, () => coordinator.storage.remove(receipt.key));
      if (!_isCurrent(receipt.owner)) {
        await _restore(receipt.key, previous);
        throw StateError('Session changed');
      }
      return ForwardAcknowledgeResult.removed;
    });
  }

  Future<String?> _read(String key) async {
    try {
      return await coordinator.storage.read(key);
    } catch (_) {
      throw const ForwardOutboxStorageFailure();
    }
  }

  Future<void> _mutate(
      String key, String? previous, Future<bool> Function() change) async {
    coordinator._epochs[key] = (coordinator._epochs[key] ?? 0) + 1;
    try {
      if (await change()) return;
    } catch (_) {}
    await _restore(key, previous);
    throw const ForwardOutboxStorageFailure();
  }

  Future<void> _restore(String key, String? previous) async {
    // Recovery is best effort: quarantine if the old bytes cannot be restored.
    try {
      final restored = previous == null
          ? await coordinator.storage.remove(key)
          : await coordinator.storage.write(key, previous);
      if (!restored || await coordinator.storage.read(key) != previous) {
        coordinator._quarantined.add(key);
        throw const ForwardOutboxStorageFailure();
      }
    } catch (_) {
      coordinator._quarantined.add(key);
      throw const ForwardOutboxStorageFailure();
    }
  }
}
