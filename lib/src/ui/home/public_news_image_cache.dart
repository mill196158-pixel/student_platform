import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:student_ui/student_ui.dart';

import '../../core/optional_image_cache_budget.dart';
import 'news_image_disk_cache.dart';
import 'news_sqlite_image_store.dart';

/// Public news only. Legacy is read-only and only under the SQLite guard.
class PublicNewsImageCache {
  /// One default coordinator per Dart isolate; screens do not own it.
  static final PublicNewsImageCache shared = PublicNewsImageCache();
  static const int maxOptionalImageBytes = 8 * 1024 * 1024;

  PublicNewsImageCache({NewsImageDiskCache? legacy,
      Future<NewsSqliteImageStore> Function()? openStore,
      OptionalImageCacheBudget? budget,
      this.operationTimeout = const Duration(seconds: 1)})
      : _legacy = legacy ?? NewsImageDiskCache(),
        _openStore = openStore ?? _openDefault,
        _budget = budget ?? OptionalImageCacheBudget.instance;

  final NewsImageDiskCache _legacy;
  final Future<NewsSqliteImageStore> Function() _openStore;
  final OptionalImageCacheBudget _budget;
  final Duration operationTimeout;
  Future<NewsSqliteImageStore>? _opening;
  final Map<String, Future<Uint8List?>> _inflight = {};
  final Map<String, String> _inflightPaths = {};
  int _pendingWrites = 0;
  int _clearEpoch = 0;
  final Map<String, int> _pathEpoch = {};

  static Future<NewsSqliteImageStore> _openDefault() async {
    final root = await getTemporaryDirectory();
    return NewsSqliteImageStore.openOwned(
        databasePath: '${await sqlite.getDatabasesPath()}/public_news_index_v2.db',
        root: Directory('${root.path}/public_news_blobs_v2'));
  }

  Future<NewsSqliteImageStore> _store() async {
    final opening = _opening ??= _openStore();
    late final NewsSqliteImageStore store;
    try {
      store = await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
    if (store.usable) return store;
    await store.waitForOwnedClose();
    if (identical(_opening, opening)) _opening = null;
    final replacement = await (_opening ??= _openStore());
    if (!replacement.usable) throw StateError('Image index unavailable');
    return replacement;
  }

  Future<NewsImageReadResult> read(NewsImageCacheKey key,
      {Future<Uint8List?> Function()? legacyFallback}) async {
    final clearEpoch = _clearEpoch, pathEpoch = _pathEpoch[key.path] ?? 0;
    try {
      final result = await (() async {
        final store = await _store();
        return store.readWithLegacy(key, () async =>
            await legacyFallback?.call() ?? await _legacy.peekLegacyReadOnly(key),
            legacyTimeout: Duration(microseconds: (operationTimeout.inMicroseconds ~/ 2).clamp(1, 500000)));
      })().timeout(operationTimeout);
      if (clearEpoch != _clearEpoch || pathEpoch != (_pathEpoch[key.path] ?? 0)) {
        return const NewsImageReadResult(NewsImageReadState.unknown);
      }
      return result;
    } catch (_) { return const NewsImageReadResult(NewsImageReadState.unknown); }
  }

  Future<Uint8List?> getOrFetch(NewsImageCacheKey key,
      Future<Uint8List?> Function() fetch) {
    final existing = _inflight[key.id];
    if (existing != null) return existing;
    final work = _getOrFetch(key, fetch);
    _inflight[key.id] = work;
    _inflightPaths[key.id] = key.path;
    void remove() { if (identical(_inflight[key.id], work)) { _inflight.remove(key.id); _inflightPaths.remove(key.id); } }
    unawaited(work.then<void>((_) => remove(), onError: (Object _, StackTrace __) => remove()));
    return work;
  }

  Future<Uint8List?> _getOrFetch(NewsImageCacheKey key,
      Future<Uint8List?> Function() fetch) async {
    final clearEpoch = _clearEpoch, pathEpoch = _pathEpoch[key.path] ?? 0;
    bool current() => clearEpoch == _clearEpoch && pathEpoch == (_pathEpoch[key.path] ?? 0);
    final cached = await read(key);
    if (!current()) return null;
    if (cached.state == NewsImageReadState.hit) return cached.bytes;
    NewsSqliteImageStore? store;
    NewsImageWriteTicket? ticket;
    var captureCurrent = true;
    try {
      final captured = await (() async {
        final opened = await _store();
        final proof = await opened.capture(key, current: () => captureCurrent && current());
        return (opened, proof);
      })().timeout(operationTimeout, onTimeout: () {
        captureCurrent = false;
        throw TimeoutException('Image authority unavailable');
      });
      store = captured.$1;
      ticket = captured.$2;
    } catch (_) { captureCurrent = false; }
    if (!current()) return null;
    final bytes = await fetch();
    if (!current()) return null;
    if (bytes == null || bytes.isEmpty) return bytes;
    if (store == null || ticket == null) return bytes;
    try {
      if (!await store.isCurrent(key, ticket).timeout(operationTimeout)) return null;
    } catch (_) { return null; }
    if (!current()) return null;
    // Display large downloads, but do not copy or persist them as optional cache.
    if (bytes.length > maxOptionalImageBytes) return bytes;
    final release = _budget.reserve(bytes.length);
    if (release != null) {
      if (_pendingWrites >= 16) { release(); return bytes; }
      final target = store, proof = ticket;
      final copy = Uint8List.fromList(bytes);
      _pendingWrites++;
      unawaited(() async {
        try { await target.put(key, copy, proof); } catch (_) {} finally { release(); _pendingWrites--; }
      }());
    } else {
      final pending = _budget.pendingInitialMeasurement;
      if (pending != null && _pendingWrites < 16) {
        final target = store, proof = ticket;
        final copy = Uint8List.fromList(bytes);
        _pendingWrites++;
        unawaited(() async {
          try {
            await pending.timeout(const Duration(seconds: 3));
            final release = _budget.reserve(copy.length);
            if (release == null) return;
            try { await target.put(key, copy, proof); } finally { release(); }
          } catch (_) {} finally { _pendingWrites--; }
        }());
      }
    }
    return bytes;
  }

  Future<void> invalidate([String? path]) async {
    if (path == null) { _clearEpoch++; } else { _pathEpoch[path] = (_pathEpoch[path] ?? 0) + 1; }
    final ids = _inflightPaths.entries.where((entry) => path == null || entry.value == path).map((entry) => entry.key).toList();
    for (final id in ids) { _inflight.remove(id); _inflightPaths.remove(id); }
    await (await _store()).invalidate(path);
  }
}
