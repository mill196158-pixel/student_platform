import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

enum InventoryClass { optional, serverCopiesUnverified, protectedOrMixed }

/// A pathname-based estimate. It is not an inode or allocated-disk measurement.
class InventoryObservation {
  const InventoryObservation(this.name, this.classification, this.bytes);
  final String name;
  final InventoryClass classification;

  /// Null denotes incomplete, inaccessible, or unsafe measurement.
  final int? bytes;
}

class InventorySnapshot {
  InventorySnapshot(
      {required this.startedAt,
      required this.finishedAt,
      required List<InventoryObservation> observations,
      this.logicalHistoryBytes})
      : observations = List.unmodifiable(observations);
  final DateTime startedAt, finishedAt;
  final List<InventoryObservation> observations;

  /// Logical content size, never physical bytes or reclaimed space.
  final int? logicalHistoryBytes;
}

/// Measures JSON in server-snapshot rows on an already-open database across
/// all accounts. It is not proof of ownership, deletion eligibility or freed
/// space. Unknown schema/content is unavailable, not an empty history.
Future<int?> readLogicalHistory(sqlite.DatabaseExecutor database) async {
  try {
    final rows = await database.query('chat_server_snapshot',
        columns: ['chat', 'payload'],
        where: 'chat<>?',
        whereArgs: ['__chat_summaries__']);
    var bytes = 0;
    for (final row in rows) {
      final payload = row['payload'];
      if (payload is! String) return null;
      final messages = jsonDecode(payload);
      if (messages is! List ||
          messages.any((message) =>
              message is! Map ||
              message['id'] is! String ||
              (message['id'] as String).isEmpty ||
              (message['id'] as String).startsWith('local_') ||
              message['delivery_status'] != 'sent' ||
              message['client_id'] != null ||
              message['clientId'] != null)) return null;
      bytes += utf8.encode(payload).length;
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Read-only, partial inventory of named app-private namespaces. This does not
/// establish admission, disk quota, physical identity, or reclaimable bytes.
class CacheInventoryCollector {
  CacheInventoryCollector(
      {required this.temporaryRoot,
      required this.databaseRoot,
      required this.supportRoot,
      this.logicalHistory});

  factory CacheInventoryCollector.platform() => CacheInventoryCollector(
        temporaryRoot: getTemporaryDirectory,
        databaseRoot: () async => Directory(await sqlite.getDatabasesPath()),
        supportRoot: getApplicationSupportDirectory,
      );

  static final shared = CacheInventoryCollector.platform();
  final Future<Directory> Function() temporaryRoot, databaseRoot, supportRoot;

  /// Optional read-only collaborator using an already-open, owner-scoped DB.
  /// It must return logical payload bytes, not DB file size.
  final Future<int?> Function()? logicalHistory;
  Future<InventorySnapshot>? _pending;

  Future<InventorySnapshot> collect() {
    final running = _pending;
    if (running != null) return running;
    final next = _collect();
    _pending = next;
    unawaited(next.then<void>((_) {
      if (identical(_pending, next)) _pending = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_pending, next)) _pending = null;
    }));
    return next;
  }

  Future<InventorySnapshot> _collect() async {
    final started = DateTime.now().toUtc();
    final seen = <String>{};
    Future<Directory?> root(Future<Directory> Function() getRoot) async {
      try {
        final dir = (await getRoot()).absolute;
        if (await FileSystemEntity.type(dir.path, followLinks: false) !=
            FileSystemEntityType.directory) return null;
        if (path.normalize(await dir.resolveSymbolicLinks()) !=
            path.normalize(dir.path)) return null;
        return dir;
      } catch (_) {
        return null;
      }
    }

    final temp = await root(temporaryRoot);
    final db = await root(databaseRoot);
    final support = await root(supportRoot);
    Future<int?> size(Directory? parent, String child,
        {bool directory = false}) async {
      if (parent == null) return null;
      try {
        final target = path.normalize(path.join(parent.path, child));
        if (!path.isWithin(parent.path, target) || !seen.add(target))
          return null;
        // Listing parent establishes absence; failed listing must never mean 0.
        final entries = await parent.list(followLinks: false).toList();
        if (!entries.any((e) => path.normalize(e.path) == target)) return 0;
        Future<int?> visit(String name) async {
          final kind = await FileSystemEntity.type(name, followLinks: false);
          if (kind == FileSystemEntityType.file) return File(name).length();
          if (kind != FileSystemEntityType.directory) return null;
          var total = 0;
          await for (final entry in Directory(name).list(followLinks: false)) {
            final result = await visit(entry.path);
            if (result == null) return null;
            total += result;
          }
          return total;
        }

        final kind = await FileSystemEntity.type(target, followLinks: false);
        if (directory
            ? kind != FileSystemEntityType.directory
            : kind != FileSystemEntityType.file) return null;
        return await visit(target);
      } catch (_) {
        return null;
      }
    }

    final items = <InventoryObservation>[];
    Future<void> add(Directory? parent, String name, InventoryClass kind,
        {bool directory = false}) async {
      items.add(InventoryObservation(
          name, kind, await size(parent, name, directory: directory)));
    }

    await add(temp, 'public_news_blobs_v2', InventoryClass.optional,
        directory: true);
    for (final name in [
      'news_images_v1',
      'guest_news_images_v1',
      'content_media_images_v1'
    ]) {
      await add(temp, name, InventoryClass.serverCopiesUnverified,
          directory: true);
    }
    Future<void> database(
        Directory? parent, String name, InventoryClass kind) async {
      final main = await size(parent, name);
      final wal = await size(parent, '$name-wal');
      final shm = await size(parent, '$name-shm');
      // Orphan sidecars cannot establish a healthy database footprint.
      final orphan = main == 0 && ((wal ?? 0) > 0 || (shm ?? 0) > 0);
      items.add(InventoryObservation(
          name,
          kind,
          orphan || main == null || wal == null || shm == null
              ? null
              : main + wal + shm));
    }

    await database(db, 'public_news_index_v2.db', InventoryClass.optional);
    for (final name in [
      'offline_chat_ordinary_v1.db',
      'forward_outbox_v1.db',
      'draft_recovery_v1.db'
    ]) {
      await database(db, name, InventoryClass.protectedOrMixed);
    }
    // The pinned guard database lives under application support, not db root.
    await database(support, 'pinned_media_guard_ordinary_v1.db',
        InventoryClass.protectedOrMixed);
    await add(support, 'pinned_media_v1', InventoryClass.protectedOrMixed,
        directory: true);
    int? logical;
    try {
      logical = await logicalHistory?.call();
      if (logical != null && logical < 0) logical = null;
    } catch (_) {
      logical = null;
    }
    return InventorySnapshot(
        startedAt: started,
        finishedAt: DateTime.now().toUtc(),
        observations: items,
        logicalHistoryBytes: logical);
  }
}
