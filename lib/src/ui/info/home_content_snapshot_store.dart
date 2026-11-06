import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';

/// Independent QA database: no migration or import from unscoped caches.
Future<Database> openHomeContentSnapshotDatabase(String path,
        {DatabaseFactory? factory}) =>
    (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        singleInstance: false,
        onConfigure: (db) async {
          final wal = await db.rawQuery('PRAGMA journal_mode=WAL');
          if (wal.length != 1 || wal.single.values.single != 'wal') {
            throw StateError('Home content WAL unavailable');
          }
          await db.execute('PRAGMA synchronous=FULL');
        },
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE home_content (project TEXT NOT NULL, '
              'uid TEXT NOT NULL, sid TEXT NOT NULL, section TEXT NOT NULL, '
              'seq INTEGER NOT NULL, denied INTEGER NOT NULL, payload TEXT, '
              'success_seq INTEGER NOT NULL DEFAULT 0, '
              'PRIMARY KEY(project,uid,sid,section))');
          await db.execute(
              'CREATE TABLE home_content_image (project TEXT NOT NULL, '
              'uid TEXT NOT NULL, sid TEXT NOT NULL, section TEXT NOT NULL, '
              'asset TEXT NOT NULL, bytes BLOB NOT NULL, '
              'PRIMARY KEY(project,uid,sid,section,asset))');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion != 1 || newVersion != 2) {
            throw StateError('Unknown database migration');
          }
          await db.execute(
              'ALTER TABLE home_content ADD COLUMN success_seq INTEGER NOT NULL DEFAULT 0');
          await db.execute('UPDATE home_content SET denied=1');
        },
        onDowngrade: (_, __, ___) =>
            throw StateError('Unknown database version'),
      ),
    );

class HomeContentSnapshot {
  const HomeContentSnapshot(this.rows, this.images);
  final List<Map<String, dynamic>> rows;
  final Map<String, Uint8List> images;
}

class HomeContentTicket {
  HomeContentTicket._(this.issuer, this.owner, this.binding, this.section,
      this.sequence, this.guard);
  final Object issuer;
  final AuthOperationScope owner;
  final OfflineSessionBinding binding;
  final String section;
  final int sequence;
  final bool Function() guard;
}

class _Stale implements Exception {
  const _Stale();
}

/// Each section replaces rows and image bytes together. Callers must pass only
/// verified, sanitised rows and authorised images, never signed URLs or tokens.
class HomeContentSnapshotStore {
  HomeContentSnapshotStore(
      {required this.db,
      required this.scope,
      required this.currentBinding,
      required this.project});
  final Database db;
  final AuthSessionScope scope;
  final OfflineSessionBinding? Function() currentBinding;
  final String project;
  final Object _issuer = Object();
  static const _where = 'project=? AND uid=? AND sid=? AND section=?';

  bool _matches(OfflineSessionBinding? a, OfflineSessionBinding b) =>
      a != null &&
      a.issuer == b.issuer &&
      a.userId == b.userId &&
      a.sessionId == b.sessionId &&
      a.notBefore == b.notBefore &&
      a.expiresAt == b.expiresAt;
  bool _valid(AuthOperationScope owner, OfflineSessionBinding binding,
      bool Function() guard) {
    try {
      return scope.isCurrent(owner) &&
          _matches(scope.bindingFor(owner, '$project/auth/v1'), binding) &&
          _matches(currentBinding(), binding) &&
          guard();
    } catch (_) {
      return false;
    }
  }

  List<Object> _args(OfflineSessionBinding b, String section) =>
      [project, b.userId, b.sessionId, section];

  Future<HomeContentTicket?> begin(String section,
      {required bool Function() isCurrent}) async {
    final owner = scope.capture();
    final binding = currentBinding();
    if (owner == null ||
        binding == null ||
        project.isEmpty ||
        !const {'news', 'promo'}.contains(section) ||
        binding.issuer != '$project/auth/v1' ||
        owner.userId != binding.userId ||
        !_valid(owner, binding, isCurrent)) return null;
    try {
      final seq = await db.transaction((txn) async {
        if (!_valid(owner, binding, isCurrent)) throw const _Stale();
        await txn.insert(
            'home_content',
            {
              'project': project,
              'uid': binding.userId,
              'sid': binding.sessionId,
              'section': section,
              'seq': 0,
              'denied': 0
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.rawUpdate('UPDATE home_content SET seq=seq+1 WHERE $_where',
            _args(binding, section));
        final result = await txn.query('home_content',
            columns: ['seq'],
            where: _where,
            whereArgs: _args(binding, section));
        if (!_valid(owner, binding, isCurrent)) throw const _Stale();
        return result.single['seq'] as int;
      });
      if (!_valid(owner, binding, isCurrent)) return null;
      return HomeContentTicket._(
          _issuer, owner, binding, section, seq, isCurrent);
    } on _Stale {
      return null;
    }
  }

  bool _current(HomeContentTicket t) =>
      identical(t.issuer, _issuer) && _valid(t.owner, t.binding, t.guard);

  // A request dispatched before its barrier closed must still persist a
  // confirmed denial while its original session remains current.
  bool _denialCurrent(HomeContentTicket t) =>
      identical(t.issuer, _issuer) && _valid(t.owner, t.binding, () => true);

  Future<bool> commit(HomeContentTicket t, HomeContentSnapshot value) async {
    if (!_current(t)) return false;
    final payload = jsonEncode(value.rows);
    if (value.rows.length > 50 ||
        utf8.encode(payload).length > 512 * 1024 ||
        value.images.length > 100) return false;
    final images = value.images
        .map((key, bytes) => MapEntry(key, Uint8List.fromList(bytes)));
    var total = 0;
    if (images.entries.any((entry) =>
        entry.key.isEmpty ||
        entry.key.length > 256 ||
        entry.value.isEmpty ||
        entry.value.length > 8 * 1024 * 1024 ||
        (total += entry.value.length) > 16 * 1024 * 1024)) return false;
    try {
      await db.transaction((txn) async {
        if (!_current(t)) throw const _Stale();
        final args = _args(t.binding, t.section);
        final updated = await txn.rawUpdate(
            'UPDATE home_content SET payload=?, denied=0, success_seq=seq '
            'WHERE $_where AND seq=?',
            [payload, ...args, t.sequence]);
        if (updated != 1 || !_current(t)) throw const _Stale();
        await txn.delete('home_content_image', where: _where, whereArgs: args);
        for (final e in images.entries) {
          if (!_current(t)) throw const _Stale();
          await txn.insert('home_content_image', {
            'project': project,
            'uid': t.binding.userId,
            'sid': t.binding.sessionId,
            'section': t.section,
            'asset': e.key,
            'bytes': e.value
          });
        }
        if (!_current(t)) throw const _Stale();
      });
      return _current(t);
    } on _Stale {
      return false;
    }
  }

  /// Call only for a confirmed, scoped denial; preserves all existing bytes.
  Future<bool> deny(HomeContentTicket t) async {
    if (!_denialCurrent(t)) return false;
    try {
      return await db.transaction((txn) async {
        if (!_denialCurrent(t)) throw const _Stale();
        final n = await txn.rawUpdate(
            'UPDATE home_content SET denied=1, seq=seq+1 '
            'WHERE $_where',
            _args(t.binding, t.section));
        if (!_denialCurrent(t)) throw const _Stale();
        return n == 1;
      });
    } on _Stale {
      return false;
    }
  }

  Future<HomeContentSnapshot?> read(
      String section, SessionCapabilities caps) async {
    final permit = caps.capture(SessionCapability.cachedRead);
    final owner = scope.capture();
    final binding = currentBinding();
    if (permit == null ||
        owner == null ||
        binding == null ||
        !const {'news', 'promo'}.contains(section) ||
        owner.userId != binding.userId ||
        binding.issuer != '$project/auth/v1' ||
        caps.mode != SessionCapabilityMode.cacheOnly ||
        !caps.owns(permit, owner)) return null;
    bool valid() => _valid(
        owner,
        binding,
        () =>
            caps.mode == SessionCapabilityMode.cacheOnly &&
            caps.permits(permit, SessionCapability.cachedRead));
    if (!valid()) return null;
    return db.transaction((txn) async {
      final args = _args(binding, section);
      final rows = await txn.rawQuery(
          'SELECT denied, length(CAST(payload AS BLOB)) AS payload_size '
          'FROM home_content WHERE $_where',
          args);
      if (!valid() ||
          rows.length != 1 ||
          rows.single['denied'] != 0 ||
          rows.single['payload_size'] is! int ||
          (rows.single['payload_size'] as int) > 512 * 1024) return null;
      final payloadRows = await txn.query('home_content',
          columns: ['payload'], where: _where, whereArgs: args);
      if (!valid() ||
          payloadRows.length != 1 ||
          payloadRows.single['payload'] is! String) return null;
      dynamic raw;
      try {
        raw = jsonDecode(payloadRows.single['payload'] as String);
      } on FormatException {
        return null;
      }
      if (raw is! List || raw.length > 50) return null;
      // Android CursorWindow cannot return a single multi-megabyte BLOB row.
      // Read bounded chunks inside this transaction so metadata and bytes
      // always belong to the same committed snapshot.
      final imageRows = await txn.rawQuery(
          'SELECT asset, length(bytes) AS size FROM home_content_image WHERE $_where',
          args);
      if (!valid() || imageRows.length > 100) return null;
      try {
        final images = <String, Uint8List>{};
        var total = 0;
        const chunkSize = 256 * 1024;
        for (final row in imageRows) {
          final asset = row['asset'], size = row['size'];
          if (asset is! String ||
              asset.isEmpty ||
              asset.length > 256 ||
              size is! int ||
              size <= 0 ||
              size > 8 * 1024 * 1024 ||
              (total += size) > 16 * 1024 * 1024) return null;
          final builder = BytesBuilder(copy: false);
          for (var offset = 0; offset < size; offset += chunkSize) {
            final chunks = await txn.rawQuery(
                'SELECT substr(bytes, ?, ?) AS chunk FROM home_content_image '
                'WHERE $_where AND asset=?',
                [offset + 1, chunkSize, ...args, asset]);
            if (!valid() || chunks.length != 1) return null;
            final bytes = chunks.single['chunk'];
            final expected =
                (size - offset) < chunkSize ? size - offset : chunkSize;
            if (bytes is! Uint8List || bytes.length != expected) return null;
            builder.add(bytes);
          }
          images[asset] = builder.takeBytes();
        }
        if (!valid()) return null;
        return HomeContentSnapshot(
            raw.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
            images);
      } catch (_) {
        return null;
      }
    });
  }
}
