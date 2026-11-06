import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_ui/student_ui.dart';
import '../../core/temporary_cache_budget.dart';
import '../../core/news_cache_lease.dart';

/// Persistent news image bytes for Mobile, keyed by path + version.
///
/// - Does not store signed URLs.
/// - Does not store base64 in SharedPreferences.
/// - Network errors never wipe existing files.
/// - Caps by entry count and approximate total bytes; prunes LRU/stale.
class NewsImageDiskCache {
  NewsImageDiskCache({
    NewsImageBytesCache? memory,
    Directory? Function()? rootOverride,
    this.directoryName = 'news_images_v1',
    this.maxEntries = 80,
    this.maxTotalBytes = 48 * 1024 * 1024,
    this.debugQuotaUsage,
    this.debugUseSqliteLease = false,
  })  : _memory = memory ?? NewsImageBytesCache.instance,
        _rootOverride = rootOverride;

  final NewsImageBytesCache _memory;
  final Directory? Function()? _rootOverride;
  final int maxEntries;
  final int maxTotalBytes;
  @visibleForTesting
  final Future<int?> Function()? debugQuotaUsage;
  @visibleForTesting
  final bool debugUseSqliteLease;

  final String directoryName;
  static const _indexName = 'index.json';

  Directory? _root;
  Map<String, _IndexEntry>? _index;
  bool _ready = false;
  int _clearEpoch = 0;
  final Map<String, int> _pathEpoch = {};
  static final Map<String, Future<void>> _directoryMutations = {};
  static final Map<String, DateTime> _lastQuotaScan = {};
  Future<void> _quotaWork = Future<void>.value();
  @visibleForTesting
  Future<void> debugWaitForQuota() => _quotaWork;
  @visibleForTesting
  Future<void> Function()? debugAfterFileWrite;
  @visibleForTesting
  Future<void> Function()? debugBeforeLease;

  Future<T> _mutate<T>(Future<T> Function() action,
      {Future<T> Function()? onLeaseUnavailable}) {
    final queueKey = _rootOverride?.call()?.absolute.path ?? 'default:$directoryName';
    final previous = _directoryMutations[queueKey] ?? Future<void>.value();
    final operation = previous.then((_) async {
      await ensureReady();
      Future<T> execute() async {
        // Other instances may share the same directory; use their latest index.
        await _loadIndex();
        return action();
      }
      if (!kIsWeb && (_rootOverride == null || debugUseSqliteLease)) {
        var entered = false;
        try {
          await debugBeforeLease?.call();
          return await NewsCacheLease.run(_root!, () {
            entered = true;
            return execute();
          });
        } catch (_) {
          if (entered || onLeaseUnavailable == null) rethrow;
          // Disable extra quota eviction durably before falling back to reads.
          try { await NewsCacheLease.disabledMarker(_root!).writeAsString('disabled', flush: true); }
          catch (_) { rethrow; }
          return onLeaseUnavailable();
        }
      }
      return execute();
    });
    final settled = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _directoryMutations[queueKey] = settled;
    settled.then((_) {
      if (identical(_directoryMutations[queueKey], settled)) {
        _directoryMutations.remove(queueKey);
      }
    });
    return operation;
  }

  bool _current(String path, int clearEpoch, int pathEpoch) =>
      _clearEpoch == clearEpoch && (_pathEpoch[path] ?? 0) == pathEpoch;

  Future<void>? _initializing;
  Future<void> ensureReady() {
    if (_ready) return Future.value();
    return _initializing ??=
        _initialize().whenComplete(() => _initializing = null);
  }

  Future<void> _initialize() async {
    final override = _rootOverride?.call();
    _root = override ??
        Directory(
          '${(await getTemporaryDirectory()).path}/$directoryName',
        );
    if (!await _root!.exists()) {
      await _root!.create(recursive: true);
    }
    await _loadIndex();
    _ready = true;
  }

  /// Instant memory/disk peek — never hits the network.
  Future<Uint8List?> peek(NewsImageCacheKey key) async {
    final clearEpoch = _clearEpoch;
    final pathEpoch = _pathEpoch[key.path] ?? 0;
    final mem = _memory.peek(key);
    if (mem != null) return mem;
    Future<Uint8List?> readDisk() async {
    if (!_current(key.path, clearEpoch, pathEpoch)) return null;
    await ensureReady();
    if (!_current(key.path, clearEpoch, pathEpoch)) return null;
    final entry = _index?[key.id];
    if (entry == null) return null;
    try {
      final file = File('${_root!.path}/${entry.file}');
      if (!await file.exists()) {
        if (!_current(key.path, clearEpoch, pathEpoch)) return null;
        _index!.remove(key.id);
        // Persist the removal with the next mutation, just like access time.
        // Reads can run concurrently without racing index file writes.
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || !_current(key.path, clearEpoch, pathEpoch))
        return null;
      _memory.put(key, bytes);
      entry.lastAccess = DateTime.now().toUtc();
      // Persist access order with the next cache mutation. A read should not
      // wait for a disk write before the image can be displayed.
      return bytes;
    } catch (e) {
      debugPrint('[news-img] disk peek failed type=${e.runtimeType}');
      return null;
    }
    }
    return _mutate(readDisk, onLeaseUnavailable: () async {
      await _loadIndex();
      return readDisk();
    });
  }

  /// Memory → disk → [fetch], with single-flight via [NewsImageBytesCache].
  Future<Uint8List?> getOrFetch(
    NewsImageCacheKey key,
    Future<Uint8List?> Function() fetch,
  ) async {
    final clearEpoch = _clearEpoch;
    final pathEpoch = _pathEpoch[key.path] ?? 0;
    bool current() => _current(key.path, clearEpoch, pathEpoch);
    final peeked = await peek(key);
    if (!current()) return null;
    if (peeked != null) return peeked;

    return _memory.getOrFetch(key, () async {
      if (!current()) return null;
      final bytes = await fetch();
      if (!current()) return null;
      if (bytes != null && bytes.isNotEmpty) {
        await _putGuarded(key, bytes, current);
      }
      return current() ? bytes : null;
    });
  }

  Future<void> put(NewsImageCacheKey key, Uint8List bytes) {
    if (bytes.isEmpty) return Future.value();
    _memory.put(key, bytes);
    return _mutate(() => _write(key, bytes), onLeaseUnavailable: () async {});
  }

  Future<void> _putGuarded(
          NewsImageCacheKey key, Uint8List bytes, bool Function() current) =>
      _mutate(() async {
        if (!current()) return;
        await ensureReady();
        if (!current()) return;
        _memory.put(key, bytes);
        await _write(key, bytes);
      }, onLeaseUnavailable: () async {});

  Future<void> _write(NewsImageCacheKey key, Uint8List bytes) async {
    await ensureReady();
    // Do not evict existing entries for a new image that cannot fit.
    if (bytes.length > maxTotalBytes && !_index!.containsKey(key.id)) return;
    final fileName = '${_fileId(key.id)}.bin';
    try {
      final file = File('${_root!.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      await debugAfterFileWrite?.call();
      _index![key.id] = _IndexEntry(
        file: fileName,
        bytes: bytes.length,
        path: key.path,
        version: key.version,
        lastAccess: DateTime.now().toUtc(),
      );
      await _evictIfNeeded();
      await _persistIndex();
      // Until the fallback reader and eviction protocol share an atomic
      // lease, extra budget eviction must remain disabled in ordinary builds.
      if (debugQuotaUsage != null) {
        final work = _scheduleSharedBudget();
        _quotaWork = Future.wait([_quotaWork, work]).then<void>((_) {});
        unawaited(_quotaWork);
      }
    } catch (e) {
      debugPrint('[news-img] disk put failed type=${e.runtimeType}');
    }
  }

  Future<void> invalidatePath(String path) {
    _pathEpoch[path] = (_pathEpoch[path] ?? 0) + 1;
    _memory.invalidatePath(path);
    return _mutate(() => _invalidatePath(path));
  }

  Future<void> _invalidatePath(String path) async {
    await ensureReady();
    final toRemove = _index!.entries
        .where((e) => e.value.path == path)
        .map((e) => e.key)
        .toList();
    for (final id in toRemove) {
      await _removeEntry(id);
    }
    await _persistIndex();
  }

  /// Drops older versions for [path], keeping [keepVersion] if present.
  Future<void> pruneOtherVersions(String path, String keepVersion) {
    _pathEpoch[path] = (_pathEpoch[path] ?? 0) + 1;
    return _mutate(() => _pruneOtherVersions(path, keepVersion));
  }

  Future<void> _pruneOtherVersions(String path, String keepVersion) async {
    await ensureReady();
    final toRemove = _index!.entries
        .where(
          (e) => e.value.path == path && e.value.version != keepVersion,
        )
        .map((e) => e.key)
        .toList();
    for (final id in toRemove) {
      final entry = _index![id];
      if (entry != null) {
        _memory.invalidateKey(
          NewsImageCacheKey(path: entry.path, version: entry.version),
        );
      }
      await _removeEntry(id);
    }
    if (toRemove.isNotEmpty) await _persistIndex();
  }

  Future<void> clear() {
    _clearEpoch++;
    _memory.clear();
    return _mutate(_clear);
  }

  Future<void> _clear() async {
    await ensureReady();
    try {
      if (await _root!.exists()) {
        await _root!.delete(recursive: true);
        await _root!.create(recursive: true);
      }
    } catch (_) {}
    _index = {};
    await _persistIndex();
  }

  Future<void> _loadIndex() async {
    final file = File('${_root!.path}/$_indexName');
    if (!await file.exists()) {
      _index = {};
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final map = <String, _IndexEntry>{};
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final value = entry.value;
          if (value is! Map) continue;
          map[entry.key.toString()] = _IndexEntry.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      }
      _index = map;
    } catch (_) {
      _index = {};
    }
  }

  Future<void> _persistIndex() async {
    final file = File('${_root!.path}/$_indexName');
    final encoded = <String, dynamic>{
      for (final e in _index!.entries) e.key: e.value.toJson(),
    };
    await file.writeAsString(jsonEncode(encoded));
  }

  Future<void> _evictIfNeeded() async {
    var total = _index!.values.fold<int>(0, (s, e) => s + e.bytes);
    while ((_index!.length > maxEntries || total > maxTotalBytes) &&
        _index!.isNotEmpty) {
      // LRU by lastAccess; equal timestamps keep earlier insertion order.
      final victim = _index!.entries.reduce((a, b) {
        final cmp = a.value.lastAccess.compareTo(b.value.lastAccess);
        if (cmp <= 0) return a;
        return b;
      });
      total -= victim.value.bytes;
      await _removeEntry(victim.key);
    }
  }

  /// Reclaims only indexed news files; never touches chat files or queues.
  /// Other writers and other Dart isolates are not yet quota participants.
  Future<void> _scheduleSharedBudget() async {
    final now = DateTime.now();
    final directory = _root!.absolute.path;
    final lastScan = _lastQuotaScan[directory];
    if (debugQuotaUsage == null && lastScan != null &&
        now.difference(lastScan) < const Duration(seconds: 30)) return;
    _lastQuotaScan[directory] = now;
    int? usage;
    try {
      usage = await (debugQuotaUsage?.call() ?? TemporaryCacheBudget.measure());
    } catch (_) {
      return;
    }
    if (usage == null || usage <= TemporaryCacheBudget.limitBytes) return;
    final measured = usage;
    await _mutate(() => _enforceSharedBudget(usage: measured));
  }

  Future<void> _enforceSharedBudget({required int usage}) async {
    if (await NewsCacheLease.disabledMarker(_root!).exists()) return;
    if (_index!.isEmpty) return;
    final keepId = _index!.entries.reduce((a, b) =>
        a.value.lastAccess.isAfter(b.value.lastAccess) ? a : b).key;
    var excess = usage - TemporaryCacheBudget.limitBytes;
    final candidates = _index!.entries.where((entry) => entry.key != keepId).toList()
      ..sort((a, b) => a.value.lastAccess.compareTo(b.value.lastAccess));
    var changed = false;
    for (final candidate in candidates) {
      if (excess <= 0) break;
      if (await NewsCacheLease.disabledMarker(_root!).exists()) return;
      final size = candidate.value.bytes;
      await _removeEntry(candidate.key);
      excess -= size;
      changed = true;
    }
    if (changed) await _persistIndex();
  }

  Future<void> _removeEntry(String id) async {
    final entry = _index!.remove(id);
    if (entry == null) return;
    _memory.invalidateKey(
      NewsImageCacheKey(path: entry.path, version: entry.version),
    );
    try {
      final file = File('${_root!.path}/${entry.file}');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  String _fileId(String keyId) => sha1.convert(utf8.encode(keyId)).toString();
}

class _IndexEntry {
  _IndexEntry({
    required this.file,
    required this.bytes,
    required this.path,
    required this.version,
    required this.lastAccess,
  });

  final String file;
  final int bytes;
  final String path;
  final String version;
  DateTime lastAccess;

  Map<String, dynamic> toJson() => {
        'file': file,
        'bytes': bytes,
        'path': path,
        'version': version,
        'lastAccess': lastAccess.toIso8601String(),
      };

  factory _IndexEntry.fromJson(Map<String, dynamic> json) {
    return _IndexEntry(
      file: (json['file'] ?? '').toString(),
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      path: (json['path'] ?? '').toString(),
      version: (json['version'] ?? '0').toString(),
      lastAccess:
          DateTime.tryParse((json['lastAccess'] ?? '').toString())?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}
