// FILE: lib/src/ui/chats/forward/forward_outbox.dart
import 'dart:convert';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/auth_session_scope.dart';
import '../core/forward_payload.dart';
import 'forward_outbox_host.dart';
import 'forward_outbox_store.dart';
import 'forward_send_gate.dart';
import 'durable_forward_outbox.dart';

class ForwardOutboxData {
  final String? text;
  final List<String> fileUrls;
  final List<String> fileIds;
  ForwardOutboxData({this.text, required this.fileUrls, required this.fileIds});
}

class LegacyForwardProvenanceUnknown implements Exception {
  const LegacyForwardProvenanceUnknown();
}

/// Keep the source selection intact until the handoff has succeeded.
Future<bool> completeForwardHandoff(
    {required Future<void> Function() prepare,
    required bool Function() isCurrent,
    VoidCallback? onPrepared}) async {
  await prepare();
  if (!isCurrent()) return false;
  onPrepared?.call();
  return true;
}

class ForwardOutbox {
  static ForwardOutboxSession? capture(BuildContext context) {
    final store = ForwardOutboxHost.maybeRead(context);
    final owner = store?.scope.capture();
    if (store == null || owner == null) return null;
    return ForwardOutboxSession._(
        store,
        owner,
        ForwardOutboxHost.usesDurable(context),
        () =>
            context.mounted &&
            identical(ForwardOutboxHost.maybeRead(context), store));
  }
  // Compatibility parser for historical entries. Production consumers use
  // the session-scoped store; this method exists for legacy validation tests.

  /// Validates before removing so unreadable queued data is not discarded.
  @visibleForTesting
  static Future<ForwardOutboxData?> readAndConsume(
      SharedPreferences prefs, String key, bool Function() isCurrent) async {
    if (!isCurrent()) return null;
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    late final ForwardOutboxData result;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (!map.containsKey('text') &&
          !map.containsKey('files') &&
          !map.containsKey('file_ids')) return null;
      final text = (map['text'] as String?) ?? '';
      if (ForwardPayload.isForwardText(text) &&
          ForwardPayload.tryParse(text) == null) return null;
      final files = (map['files'] as List?)
              ?.map((e) => (e ?? '').toString())
              .where((s) => s.isNotEmpty)
              .toList() ??
          const <String>[];
      final ids = (map['file_ids'] as List?)
              ?.map((e) => (e ?? '').toString())
              .where((s) => s.isNotEmpty)
              .toList() ??
          const <String>[];
      result = ForwardOutboxData(text: text, fileUrls: files, fileIds: ids);
    } catch (_) {
      return null;
    }
    if (!isCurrent()) return null;
    await prefs.remove(key);
    return isCurrent() ? result : null;
  }
}

/// A captured session must be obtained before picker/navigation awaits.
class ForwardOutboxSession {
  ForwardOutboxSession._(
      this._store, this._owner, this._durableMode, this._hostIsCurrent);
  final ForwardOutboxStore _store;
  final AuthOperationScope _owner;
  final bool _durableMode;
  final bool Function() _hostIsCurrent;
  bool get isCurrent => _hostIsCurrent() && _store.scope.isCurrent(_owner);

  String _transitionLock(String chat) =>
      'forward_transition:${_owner.userId}:$chat';

  Future<Set<String>> terminalOperationsForChat(
      DurableForwardOutbox durable, String chat) async {
    if (!_durableMode ||
        !isCurrent ||
        !identical(durable.scope, _store.scope)) {
      throw StateError('Session changed');
    }
    final result = await durable.terminalOperations(_owner, chat);
    if (!isCurrent) throw StateError('Session changed');
    return result;
  }

  /// All migrated writers and consumers must use this same coordinator lock.
  /// Historical records without backend provenance remain untouched.
  Future<DurableForwardReceipt?> claimDurableForChat(
      String chatId, DurableForwardOutbox durable) {
    if (!_durableMode) throw StateError('Durable forward mode disabled');
    final target = chatId.trim();
    if (target.isEmpty || !identical(durable.scope, _store.scope)) {
      throw StateError('Invalid durable forward target');
    }
    return _store.coordinator.serial(_transitionLock(target), () async {
      if (!isCurrent) throw StateError('Session changed');
      final legacy = await _store.peek(_owner, target);
      if (!isCurrent) throw StateError('Session changed');
      if (legacy != null) {
        // Historical keys contain uid/chat but no backend. A current session
        // cannot prove which project wrote this record, so never copy it into
        // this project or discard it without verified provenance.
        throw const LegacyForwardProvenanceUnknown();
      } else if (await _store.hasAny(_owner, target)) {
        throw const FormatException(
            'Не удалось прочитать сохранённую пересылку.');
      }
      final entry = await durable.peek(_owner, target);
      if (!isCurrent) throw StateError('Session changed');
      return entry;
    });
  }

  /// Reserve without overwriting either a legacy or a durable slot.
  Future<void> putDurableForChat(DurableForwardOutbox durable,
      {required String chatId,
      required String text,
      required bool Function() isSourceCurrent,
      List<String> fileUrls = const [],
      List<String> fileIds = const []}) {
    if (!_durableMode) throw StateError('Durable forward mode disabled');
    final target = chatId.trim();
    if (target.isEmpty || !identical(durable.scope, _store.scope)) {
      throw StateError('Invalid durable forward target');
    }
    final urls = List<String>.of(fileUrls), ids = List<String>.of(fileIds);
    return _store.coordinator.serial(_transitionLock(target), () async {
      if (!isCurrent || !isSourceCurrent()) throw StateError('Session changed');
      if (await _store.hasAny(_owner, target)) {
        throw const DurableForwardOccupied();
      }
      if (!isCurrent || !isSourceCurrent()) throw StateError('Session changed');
      final unverified = await durable.reserve(_owner, target,
          source: text,
          sourceUrls: urls,
          sourceIds: ids,
          isSourceCurrent: isSourceCurrent);
      if (!isCurrent || !isSourceCurrent()) throw StateError('Session changed');
      final queued = await durable.confirmReservation(unverified);
      if (!isCurrent || !isSourceCurrent()) throw StateError('Session changed');
      _store.coordinator.recordAutoApproval(
          durable.backend, _owner, target, queued.operation, isSourceCurrent);
    });
  }

  /// A proof exists only in the originating process after a checked commit.
  bool Function()? consumeAutoApproval(
      DurableForwardOutbox durable, DurableForwardReceipt receipt) {
    if (!_durableMode ||
        !isCurrent ||
        !identical(durable.scope, _store.scope) ||
        durable.backend != receipt.backend) return null;
    final proof = _store.coordinator.consumeAutoApproval(
        durable.backend, _owner, receipt.chat, receipt.operation);
    if (proof == null) return null;
    return () => isCurrent && proof();
  }

  Future<void> putForChat(
      {required String chatId,
      String? text,
      List<String> fileUrls = const [],
      List<String> fileIds = const [],
      bool Function()? isSourceCurrent}) async {
    if (_durableMode) throw StateError('Legacy forward writer disabled');
    if (!isCurrent) throw StateError('Session changed');
    final target = chatId.trim();
    if (target.isEmpty) throw const FormatException('Missing chat');
    await _store.coordinator.serial(_transitionLock(target), () async {
      if (!isCurrent) throw StateError('Session changed');
      await _store.put(_owner, target,
          text: text ?? '', files: fileUrls, fileIds: fileIds);
      if (!isCurrent) throw StateError('Session changed');
      if (qaNoAutomaticWrites) {
        final entry = await _store.peek(_owner, target);
        if (entry == null || !isCurrent) throw StateError('Forward unavailable');
        bool currentSource() {
          try { return isCurrent && (isSourceCurrent?.call() ?? false); }
          catch (_) { return false; }
        }
        if (currentSource()) {
          _store.coordinator.recordAutoApproval('qa-legacy-handoff', _owner,
              target, entry.migrationFingerprint, currentSource);
        }
      }
    });
  }

  /// Transitional destructive take: callers must not treat this as durable staging.
  Future<ForwardOutboxData?> tryTakeForChat(String chatId,
      {bool requireQaHandoff = false}) async {
    if (_durableMode) throw StateError('Legacy forward consumer disabled');
    if (!isCurrent) return null;
    final target = chatId.trim();
    if (target.isEmpty) return null;
    return _store.coordinator.serial(_transitionLock(target), () async {
      if (!isCurrent) return null;
      final entry = await _store.peek(_owner, target);
      if (!isCurrent || entry == null) return null;
      final proof = _store.coordinator.consumeAutoApproval('qa-legacy-handoff',
          _owner, target, entry.migrationFingerprint);
      if (requireQaHandoff && (proof == null || !proof())) return null;
      if (!ForwardPayload.isForwardText(entry.text) &&
          (entry.files.isNotEmpty || entry.fileIds.isNotEmpty)) {
        // Current consumers cannot reconstruct these attachments from a plain
        // text handoff. Retain the record rather than silently dropping them.
        throw const FormatException('Не все вложения готовы к пересылке.');
      }
      if (ForwardPayload.isForwardText(entry.text)) {
        final payload = ForwardPayload.tryParse(entry.text);
        if (payload == null ||
            !forwardSourceReferencesComplete(payload, entry.fileIds)) {
          throw const FormatException('Не все вложения готовы к пересылке.');
        }
      }
      final result = await _store.acknowledge(entry,
          isCurrent: requireQaHandoff ? () => isCurrent && (proof?.call() ?? false) : null);
      if (!isCurrent || (requireQaHandoff && !(proof?.call() ?? false)) ||
          result != ForwardAcknowledgeResult.removed) return null;
      return ForwardOutboxData(
          text: entry.text, fileUrls: entry.files, fileIds: entry.fileIds);
    });
  }
}
