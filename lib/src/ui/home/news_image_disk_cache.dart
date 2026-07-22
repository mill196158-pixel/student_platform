import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_ui/student_ui.dart';

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
    this.maxEntries = 80,
    this.maxTotalBytes = 48 * 1024 * 1024,
  })  : _memory = memory ?? NewsImageBytesCache.instance,
        _rootOverride = rootOverride;

  final NewsImageBytesCache _memory;
  final Directory? Function()? _rootOverride;
  final int maxEntries;
  final int maxTotalBytes;

  static const _dirName = 'news_images_v1';
  static const _indexName = 'index.json';

  Directory? _root;
  Map<String, _IndexEntry>? _index;
  bool _ready = false;

  Future<void> ensureReady() async {
    if (_ready) return;
    final override = _rootOverride?.call();
    _root = override ??
        Directory(
          '${(await getTemporaryDirectory()).path}/$_dirName',
        );
    if (!await _root!.exists()) {
      await _root!.create(recursive: true);
    }
    await _loadIndex();
    _ready = true;
  }

  /// Instant memory/disk peek — never hits the network.
  Future<Uint8List?> peek(NewsImageCacheKey key) async {
    final mem = _memory.peek(key);
    if (mem != null) return mem;
    await ensureReady();
    final entry = _index?[key.id];
    if (entry == null) return null;
    try {
      final file = File('${_root!.path}/${entry.file}');
      if (!await file.exists()) {
        _index!.remove(key.id);
        await _persistIndex();
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      _memory.put(key, bytes);
      entry.lastAccess = DateTime.now().toUtc();
      await _persistIndex();
      return bytes;
    } catch (e) {
      debugPrint('[news-img] disk peek failed type=${e.runtimeType}');
      return null;
    }
  }

  /// Memory → disk → [fetch], with single-flight via [NewsImageBytesCache].
  Future<Uint8List?> getOrFetch(
    NewsImageCacheKey key,
    Future<Uint8List?> Function() fetch,
  ) async {
    final peeked = await peek(key);
    if (peeked != null) return peeked;

    return _memory.getOrFetch(key, () async {
      final bytes = await fetch();
      if (bytes != null && bytes.isNotEmpty) {
        await put(key, bytes);
      }
      return bytes;
    });
  }

  Future<void> put(NewsImageCacheKey key, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    _memory.put(key, bytes);
    await ensureReady();
    final fileName = '${_fileId(key.id)}.bin';
    try {
      final file = File('${_root!.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      _index![key.id] = _IndexEntry(
        file: fileName,
        bytes: bytes.length,
        path: key.path,
        version: key.version,
        lastAccess: DateTime.now().toUtc(),
      );
      await _evictIfNeeded();
      await _persistIndex();
    } catch (e) {
      debugPrint('[news-img] disk put failed type=${e.runtimeType}');
    }
  }

  Future<void> invalidatePath(String path) async {
    _memory.invalidatePath(path);
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
  Future<void> pruneOtherVersions(String path, String keepVersion) async {
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

  Future<void> clear() async {
    _memory.clear();
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
