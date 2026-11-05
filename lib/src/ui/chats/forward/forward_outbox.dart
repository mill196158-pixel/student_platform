// FILE: lib/src/ui/chats/forward/forward_outbox.dart
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/auth_session_scope.dart';
import '../core/forward_payload.dart';
import 'forward_outbox_host.dart';
import 'forward_outbox_store.dart';

class ForwardOutboxData {
  final String? text;
  final List<String> fileUrls;
  final List<String> fileIds;
  ForwardOutboxData({this.text, required this.fileUrls, required this.fileIds});
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
  ForwardOutboxSession._(this._store, this._owner, this._hostIsCurrent);
  final ForwardOutboxStore _store;
  final AuthOperationScope _owner;
  final bool Function() _hostIsCurrent;
  bool get isCurrent => _hostIsCurrent() && _store.scope.isCurrent(_owner);

  Future<void> putForChat(
      {required String chatId,
      String? text,
      List<String> fileUrls = const [],
      List<String> fileIds = const []}) async {
    if (!isCurrent) throw StateError('Session changed');
    final target = chatId.trim();
    if (target.isEmpty) throw const FormatException('Missing chat');
    await _store.put(_owner, target,
        text: text ?? '', files: fileUrls, fileIds: fileIds);
    if (!isCurrent) throw StateError('Session changed');
  }

  /// Transitional destructive take: callers must not treat this as durable staging.
  Future<ForwardOutboxData?> tryTakeForChat(String chatId) async {
    if (!isCurrent) return null;
    final target = chatId.trim();
    if (target.isEmpty) return null;
    final entry = await _store.peek(_owner, target);
    if (!isCurrent || entry == null) return null;
    final result = await _store.acknowledge(entry);
    if (!isCurrent || result != ForwardAcknowledgeResult.removed) return null;
    return ForwardOutboxData(
        text: entry.text, fileUrls: entry.files, fileIds: entry.fileIds);
  }
}
