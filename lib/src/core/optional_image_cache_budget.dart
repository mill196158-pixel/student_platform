import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

/// Best-effort admission for optional image cache writes, not a disk quota.
/// Unknown measurements skip persistence; other writers and engines do not reserve.
class OptionalImageCacheBudget {
  OptionalImageCacheBudget({
    Future<List<Directory>> Function()? roots,
    this.limitBytes = 500000000,
    this.refreshInterval = const Duration(seconds: 30),
    Duration Function()? elapsed,
  }) : _roots = roots ?? _runtimeRoots,
       _elapsed = elapsed ?? _newClock();

  static final instance = OptionalImageCacheBudget();
  final Future<List<Directory>> Function() _roots;
  final int limitBytes;
  final Duration refreshInterval;
  final Duration Function() _elapsed;
  int? _observed;
  int _reserved = 0;
  int _revision = 0;
  Duration? _measuredAt;
  Future<void>? _refreshing;
  bool _refreshAfterSettled = false;

  static Duration Function() _newClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  bool get _fresh {
    final at = _measuredAt;
    if (at == null) return false;
    final age = _elapsed() - at;
    return !age.isNegative && age < refreshInterval;
  }

  /// A pending initial scan can support one bounded background retry.
  Future<void>? get pendingInitialMeasurement =>
      _observed == null || !_fresh ? _refreshing : null;

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
    if (_observed == null || !_fresh || _observed! + _reserved + bytes > limitBytes) {
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
      if (_refreshAfterSettled && _reserved == 0 && _refreshing == null) {
        _refreshAfterSettled = false;
        _measuredAt = null;
      }
      _scheduleRefresh();
    };
  }

  void _scheduleRefresh() {
    if (_refreshing != null) return;
    if (_fresh) return;
    final revision = _revision;
    final startedAt = _elapsed();
    final future = _measure().then((value) {
      if (_revision == revision && _reserved == 0) {
        _observed = value;
        _measuredAt = startedAt;
      } else {
        _refreshAfterSettled = true;
      }
    }).catchError((Object _) {
      if (_revision == revision && _reserved == 0) {
        _observed = null;
        _measuredAt = startedAt;
      } else {
        _refreshAfterSettled = true;
      }
    });
    _refreshing = future;
    unawaited(future.whenComplete(() {
      _refreshing = null;
      if (_refreshAfterSettled && _reserved == 0) {
        _refreshAfterSettled = false;
        _measuredAt = null;
        _scheduleRefresh();
      }
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
