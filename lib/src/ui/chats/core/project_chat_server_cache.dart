import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/guarded_database.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/core/qa_native_project_guard.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

/// A separate local DB. Transactions ensure incomplete writes do not become
/// visible after a crash. This is not an offline authorization mechanism.
class _DatabaseAppGuard {
  _DatabaseAppGuard(this.token, this.file, {this.nativeGuard});
  final String token;
  final RandomAccessFile? file;
  final QaNativeProjectGuard? nativeGuard;
  bool get isHeld => file != null || nativeGuard?.isCurrent == true;
}

final Map<Database, _DatabaseAppGuard> _databaseAppGuards = {};
// QA-only opt-in: a native authority must close before the Dart guard lease.
final Map<Database, Future<bool> Function()> _qaNativeCloseBarriers = {};
final Set<Database> _qaGuardClosing = {};

/// Process-local capability bound to the exact guarded DB handle and its
/// still-held OS lease. It cannot be constructed from a token read from DB.
class ProjectDatabaseOwnerCapability {
  ProjectDatabaseOwnerCapability._(this._database, this._guard);
  final Database _database;
  final _DatabaseAppGuard _guard;
  bool isCurrentFor(Database database) => identical(database, _database) &&
      database.isOpen && _guard.isHeld &&
      !_qaGuardClosing.contains(database) &&
      identical(_databaseAppGuards[database], _guard);
  String? tokenFor(Database database) => isCurrentFor(database) ? _guard.token : null;
}

ProjectDatabaseOwnerCapability? captureProjectDatabaseOwner(Database database) {
  final guard = _databaseAppGuards[database];
  if (guard == null || !guard.isHeld || !database.isOpen) return null;
  return ProjectDatabaseOwnerCapability._(database, guard);
}

/// Registers only for the exact live handle. The callback must be idempotent:
/// an underlying close can fail after authority has already been revoked.
bool registerQaNativeCloseBarrier(Database database,
    ProjectDatabaseOwnerCapability owner, Future<bool> Function() closeNative) {
  if (!owner.isCurrentFor(database) || _qaGuardClosing.contains(database) ||
      _qaNativeCloseBarriers.containsKey(database)) return false;
  _qaNativeCloseBarriers[database] = closeNative;
  return true;
}

@visibleForTesting
Future<void> Function()? debugBeforeDatabaseGuard;
@visibleForTesting
Future<void> Function()? debugBeforePinnedRecovery;
@visibleForTesting
Future<void> Function()? debugAfterCloseAdmission;

@visibleForTesting
String? debugProjectChatDatabaseGuard(Database db) => _databaseAppGuards[db]?.token;

@visibleForTesting
Future<void> debugAbandonProjectChatDatabase(Database db) async {
  final guard = _databaseAppGuards.remove(db);
  if (guard == null) return;
  if (db is GuardedDatabase) await db.inner.close();
  await guard.file?.unlock();
  await guard.file?.close();
}

String _newGuardToken() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
}

Future<Database> openProjectChatServerDatabase(String path,
    {DatabaseFactory? factory, Future<QaNativeProjectGuard?> Function()? qaNativeGuard}) async {
  final opener = factory ?? databaseFactory;
  final db = await opener.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 3,
          singleInstance: false,
          onConfigure: (db) async {
            await db.rawQuery('PRAGMA busy_timeout=3000');
            // Existing databases are never rewritten or reconfigured here.
            final tables = await db.rawQuery(
                "SELECT name FROM sqlite_master WHERE type='table' LIMIT 1");
            if (tables.isEmpty) {
              await db.execute('PRAGMA auto_vacuum=INCREMENTAL');
            }
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
  final token = _newGuardToken();
  RandomAccessFile? guardFile;
  try {
    await debugBeforeDatabaseGuard?.call();
    if (qaNativeGuard != null) {
      final native = await qaNativeGuard();
      if (native == null || !native.isCurrent || !await native.claimForPath(db.path)) throw StateError('Native guard unavailable');
      late GuardedDatabase wrapped;
      wrapped = GuardedDatabase(db, () => _closeWithQaBarrier(wrapped, db, opener),
          retryClosed:()=>_databaseAppGuards[wrapped]?.nativeGuard?.isCurrent == true);
      _databaseAppGuards[wrapped] = _DatabaseAppGuard(native.token, null, nativeGuard:native);
      return wrapped;
    }
    final directory = Directory('${db.path}.guards');
    if (!await directory.exists()) await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.directory) {
      throw StateError('Unsafe cache guard directory');
    }
    final marker = File('${directory.path}/$token');
    await marker.create(exclusive: true);
    guardFile = await marker.open(mode: FileMode.append);
    await guardFile.lock(FileLock.exclusive);
    await guardFile.writeString(token);
    await guardFile.flush();
    await db.insert('chat_app_guards', {'token': token, 'project': '*',
      'uid': pid.toString(), 'sid': '', 'database_token': token});
    late GuardedDatabase wrapped;
    wrapped = GuardedDatabase(db, () => _closeWithQaBarrier(wrapped, db, opener));
    _databaseAppGuards[wrapped] = _DatabaseAppGuard(token, guardFile);
    return wrapped;
  } catch (_) {
    if (guardFile != null) {
      try { await guardFile.unlock(); } catch (_) {}
      try { await guardFile.close(); } catch (_) {}
    }
    if (qaNativeGuard != null) { await db.close(); rethrow; }
    // Preserve reads using a durable, deliberately unverifiable guard. It
    // cannot be recovered automatically and forbids eviction on all handles.
    try {
      await db.insert('chat_app_guards', {'token': token, 'project': '*',
        'uid': 'unverifiable', 'sid': '', 'database_token': token});
      late GuardedDatabase wrapped;
      wrapped = GuardedDatabase(db, () => _closeWithQaBarrier(wrapped, db, opener));
      _databaseAppGuards[wrapped] = _DatabaseAppGuard(token, null);
      return wrapped;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }
}

/// Only after all users of this handle have stopped. A process crash leaves
/// its guard in place and therefore conservatively prevents later eviction.
Future<void> closeProjectChatServerDatabase(Database db) async {
  await db.close();
}

Future<void> _closeWithQaBarrier(Database wrapped, Database db, DatabaseFactory factory) async {
  final barrier = _qaNativeCloseBarriers[wrapped];
  if (barrier == null) return _closeProjectChatServerDatabase(wrapped, db, factory);
  _qaGuardClosing.add(wrapped);
  try {
    if (!await barrier()) throw StateError('Native authority could not close');
    await _closeProjectChatServerDatabase(wrapped, db, factory);
    _qaNativeCloseBarriers.remove(wrapped);
  } finally { _qaGuardClosing.remove(wrapped); }
}

Future<void> _closeProjectChatServerDatabase(Database wrapped, Database db,
    DatabaseFactory factory) async {
  final guard = _databaseAppGuards[wrapped];
  if (guard != null && db.isOpen) {
    await db.transaction((txn) async {
      final tables = await txn.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='pinned_fence_pending'");
      if (tables.isNotEmpty) {
        final columns = await txn.rawQuery('PRAGMA table_info(pinned_fence_pending)');
        if (!columns.any((row) => row['name'] == 'database_token')) {
          throw StateError('Cannot close while pinned fence ownership is unknown');
        }
        final pending = await txn.query('pinned_fence_pending', columns: ['token'],
            where: 'database_token=?', whereArgs: [guard.token], limit: 1);
        if (pending.isNotEmpty) throw StateError('Media access checks are still running');
      }
      final media = await txn.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='media_cache_read_leases'");
      if (media.isNotEmpty && (await txn.query('media_cache_read_leases', columns: ['token'],
          where: 'database_token=?', whereArgs: [guard.token], limit: 1)).isNotEmpty) {
        throw StateError('Media readers are still active');
      }
      final updated = await txn.update('chat_app_guards', {'sid': 'closing'},
          where: 'token=? AND project=? AND sid=?', whereArgs: [guard.token, '*', '']);
      if (updated != 1) throw StateError('Database guard cannot close safely');
    });
    await debugAfterCloseAdmission?.call();
  }
  // Keep the guard and FD if close fails: other engines must not evict.
  if (db.isOpen) await db.close();
  if (guard != null) {
    // The old handle is closed; use an unguarded maintenance connection only
    // to release this exact token. Failure leaves the OS lock held fail-closed.
    final maintenance = await factory.openDatabase(db.path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await maintenance.transaction((txn) async {
        await PinnedAccessFence.recoverHandle(txn, guard.token);
        await txn.delete('chat_route_leases', where: 'database_token=?', whereArgs: [guard.token]);
        final media = await txn.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='media_cache_read_leases'");
        if (media.isNotEmpty) {
          await txn.delete('media_cache_read_leases', where: 'database_token=?', whereArgs: [guard.token]);
        }
        await txn.delete('chat_app_guards', where: 'database_token=?', whereArgs: [guard.token]);
      });
    } finally {
      await maintenance.close();
    }
    if (guard.nativeGuard != null && !await guard.nativeGuard!.release()) {
      throw StateError('Native guard could not be released');
    }
    _databaseAppGuards.remove(wrapped);
    await guard.file?.unlock();
    await guard.file?.close();
  }
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
  // Separate optional metadata: version remains 3 so older clients can still
  // open their existing snapshots after rollback. No user data is rewritten.
  await db.execute('CREATE TABLE IF NOT EXISTS chat_snapshot_access ('
      'project TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL, chat TEXT NOT NULL, '
      'access_ms INTEGER NOT NULL, PRIMARY KEY(project,uid,sid,chat))');
  await db.execute('CREATE TABLE IF NOT EXISTS chat_route_leases ('
      'token TEXT NOT NULL PRIMARY KEY, project TEXT NOT NULL, uid TEXT NOT NULL, '
      'sid TEXT NOT NULL, chat TEXT NOT NULL, database_token TEXT NOT NULL)');
  await db.execute('CREATE TABLE IF NOT EXISTS chat_app_guards ('
      'token TEXT NOT NULL PRIMARY KEY, project TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL, '
      'database_token TEXT NOT NULL)');
  for (final entry in <String, List<String>>{
    'chat_snapshot_access': ['project', 'uid', 'sid', 'chat', 'access_ms'],
    'chat_route_leases': ['token', 'project', 'uid', 'sid', 'chat', 'database_token'],
    'chat_app_guards': ['token', 'project', 'uid', 'sid', 'database_token'],
  }.entries) {
    final columns = await db.rawQuery('PRAGMA table_info(${entry.key})');
    if (columns.length != entry.value.length) throw StateError('Invalid chat quota schema');
    for (var i = 0; i < columns.length; i++) {
      final column = columns[i];
      if (column['name'] != entry.value[i] || column['notnull'] != 1 ||
          column['type'] != (entry.key == 'chat_snapshot_access' && i == 4 ? 'INTEGER' : 'TEXT') ||
          column['pk'] != (entry.key == 'chat_snapshot_access' ? (i < 4 ? i + 1 : 0) : (i == 0 ? 1 : 0))) {
        throw StateError('Invalid chat quota schema');
      }
    }
  }
}

class ProjectChatPageTicket {
  ProjectChatPageTicket._(
      this._issuer, this._owner, this._binding, this._chat, this._version, this._guard);
  final Object _issuer;
  final AuthOperationScope _owner;
  final OfflineSessionBinding _binding;
  final String _chat;
  final int _version;
  final bool Function()? _guard;
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

class ChatHistoryRouteLease {
  ChatHistoryRouteLease._(this.issuer, this.token, this.project, this.uid, this.sid, this.chat);
  final Object issuer;
  final String token, project, uid, sid, chat;
}

/// Created synchronously before a route's first build. Until its durable
/// wildcard lease settles, this isolate refuses history eviction. Other
/// engines are fenced by their database-handle guards.
class ChatHistoryRouteHold {
  ChatHistoryRouteHold(ProjectChatServerCache? cache) : _cache = cache {
    _pendingRouteHolds++;
    unawaited(_start());
  }
  final ProjectChatServerCache? _cache;
  final Completer<void> _ready = Completer<void>();
  ChatHistoryRouteLease? _lease;
  bool _closed = false, _failed = false;

  Future<void> get ready => _ready.future;
  bool get isReady => _ready.isCompleted;

  Future<void> _start() async {
    try {
      final cache = _cache;
      ChatHistoryRouteLease? lease;
      if (cache != null) {
        final acquisition = cache.acquireHistoryRouteLease('*');
        var timedOut = false;
        lease = await acquisition.timeout(const Duration(milliseconds: 300),
            onTimeout: () { timedOut = true; return null; });
        if (timedOut) {
          // The underlying operation is not cancelled. Never adopt a late
          // lease: release it once it settles, even if this route has closed.
          unawaited(acquisition.then<void>((lateLease) async {
            if (lateLease != null) {
              try { await cache.releaseHistoryRouteLease(lateLease); } catch (_) {}
            }
          }, onError: (Object _, StackTrace __) {}));
        }
      }
      if (_closed) {
        if (lease != null && cache != null) await cache.releaseHistoryRouteLease(lease);
      } else if (lease == null) {
        _failed = true;
        _failedRouteHolds++;
      } else {
        _lease = lease;
      }
    } catch (_) {
      if (!_closed) { _failed = true; _failedRouteHolds++; }
    } finally {
      // A failed acquisition cannot show cached UI while a previously started
      // native commit is still settling. New evictions see the failed hold.
      if (_failed) await Future.wait(List<Future<void>>.of(_historyEvictionBarriers));
      _pendingRouteHolds--;
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_failed) { _failed = false; _failedRouteHolds--; }
    await ready;
    final lease = _lease;
    _lease = null;
    if (lease != null && _cache != null) {
      await _cache.releaseHistoryRouteLease(lease);
    }
  }
}

int _pendingRouteHolds = 0;
int _failedRouteHolds = 0;
final Set<Future<void>> _historyEvictionBarriers = {};

/// Synchronous guard for capturing an already-loaded snapshot before eviction.
bool get historyEvictionInProgress => _historyEvictionBarriers.isNotEmpty;

class ChatHistoryAppGuard {
  ChatHistoryAppGuard._(this.issuer, this.token, this.project, this.uid, this.sid,
      this.logicalBytesEvicted);
  final Object issuer;
  final String token, project, uid, sid;
  /// Logical payload reduction only; physical DB and WAL may remain unchanged.
  final int logicalBytesEvicted;
}

class ProjectMediaProtectionSession {
  ProjectMediaProtectionSession._(this.store, this.userId, this._current);
  final MediaCacheProtection store;
  final String userId;
  final bool Function() _current;
  bool get isCurrent {
    try { return _current(); } catch (_) { return false; }
  }
  Future<void> close() => store.endOwnerReadWindow(userId);
}

class ChatHistoryCompaction {
  const ChatHistoryCompaction(this.beforeBytes, this.afterBytes);
  final int beforeBytes, afterBytes;
  int get physicallyFreedBytes => beforeBytes > afterBytes ? beforeBytes - afterBytes : 0;
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
  @visibleForTesting
  Future<void> Function()? debugBeforeSummaryCommit;
  @visibleForTesting
  Future<void> Function()? debugBeforePageCommit;
  @visibleForTesting
  Future<void> Function()? debugBeforeHistoryEvictCommit;
  static final Map<String, int> _eventVersions = {};
  /// Invalidates in-process consumers before a snapshot mutation can begin.
  /// This does not provide cross-process invalidation.
  static final ValueNotifier<int> snapshotChanges = ValueNotifier<int>(0);
  static int _snapshotMutations = 0;
  static bool get snapshotMutationInProgress => _snapshotMutations != 0;
  static void _beginSnapshotMutation() { _snapshotMutations++; snapshotChanges.value++; }
  static void _endSnapshotMutation() { _snapshotMutations--; snapshotChanges.value++; }
  static final Set<String> _eventQuarantine = {};
  static final Map<String, Future<void>> _eventQueues = {};

  /// Opens a prewarmed owner-wide file lease bound to the exact auth scope.
  /// No media eviction is enabled by this method.
  Future<ProjectMediaProtectionSession?> openMediaProtection(Directory root) async {
    final owner = scope.capture(), binding = currentBinding(), guard = _databaseAppGuards[db];
    final issuerBase = project.replaceFirst(RegExp(r'/+$'), '');
    if (owner == null || binding == null || guard?.isHeld != true ||
        owner.userId != binding.userId || binding.issuer != '$issuerBase/auth/v1') return null;
    bool current() => scope.isCurrent(owner) && _matches(currentBinding(), binding);
    try {
      final store = MediaCacheProtection(db: db, root: root, project: project,
        databaseToken: guard!.token, currentOwner: () => current() ? owner.userId : null,
        currentSessionId: () => current() ? binding.sessionId : null);
      await store.initialize();
      if (!current() || !await store.beginOwnerReadWindow(owner.userId, current)) return null;
      if (!current()) { await store.endOwnerReadWindow(owner.userId); return null; }
      store.accessRecovery = recoverDeadAccessGuards().then<bool>((_) => true,
          onError: (Object _, StackTrace __) => false);
      return ProjectMediaProtectionSession._(store, owner.userId, current);
    } catch (_) { return null; }
  }

  Future<void> _touchHistory(Transaction txn, OfflineSessionBinding binding,
      String chat) => txn.insert('chat_snapshot_access', {
        'project': project, 'uid': binding.userId, 'sid': binding.sessionId,
        'chat': chat, 'access_ms': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace).then((_) {});

  /// Must be acquired before a route reads or displays the cached chat.
  /// A crash leaves a durable lease and prevents automatic eviction.
  Future<ChatHistoryRouteLease?> acquireHistoryRouteLease(String chat) async {
    final owner = scope.capture(), binding = currentBinding();
    final databaseGuard = _databaseAppGuards[db];
    if (owner == null || binding == null || chat.isEmpty ||
        databaseGuard == null || owner.userId != binding.userId || binding.issuer != '$project/auth/v1') return null;
    bool current() => scope.isCurrent(owner) && _matches(currentBinding(), binding);
    final token = _newGuardToken();
    try {
      return await db.transaction((txn) async {
        if (!current()) throw const _StalePage();
        await txn.insert('chat_route_leases', {
          'token': token, 'project': project, 'uid': binding.userId,
          'sid': binding.sessionId, 'chat': chat, 'database_token': databaseGuard.token,
        });
        if (!current()) throw const _StalePage();
        return ChatHistoryRouteLease._(_issuer, token, project, binding.userId, binding.sessionId, chat);
      });
    } on _StalePage { return null; }
  }

  Future<void> releaseHistoryRouteLease(ChatHistoryRouteLease lease) async {
    if (!identical(lease.issuer, _issuer) || lease.project != project) return;
    await db.delete('chat_route_leases', where: 'token=? AND project=? AND uid=? AND sid=? AND chat=?',
        whereArgs: [lease.token, lease.project, lease.uid, lease.sid, lease.chat]);
  }

  // The guard directory is private to the app. Lock files are unique and are
  // never replaced or deleted. Same-PID guards are never probed because POSIX
  // advisory locks are process-wide and closing another fd could unlock them.
  Future<void> _recoverDeadHandles(Transaction txn, List<RandomAccessFile> held) async {
    final rows = await txn.query('chat_app_guards', columns: ['token', 'uid'],
        where: 'project=?', whereArgs: ['*']);
    final directory = Directory('${db.path}.guards');
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) return;
    for (final row in rows) {
      final token = row['token'], rawPid = row['uid'];
      if (token is! String || rawPid is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(token)) continue;
      final ownerPid = int.tryParse(rawPid);
      if (ownerPid == null || ownerPid <= 0 || ownerPid == pid) continue;
      final marker = File('${directory.path}/$token');
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file) continue;
      RandomAccessFile? file;
      try {
        file = await marker.open(mode: FileMode.append);
        await file.lock(FileLock.exclusive);
        await file.setPosition(0);
        if (await file.length() != token.length ||
            utf8.decode(await file.read(token.length)) != token ||
            await FileSystemEntity.type(marker.path, followLinks: false) != FileSystemEntityType.file) {
          await file.unlock();
          await file.close();
          continue;
        }
        held.add(file);
        file = null;
        await PinnedAccessFence.recoverHandle(txn, token);
        await txn.delete('chat_route_leases', where: 'database_token=?', whereArgs: [token]);
        final media = await txn.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='media_cache_read_leases'");
        if (media.isNotEmpty) {
          await txn.delete('media_cache_read_leases', where: 'database_token=?', whereArgs: [token]);
        }
        await txn.delete('chat_app_guards', where: 'database_token=?', whereArgs: [token]);
      } catch (_) {
        if (file != null) {
          try { await file.unlock(); } catch (_) {}
          try { await file.close(); } catch (_) {}
        }
        // A live process or an unverifiable guard is always retained.
      }
    }
  }

  /// Recovery never authorizes a pinned file; it marks unknown requests
  /// denied until a subsequent successful live check for that object.
  Future<void> recoverDeadAccessGuards() async {
    final held = <RandomAccessFile>[];
    try {
      await debugBeforePinnedRecovery?.call();
      await db.transaction((txn) => _recoverDeadHandles(txn, held));
    } finally {
      for (final file in held) {
        try { await file.unlock(); } catch (_) {}
        try { await file.close(); } catch (_) {}
      }
    }
  }

  /// Call before any engine can expose cached chats. All participating
  /// engines must register a guard; stale guards deliberately stop eviction.
  Future<ChatHistoryAppGuard?> beginHistoryAppGuard(int targetLogicalBytes,
      {required bool allEnginesGuarded}) async {
    final owner = scope.capture(), binding = currentBinding();
    if (!allEnginesGuarded || targetLogicalBytes < 0 || owner == null || binding == null ||
        owner.userId != binding.userId || binding.issuer != '$project/auth/v1') return null;
    bool current() => scope.isCurrent(owner) && _matches(currentBinding(), binding);
    final databaseGuard = _databaseAppGuards[db];
    if (databaseGuard == null || databaseGuard.file == null) return null;
    final token = _newGuardToken();
    final recoveredLocks = <RandomAccessFile>[];
    final mayEvict = targetLogicalBytes > 0 && _pendingRouteHolds == 0 && _failedRouteHolds == 0;
    final settled = Completer<void>();
    if (mayEvict) _historyEvictionBarriers.add(settled.future);
    try {
      return await db.transaction((txn) async {
        if (!current()) throw const _StalePage();
        await _recoverDeadHandles(txn, recoveredLocks);
        if (!current()) throw const _StalePage();
        final guards = await txn.query('chat_app_guards', columns: ['token'],
            where: 'token<>?', whereArgs: [databaseGuard.token], limit: 1);
        final removed = guards.isEmpty && mayEvict &&
                _pendingRouteHolds == 0 && _failedRouteHolds == 0
            ? await _evictServerHistory(txn, binding, () => current() &&
                _pendingRouteHolds == 0 && _failedRouteHolds == 0, targetLogicalBytes)
            : 0;
        await txn.insert('chat_app_guards', {'token': token, 'project': project,
          'uid': binding.userId, 'sid': binding.sessionId, 'database_token': databaseGuard.token});
        if (!current()) throw const _StalePage();
        return ChatHistoryAppGuard._(_issuer, token, project, binding.userId,
            binding.sessionId, removed);
      });
    } on _StalePage { return null; }
    finally {
      for (final file in recoveredLocks) {
        try { await file.unlock(); } catch (_) {}
        try { await file.close(); } catch (_) {}
      }
      if (mayEvict) {
        _historyEvictionBarriers.remove(settled.future);
        settled.complete();
      }
    }
  }

  Future<void> releaseHistoryAppGuard(ChatHistoryAppGuard guard) async {
    if (!identical(guard.issuer, _issuer) || guard.project != project) return;
    await db.delete('chat_app_guards', where: 'token=? AND project=? AND uid=? AND sid=?',
        whereArgs: [guard.token, guard.project, guard.uid, guard.sid]);
  }

  /// Optional maintenance for incremental or FULL auto-vacuum databases.
  /// Existing databases never undergo a full VACUUM or schema rewrite.
  Future<ChatHistoryCompaction?> compactHistory(ChatHistoryAppGuard guard) async {
    if (!identical(guard.issuer, _issuer) || guard.project != project) return null;
    final owner = scope.capture(), binding = currentBinding();
    if (owner == null || binding == null || owner.userId != guard.uid ||
        binding.userId != guard.uid || binding.sessionId != guard.sid ||
        binding.issuer != '$project/auth/v1') return null;
    bool current() => scope.isCurrent(owner) && _matches(currentBinding(), binding);
    Future<int> physicalBytes() async {
      var total = 0;
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('${db.path}$suffix');
        if (await file.exists()) total += (await file.stat()).size;
      }
      return total;
    }
    try {
      final guards = await db.query('chat_app_guards', columns: ['token']);
      final databaseGuard = _databaseAppGuards[db];
      final guardTokens = guards.map((row) => row['token']).toSet();
      if (!current() || databaseGuard == null || guards.length != 2 ||
          !guardTokens.contains(databaseGuard.token) || !guardTokens.contains(guard.token)) return null;
      final mode = await db.rawQuery('PRAGMA auto_vacuum');
      if (mode.length != 1 || (mode.single.values.single != 1 && mode.single.values.single != 2)) return null;
      final before = await physicalBytes();
      if (mode.single.values.single == 2) {
        await db.rawQuery('PRAGMA incremental_vacuum');
      }
      if (!current()) return null;
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      if (!current()) return null;
      final after = await physicalBytes();
      return ChatHistoryCompaction(before, after);
    } catch (error) {
      if (kDebugMode) debugPrint('[history-compaction] failed: ${error.runtimeType} $error');
      return null;
    }
  }

  Future<int> _evictServerHistory(Transaction txn, OfflineSessionBinding binding,
      bool Function() current, int targetLogicalBytes) async {
        final rows = await txn.rawQuery('SELECT s.chat, s.payload FROM chat_server_snapshot s '
            'JOIN chat_snapshot_access a ON s.project=a.project AND s.uid=a.uid AND s.sid=a.sid AND s.chat=a.chat '
            'WHERE s.project=? AND s.uid=? AND s.sid=? AND s.chat<>? '
            'AND NOT EXISTS (SELECT 1 FROM chat_route_leases l WHERE l.project=s.project AND l.uid=s.uid AND l.sid=s.sid AND (l.chat=s.chat OR l.chat=\'*\')) '
            'ORDER BY a.access_ms ASC, s.chat ASC', [project, binding.userId, binding.sessionId, summaryChatKey]);
        var removed = 0;
        for (final row in rows) {
          if (removed >= targetLogicalBytes) break;
          if (!current()) throw const _StalePage();
          final chat = row['chat'], payload = row['payload'];
          if (chat is! String || payload is! String ||
              !_isRecoverableHistorySnapshot(chat, payload)) continue;
          final args = [project, binding.userId, binding.sessionId, chat];
          final attempts = await txn.query('chat_server_attempt', columns: ['seq', 'blocked'],
              where: 'project=? AND uid=? AND sid=? AND chat=?', whereArgs: args);
          if (!current()) throw const _StalePage();
          if (attempts.length != 1) continue;
          final seq = attempts.single['seq'], blocked = attempts.single['blocked'];
          if (seq is! int || seq < 0 || seq >= 9223372036854775807 ||
              blocked is! int || blocked != 0) continue;
          final changed = await txn.rawUpdate(
              'UPDATE chat_server_attempt SET seq=seq+1 WHERE project=? AND uid=? AND sid=? AND chat=? AND seq=? AND blocked=0',
              [...args, seq]);
          if (!current()) throw const _StalePage();
          if (changed != 1) continue;
          await txn.delete('chat_server_snapshot', where: 'project=? AND uid=? AND sid=? AND chat=?', whereArgs: args);
          await txn.delete('chat_snapshot_access', where: 'project=? AND uid=? AND sid=? AND chat=?', whereArgs: args);
          removed += utf8.encode(payload).length;
        }
        await debugBeforeHistoryEvictCommit?.call();
        if (!current()) throw const _StalePage();
        return removed;
  }

  // Unknown or mixed rows can contain unsent data from older versions. Only
  // discard an entire snapshot when every entry is a confirmed server copy.
  bool _isRecoverableHistorySnapshot(String chat, String payload) {
    try {
      if (chat.trim().isEmpty) return false;
      final decoded = jsonDecode(payload);
      if (decoded is! List) return false;
      for (final raw in decoded) {
        if (raw is! Map || raw['chat_id'] != chat ||
            raw['id'] is! String || (raw['id'] as String).isEmpty ||
            (raw['id'] as String).trim().isEmpty ||
            (raw['id'] as String).startsWith('local_') ||
            raw['delivery_status'] != 'sent' ||
            raw['client_id'] != null || raw['clientId'] != null ||
            DateTime.tryParse((raw['created_at'] ?? raw['at'] ?? '').toString()) == null) return false;
        for (final key in ['imagePath', 'image_path']) {
          final value = raw[key];
          if (value != null && (value is! String || value.isNotEmpty)) return false;
        }
        for (final key in ['outbound_file_ids', 'outboundFileIds']) {
          final value = raw[key];
          if (value != null && (value is! List || value.isNotEmpty)) return false;
        }
      }
      return _parse(payload, chat) != null;
    } catch (_) {
      return false;
    }
  }
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
  Future<ProjectChatPageTicket?> begin(String chat, {bool Function()? isCurrent}) async {
    final owner = scope.capture();
    final binding = currentBinding();
    if (owner == null ||
        binding == null ||
        chat.isEmpty ||
        project.isEmpty ||
        owner.userId != binding.userId ||
        binding.issuer != '$project/auth/v1' ||
        _eventQuarantine.contains(_eventKey(binding, chat))) return null;
    _beginSnapshotMutation();
    bool valid() {
      try {
        return scope.isCurrent(owner) &&
            _matches(currentBinding(), binding) &&
            !_eventQuarantine.contains(_eventKey(binding, chat)) &&
            (isCurrent?.call() ?? true);
      } catch (_) { return false; }
    }
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
      return ProjectChatPageTicket._(_issuer, owner, binding, chat, seq, isCurrent);
    } on _StalePage {
      return null;
    } finally {
      _endSnapshotMutation();
    }
  }

  bool _current(ProjectChatPageTicket t) {
    try {
      return identical(t._issuer, _issuer) &&
          scope.isCurrent(t._owner) &&
          _matches(currentBinding(), t._binding) &&
          !_eventQuarantine.contains(_eventKey(t._binding, t._chat)) &&
          (t._guard?.call() ?? true);
    } catch (_) { return false; }
  }

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
    _beginSnapshotMutation();
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
        await _touchHistory(txn, b, t._chat);
        if (kDebugMode && debugBeforePageCommit != null) await debugBeforePageCommit!();
        if (!_current(t)) throw const _StalePage();
        return true;
      });
    } on _StalePage {
      return false;
    } finally {
      _endSnapshotMutation();
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
        final pause = debugBeforeSummaryCommit;
        if (pause != null) await pause();
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
    _beginSnapshotMutation();
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
      _endSnapshotMutation();
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
    _beginSnapshotMutation();
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
    } finally {
      _endSnapshotMutation();
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
      String chat, SessionCapabilities capabilities) =>
      _readForMode(chat, capabilities, SessionCapabilityMode.cacheOnly);

  /// Read-only QA prewarm. It cannot grant offline access and never writes.
  Future<List<Message>?> readForOnlinePrewarm(
      String chat, SessionCapabilities capabilities) =>
      _readForMode(chat, capabilities, SessionCapabilityMode.online);

  Future<List<Message>?> _readForMode(String chat,
      SessionCapabilities capabilities, SessionCapabilityMode mode) async {
    final permit = capabilities.capture(SessionCapability.cachedRead);
    final owner = scope.capture();
    final binding = currentBinding();
    if (permit == null ||
        owner == null ||
        binding == null ||
        capabilities.mode != mode ||
        !capabilities.owns(permit, owner) ||
        owner.userId != binding.userId ||
        binding.issuer != '$project/auth/v1' ||
        chat.isEmpty ||
        _eventQuarantine.contains(_eventKey(binding, chat))) return null;
    bool valid() =>
        scope.isCurrent(owner) &&
        _matches(currentBinding(), binding) &&
        capabilities.mode == mode &&
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
      final parsed = _parse(rows.single['payload'] as String, chat);
      if (parsed == null || !valid()) return null;
      await _touchHistory(txn, binding, chat);
      if (!valid()) return null;
      return parsed;
    });
  }
}

class _StalePage implements Exception {
  const _StalePage();
}
