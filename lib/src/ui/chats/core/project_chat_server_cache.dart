import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

/// A separate local DB. Transactions ensure incomplete writes do not become
/// visible after a crash. This is not an offline authorization mechanism.
Future<Database> openProjectChatServerDatabase(String path,
    {DatabaseFactory? factory}) async {
  return (factory ?? databaseFactory).openDatabase(path,
      options: OpenDatabaseOptions(
          version: 3,
          singleInstance: false,
          onConfigure: (db) async {
            final result = await db.rawQuery('PRAGMA journal_mode=WAL');
            if (result.length != 1 ||
                result.single.length != 1 ||
                result.single.values.single.toString().toLowerCase() != 'wal') {
              throw StateError('Chat database WAL unavailable');
            }
            await db.execute('PRAGMA synchronous=FULL');
          },
          onCreate: (db, version) async {
            await db.execute(
                'CREATE TABLE chat_server_snapshot (project TEXT NOT NULL, uid TEXT NOT NULL, '
                'sid TEXT NOT NULL, chat TEXT NOT NULL, payload TEXT NOT NULL, '
                'PRIMARY KEY(project,uid,sid,chat))');
            await _createAttemptTable(db);
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if (newVersion != 3 || (oldVersion != 1 && oldVersion != 2)) {
              throw StateError('Unknown chat database migration');
            }
            if (oldVersion == 1) {
              await _createAttemptTable(db);
            } else {
              await db.execute(
                  'ALTER TABLE chat_server_attempt ADD COLUMN blocked INTEGER NOT NULL DEFAULT 0 CHECK(blocked IN (0,1))');
            }
          },
          onDowngrade: (_, __, ___) =>
              throw StateError('Unknown chat database version'),
          onOpen: _validateChatSchema));
}

Future<void> _createAttemptTable(Database db) => db.execute(
    'CREATE TABLE chat_server_attempt (project TEXT NOT NULL, uid TEXT NOT NULL, '
    'sid TEXT NOT NULL, chat TEXT NOT NULL, seq INTEGER NOT NULL CHECK(seq>=0), '
    'blocked INTEGER NOT NULL DEFAULT 0 CHECK(blocked IN (0,1)), '
    'PRIMARY KEY(project,uid,sid,chat))');

Future<void> _validateChatSchema(Database db) async {
  final wal = await db.rawQuery('PRAGMA journal_mode');
  final sync = await db.rawQuery('PRAGMA synchronous');
  if (wal.length != 1 ||
      wal.single.length != 1 ||
      wal.single.values.single.toString().toLowerCase() != 'wal' ||
      sync.length != 1 ||
      sync.single.length != 1 ||
      sync.single.values.single != 2) {
    throw StateError('Chat database durability unavailable');
  }
  for (final entry in <String, List<String>>{
    'chat_server_snapshot': ['project', 'uid', 'sid', 'chat', 'payload'],
    'chat_server_attempt': ['project', 'uid', 'sid', 'chat', 'seq', 'blocked'],
  }.entries) {
    final columns = await db.rawQuery('PRAGMA table_info(${entry.key})');
    if (columns.length != entry.value.length)
      throw StateError('Invalid chat database schema');
    for (var i = 0; i < columns.length; i++) {
      final expectedType =
          entry.key == 'chat_server_attempt' && i >= 4 ? 'INTEGER' : 'TEXT';
      if (columns[i]['name'] != entry.value[i] ||
          columns[i]['type'] != expectedType ||
          columns[i]['notnull'] != 1 ||
          columns[i]['pk'] != (i < 4 ? i + 1 : 0)) {
        throw StateError('Invalid chat database schema');
      }
    }
  }
}

class ProjectChatPageTicket {
  ProjectChatPageTicket._(
      this._issuer, this._owner, this._binding, this._chat, this._version);
  final Object _issuer;
  final AuthOperationScope _owner;
  final OfflineSessionBinding _binding;
  final String _chat;
  final int _version;
}

class ChatHideHold {
  ChatHideHold._(
      this._issuer, this._owner, this._binding, this._chat, this._seq);
  final Object _issuer;
  final AuthOperationScope _owner;
  final OfflineSessionBinding _binding;
  final String _chat;
  final int _seq;
}

class ProjectChatServerCache {
  ProjectChatServerCache(
      {required this.db,
      required this.scope,
      required this.currentBinding,
      required this.project});
  final Database db;
  final AuthSessionScope scope;
  final OfflineSessionBinding? Function() currentBinding;
  final String project;
  final Object _issuer = Object();
  static ProjectChatServerCache? qaInstance;
  static final Map<String, int> _eventVersions = {};
  static final Set<String> _eventQuarantine = {};
  static final Map<String, Future<void>> _eventQueues = {};
  String _eventKey(OfflineSessionBinding b, String chat) =>
      jsonEncode([project, b.userId, b.sessionId, chat]);

  bool _matches(OfflineSessionBinding? a, OfflineSessionBinding b) =>
      a != null &&
      a.issuer == b.issuer &&
      a.userId == b.userId &&
      a.sessionId == b.sessionId &&
      a.notBefore == b.notBefore &&
      a.expiresAt == b.expiresAt;

  /// The durable sequence commits before dispatch. A newer isolate or process
  /// invalidates an older response through the same SQLite transaction.
  Future<ProjectChatPageTicket?> begin(String chat) async {
    final owner = scope.capture();
    final binding = currentBinding();
    if (owner == null ||
        binding == null ||
        chat.isEmpty ||
        project.isEmpty ||
        owner.userId != binding.userId ||
        binding.issuer != '$project/auth/v1' ||
        _eventQuarantine.contains(_eventKey(binding, chat))) return null;
    bool valid() =>
        scope.isCurrent(owner) &&
        _matches(currentBinding(), binding) &&
        !_eventQuarantine.contains(_eventKey(binding, chat));
    try {
      final seq = await db.transaction((txn) async {
        if (!valid()) throw const _StalePage();
        await txn.insert(
            'chat_server_attempt',
            {
              'project': project,
              'uid': binding.userId,
              'sid': binding.sessionId,
              'chat': chat,
              'seq': 0
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        if (!valid()) throw const _StalePage();
        final updated = await txn.rawUpdate(
            'UPDATE chat_server_attempt SET seq=seq+1 WHERE project=? AND uid=? AND sid=? AND chat=? AND blocked=0',
            [project, binding.userId, binding.sessionId, chat]);
        if (updated != 1) throw const _StalePage();
        if (!valid()) throw const _StalePage();
        final rows = await txn.query('chat_server_attempt',
            columns: ['seq'],
            where: 'project=? AND uid=? AND sid=? AND chat=?',
            whereArgs: [project, binding.userId, binding.sessionId, chat]);
        if (!valid() ||
            rows.length != 1 ||
            rows.single['seq'] is! int ||
            (rows.single['seq'] as int) <= 0) throw const _StalePage();
        return rows.single['seq'] as int;
      });
      if (!valid()) return null;
      return ProjectChatPageTicket._(_issuer, owner, binding, chat, seq);
    } on _StalePage {
      return null;
    }
  }

  bool _current(ProjectChatPageTicket t) =>
      identical(t._issuer, _issuer) &&
      scope.isCurrent(t._owner) &&
      _matches(currentBinding(), t._binding) &&
      !_eventQuarantine.contains(_eventKey(t._binding, t._chat));

  List<Message>? _parse(String raw, String chat) {
    try {
      final rows = jsonDecode(raw);
      if (rows is! List) return null;
      final result = <Message>[];
      for (final row in rows) {
        if (row is! Map || row.keys.any((key) => key is! String)) return null;
        final data = Map<String, dynamic>.from(row);
        if (data['chat_id'] != chat ||
            data['id'] is! String ||
            (data['id'] as String).isEmpty ||
            DateTime.tryParse(
                    (data['created_at'] ?? data['at'] ?? '').toString()) ==
                null) return null;
        final message = Message.fromJson(data);
        if (message.isLocal) return null;
        result.add(message);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  /// The attempt must be obtained before starting the server request.
  Future<bool> saveServerPage(ProjectChatPageTicket t, List<Message> page,
      {required bool hasMore, DateTime? clearedAt}) async {
    if (!_current(t) ||
        (page.isEmpty && hasMore) ||
        page.any((m) =>
            m.chatId != t._chat ||
            m.id.isEmpty ||
            m.isLocal ||
            (clearedAt != null && !m.at.isAfter(clearedAt)))) return false;
    final incoming = List<Message>.of(page);
    incoming.sort((a, b) {
      final c = a.at.compareTo(b.at);
      return c == 0 ? a.id.compareTo(b.id) : c;
    });
    try {
      return await db.transaction((txn) async {
        if (!_current(t)) throw const _StalePage();
        final b = t._binding;
        final attempts = await txn.query('chat_server_attempt',
            columns: ['seq', 'blocked'],
            where: 'project=? AND uid=? AND sid=? AND chat=?',
            whereArgs: [project, b.userId, b.sessionId, t._chat]);
        if (!_current(t) ||
            attempts.length != 1 ||
            attempts.single['seq'] != t._version ||
            attempts.single['blocked'] != 0) throw const _StalePage();
        final rows = await txn.query('chat_server_snapshot',
            columns: ['payload'],
            where: 'project=? AND uid=? AND sid=? AND chat=?',
            whereArgs: [project, b.userId, b.sessionId, t._chat]);
        if (!_current(t)) throw const _StalePage();
        final old = rows.length == 1 && rows.single['payload'] is String
            ? _parse(rows.single['payload'] as String, t._chat) ?? <Message>[]
            : <Message>[];
        final older = hasMore && incoming.isNotEmpty
            ? old.where((m) =>
                (clearedAt == null || m.at.isAfter(clearedAt)) &&
                (m.at.isBefore(incoming.first.at) ||
                    (m.at.isAtSameMomentAs(incoming.first.at) &&
                        m.id.compareTo(incoming.first.id) < 0)))
            : <Message>[];
        final merged = <String, Message>{
          for (final m in older) m.id: m,
          for (final m in incoming) m.id: m
        }.values.toList()
          ..sort((a, b) {
            final c = a.at.compareTo(b.at);
            return c == 0 ? a.id.compareTo(b.id) : c;
          });
        final tail =
            merged.length > 120 ? merged.sublist(merged.length - 120) : merged;
        final payload = jsonEncode(tail.map((m) => m.toJson()).toList());
        await txn.insert(
            'chat_server_snapshot',
            {
              'project': project,
              'uid': b.userId,
              'sid': b.sessionId,
              'chat': t._chat,
              'payload': payload
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        if (!_current(t)) throw const _StalePage();
        return true;
      });
    } on _StalePage {
      return false;
    }
  }

  static const summaryChatKey = '__chat_summaries__';

  static bool _validSummary(Map<String, dynamic> row) {
    final team = row['team'],
        dm = row['isDm'],
        chat = row['chatId'],
        title = row['title'];
    if (team is! Map ||
        team['id'] is! String ||
        team['name'] is! String ||
        team['teacher'] is! String ||
        team['groupCode'] is! String ||
        team['icon'] is! String ||
        (team['kind'] != null &&
            team['kind'] != 'subject' &&
            team['kind'] != 'group_space') ||
        dm is! bool ||
        chat is! String ||
        chat.isEmpty ||
        title is! String ||
        title.isEmpty ||
        (dm &&
            (row['peerId'] is! String || (row['peerId'] as String).isEmpty)) ||
        row['unread'] is! int ||
        (row['unread'] as int) < 0 ||
        row['pinned'] is! bool ||
        row['muted'] is! bool) return false;
    for (final key in [
      'subtitle',
      'lastAuthor',
      'lastMsgPreview',
      'lastTime',
      'lastMessageId',
      'peerId',
      'avatarUrl'
    ]) {
      if (row[key] != null && row[key] is! String) return false;
    }
    return row['lastTime'] == null ||
        DateTime.tryParse(row['lastTime'] as String) != null;
  }

  /// Only strict, confirmed server summaries may be supplied. This never reads
  /// uid-only legacy caches or imports their local pin/mute state.
  Future<bool> saveSummaries(
      ProjectChatPageTicket ticket, List<Map<String, dynamic>> rows) async {
    if (ticket._chat != summaryChatKey ||
        !_current(ticket) ||
        rows.any((r) => !_validSummary(r))) return false;
    final ids = rows.map((r) => r['chatId']).toSet();
    if (ids.length != rows.length) return false;
    final payload = jsonEncode(rows);
    try {
      return await db.transaction((txn) async {
        final b = ticket._binding,
            args = [project, b.userId, b.sessionId, summaryChatKey];
        if (!_current(ticket)) throw const _StalePage();
        final states = await txn.query('chat_server_attempt',
            columns: ['seq', 'blocked'],
            where: 'project=? AND uid=? AND sid=? AND chat=?',
            whereArgs: args);
        if (!_current(ticket) ||
            states.length != 1 ||
            states.single['seq'] != ticket._version ||
            states.single['blocked'] != 0) throw const _StalePage();
        await txn.insert(
            'chat_server_snapshot',
            {
              'project': project,
              'uid': b.userId,
              'sid': b.sessionId,
              'chat': summaryChatKey,
              'payload': payload
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        if (!_current(ticket)) throw const _StalePage();
        return true;
      });
    } on _StalePage {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>?> readSummaries(
      SessionCapabilities caps) async {
    final permit = caps.capture(SessionCapability.cachedRead),
        owner = scope.capture(),
        binding = currentBinding();
    if (permit == null ||
        owner == null ||
        binding == null ||
        caps.mode != SessionCapabilityMode.cacheOnly ||
        !caps.owns(permit, owner) ||
        owner.userId != binding.userId ||
        binding.issuer != '$project/auth/v1' ||
        _eventQuarantine.contains(_eventKey(binding, summaryChatKey)))
      return null;
    bool valid() =>
        scope.isCurrent(owner) &&
        _matches(currentBinding(), binding) &&
        caps.mode == SessionCapabilityMode.cacheOnly &&
        caps.permits(permit, SessionCapability.cachedRead) &&
        !_eventQuarantine.contains(_eventKey(binding, summaryChatKey));
    try {
      return await db.transaction((txn) async {
        final args = [
          project,
          binding.userId,
          binding.sessionId,
          summaryChatKey
        ];
        final state = await txn.query('chat_server_attempt',
            columns: ['blocked'],
            where: 'project=? AND uid=? AND sid=? AND chat=?',
            whereArgs: args);
        if (!valid() || state.length != 1 || state.single['blocked'] != 0)
          return null;
        final rows = await txn.query('chat_server_snapshot',
            columns: ['payload'],
            where: 'project=? AND uid=? AND sid=? AND chat=?',
            whereArgs: args);
        if (!valid() || rows.length != 1 || rows.single['payload'] is! String)
          return null;
        final parsed = jsonDecode(rows.single['payload'] as String);
        if (parsed is! List) return null;
        final result = <Map<String, dynamic>>[];
        for (final row in parsed) {
          if (row is! Map || row.keys.any((k) => k is! String)) return null;
          final map = Map<String, dynamic>.from(row);
          if (!_validSummary(map)) return null;
          result.add(map);
        }
        if (result.map((r) => r['chatId']).toSet().length != result.length ||
            !valid()) return null;
        return result;
      });
    } catch (_) {
      return null;
    }
  }

  /// Realtime and personal clear changes invalidate the whole verified page;
  /// advance the durable sequence in the same transaction so delayed page
  /// responses cannot recreate a snapshot after invalidation commits.
  Future<bool> invalidate(String chat) async {
    final owner = scope.capture();
    final binding = currentBinding();
    if (owner == null ||
        binding == null ||
        chat.isEmpty ||
        owner.userId != binding.userId ||
        binding.issuer != '$project/auth/v1') return false;
    final key = _eventKey(binding, chat);
    final version = (_eventVersions[key] ?? 0) + 1;
    _eventVersions[key] = version;
    _eventQuarantine.add(key);
    final previous = _eventQueues[key];
    final done = Completer<void>();
    _eventQueues[key] = done.future;
    var settled = false;
    try {
      if (previous != null) await previous;
      final hold = await _beginHold(chat, allowEventQuarantine: true);
      if (hold == null) return false;
      settled = await finishHide(hold);
      return settled;
    } finally {
      if (settled && _eventVersions[key] == version)
        _eventQuarantine.remove(key);
      done.complete();
      if (identical(_eventQueues[key], done.future)) _eventQueues.remove(key);
    }
  }

  /// A durable hold is committed before hide can reach the server. It remains
  /// closed after an ambiguous result or process death.
  Future<ChatHideHold?> beginHide(String chat) => _beginHold(chat);

  Future<ChatHideHold?> _beginHold(String chat,
      {bool allowEventQuarantine = false}) async {
    final owner = scope.capture();
    final binding = currentBinding();
    if (owner == null ||
        binding == null ||
        chat.isEmpty ||
        owner.userId != binding.userId ||
        binding.issuer != '$project/auth/v1' ||
        (!allowEventQuarantine &&
            _eventQuarantine.contains(_eventKey(binding, chat)))) return null;
    bool valid() =>
        scope.isCurrent(owner) &&
        _matches(currentBinding(), binding) &&
        (allowEventQuarantine ||
            !_eventQuarantine.contains(_eventKey(binding, chat)));
    try {
      final seq = await db.transaction((txn) async {
        if (!valid()) throw const _StalePage();
        await txn.insert(
            'chat_server_attempt',
            {
              'project': project,
              'uid': binding.userId,
              'sid': binding.sessionId,
              'chat': chat,
              'seq': 0
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        if (!valid()) throw const _StalePage();
        final args = [project, binding.userId, binding.sessionId, chat];
        final updated = await txn.rawUpdate(
            'UPDATE chat_server_attempt SET seq=seq+1,blocked=1 WHERE project=? AND uid=? AND sid=? AND chat=? AND blocked=0',
            args);
        if (!valid() || updated != 1) throw const _StalePage();
        await txn.delete('chat_server_snapshot',
            where: 'project=? AND uid=? AND sid=? AND chat=?', whereArgs: args);
        if (!valid()) throw const _StalePage();
        final rows = await txn.query('chat_server_attempt',
            columns: ['seq', 'blocked'],
            where: 'project=? AND uid=? AND sid=? AND chat=?',
            whereArgs: args);
        if (!valid() ||
            rows.length != 1 ||
            rows.single['seq'] is! int ||
            rows.single['blocked'] != 1) throw const _StalePage();
        return rows.single['seq'] as int;
      });
      return valid()
          ? ChatHideHold._(_issuer, owner, binding, chat, seq)
          : null;
    } on _StalePage {
      return null;
    }
  }

  bool isHoldCurrent(ChatHideHold hold) =>
      identical(hold._issuer, _issuer) &&
      scope.isCurrent(hold._owner) &&
      _matches(currentBinding(), hold._binding);

  Future<bool> finishHide(ChatHideHold hold) async {
    bool valid() =>
        identical(hold._issuer, _issuer) &&
        scope.isCurrent(hold._owner) &&
        _matches(currentBinding(), hold._binding);
    if (!valid()) return false;
    try {
      return await db.transaction((txn) async {
        if (!valid()) throw const _StalePage();
        final b = hold._binding,
            args = [project, b.userId, b.sessionId, hold._chat];
        final changed = await txn.rawUpdate(
            'UPDATE chat_server_attempt SET seq=seq+1,blocked=0 WHERE project=? AND uid=? AND sid=? AND chat=? AND blocked=1 AND seq=?',
            [...args, hold._seq]);
        if (!valid() || changed != 1) throw const _StalePage();
        await txn.delete('chat_server_snapshot',
            where: 'project=? AND uid=? AND sid=? AND chat=?', whereArgs: args);
        if (!valid()) throw const _StalePage();
        return true;
      });
    } on _StalePage {
      return false;
    }
  }

  /// Requires an independently issued cache-only permit; no network or writes.
  Future<List<Message>?> read(
      String chat, SessionCapabilities capabilities) async {
    final permit = capabilities.capture(SessionCapability.cachedRead);
    final owner = scope.capture();
    final binding = currentBinding();
    if (permit == null ||
        owner == null ||
        binding == null ||
        capabilities.mode != SessionCapabilityMode.cacheOnly ||
        !capabilities.owns(permit, owner) ||
        owner.userId != binding.userId ||
        binding.issuer != '$project/auth/v1' ||
        chat.isEmpty ||
        _eventQuarantine.contains(_eventKey(binding, chat))) return null;
    bool valid() =>
        scope.isCurrent(owner) &&
        _matches(currentBinding(), binding) &&
        capabilities.mode == SessionCapabilityMode.cacheOnly &&
        capabilities.permits(permit, SessionCapability.cachedRead) &&
        !_eventQuarantine.contains(_eventKey(binding, chat));
    return db.transaction((txn) async {
      final args = [project, binding.userId, binding.sessionId, chat];
      final state = await txn.query('chat_server_attempt',
          columns: ['blocked'],
          where: 'project=? AND uid=? AND sid=? AND chat=?',
          whereArgs: args);
      if (!valid() || state.length != 1 || state.single['blocked'] != 0)
        return null;
      final rows = await txn.query('chat_server_snapshot',
          columns: ['payload'],
          where: 'project=? AND uid=? AND sid=? AND chat=?',
          whereArgs: args);
      if (!valid() || rows.length != 1 || rows.single['payload'] is! String)
        return null;
      return _parse(rows.single['payload'] as String, chat);
    });
  }
}

class _StalePage implements Exception {
  const _StalePage();
}
