import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'cache_inventory_snapshot.dart';

/// Best-effort admission for optional image cache writes, not a disk quota.
/// Unknown measurements skip persistence; other writers and engines do not reserve.
class OptionalImageCacheBudget {
  OptionalImageCacheBudget({
    Future<List<Directory>> Function()? roots,
    CacheInventoryCollector? collector,
    this.limitBytes = 500000000,
    int? serviceReserveBytes,
    this.refreshInterval = const Duration(seconds: 30),
    Duration Function()? elapsed,
  })  : _roots = roots ?? _runtimeRoots,
        _collector = roots == null
            ? (collector ?? CacheInventoryCollector.shared)
            : null,
        serviceReserveBytes =
            serviceReserveBytes ?? (roots == null ? 16 * 1024 * 1024 : 0),
        _elapsed = elapsed ?? _newClock() {
    if (limitBytes < 0 ||
        limitBytes > _maxExactBytes ||
        this.serviceReserveBytes < 0 ||
        this.serviceReserveBytes > _maxExactBytes) {
      throw ArgumentError('Invalid cache budget');
    }
  }

  static const int _maxExactBytes = 9007199254740991;

  static final instance = OptionalImageCacheBudget();
  final Future<List<Directory>> Function() _roots;
  final CacheInventoryCollector? _collector;
  final int limitBytes;
  final int serviceReserveBytes;
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

  /// True only for a fresh, known observation; unknown never triggers cleanup.
  bool knownInsufficientFor(int bytes) =>
      bytes >= 0 && _observed != null && _fresh && !_fits(bytes);

  bool _fits(int bytes) {
    final observed = _observed;
    if (observed == null ||
        observed < 0 ||
        bytes < 0 ||
        serviceReserveBytes > limitBytes) return false;
    var remaining = limitBytes - serviceReserveBytes;
    if (observed > remaining) return false;
    remaining -= observed;
    if (_reserved > remaining) return false;
    return bytes <= remaining - _reserved;
  }

  int? get observedBytes => _fresh ? _observed : null;
  int get reservedBytes => _reserved;

  /// Triggers the same measurement used for admission. Never modifies files.
  Future<void> refreshForDisplay() async {
    _scheduleRefresh();
    await _refreshing;
  }

  /// Never credit an unlink directly. Re-measure actual roots after it settles.
  void refreshAfterCollection() {
    _revision++;
    _measuredAt = null;
    if (_refreshing != null || _reserved != 0) {
      _refreshAfterSettled = true;
      return;
    }
    _scheduleRefresh();
  }

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
    if (_observed == null || !_fresh || !_fits(bytes)) {
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
        _observed = value.bytes;
        _measuredAt = value.age == null ? startedAt : _elapsed() - value.age!;
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

  Future<({int? bytes, Duration? age})> _measure() async {
    try {
      final collector = _collector;
      if (collector != null) {
        final snapshot = await collector.collect();
        final age = collector.ageOf(snapshot);
        if (age == null || age >= refreshInterval)
          return (bytes: null, age: age);
        final names = <String>{
          'public_news_blobs_v2',
          'public_news_index_v2.db',
          'news_images_v1',
          'guest_news_images_v1',
          'content_media_images_v1'
        };
        final expected = Set<String>.of(names);
        var sum = 0;
        for (final item in snapshot.observations) {
          if (!expected.contains(item.name)) continue;
          if (!names.remove(item.name)) return (bytes: null, age: age);
          if ((item.classification != InventoryClass.optional &&
                  item.classification !=
                      InventoryClass.serverCopiesUnverified) ||
              item.bytes == null ||
              item.bytes! < 0) return (bytes: null, age: age);
          if (item.bytes! > _maxExactBytes - sum)
            return (bytes: null, age: age);
          sum += item.bytes!;
        }
        return (bytes: names.isEmpty ? sum : null, age: age);
      }
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

      if (roots.isEmpty) return (bytes: null, age: null);
      for (final root in roots) {
        if (!await visit(root)) return (bytes: null, age: null);
      }
      return (bytes: total, age: null);
    } catch (_) {
      return (bytes: null, age: null);
    }
  }

  /// Only for deterministic tests; the runtime does not wait for scans.
  Future<void> refreshForTesting() async {
    _scheduleRefresh();
    await _refreshing;
  }
}
