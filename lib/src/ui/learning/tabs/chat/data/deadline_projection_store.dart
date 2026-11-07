import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

/// Last confirmed server projections. An invalidation is durable before the
/// server mutation starts; a later successful load replaces dirty snapshots
/// atomically. No network or destructive file recovery occurs here.
class DeadlineProjectionStore {
  DeadlineProjectionStore(this.db);
  final Database db;

  static Future<DeadlineProjectionStore> open({String? databasePath, DatabaseFactory? factory}) async {
    final target = databasePath ?? path.join(await getDatabasesPath(), 'deadline_projection_v1.db');
    final database = await (factory ?? databaseFactory).openDatabase(target,
        options: OpenDatabaseOptions(version: 1, singleInstance: false,
          onConfigure: (db) async {
            final result = await db.rawQuery('PRAGMA journal_mode=WAL');
            if (result.length != 1 || result.single.values.single.toString().toLowerCase() != 'wal') {
              throw StateError('Deadline durability unavailable');
            }
            await db.execute('PRAGMA synchronous=FULL');
          },
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE owner_state (project TEXT NOT NULL, uid TEXT NOT NULL, revision INTEGER NOT NULL, dirty INTEGER NOT NULL, PRIMARY KEY(project, uid))');
            await db.execute('CREATE TABLE projection (project TEXT NOT NULL, uid TEXT NOT NULL, range_key TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(project, uid, range_key))');
          }));
    return DeadlineProjectionStore(database);
  }

  Future<int> revision(String project, String uid) async {
    final rows = await db.query('owner_state', columns: ['revision'],
        where: 'project=? AND uid=?', whereArgs: [project, uid]);
    return rows.isEmpty ? 0 : rows.single['revision'] as int;
  }

  Future<void> markDirty(String project, String uid) async {
    await db.transaction((tx) async {
      await tx.rawInsert('INSERT OR IGNORE INTO owner_state(project,uid,revision,dirty) VALUES(?,?,0,0)', [project, uid]);
      await tx.rawUpdate('UPDATE owner_state SET revision=revision+1,dirty=1 WHERE project=? AND uid=?', [project, uid]);
    });
  }

  Future<bool> saveConfirmed(String project, String uid, String range,
      int expectedRevision, String payload, bool Function() current) async {
    return db.transaction((tx) async {
      if (!current()) return false;
      await tx.rawInsert('INSERT OR IGNORE INTO owner_state(project,uid,revision,dirty) VALUES(?,?,0,0)', [project, uid]);
      final rows = await tx.query('owner_state', columns: ['revision', 'dirty'],
          where: 'project=? AND uid=?', whereArgs: [project, uid]);
      if (!current() || rows.single['revision'] != expectedRevision) return false;
      if (rows.single['dirty'] == 1) {
        await tx.delete('projection', where: 'project=? AND uid=?', whereArgs: [project, uid]);
      }
      if (!current()) throw StateError('Deadline session changed');
      await tx.insert('projection', {'project': project, 'uid': uid, 'range_key': range,
        'revision': expectedRevision, 'payload': payload}, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.update('owner_state', {'dirty': 0}, where: 'project=? AND uid=?', whereArgs: [project, uid]);
      if (!current()) throw StateError('Deadline session changed');
      return true;
    });
  }

  Future<String?> read(String project, String uid, String range) async {
    final rows = await db.rawQuery('SELECT p.payload FROM projection p JOIN owner_state s ON s.project=p.project AND s.uid=p.uid AND s.revision=p.revision WHERE p.project=? AND p.uid=? AND p.range_key=? AND s.dirty=0', [project, uid, range]);
    return rows.length == 1 ? rows.single['payload'] as String? : null;
  }
}
