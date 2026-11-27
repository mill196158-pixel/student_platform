import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:student_ui/student_ui.dart';

import '../../core/optional_image_cache_budget.dart';
import 'news_image_disk_cache.dart';
import 'news_sqlite_image_store.dart';

enum PublicNewsClearStatus { complete, partial, unavailable }

class PublicNewsClearResult {
  const PublicNewsClearResult(this.status, {this.filesRemoved = 0});
  final PublicNewsClearStatus status;
  final int filesRemoved;
}

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
        _openExisting = openStore ?? NewsSqliteImageStore.openExistingPublicNews,
        _ownsClearHandle = openStore == null,
        _budget = budget ?? OptionalImageCacheBudget.instance;

  final NewsImageDiskCache _legacy;
  final Future<NewsSqliteImageStore> Function() _openStore;
  final Future<NewsSqliteImageStore?> Function() _openExisting;
  final bool _ownsClearHandle;
  final OptionalImageCacheBudget _budget;
  final Duration operationTimeout;
  Future<NewsSqliteImageStore>? _opening;
  final Map<String, Future<Uint8List?>> _inflight = {};
  final Map<String, String> _inflightPaths = {};
  int _pendingWrites = 0;
  Future<void>? _collectingOrphans;
  Future<PublicNewsClearResult>? _clearing;
  int _clearEpoch = 0;
  final Map<String, int> _pathEpoch = {};
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  ValueListenable<int> get invalidations => _revision;

  (int, int) displayVersion(NewsImageCacheKey key) =>
      (_clearEpoch, _pathEpoch[key.path] ?? 0);

  static Future<NewsSqliteImageStore> _openDefault() => NewsSqliteImageStore.openPublicNews();

  void _scheduleOrphanCollection(NewsSqliteImageStore store) {
    if (_collectingOrphans != null) return;
    var active = true;
    final done = () async {
      final deadline = Timer(const Duration(seconds: 2), () { active = false; });
      try {
        await store.collectOrphaned(current: () => active);
      } catch (_) {
        // Optional maintenance must never affect display.
      } finally {
        deadline.cancel();
        active = false;
        _budget.refreshAfterCollection();
      }
    }();
    _collectingOrphans = done;
    unawaited(done.whenComplete(() { if (identical(_collectingOrphans, done)) _collectingOrphans = null; }));
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
    if (_clearing != null) return const NewsImageReadResult(NewsImageReadState.unknown);
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
    if (_clearing != null) {
      final bytes = await fetch();
      return current() ? bytes : null;
    }
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
      if (_budget.knownInsufficientFor(bytes.length)) _scheduleOrphanCollection(store);
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
    _revision.value++;
    final ids = _inflightPaths.entries.where((entry) => path == null || entry.value == path).map((entry) => entry.key).toList();
    for (final id in ids) { _inflight.remove(id); _inflightPaths.remove(id); }
    await (await _store()).invalidate(path);
  }

  /// Drops the v2 public-news index entries, then removes their unreferenced
  /// files. Fresh downloads after that commit may populate the cache again.
  Future<PublicNewsClearResult> clearStoredCopies() {
    final pending = _clearing;
    if (pending != null) return pending;
    _clearEpoch++;
    _inflight.clear();
    _inflightPaths.clear();
    _clearing = _clearStoredCopies().whenComplete(() {
      _clearing = null;
      _budget.refreshAfterCollection();
    });
    _revision.value++;
    return _clearing!;
  }

  Future<PublicNewsClearResult> _clearStoredCopies() async {
    var removed = 0, invalidated = false;
    NewsSqliteImageStore? store;
    try {
      try {
        store = await _openExisting();
        if (store == null) return const PublicNewsClearResult(PublicNewsClearStatus.complete);
        await store.invalidateStoredPublicCopies();
        invalidated = true;
        final elapsed = Stopwatch()..start();
        bool current() => elapsed.elapsed < const Duration(seconds: 8);
        // Each pass releases the database between groups of at most 16 files.
        for (var batch = 0; batch < 64 && current(); batch++) {
          final result = await store.collectAfterUserClear(current: current);
          if (result == null) break;
          removed += result.filesUnlinked;
          if (result.remainingCandidates == 0) {
            return PublicNewsClearResult(result.hasUnrecognizedEntries
                ? PublicNewsClearStatus.partial : PublicNewsClearStatus.complete,
                filesRemoved: removed);
          }
          if (result.filesUnlinked == 0) break;
        }
      } finally {
        if (_ownsClearHandle && store != null) await store.database.close();
      }
    } catch (_) {
      // A failure after the index commit can leave orphan files for a retry.
    }
    return PublicNewsClearResult(
        invalidated ? PublicNewsClearStatus.partial : PublicNewsClearStatus.unavailable,
        filesRemoved: removed);
  }
}
