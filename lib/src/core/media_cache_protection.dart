import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Durable metadata for private cached files. Unknown files are never
/// candidates. A file is pinned when first registered; callers must obtain
/// explicit user intent before unpinning it.
class MediaCacheProtection {
  MediaCacheProtection(
      {required this.db,
      required this.root,
      required this.project,
      required this.databaseToken,
      required this.currentOwner,
      this.currentSessionId});
  final Database db;
  final Directory root;
  final String project, databaseToken;
  final String? Function() currentOwner;
  final String? Function()? currentSessionId;

  /// Set by the managed database bootstrap before this store is published.
  Future<bool>? accessRecovery;
  final Map<String, _OwnerReadWindow> _readWindows = {};
  final Map<String, int> _windowEpochs = {};
  @visibleForTesting
  Future<void> Function()? debugAfterWindowInsert;
  @visibleForTesting
  Future<void> Function()? debugAfterBatchInsert;
  @visibleForTesting
  Future<void> Function()? debugAfterEvictionRename;
  @visibleForTesting
  Future<void> Function()? debugBeforeRecoveryRename;

  Future<void> initialize() async {
    await db.execute('CREATE TABLE IF NOT EXISTS media_cache_objects ('
        'project TEXT NOT NULL, uid TEXT NOT NULL, digest TEXT NOT NULL, '
        'pinned INTEGER NOT NULL CHECK(pinned IN (0,1)), touched INTEGER NOT NULL, '
        'PRIMARY KEY(project,uid,digest))');
    await db.execute('CREATE TABLE IF NOT EXISTS media_cache_read_leases ('
        'token TEXT NOT NULL PRIMARY KEY, project TEXT NOT NULL, uid TEXT NOT NULL, '
        'digest TEXT NOT NULL, database_token TEXT NOT NULL)');
    await db
        .execute('CREATE TABLE IF NOT EXISTS media_cache_logout_tombstones ('
            'project TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL, '
            'PRIMARY KEY(project,uid,sid))');
    await db.execute('CREATE TABLE IF NOT EXISTS media_cache_eviction_journal ('
        'token TEXT PRIMARY KEY, project TEXT NOT NULL, uid TEXT NOT NULL, digest TEXT NOT NULL, '
        'database_token TEXT NOT NULL, state TEXT NOT NULL, size INTEGER NOT NULL, '
        'UNIQUE(project,uid,digest))');
    final columns =
        await db.rawQuery('PRAGMA table_info(media_cache_eviction_journal)');
    if (!columns.any((row) => row['name'] == 'sid')) {
      try {
        await db.execute(
            'ALTER TABLE media_cache_eviction_journal ADD COLUMN sid TEXT');
      } catch (_) {
        final retry = await db
            .rawQuery('PRAGMA table_info(media_cache_eviction_journal)');
        if (!retry.any((row) => row['name'] == 'sid')) rethrow;
      }
    }
  }

  /// Durable logout fence. The caller must capture identity before invalidating
  /// its scope and await completion before deleting files or signing out.
  Future<bool> markSessionLoggedOut(String uid, String sid,
      {required bool Function() stillCurrent}) async {
    if (uid.isEmpty || sid.isEmpty || !stillCurrent()) return false;
    return db.transaction((txn) async {
      if (!stillCurrent()) return false;
      await txn.insert('media_cache_logout_tombstones',
          {'project': project, 'uid': uid, 'sid': sid},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      return stillCurrent();
    });
  }

  Future<bool> _sessionAllowed(
      Transaction txn, String uid, String sid, bool Function() permit) async {
    if (sid.isEmpty ||
        !_current(uid, permit) ||
        currentSessionId?.call() != sid) return false;
    final rows = await txn.query('media_cache_logout_tombstones',
        columns: ['sid'],
        where: 'project=? AND uid=? AND sid=?',
        whereArgs: [project, uid, sid],
        limit: 1);
    return rows.isEmpty &&
        _current(uid, permit) &&
        currentSessionId?.call() == sid;
  }

  String digest(String uid, String key) =>
      sha256.convert(utf8.encode('$uid:$key')).toString();

  Future<File?> _checkedFile(String uid, String key) async {
    if (key.isEmpty) return null;
    return _checkedHash(uid, digest(uid, key));
  }

  /// Returns only an exact, non-symlink legacy cache path for this owner.
  Future<File?> verifiedExistingFile(
      String uid, String key, bool Function() permit) async {
    if (!_current(uid, permit)) return null;
    final file = await _checkedFile(uid, key);
    return _current(uid, permit) ? file : null;
  }

  Future<File?> _checkedHash(String uid, String hash) async {
    if (uid.isEmpty ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(uid) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) return null;
    final ownerDir = Directory('${root.path}/authorized_chat_files/$uid');
    final file = File('${ownerDir.path}/$hash');
    try {
      for (final path in [
        root.path,
        '${root.path}/authorized_chat_files',
        ownerDir.path
      ]) {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory) return null;
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) return null;
      final canonicalDir = await ownerDir.resolveSymbolicLinks();
      final canonicalFile = await file.resolveSymbolicLinks();
      if (File(canonicalFile).parent.path != canonicalDir) return null;
      return file;
    } catch (_) {
      return null;
    }
  }

  bool _current(String uid, bool Function() permit) {
    try {
      return uid == currentOwner() && permit();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _guardPresent(Transaction txn) async {
    try {
      final rows = await txn.query('chat_app_guards',
          columns: ['token'],
          where: 'token=? AND project=? AND sid=?',
          whereArgs: [databaseToken, '*', '']);
      return rows.length == 1;
    } catch (_) {
      return false;
    }
  }

  /// One durable wildcard lease protects all this owner's cached files while
  /// the window is open. It can be warmed before any image is displayed.
  Future<bool> beginOwnerReadWindow(String uid, bool Function() permit) async {
    if (uid.isEmpty || databaseToken.isEmpty || !_current(uid, permit))
      return false;
    if (_readWindows.containsKey(uid)) return false;
    final epoch = _windowEpochs[uid] ?? 0;
    final random = Random.secure();
    final token =
        base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
    final acquired = await db.transaction((txn) async {
      if (!_current(uid, permit) || !await _guardPresent(txn)) return false;
      if ((await txn.query('media_cache_eviction_journal',
              columns: ['token'], where: 'uid=?', whereArgs: [uid], limit: 1))
          .isNotEmpty) return false;
      await txn.insert('media_cache_read_leases', {
        'token': token,
        'project': project,
        'uid': uid,
        'digest': '*',
        'database_token': databaseToken
      });
      await debugAfterWindowInsert?.call();
      if (!_current(uid, permit))
        throw StateError('Session changed during media window');
      return true;
    });
    if (!acquired) return false;
    if (!_current(uid, permit) ||
        (_windowEpochs[uid] ?? 0) != epoch ||
        _readWindows.containsKey(uid)) {
      await db.delete('media_cache_read_leases',
          where: 'token=? AND database_token=?',
          whereArgs: [token, databaseToken]);
      return false;
    }
    _readWindows[uid] = _OwnerReadWindow(token, permit);
    return true;
  }

  bool hasOwnerReadWindow(String uid, bool Function() permit) {
    final window = _readWindows[uid];
    return window != null &&
        !window.closing &&
        _current(uid, window.permit) &&
        _current(uid, permit);
  }

  Future<T> readInOwnerWindow<T>(
      String uid, bool Function() permit, Future<T> Function() read) async {
    final window = _readWindows[uid];
    if (window == null || !hasOwnerReadWindow(uid, permit)) {
      throw StateError('Media read window unavailable');
    }
    window.readers++;
    try {
      final result = await read();
      if (!_current(uid, window.permit) || !_current(uid, permit)) {
        throw StateError('Session changed during media read');
      }
      return result;
    } finally {
      window.readers--;
      if (window.readers == 0 &&
          window.drained != null &&
          !window.drained!.isCompleted) {
        window.drained!.complete();
      }
    }
  }

  /// Stops admitting new fast reads synchronously, then waits for all reads
  /// which already started before releasing the durable wildcard lease.
  Future<void> endOwnerReadWindow(String uid) async {
    _windowEpochs[uid] = (_windowEpochs[uid] ?? 0) + 1;
    final window = _readWindows[uid];
    if (window == null || window.closing) return;
    window.closing = true;
    if (window.readers != 0) {
      window.drained = Completer<void>();
      await window.drained!.future;
    }
    await db.delete('media_cache_read_leases',
        where: 'token=? AND database_token=?',
        whereArgs: [window.token, databaseToken]);
    if (identical(_readWindows[uid], window)) _readWindows.remove(uid);
  }

  /// Registers only the expected real file; never turns an existing pin off.
  Future<bool> registerPinned(
      String uid, String key, bool Function() permit) async {
    if (!_current(uid, permit) || await _checkedFile(uid, key) == null)
      return false;
    return db.transaction((txn) async {
      if (!_current(uid, permit) || await _checkedFile(uid, key) == null)
        return false;
      if ((await txn.query('media_cache_eviction_journal',
              columns: ['token'],
              where: 'uid=? AND digest=?',
              whereArgs: [uid, digest(uid, key)],
              limit: 1))
          .isNotEmpty) return false;
      await txn.insert(
          'media_cache_objects',
          {
            'project': project,
            'uid': uid,
            'digest': digest(uid, key),
            'pinned': 1,
            'touched': DateTime.now().millisecondsSinceEpoch
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.update('media_cache_objects', {'pinned': 1},
          where: 'project=? AND uid=? AND digest=?',
          whereArgs: [project, uid, digest(uid, key)]);
      return _current(uid, permit);
    });
  }

  Future<String?> acquireRead(
      String uid, String key, bool Function() permit) async {
    if (!_current(uid, permit) || await _checkedFile(uid, key) == null)
      return null;
    final random = Random.secure();
    final token =
        base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
    return db.transaction((txn) async {
      if (!_current(uid, permit) || await _checkedFile(uid, key) == null)
        return null;
      if ((await txn.query('media_cache_eviction_journal',
              columns: ['token'],
              where: 'uid=? AND digest=?',
              whereArgs: [uid, digest(uid, key)],
              limit: 1))
          .isNotEmpty) return null;
      final matches = await txn.query('media_cache_objects',
          columns: ['pinned'],
          where: 'project=? AND uid=? AND digest=?',
          whereArgs: [project, uid, digest(uid, key)]);
      if (matches.length != 1 || !_current(uid, permit)) return null;
      await txn.insert('media_cache_read_leases', {
        'token': token,
        'project': project,
        'uid': uid,
        'digest': digest(uid, key),
        'database_token': databaseToken
      });
      if (!_current(uid, permit))
        throw StateError('Session changed during media lease');
      return token;
    });
  }

  /// Acquires one bounded, atomic group of specific file leases. Unlike an
  /// owner-wide window, unrelated files can remain candidates for cleanup.
  /// Unknown, missing or unregistered files fail the whole group closed.
  Future<MediaReadBatch?> acquireReadBatch(
      String uid, Iterable<String> keys, bool Function() permit) async {
    final unique = keys.toSet();
    if (unique.isEmpty || unique.length > 64 || !_current(uid, permit))
      return null;
    for (final key in unique) {
      if (await _checkedFile(uid, key) == null || !_current(uid, permit))
        return null;
    }
    final random = Random.secure();
    final prefix =
        base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
    try {
      return await db.transaction((txn) async {
        if (!_current(uid, permit) || !await _guardPresent(txn)) return null;
        final entries = <(String, String)>[];
        var index = 0;
        for (final key in unique) {
          if (!_current(uid, permit) || await _checkedFile(uid, key) == null) {
            throw StateError('Media batch changed during admission');
          }
          final hash = digest(uid, key);
          if ((await txn.query('media_cache_eviction_journal',
                  columns: ['token'],
                  where: 'uid=? AND digest=?',
                  whereArgs: [uid, hash],
                  limit: 1))
              .isNotEmpty) {
            throw StateError('Media eviction in progress');
          }
          final rows = await txn.query('media_cache_objects',
              columns: ['digest'],
              where: 'project=? AND uid=? AND digest=?',
              whereArgs: [project, uid, hash]);
          if (rows.length != 1) throw StateError('Unknown media object');
          final token = '$prefix:${index++}';
          await txn.insert('media_cache_read_leases', {
            'token': token,
            'project': project,
            'uid': uid,
            'digest': hash,
            'database_token': databaseToken
          });
          await debugAfterBatchInsert?.call();
          await txn.update('media_cache_objects',
              {'touched': DateTime.now().millisecondsSinceEpoch},
              where: 'project=? AND uid=? AND digest=?',
              whereArgs: [project, uid, hash]);
          entries.add((hash, token));
        }
        if (!_current(uid, permit))
          throw StateError('Session changed during media batch');
        return MediaReadBatch._(project, uid, databaseToken, entries);
      });
    } catch (_) {
      return null;
    }
  }

  Future<void> releaseReadBatch(MediaReadBatch batch) async {
    if (batch.project != project || batch.databaseToken != databaseToken)
      return;
    await db.transaction((txn) async {
      for (final entry in batch._entries) {
        await txn.delete('media_cache_read_leases',
            where:
                'token=? AND project=? AND uid=? AND digest=? AND database_token=?',
            whereArgs: [
              entry.$2,
              batch.project,
              batch.uid,
              entry.$1,
              databaseToken
            ]);
      }
    });
  }

  Future<void> releaseRead(String uid, String key, String token) async {
    await db.delete('media_cache_read_leases',
        where:
            'token=? AND project=? AND uid=? AND digest=? AND database_token=?',
        whereArgs: [token, project, uid, digest(uid, key), databaseToken]);
  }

  /// Only an explicit user action may change a protected file to evictable.
  Future<bool> unpin(String uid, String key,
      {required bool explicitlyAllowed,
      required bool Function() permit}) async {
    if (!explicitlyAllowed ||
        !_current(uid, permit) ||
        await _checkedFile(uid, key) == null) return false;
    return db.transaction((txn) async {
      if (!_current(uid, permit)) return false;
      final count = await txn.update('media_cache_objects', {'pinned': 0},
          where: 'project=? AND uid=? AND digest=?',
          whereArgs: [project, uid, digest(uid, key)]);
      if (!_current(uid, permit))
        throw StateError('Session changed during unpin');
      return count == 1;
    });
  }

  // The staging path is derived exclusively from a verified owner/hash/token.
  // It is never accepted from a database path or from a caller.
  File? _evictionFile(String uid, String hash, String token) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(uid) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(token)) return null;
    return File('${root.path}/authorized_chat_files/$uid/.evict-$token-$hash');
  }

  /// Restores an interrupted eviction instead of deleting its last copy.
  /// The caller must either own the in-flight operation or prove its handle
  /// has been removed from chat_app_guards inside the same transaction.
  Future<bool> _restoreEviction(String uid, String hash, String token,
      {required bool ownOperation,
      required bool Function() permit,
      bool Function(String)? mayRestore}) async {
    final staged = _evictionFile(uid, hash, token);
    if (staged == null) return false;
    try {
      return await db.transaction((txn) async {
        final rows = await txn.query('media_cache_eviction_journal',
            where: 'token=? AND project=? AND uid=? AND digest=?',
            whereArgs: [token, project, uid, hash]);
        if (rows.length != 1) return false;
        final sid = rows.single['sid'];
        if (sid is! String || !await _sessionAllowed(txn, uid, sid, permit))
          return false;
        if (!ownOperation) {
          // A dead handle does not distinguish a crash from a completed
          // logout. An external proof must bind the old handle to the same
          // continuously authorised session before any restoration.
          final origin = rows.single['database_token'];
          if (origin is! String || mayRestore?.call(origin) != true) {
            return false;
          }
          final guards = await txn.query('chat_app_guards',
              columns: ['token'], where: 'token=?', whereArgs: [origin]);
          if (guards.isNotEmpty) return false;
        }
        final directory = Directory('${root.path}/authorized_chat_files/$uid');
        for (final path in [
          root.path,
          '${root.path}/authorized_chat_files',
          directory.path
        ]) {
          if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.directory) return false;
        }
        if (!await _sessionAllowed(txn, uid, sid, permit)) return false;
        final original = File('${directory.path}/$hash');
        final originalType =
            await FileSystemEntity.type(original.path, followLinks: false);
        final stagedType =
            await FileSystemEntity.type(staged.path, followLinks: false);
        if (originalType == FileSystemEntityType.notFound &&
            stagedType == FileSystemEntityType.file) {
          await debugBeforeRecoveryRename?.call();
          if (!await _sessionAllowed(txn, uid, sid, permit)) return false;
          await staged.rename(original.path);
        } else if (!(originalType == FileSystemEntityType.file &&
            stagedType == FileSystemEntityType.notFound)) {
          // Two copies, a symlink, or no copy: leave the journal in place.
          return false;
        }
        if (!await _sessionAllowed(txn, uid, sid, permit))
          throw StateError('Session changed during recovery');
        await txn.insert(
            'media_cache_objects',
            {
              'project': project,
              'uid': uid,
              'digest': hash,
              'pinned': 1,
              'touched': DateTime.now().millisecondsSinceEpoch
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.delete('media_cache_eviction_journal',
            where: 'token=?', whereArgs: [token]);
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  /// Restores only operations whose database handle has already been proven
  /// dead by guard recovery. Unknown or still-live handles stay protected.
  Future<int> recoverInterruptedEvictions(String uid, bool Function() permit,
      {bool Function(String databaseToken)? mayRestore}) async {
    if (!_current(uid, permit)) return 0;
    try {
      final rows = await db.query('media_cache_eviction_journal',
          columns: ['token', 'digest'],
          where: 'project=? AND uid=?',
          whereArgs: [project, uid]);
      var restored = 0;
      for (final row in rows) {
        if (!_current(uid, permit)) break;
        final token = row['token'], hash = row['digest'];
        if (token is String &&
            hash is String &&
            await _restoreEviction(uid, hash, token,
                ownOperation: false,
                permit: permit,
                mayRestore: mayRestore)) restored++;
      }
      return restored;
    } catch (_) {
      return 0;
    }
  }

  /// Eviction remains QA-only until all writers/readers participate. Journal
  /// first, stage by same-directory rename, then commit the metadata change.
  /// An interrupted operation is restored, never silently deleted by rollback.
  Future<int> evict(String uid, int requestedBytes,
      {required bool allOperationsParticipate,
      required bool Function() permit}) async {
    if (!const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA') ||
        !allOperationsParticipate ||
        requestedBytes <= 0 ||
        !_current(uid, permit)) return 0;
    final sid = currentSessionId?.call();
    if (sid == null || sid.isEmpty) return 0;
    final candidates = await db.rawQuery(
        'SELECT o.digest FROM media_cache_objects o '
        'WHERE o.project=? AND o.uid=? AND o.pinned=0 AND NOT EXISTS '
        '(SELECT 1 FROM media_cache_objects other WHERE other.uid=o.uid AND other.digest=o.digest AND other.project<>o.project) AND NOT EXISTS '
        '(SELECT 1 FROM media_cache_read_leases l WHERE l.uid=o.uid AND (l.digest=o.digest OR l.digest=\'*\')) '
        'ORDER BY o.touched ASC, o.digest ASC',
        [project, uid]);
    var removed = 0;
    for (final row in candidates) {
      if (removed >= requestedBytes || !_current(uid, permit)) break;
      final hash = row['digest'];
      if (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))
        continue;
      final file = await _checkedHash(uid, hash);
      if (file == null || !_current(uid, permit)) continue;
      final token = base64UrlEncode(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)));
      final staged = _evictionFile(uid, hash, token);
      if (staged == null) continue;
      var journaled = false;
      try {
        final size = await file.length();
        journaled = await db.transaction((txn) async {
          if (!await _sessionAllowed(txn, uid, sid, permit) ||
              await _checkedHash(uid, hash) == null) return false;
          final eligible = await txn.rawQuery(
              'SELECT 1 FROM media_cache_objects o '
              'WHERE o.project=? AND o.uid=? AND o.digest=? AND o.pinned=0 AND NOT EXISTS '
              '(SELECT 1 FROM media_cache_objects other WHERE other.uid=o.uid AND other.digest=o.digest AND other.project<>o.project) AND NOT EXISTS '
              '(SELECT 1 FROM media_cache_read_leases l WHERE l.uid=o.uid AND (l.digest=o.digest OR l.digest=\'*\'))',
              [project, uid, hash]);
          if (eligible.length != 1 || await staged.exists()) return false;
          await txn.insert('media_cache_eviction_journal', {
            'token': token,
            'project': project,
            'uid': uid,
            'digest': hash,
            'database_token': databaseToken,
            'sid': sid,
            'state': 'staging',
            'size': size
          });
          if (!_current(uid, permit))
            throw StateError('Session changed during eviction');
          return true;
        });
        if (!journaled) continue;
        if (!_current(uid, permit) || await _checkedHash(uid, hash) == null) {
          if (_current(uid, permit))
            await _restoreEviction(uid, hash, token,
                ownOperation: true, permit: permit);
          continue;
        }
        final stagedOk = await db.transaction((txn) async {
          if (!await _sessionAllowed(txn, uid, sid, permit) ||
              await _checkedHash(uid, hash) == null) return false;
          await file.rename(staged.path);
          if (!await _sessionAllowed(txn, uid, sid, permit)) {
            throw StateError('Session changed during staging');
          }
          return true;
        });
        if (!stagedOk) continue;
        await debugAfterEvictionRename?.call();
        final committed = await db.transaction((txn) async {
          if (!await _sessionAllowed(txn, uid, sid, permit)) return false;
          final leases = await txn.query('media_cache_read_leases',
              columns: ['token'],
              where: 'uid=? AND (digest=? OR digest=?)',
              whereArgs: [uid, hash, '*'],
              limit: 1);
          if (leases.isNotEmpty) return false;
          final shared = await txn.query('media_cache_objects',
              columns: ['digest'],
              where: 'uid=? AND digest=? AND project<>?',
              whereArgs: [uid, hash, project],
              limit: 1);
          if (shared.isNotEmpty) return false;
          final count = await txn.delete('media_cache_objects',
              where: 'project=? AND uid=? AND digest=? AND pinned=0',
              whereArgs: [project, uid, hash]);
          if (count != 1 || !_current(uid, permit))
            throw StateError('Eviction changed');
          await txn.update(
              'media_cache_eviction_journal', {'state': 'committed'},
              where: 'token=?', whereArgs: [token]);
          return true;
        });
        if (!committed) {
          if (_current(uid, permit))
            await _restoreEviction(uid, hash, token,
                ownOperation: true, permit: permit);
          continue;
        }
        await staged.delete();
        if (await FileSystemEntity.type(staged.path, followLinks: false) !=
            FileSystemEntityType.notFound) continue;
        await db.delete('media_cache_eviction_journal',
            where: 'token=?', whereArgs: [token]);
        removed += size;
      } catch (_) {
        if (journaled && _current(uid, permit))
          await _restoreEviction(uid, hash, token,
              ownOperation: true, permit: permit);
      }
    }
    return removed;
  }
}

class MediaReadBatch {
  MediaReadBatch._(this.project, this.uid, this.databaseToken,
      List<(String, String)> entries)
      : _entries = List.unmodifiable(entries);
  final String project, uid, databaseToken;
  final List<(String, String)> _entries;
}

class _OwnerReadWindow {
  _OwnerReadWindow(this.token, this.permit);
  final String token;
  final bool Function() permit;
  int readers = 0;
  bool closing = false;
  Completer<void>? drained;
}
