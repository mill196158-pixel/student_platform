import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

/// Best-effort admission for optional image cache writes, not a disk quota.
/// Unknown measurements fail open; other writers and engines do not reserve.
class OptionalImageCacheBudget {
  OptionalImageCacheBudget({
    Future<List<Directory>> Function()? roots,
    this.limitBytes = 500000000,
    this.refreshInterval = const Duration(seconds: 30),
  }) : _roots = roots ?? _runtimeRoots;

  static final instance = OptionalImageCacheBudget();
  final Future<List<Directory>> Function() _roots;
  final int limitBytes;
  final Duration refreshInterval;
  int? _observed;
  int _reserved = 0;
  int _revision = 0;
  DateTime? _measuredAt;
  Future<void>? _refreshing;

  static Future<List<Directory>> _runtimeRoots() async => [
        await getTemporaryDirectory(),
        await getApplicationCacheDirectory(),
        Directory(await sqlite.getDatabasesPath()),
      ];

  /// Synchronous: never waits for filesystem traversal on the display path.
  /// A null result means the optional persistence should be skipped.
  void Function()? reserve(int bytes) {
    if (bytes < 0) throw ArgumentError.value(bytes, 'bytes');
    _scheduleRefresh();
    if (_observed != null && _observed! + _reserved + bytes > limitBytes) {
      return null;
    }
    _reserved += bytes;
    _revision++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _reserved -= bytes;
      // File writes may have succeeded even when their caller later throws.
      // Charge the entire reservation until a later measurement replaces it.
      if (_observed != null) _observed = _observed! + bytes;
      _revision++;
      _scheduleRefresh();
    };
  }

  void _scheduleRefresh() {
    if (_refreshing != null) return;
    if (_measuredAt != null &&
        DateTime.now().difference(_measuredAt!) < refreshInterval) return;
    final revision = _revision;
    final future = _measure().then((value) {
      if (_revision == revision && _reserved == 0) {
        _observed = value;
        _measuredAt = DateTime.now();
      }
    }).catchError((Object _) {
      if (_revision == revision && _reserved == 0) {
        _observed = null;
        _measuredAt = DateTime.now();
      }
    });
    _refreshing = future;
    unawaited(future.whenComplete(() {
      _refreshing = null;
      if (_measuredAt == null && _reserved == 0) _scheduleRefresh();
    }));
  }

  Future<int?> _measure() async {
    try {
      final roots = await _roots();
      final visited = <String>{};
      var total = 0;
      Future<bool> visit(FileSystemEntity entity) async {
        final name = path.normalize(path.absolute(entity.path));
        if (!visited.add(name)) return true;
        final kind = await FileSystemEntity.type(name, followLinks: false);
        if (kind == FileSystemEntityType.file) {
          total += await File(name).length();
          return true;
        }
        if (kind != FileSystemEntityType.directory) return false;
        await for (final item in Directory(name).list(followLinks: false)) {
          if (!await visit(item)) return false;
        }
        return true;
      }
      if (roots.isEmpty) return null;
      for (final root in roots) {
        if (!await visit(root)) return null;
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  /// Only for deterministic tests; the runtime does not wait for scans.
  Future<void> refreshForTesting() async {
    _scheduleRefresh();
    await _refreshing;
  }
}
