import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'draft_session_owner.dart';
import 'draft_recovery_journal.dart';

/// Account and conversation scoped local drafts. The single value includes
/// text, reply and attachment metadata so a crash cannot mix two snapshots.
class AccountDraftStore {
  @visibleForTesting
  static Future<void> Function()? debugBeforeRead;
  AccountDraftStore({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;
  static final Map<String, Future<void>> _pending = {};

  String _key(String project, String owner, String conversation) {
    if ([project, owner, conversation].any((value) => value.trim().isEmpty)) {
      throw ArgumentError('Incomplete draft identity');
    }
    return 'account_draft_v1_${base64Url.encode(utf8.encode(jsonEncode([
      project, owner, conversation,
    ])))}';
  }

  Future<Map<String, dynamic>?> read(String project, String owner,
      String conversation, bool Function() current) async {
    final key = _key(project, owner, conversation);
    if (!current()) return null;
    if (kDebugMode) await debugBeforeRead?.call();
    if (!current()) return null;
    final pending = _pending[key];
    // Refuse to hydrate rather than replacing an unresolved newer write with
    // an older persisted snapshot. The caller must keep its composer intact.
    if (pending != null) await pending.timeout(const Duration(seconds: 2));
    if (!current() || _pending.containsKey(key)) return null;
    final prefs = await _preferences();
    if (!current() || _pending.containsKey(key)) return null;
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != 1 ||
          decoded['project'] != project || decoded['owner'] != owner ||
          decoded['conversation'] != conversation || decoded['draft'] is! Map) {
        return null;
      }
      return Map<String, dynamic>.from(decoded['draft'] as Map);
    } catch (_) {
      return null;
    }
  }

  Future<bool> write(String project, String owner, String conversation,
      Map<String, dynamic> draft, bool Function() current) {
    if (!current()) return Future.value(false);
    final key = _key(project, owner, conversation);
    final encoded = jsonEncode({
      'version': 1, 'project': project, 'owner': owner,
      'conversation': conversation, 'draft': draft,
    });
    final previous = _pending[key] ?? Future<void>.value();
    final operation = previous.catchError((_) {}).then((_) async {
      if (!current()) return false;
      final prefs = await _preferences();
      if (!current()) return false;
      final saved = await prefs.setString(key, encoded);
      return saved && current();
    });
    final barrier = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _pending[key] = barrier;
    barrier.whenComplete(() {
      if (identical(_pending[key], barrier)) _pending.remove(key);
    });
    return operation;
  }

}

/// Keeps edits made during a token-refresh gap until the original owner is
/// confirmed again. No snapshot is handed to a different session.
class AccountDraftWriter {
  AccountDraftWriter(this.store, this.owner, this.conversation,
      {this.onFailure, this.onJournalFailure, DraftRecoveryJournal? journal})
      : _journal = journal ?? DraftRecoveryJournal() {
    owner.changes.addListener(_changed);
  }
  final AccountDraftStore store;
  final DraftSessionOwner owner;
  final String conversation;
  final void Function()? onFailure;
  final void Function()? onJournalFailure;
  Map<String, dynamic>? _pending;
  int _revision = 0;
  bool _writing = false;
  bool _closed = false;
  int _attempt = 0;
  bool _journaling = false;
  int _journalRevision = -1;
  final DraftRecoveryJournal _journal;

  void save(Map<String, dynamic> draft) {
    if (_closed || !owner.sameGeneration) return;
    // Capture nested maps and lists before a debounce or an asynchronous I/O.
    _pending = Map<String, dynamic>.from(jsonDecode(jsonEncode(draft)) as Map);
    _revision++;
    _attempt = 0;
    _changed();
  }

  void _changed() {
    if (_pending != null && !owner.canSave && owner.canJournal &&
        !_journaling && _journalRevision != _revision) {
      final revision = _revision;
      final snapshot = _pending!;
      _journaling = true;
      _journal.append(project: owner.project, owner: owner.userId,
          sessionId: owner.sessionId, conversation: conversation,
          draft: snapshot, permitted: () => owner.canJournal).then((saved) {
        if (saved) _journalRevision = revision;
        else if (owner.canJournal) (onJournalFailure ?? onFailure)?.call();
      }).catchError((Object _) {
        if (owner.canJournal) (onJournalFailure ?? onFailure)?.call();
      }).whenComplete(() {
        _journaling = false;
        if (_pending != null && revision != _revision) _changed();
      });
    }
    if (_writing || _pending == null || !owner.canSave) {
      if (_closed && !_writing && (_pending == null || !owner.sameGeneration)) {
        owner.changes.removeListener(_changed);
      }
      return;
    }
    final revision = _revision;
    final snapshot = _pending!;
    _attempt++;
    _writing = true;
    var savedSuccessfully = false;
    store.write(owner.project, owner.userId, conversation, snapshot,
        () => owner.canSave).then((saved) {
      savedSuccessfully = saved;
      if (saved && revision == _revision) _pending = null;
    }).catchError((Object _) {}).whenComplete(() {
      _writing = false;
      if (_pending != null && revision != _revision) _changed();
      if (!savedSuccessfully && _pending != null && revision == _revision &&
          owner.canSave) {
        if (_attempt < 3) {
          Future<void>.delayed(const Duration(milliseconds: 250), _changed);
        } else {
          onFailure?.call();
        }
      }
      if (_closed && !_writing && (_pending == null || !owner.sameGeneration)) {
        owner.changes.removeListener(_changed);
      }
    });
  }

  void close() {
    _closed = true;
    _changed();
  }
}
