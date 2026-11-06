import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Serializes participating readers and writers across database connections.
/// A crashed process releases its SQLite transaction without a TTL lockfile.
class NewsCacheLease {
  static final Map<String, Future<Database>> _databases = {};

  static String _path(Directory root) {
    final absolute = root.absolute.path;
    final digest = sha256.convert(utf8.encode(absolute));
    return '${root.parent.path}/.news-cache-lease-$digest.db';
  }

  static File disabledMarker(Directory root) => File('${_path(root)}.disabled');

  @visibleForTesting
  static Future<void> debugClose(Directory root) async {
    final database = _databases.remove(_path(root));
    if (database != null) await (await database).close();
  }

  static Future<T> run<T>(Directory root, Future<T> Function() action) async {
    final path = _path(root);
    final opening = _databases[path] ??= openDatabase(path,
        singleInstance: false,
        onConfigure: (db) => db.execute('PRAGMA busy_timeout = 3000'));
    late Database database;
    try {
      database = await opening;
    } catch (_) {
      if (identical(_databases[path], opening)) _databases.remove(path);
      rethrow;
    }
    return database.transaction((_) => action(), exclusive: true);
  }
}
