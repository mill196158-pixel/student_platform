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
  MediaCacheProtection({required this.db, required this.root, required this.project,
    required this.databaseToken, required this.currentOwner});
  final Database db;
  final Directory root;
  final String project, databaseToken;
  final String? Function() currentOwner;
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

  Future<void> initialize() async {
    await db.execute('CREATE TABLE IF NOT EXISTS media_cache_objects ('
      'project TEXT NOT NULL, uid TEXT NOT NULL, digest TEXT NOT NULL, '
      'pinned INTEGER NOT NULL CHECK(pinned IN (0,1)), touched INTEGER NOT NULL, '
      'PRIMARY KEY(project,uid,digest))');
    await db.execute('CREATE TABLE IF NOT EXISTS media_cache_read_leases ('
      'token TEXT NOT NULL PRIMARY KEY, project TEXT NOT NULL, uid TEXT NOT NULL, '
      'digest TEXT NOT NULL, database_token TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS media_cache_eviction_journal ('
      'token TEXT PRIMARY KEY, project TEXT NOT NULL, uid TEXT NOT NULL, digest TEXT NOT NULL, '
      'database_token TEXT NOT NULL, state TEXT NOT NULL, size INTEGER NOT NULL, '
      'UNIQUE(project,uid,digest))');
  }

  String digest(String uid, String key) => sha256.convert(utf8.encode('$uid:$key')).toString();

  Future<File?> _checkedFile(String uid, String key) async {
    if (key.isEmpty) return null;
    return _checkedHash(uid, digest(uid, key));
  }

  /// Returns only an exact, non-symlink legacy cache path for this owner.
  Future<File?> verifiedExistingFile(String uid, String key,
      bool Function() permit) async {
    if (!_current(uid, permit)) return null;
    final file = await _checkedFile(uid, key);
    return _current(uid, permit) ? file : null;
  }

  Future<File?> _checkedHash(String uid, String hash) async {
    if (uid.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(uid) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) return null;
    final ownerDir = Directory('${root.path}/authorized_chat_files/$uid');
    final file = File('${ownerDir.path}/$hash');
    try {
      for (final path in [root.path, '${root.path}/authorized_chat_files', ownerDir.path]) {
        if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.directory) return null;
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) return null;
      final canonicalDir = await ownerDir.resolveSymbolicLinks();
      final canonicalFile = await file.resolveSymbolicLinks();
      if (File(canonicalFile).parent.path != canonicalDir) return null;
      return file;
    } catch (_) { return null; }
  }

  bool _current(String uid, bool Function() permit) {
    try { return uid == currentOwner() && permit(); } catch (_) { return false; }
  }

  Future<bool> _guardPresent(Transaction txn) async {
    try {
      final rows = await txn.query('chat_app_guards', columns: ['token'],
          where: 'token=? AND project=? AND sid=?', whereArgs: [databaseToken, '*', '']);
      return rows.length == 1;
    } catch (_) { return false; }
  }

  /// One durable wildcard lease protects all this owner's cached files while
  /// the window is open. It can be warmed before any image is displayed.
  Future<bool> beginOwnerReadWindow(String uid, bool Function() permit) async {
    if (uid.isEmpty || databaseToken.isEmpty || !_current(uid, permit)) return false;
    if (_readWindows.containsKey(uid)) return false;
    final epoch = _windowEpochs[uid] ?? 0;
    final random = Random.secure();
    final token = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
    final acquired = await db.transaction((txn) async {
      if (!_current(uid, permit) || !await _guardPresent(txn)) return false;
      if ((await txn.query('media_cache_eviction_journal', columns: ['token'],
          where: 'project=? AND uid=?', whereArgs: [project, uid], limit: 1)).isNotEmpty) return false;
      await txn.insert('media_cache_read_leases', {'token': token, 'project': project,
        'uid': uid, 'digest': '*', 'database_token': databaseToken});
      await debugAfterWindowInsert?.call();
      if (!_current(uid, permit)) throw StateError('Session changed during media window');
      return true;
    });
    if (!acquired) return false;
    if (!_current(uid, permit) || (_windowEpochs[uid] ?? 0) != epoch || _readWindows.containsKey(uid)) {
      await db.delete('media_cache_read_leases', where: 'token=? AND database_token=?',
          whereArgs: [token, databaseToken]);
      return false;
    }
    _readWindows[uid] = _OwnerReadWindow(token, permit);
    return true;
  }

  bool hasOwnerReadWindow(String uid, bool Function() permit) {
    final window = _readWindows[uid];
    return window != null && !window.closing && _current(uid, window.permit) && _current(uid, permit);
  }

  Future<T> readInOwnerWindow<T>(String uid, bool Function() permit,
      Future<T> Function() read) async {
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
      if (window.readers == 0 && window.drained != null && !window.drained!.isCompleted) {
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
    await db.delete('media_cache_read_leases', where: 'token=? AND database_token=?',
        whereArgs: [window.token, databaseToken]);
    if (identical(_readWindows[uid], window)) _readWindows.remove(uid);
  }

  /// Registers only the expected real file; never turns an existing pin off.
  Future<bool> registerPinned(String uid, String key, bool Function() permit) async {
    if (!_current(uid, permit) || await _checkedFile(uid, key) == null) return false;
    return db.transaction((txn) async {
      if (!_current(uid, permit) || await _checkedFile(uid, key) == null) return false;
      if ((await txn.query('media_cache_eviction_journal', columns: ['token'],
          where: 'project=? AND uid=? AND digest=?', whereArgs: [project, uid, digest(uid, key)], limit: 1)).isNotEmpty) return false;
      await txn.insert('media_cache_objects', {'project': project, 'uid': uid,
        'digest': digest(uid, key), 'pinned': 1, 'touched': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.update('media_cache_objects', {'pinned': 1},
        where: 'project=? AND uid=? AND digest=?', whereArgs: [project, uid, digest(uid, key)]);
      return _current(uid, permit);
    });
  }

  Future<String?> acquireRead(String uid, String key, bool Function() permit) async {
    if (!_current(uid, permit) || await _checkedFile(uid, key) == null) return null;
    final random = Random.secure();
    final token = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
    return db.transaction((txn) async {
      if (!_current(uid, permit) || await _checkedFile(uid, key) == null) return null;
      if ((await txn.query('media_cache_eviction_journal', columns: ['token'],
          where: 'project=? AND uid=? AND digest=?', whereArgs: [project, uid, digest(uid, key)], limit: 1)).isNotEmpty) return null;
      final matches = await txn.query('media_cache_objects', columns: ['pinned'],
        where: 'project=? AND uid=? AND digest=?', whereArgs: [project, uid, digest(uid, key)]);
      if (matches.length != 1 || !_current(uid, permit)) return null;
      await txn.insert('media_cache_read_leases', {'token': token, 'project': project,
        'uid': uid, 'digest': digest(uid, key), 'database_token': databaseToken});
      if (!_current(uid, permit)) throw StateError('Session changed during media lease');
      return token;
    });
  }

  /// Acquires one bounded, atomic group of specific file leases. Unlike an
  /// owner-wide window, unrelated files can remain candidates for cleanup.
  /// Unknown, missing or unregistered files fail the whole group closed.
  Future<MediaReadBatch?> acquireReadBatch(String uid, Iterable<String> keys,
      bool Function() permit) async {
    final unique = keys.toSet();
    if (unique.isEmpty || unique.length > 64 || !_current(uid, permit)) return null;
    for (final key in unique) {
      if (await _checkedFile(uid, key) == null || !_current(uid, permit)) return null;
    }
    final random = Random.secure();
    final prefix = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
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
          if ((await txn.query('media_cache_eviction_journal', columns: ['token'],
              where: 'project=? AND uid=? AND digest=?', whereArgs: [project, uid, hash], limit: 1)).isNotEmpty) {
            throw StateError('Media eviction in progress');
          }
          final rows = await txn.query('media_cache_objects', columns: ['digest'],
              where: 'project=? AND uid=? AND digest=?', whereArgs: [project, uid, hash]);
          if (rows.length != 1) throw StateError('Unknown media object');
          final token = '$prefix:${index++}';
          await txn.insert('media_cache_read_leases', {'token': token, 'project': project,
            'uid': uid, 'digest': hash, 'database_token': databaseToken});
          await debugAfterBatchInsert?.call();
          await txn.update('media_cache_objects', {'touched': DateTime.now().millisecondsSinceEpoch},
            where: 'project=? AND uid=? AND digest=?', whereArgs: [project, uid, hash]);
          entries.add((hash, token));
        }
        if (!_current(uid, permit)) throw StateError('Session changed during media batch');
        return MediaReadBatch._(project, uid, databaseToken, entries);
      });
    } catch (_) { return null; }
  }

  Future<void> releaseReadBatch(MediaReadBatch batch) async {
    if (batch.project != project || batch.databaseToken != databaseToken) return;
    await db.transaction((txn) async {
      for (final entry in batch._entries) {
        await txn.delete('media_cache_read_leases', where: 'token=? AND project=? AND uid=? AND digest=? AND database_token=?',
          whereArgs: [entry.$2, batch.project, batch.uid, entry.$1, databaseToken]);
      }
    });
  }

  Future<void> releaseRead(String uid, String key, String token) async {
    await db.delete('media_cache_read_leases',
      where: 'token=? AND project=? AND uid=? AND digest=? AND database_token=?',
      whereArgs: [token, project, uid, digest(uid, key), databaseToken]);
  }

  /// Only an explicit user action may change a protected file to evictable.
  Future<bool> unpin(String uid, String key,
      {required bool explicitlyAllowed, required bool Function() permit}) async {
    if (!explicitlyAllowed || !_current(uid, permit) || await _checkedFile(uid, key) == null) return false;
    return db.transaction((txn) async {
      if (!_current(uid, permit)) return false;
      final count = await txn.update('media_cache_objects', {'pinned': 0},
        where: 'project=? AND uid=? AND digest=?', whereArgs: [project, uid, digest(uid, key)]);
      if (!_current(uid, permit)) throw StateError('Session changed during unpin');
      return count == 1;
    });
  }

  /// Deletes only explicitly unpinned, registered files with no durable read
  /// lease. This must remain disabled until every reader and writer uses this
  /// same database protocol. Returned bytes are measured after deletion.
  Future<int> evict(String uid, int requestedBytes,
      {required bool allOperationsParticipate, required bool Function() permit}) async {
    // Until every fallback read is durably fenced across engines, an
    // ordinary build must never evict an attachment.
    if (!const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA') ||
        !allOperationsParticipate || requestedBytes <= 0 || !_current(uid, permit)) return 0;
    return db.transaction((txn) async {
      if (!_current(uid, permit)) return 0;
      final rows = await txn.rawQuery('SELECT o.digest FROM media_cache_objects o '
        'WHERE o.project=? AND o.uid=? AND o.pinned=0 AND NOT EXISTS '
        '(SELECT 1 FROM media_cache_read_leases l WHERE l.project=o.project AND l.uid=o.uid AND (l.digest=o.digest OR l.digest=\'*\')) '
        'ORDER BY o.touched ASC, o.digest ASC', [project, uid]);
      var removed = 0;
      for (final row in rows) {
        if (removed >= requestedBytes || !_current(uid, permit)) break;
        final hash = row['digest'];
        if (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) continue;
        final file = await _checkedHash(uid, hash);
        if (file == null) continue;
        try {
          final size = await file.length();
          if (!_current(uid, permit)) break;
          await file.delete();
          if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.notFound) continue;
          await txn.delete('media_cache_objects', where: 'project=? AND uid=? AND digest=? AND pinned=0',
              whereArgs: [project, uid, hash]);
          removed += size;
        } on FileSystemException { /* Preserve unverifiable entries. */ }
      }
      return removed;
    });
  }
}

class MediaReadBatch {
  MediaReadBatch._(this.project, this.uid, this.databaseToken, List<(String, String)> entries)
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
