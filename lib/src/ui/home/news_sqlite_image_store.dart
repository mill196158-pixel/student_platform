import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:student_ui/student_ui.dart';

class NewsImageWriteTicket {
  const NewsImageWriteTicket._(this._namespace, this._protocol, this._id,
      this._path, this._generation);
  final String _namespace, _protocol, _id, _path;
  final (int, int) _generation;
}

enum NewsImageReadState { hit, miss, unknown }

class NewsImageReadResult {
  const NewsImageReadResult(this.state, [this.bytes]);
  final NewsImageReadState state;
  final Uint8List? bytes;
}

class NewsOrphanCollectionResult {
  const NewsOrphanCollectionResult(this.filesUnlinked, this.namedBytesUnlinked);
  final int filesUnlinked, namedBytesUnlinked;
}

/// A new-namespace store. Only the fixed public-news binding may collect
/// unreferenced immutable blobs; legacy files are never collected here.
/// Callers must use the same coordination database for this namespace.
class NewsSqliteImageStore {
  NewsSqliteImageStore({required this.database, required this.root}) : ownsDatabase = false, _canCollectOrphans = false;
  NewsSqliteImageStore._owned(this.database, this.root, this._canCollectOrphans) : ownsDatabase = true;
  @visibleForTesting
  NewsSqliteImageStore.forCollectionTest({required this.database, required this.root})
      : ownsDatabase = false, _canCollectOrphans = true;
  static Future<NewsSqliteImageStore> openOwned({required String databasePath,
      required Directory root, sqlite.DatabaseFactory? factory}) async {
    final db = await (factory ?? sqlite.databaseFactory).openDatabase(databasePath,
        options: sqlite.OpenDatabaseOptions(singleInstance: false));
    return NewsSqliteImageStore._owned(db, root, false);
  }
  /// The only ordinary collector binding: fixed public-news namespace + DB.
  static Future<NewsSqliteImageStore> openPublicNews() async {
    final temp = await getTemporaryDirectory();
    final dbPath = '${await sqlite.getDatabasesPath()}/public_news_index_v2.db';
    final db = await sqlite.databaseFactory.openDatabase(dbPath,
        options: sqlite.OpenDatabaseOptions(singleInstance: false));
    return NewsSqliteImageStore._owned(db, Directory('${temp.path}/public_news_blobs_v2'), true);
  }
  final sqlite.Database database;
  final Directory root;
  final bool ownsDatabase;
  final bool _canCollectOrphans;
  bool _poisoned = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closing;
  bool get usable => !_poisoned && database.isOpen;

  Future<void> waitForOwnedClose() async {
    if (!_poisoned || !ownsDatabase || _closing == null) throw StateError('No owned close');
    await _closing;
    if (database.isOpen) throw StateError('Image database still open');
  }

  Future<void> _poison() async {
    _poisoned = true;
    if (ownsDatabase) await (_closing ??= database.close());
  }
  @visibleForTesting
  Future<void> Function()? debugAfterBlobRename;
  @visibleForTesting
  Future<void> Function()? debugAfterCommit;
  @visibleForTesting
  Future<void> Function()? debugAfterOrphanListing;
  @visibleForTesting
  Future<void> Function(File)? debugBeforeOrphanUnlink;
  @visibleForTesting
  Future<void> Function()? debugAfterOrphanUnlink;
  @visibleForTesting
  Future<void> Function()? debugBeforeImageRead;

  Future<void> _schema(sqlite.Transaction tx, String namespace, {bool allowBootstrap = true}) async {
    final marker = File('$namespace/.news-store-protocol');
    final kind = await FileSystemEntity.type(marker.path, followLinks: false);
    final names = ['news_store_epochs', 'news_store_images', 'news_store_protocol', 'news_store_suppression'];
    final tables = await tx.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name IN (?,?,?,?)", names);
    if (!allowBootstrap && (kind != FileSystemEntityType.file || tables.length != names.length)) {
      throw StateError('Unverified cache protocol');
    }
    if (tables.isEmpty && kind == FileSystemEntityType.notFound) {
      await tx.execute('CREATE TABLE news_store_epochs ('
        'namespace TEXT NOT NULL, path TEXT NOT NULL, generation INTEGER NOT NULL, '
        'PRIMARY KEY(namespace,path))');
      await tx.execute('CREATE TABLE news_store_images ('
        'namespace TEXT NOT NULL, id TEXT NOT NULL, path TEXT NOT NULL, '
        'filename TEXT NOT NULL, sha TEXT NOT NULL, size INTEGER NOT NULL, '
        'PRIMARY KEY(namespace,id))');
      await tx.execute('CREATE TABLE news_store_protocol ('
        'namespace TEXT PRIMARY KEY, token TEXT NOT NULL, version INTEGER NOT NULL)');
      await tx.execute('CREATE TABLE news_store_suppression ('
        'namespace TEXT NOT NULL, path TEXT NOT NULL, keep_version TEXT, PRIMARY KEY(namespace,path))');
    } else if (tables.length != names.length) {
      throw StateError('Incomplete cache schema');
    }
    const expected = <String, List<String>>{
      'news_store_epochs': ['namespace:TEXT:1:1', 'path:TEXT:1:2', 'generation:INTEGER:1:0'],
      'news_store_images': ['namespace:TEXT:1:1', 'id:TEXT:1:2', 'path:TEXT:1:0', 'filename:TEXT:1:0', 'sha:TEXT:1:0', 'size:INTEGER:1:0'],
      'news_store_protocol': ['namespace:TEXT:0:1', 'token:TEXT:1:0', 'version:INTEGER:1:0'],
      'news_store_suppression': ['namespace:TEXT:1:1', 'path:TEXT:1:2', 'keep_version:TEXT:0:0'],
    };
    for (final entry in expected.entries) {
      final columns = await tx.rawQuery('PRAGMA table_info(${entry.key})');
      final actual = columns.map((c) => '${c['name']}:${c['type']}:${c['notnull']}:${c['pk']}').toList();
      if (!listEquals(actual, entry.value)) throw StateError('Invalid cache schema');
    }
    final rows = await tx.query('news_store_protocol', where: 'namespace=?', whereArgs: [namespace]);
    if (kind == FileSystemEntityType.notFound && rows.isEmpty) {
      final existing = await Directory(namespace).list(followLinks: false).toList();
      if (existing.isNotEmpty) throw StateError('Unverified cache namespace');
      final token = base64UrlEncode(List<int>.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
      await marker.create(exclusive: true);
      await marker.writeAsString(token, flush: true);
      await tx.insert('news_store_protocol', {'namespace': namespace, 'token': token, 'version': 2});
      await tx.insert('news_store_epochs', {'namespace': namespace, 'path': '', 'generation': 0});
      return;
    }
    if (kind != FileSystemEntityType.file || rows.length != 1 || rows.single['version'] != 2) {
      throw StateError('Unverified cache protocol');
    }
    final token = await marker.readAsString();
    if (token != rows.single['token'] || !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(token)) {
      throw StateError('Mismatched cache protocol');
    }
    final roots = await tx.query('news_store_epochs', columns: ['generation'],
        where: 'namespace=? AND path=?', whereArgs: [namespace, '']);
    if (roots.length != 1 || roots.single['generation'] is! int || (roots.single['generation'] as int) < 0) {
      throw StateError('Missing cache generation');
    }
  }

  Future<String> _namespace() async {
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) throw StateError('Unsafe cache root');
    return root.resolveSymbolicLinks();
  }

  Future<T> _transaction<T>(Future<T> Function(sqlite.Transaction) action) {
    var allowed = true, started = false;
    final expiry = Completer<T>();
    final timer = Timer(const Duration(milliseconds: 500), () {
      if (!started) {
        allowed = false;
        expiry.completeError(TimeoutException('Image index acquisition timed out'));
      }
    });
    final operation = _tail.then((_) async {
      if (!allowed || !usable) throw StateError('Image index unavailable');
      if (ownsDatabase) await database.rawQuery('PRAGMA busy_timeout=100');
      if (!allowed || !usable) throw StateError('Image index unavailable');
      for (var attempt = 0;; attempt++) {
        var entered = false, actionCompleted = false;
        Object? actionError;
        try {
          return await database.transaction((tx) async {
            entered = true;
            try {
              if (!allowed || !usable) throw StateError('Image index acquisition cancelled');
              started = true;
              timer.cancel();
              final value = await action(tx);
              actionCompleted = true;
              return value;
            } catch (error) {
              actionError = error;
              rethrow;
            }
          });
        } catch (error) {
          // A successful callback followed by a failed COMMIT, or an error
          // replacing its exception during rollback, poisons this handle.
          if (entered && (actionCompleted ||
              (actionError != null && !identical(actionError, error)))) {
            await _poison();
          }
          if (entered || !allowed || attempt >= 39 ||
              !error.toString().toLowerCase().contains('database is locked')) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
    });
    // Keep the queue until the real transaction and any owned close settle,
    // even if the caller's acquisition deadline expires first.
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    operation.ignore();
    return Future.any([operation, expiry.future]).whenComplete(timer.cancel);
  }

  Future<(int, int)> _generation(sqlite.Transaction tx, String namespace, String path) async {
    final rows = await tx.query('news_store_epochs',
        where: 'namespace=? AND path IN (?,?)', whereArgs: [namespace, '', path]);
    var all = 0, item = 0;
    for (final row in rows) {
      if (row['path'] == '') all = row['generation'] as int;
      if (row['path'] == path) item = row['generation'] as int;
    }
    return (all, item);
  }

  /// Capture before network fetch; an invalidation makes the ticket stale.
  Future<NewsImageWriteTicket> capture(NewsImageCacheKey key,
      {bool Function()? current}) async {
    if (key.path.isEmpty) throw ArgumentError.value(key.path);
    final ns = await _namespace();
    // Bootstrap marker publication must commit separately. A cancelled ticket
    // can then roll back its generation without orphaning that marker.
    await _transaction((tx) => _schema(tx, ns));
    if (current != null && !current()) throw StateError('Cancelled image ticket');
    return _transaction((tx) async {
      await _schema(tx, ns);
      if (current != null && !current()) {
        throw StateError('Cancelled image ticket');
      }
      // Starting a newer fetch for this path invalidates every older ticket,
      // including a delayed prune from a previous version.
      await tx.rawInsert('INSERT INTO news_store_epochs(namespace,path,generation) VALUES(?,?,1) '
          'ON CONFLICT(namespace,path) DO UPDATE SET generation=generation+1', [ns, key.path]);
      final rows = await tx.query('news_store_protocol', columns: ['token'],
          where: 'namespace=?', whereArgs: [ns]);
      final generation = await _generation(tx, ns, key.path);
      if (current != null && !current()) {
        throw StateError('Cancelled image ticket');
      }
      return NewsImageWriteTicket._(ns, rows.single['token'] as String,
          key.id, key.path, generation);
    });
  }

  Future<bool> isCurrent(NewsImageCacheKey key, NewsImageWriteTicket ticket) async {
    final ns = await _namespace();
    return _transaction((tx) async {
      await _schema(tx, ns);
      final rows = await tx.query('news_store_protocol', columns: ['token'],
          where: 'namespace=?', whereArgs: [ns]);
      return ticket._namespace == ns && ticket._id == key.id &&
          ticket._path == key.path && rows.length == 1 &&
          rows.single['token'] == ticket._protocol &&
          await _generation(tx, ns, key.path) == ticket._generation;
    });
  }

  Future<bool> put(NewsImageCacheKey key, Uint8List bytes, NewsImageWriteTicket ticket) async {
    if (key.path.isEmpty || bytes.isEmpty) return false;
    final snapshot = Uint8List.fromList(bytes);
    final ns = await _namespace();
    final result = await _transaction((tx) async {
      await _schema(tx, ns);
      if (ticket._namespace != ns || ticket._id != key.id || ticket._path != key.path) return false;
      final protocol = await tx.query('news_store_protocol', columns: ['token'],
          where: 'namespace=?', whereArgs: [ns]);
      if (protocol.length != 1 || protocol.single['token'] != ticket._protocol ||
          await _generation(tx, ns, key.path) != ticket._generation) return false;
      final token = base64UrlEncode(List<int>.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
      final filename = '$token.bin';
      final tmp = File('$ns/.$token.tmp');
      final blob = File('$ns/$filename');
      await tmp.create(exclusive: true);
      await tmp.writeAsBytes(snapshot, flush: true);
      await tmp.rename(blob.path);
      await debugAfterBlobRename?.call();
      await tx.insert('news_store_images', {
        'namespace': ns, 'id': key.id, 'path': key.path,
        'filename': filename, 'sha': sha256.convert(snapshot).toString(), 'size': snapshot.length,
      }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
      return true;
    });
    if (result) await debugAfterCommit?.call();
    return result;
  }

  Future<Uint8List?> read(NewsImageCacheKey key) async {
    final ns = await _namespace();
    await _transaction((tx) => _schema(tx, ns));
    return _transaction((tx) async {
      await _schema(tx, ns);
      return _readInTransaction(tx, ns, key);
    });
  }

  /// Deletes only unreferenced immutable public-news files under the same
  /// index transaction as all readers/writers. Bytes are named file lengths,
  /// not a claim about physical disk space actually reclaimed.
  Future<NewsOrphanCollectionResult?> collectOrphaned({
      required bool Function() current, int maxFiles = 16}) async {
    if (!_canCollectOrphans || maxFiles <= 0 || maxFiles > 16 || !current()) return null;
    try {
      if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory || !current()) return null;
      final ns = await root.resolveSymbolicLinks();
      if (!current()) return null;
      return await _transaction((tx) async {
        if (!current()) return null;
        await _schema(tx, ns, allowBootstrap: false);
        if (!current()) return null;
        final rows = await tx.query('news_store_images', columns: ['filename'], where: 'namespace=?', whereArgs: [ns]);
        final namePattern = RegExp(r'^[A-Za-z0-9_-]{32}\.bin$');
        final references = <String>{};
        for (final row in rows) {
          final name = row['filename'];
          if (name is! String || !namePattern.hasMatch(name)) return null;
          references.add(name);
        }
        final candidates = <File>[];
        var scanned = 0;
        await for (final entry in Directory(ns).list(followLinks: false)) {
          if (!current() || ++scanned > 1024) return null;
          final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
          if (name == '.news-store-protocol' && entry is File) continue;
          if (entry is! File || !namePattern.hasMatch(name)) return null;
          if (!references.contains(name)) candidates.add(entry);
        }
        await debugAfterOrphanListing?.call();
        if (!current()) return null;
        var files = 0, bytes = 0;
        for (final file in candidates.take(maxFiles)) {
          if (!current()) break;
          try {
            if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file || !current()) continue;
            final length = await file.length();
            if (!current()) break;
            await debugBeforeOrphanUnlink?.call(file);
            if (!current()) break;
            await file.delete();
            if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.notFound) continue;
            files++;
            bytes += length;
            await debugAfterOrphanUnlink?.call();
          } on FileSystemException {
            // A missing/unremovable file does not earn accounting credit.
          }
        }
        return NewsOrphanCollectionResult(files, bytes);
      });
    } catch (_) { return null; }
  }

  Future<Uint8List?> _readInTransaction(sqlite.Transaction tx, String ns, NewsImageCacheKey key) async {
      final rows = await tx.query('news_store_images', where: 'namespace=? AND id=? AND path=?',
          whereArgs: [ns, key.id, key.path]);
      if (rows.length != 1) return null;
      final row = rows.single;
      final filename = row['filename'];
      if (filename is! String || !RegExp(r'^[A-Za-z0-9_-]{32}\.bin$').hasMatch(filename)) throw StateError('Invalid image path');
      final file = File('$ns/$filename');
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) throw StateError('Missing image');
      try {
        await debugBeforeImageRead?.call();
        final data = await file.readAsBytes();
        if (data.length != row['size'] || sha256.convert(data).toString() != row['sha']) throw StateError('Invalid image');
        return data;
      } on FileSystemException { throw StateError('Image unavailable'); }
  }

  /// Legacy is consulted only inside the shared transaction after checking
  /// durable suppression. Errors are unknown, never a cached miss.
  Future<NewsImageReadResult> readWithLegacy(NewsImageCacheKey key,
      Future<Uint8List?> Function() readLegacy,
      {Duration legacyTimeout = const Duration(milliseconds: 500)}) async {
    try {
      final ns = await _namespace();
      // Bootstrap is committed before a timed callback can abort its own
      // transaction; otherwise an orphan marker would strand a fresh store.
      await _transaction((tx) => _schema(tx, ns));
      return await _transaction((tx) async {
        await _schema(tx, ns);
        final data = await _readInTransaction(tx, ns, key);
        if (data != null) return NewsImageReadResult(NewsImageReadState.hit, data);
        final suppression = await tx.query('news_store_suppression',
            where: 'namespace=? AND path IN (?,?)', whereArgs: [ns, '', key.path]);
        if (suppression.any((row) => row['path'] == '' ||
            (row['path'] == key.path && row['keep_version'] != key.version))) {
          return const NewsImageReadResult(NewsImageReadState.miss);
        }
        if (legacyTimeout <= Duration.zero) throw StateError('Invalid legacy timeout');
        final legacy = await readLegacy().timeout(legacyTimeout);
        return legacy == null || legacy.isEmpty
            ? const NewsImageReadResult(NewsImageReadState.miss)
            : NewsImageReadResult(NewsImageReadState.hit, legacy);
      });
    } catch (_) {
      return const NewsImageReadResult(NewsImageReadState.unknown);
    }
  }

  /// Drop old versions only when the original fetch ticket is still current.
  Future<bool> pruneOtherVersions(NewsImageCacheKey key, NewsImageWriteTicket ticket) async {
    final ns = await _namespace();
    return _transaction((tx) async {
      await _schema(tx, ns);
      final protocol = await tx.query('news_store_protocol', columns: ['token'],
          where: 'namespace=?', whereArgs: [ns]);
      if (ticket._namespace != ns || ticket._id != key.id || ticket._path != key.path ||
          protocol.length != 1 || protocol.single['token'] != ticket._protocol ||
          await _generation(tx, ns, key.path) != ticket._generation) return false;
      await tx.rawInsert('INSERT INTO news_store_epochs(namespace,path,generation) VALUES(?,?,1) '
          'ON CONFLICT(namespace,path) DO UPDATE SET generation=generation+1', [ns, key.path]);
      await tx.insert('news_store_suppression',
          {'namespace': ns, 'path': key.path, 'keep_version': key.version},
          conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
      await tx.delete('news_store_images', where: 'namespace=? AND path=? AND id<>?',
          whereArgs: [ns, key.path, key.id]);
      return true;
    });
  }

  Future<void> invalidate([String? path]) async {
    if (path != null && path.isEmpty) throw ArgumentError.value(path);
    final ns = await _namespace();
    await _transaction((tx) => _schema(tx, ns));
    await _transaction((tx) async {
      await _schema(tx, ns);
      await tx.rawInsert('INSERT INTO news_store_epochs(namespace,path,generation) VALUES(?,?,1) '
          'ON CONFLICT(namespace,path) DO UPDATE SET generation=generation+1', [ns, path ?? '']);
      await tx.insert('news_store_suppression',
          {'namespace': ns, 'path': path ?? '', 'keep_version': null},
          conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
      await tx.delete('news_store_images', where: path == null ? 'namespace=?' : 'namespace=? AND path=?',
          whereArgs: path == null ? [ns] : [ns, path]);
    });
  }
}
