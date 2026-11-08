import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:student_ui/student_ui.dart';

class NewsImageWriteTicket {
  const NewsImageWriteTicket._(this._namespace, this._protocol, this._id,
      this._path, this._generation);
  final String _namespace, _protocol, _id, _path;
  final (int, int) _generation;
}

/// A new-namespace store. No legacy files or orphaned blobs are deleted.
/// Callers must use the same coordination database for this namespace.
class NewsSqliteImageStore {
  NewsSqliteImageStore({required this.database, required this.root});
  final sqlite.Database database;
  final Directory root;
  @visibleForTesting
  Future<void> Function()? debugAfterBlobRename;
  @visibleForTesting
  Future<void> Function()? debugAfterCommit;

  Future<void> _schema(sqlite.Transaction tx, String namespace) async {
    final marker = File('$namespace/.news-store-protocol');
    final kind = await FileSystemEntity.type(marker.path, followLinks: false);
    final names = ['news_store_epochs', 'news_store_images', 'news_store_protocol'];
    final tables = await tx.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name IN (?,?,?)", names);
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
    } else if (tables.length != names.length) {
      throw StateError('Incomplete cache schema');
    }
    const expected = <String, List<String>>{
      'news_store_epochs': ['namespace:TEXT:1:1', 'path:TEXT:1:2', 'generation:INTEGER:1:0'],
      'news_store_images': ['namespace:TEXT:1:1', 'id:TEXT:1:2', 'path:TEXT:1:0', 'filename:TEXT:1:0', 'sha:TEXT:1:0', 'size:INTEGER:1:0'],
      'news_store_protocol': ['namespace:TEXT:0:1', 'token:TEXT:1:0', 'version:INTEGER:1:0'],
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
      await tx.insert('news_store_protocol', {'namespace': namespace, 'token': token, 'version': 1});
      await tx.insert('news_store_epochs', {'namespace': namespace, 'path': '', 'generation': 0});
      return;
    }
    if (kind != FileSystemEntityType.file || rows.length != 1 || rows.single['version'] != 1) {
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

  Future<T> _transaction<T>(Future<T> Function(sqlite.Transaction) action) async {
    for (var attempt = 0;; attempt++) {
      var started = false;
      try {
        return await database.transaction((tx) async {
          started = true;
          return action(tx);
        });
      } catch (error) {
        // Once entered, the callback may have written a blob or committed
        // ambiguously. It must never be replayed automatically.
        if (started || attempt >= 39 ||
            !error.toString().toLowerCase().contains('database is locked')) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
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
  Future<NewsImageWriteTicket> capture(NewsImageCacheKey key) async {
    if (key.path.isEmpty) throw ArgumentError.value(key.path);
    final ns = await _namespace();
    return _transaction((tx) async {
      await _schema(tx, ns);
      final rows = await tx.query('news_store_protocol', columns: ['token'],
          where: 'namespace=?', whereArgs: [ns]);
      return NewsImageWriteTicket._(ns, rows.single['token'] as String,
          key.id, key.path, await _generation(tx, ns, key.path));
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
    return _transaction((tx) async {
      await _schema(tx, ns);
      final rows = await tx.query('news_store_images', where: 'namespace=? AND id=? AND path=?',
          whereArgs: [ns, key.id, key.path]);
      if (rows.length != 1) return null;
      final row = rows.single;
      final filename = row['filename'];
      if (filename is! String || !RegExp(r'^[A-Za-z0-9_-]{32}\.bin$').hasMatch(filename)) return null;
      final file = File('$ns/$filename');
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) return null;
      try {
        final data = await file.readAsBytes();
        if (data.length != row['size'] || sha256.convert(data).toString() != row['sha']) return null;
        return data;
      } on FileSystemException { return null; }
    });
  }

  Future<void> invalidate([String? path]) async {
    if (path != null && path.isEmpty) throw ArgumentError.value(path);
    final ns = await _namespace();
    await _transaction((tx) async {
      await _schema(tx, ns);
      await tx.rawInsert('INSERT INTO news_store_epochs(namespace,path,generation) VALUES(?,?,1) '
          'ON CONFLICT(namespace,path) DO UPDATE SET generation=generation+1', [ns, path ?? '']);
      await tx.delete('news_store_images', where: path == null ? 'namespace=?' : 'namespace=? AND path=?',
          whereArgs: path == null ? [ns] : [ns, path]);
    });
  }
}
