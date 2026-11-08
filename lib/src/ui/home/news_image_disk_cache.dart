import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:student_ui/student_ui.dart';

import '../../core/optional_image_cache_budget.dart';

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
    this.immutableQaDatabase,
    this.legacyQaRootOverride,
    this.debugOptionalBudget,
  })  : _memory = memory ?? NewsImageBytesCache.instance,
        _rootOverride = rootOverride;

  final NewsImageBytesCache _memory;
  final Directory? Function()? _rootOverride;
  @visibleForTesting
  final OptionalImageCacheBudget? debugOptionalBudget;
  final int maxEntries;
  final int maxTotalBytes;

  /// Synthetic QA only. Never enables eviction or changes ordinary builds.
  @visibleForTesting
  final sqlite.Database? immutableQaDatabase;
  @visibleForTesting
  final Directory? Function()? legacyQaRootOverride;
  @visibleForTesting
  Future<void> Function()? debugBeforeImmutablePublish;
  @visibleForTesting
  Future<void> Function()? debugAfterImmutablePublish;
  @visibleForTesting
  Future<void> Function()? debugAfterClearIntent;
  @visibleForTesting
  Future<void> Function()? debugAfterCollectorIntent;
  @visibleForTesting
  Future<void> Function()? debugAfterCollectorRename;
  @visibleForTesting
  Future<void> Function()? debugAfterCollectorRenameBeforeCommit;
  @visibleForTesting
  Future<void> Function()? debugAfterCollectorUnlinkBeforeCommit;

  final String directoryName;
  static const _indexName = 'index.json';

  Directory? _root;
  Directory? _legacyQaRoot;
  Map<String, _IndexEntry>? _index;
  bool _qaIndexVerified = false;
  bool _qaIndexMissing = false;
  bool _ready = false;
  int _clearEpoch = 0;
  final Map<String, int> _pathEpoch = {};
  int _pendingBudgetRetries = 0;
  Future<void> _mutations = Future<void>.value();
  @visibleForTesting
  Future<void> Function()? debugAfterFileWrite;

  bool get _immutableQa =>
      const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA');
  Future<sqlite.Database>? _qaDatabaseFuture;
  Future<sqlite.Database> _openQaDatabase() {
    final supplied = immutableQaDatabase;
    if (supplied != null) return Future.value(supplied);
    return _qaDatabaseFuture ??= () async {
      final path =
          '${await sqlite.getDatabasesPath()}/news_cache_coordination_qa_v1.db';
      return sqlite.openDatabase(path);
    }();
  }

  static final Object _qaTxnKey = Object();
  sqlite.Transaction get _qaTransaction =>
      Zone.current[_qaTxnKey] as sqlite.Transaction;
  String get _qaDirectory => _root!.absolute.path;

  Future<(int, int)> _qaGeneration(String path) async {
    final rows = await _qaTransaction.query('news_cache_qa_epochs',
        where: 'directory=? AND path IN (?, ?)',
        whereArgs: [_qaDirectory, '', path]);
    var directory = 0, item = 0;
    for (final row in rows) {
      if (row['path'] == '') directory = row['generation'] as int;
      if (row['path'] == path) item = row['generation'] as int;
    }
    return (directory, item);
  }

  Future<void> _qaBump(String path) async {
    await _qaTransaction.rawInsert(
        'INSERT INTO news_cache_qa_epochs(directory,path,generation) VALUES(?,?,1) '
        'ON CONFLICT(directory,path) DO UPDATE SET generation=generation+1',
        [_qaDirectory, path]);
  }

  Future<T> _qaGuard<T>(Future<T> Function() action) async {
    await ensureReady();
    final database = await _openQaDatabase();
    // SQLite may encounter a lock at COMMIT after filesystem publication.
    // Let SQLite wait there; never replay the filesystem callback on failure.
    await database.execute('PRAGMA busy_timeout=3000');
    for (var attempt = 0;; attempt++) {
      var transactionStarted = false;
      try {
        return await database.transaction((txn) async {
          transactionStarted = true;
          await txn.execute(
              'CREATE TABLE IF NOT EXISTS news_cache_qa_lock (id INTEGER PRIMARY KEY)');
          await txn.insert('news_cache_qa_lock', {'id': 1},
              conflictAlgorithm: sqlite.ConflictAlgorithm.ignore);
          await txn.update('news_cache_qa_lock', {'id': 1}, where: 'id=1');
          await txn.execute('CREATE TABLE IF NOT EXISTS news_cache_qa_epochs ('
              'directory TEXT NOT NULL, path TEXT NOT NULL, generation INTEGER NOT NULL, '
              'PRIMARY KEY(directory,path))');
          await txn.execute(
              'CREATE TABLE IF NOT EXISTS news_cache_qa_clear_intents ('
              'directory TEXT PRIMARY KEY, snapshot TEXT NOT NULL)');
          await txn.execute(
              'CREATE TABLE IF NOT EXISTS news_cache_qa_legacy_suppression ('
              'directory TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(directory,path))');
          await txn.execute(
              'CREATE TABLE IF NOT EXISTS news_cache_qa_legacy_keep ('
              'directory TEXT NOT NULL, path TEXT NOT NULL, version TEXT NOT NULL, PRIMARY KEY(directory,path))');
          await txn
              .execute('CREATE TABLE IF NOT EXISTS news_cache_qa_protocols ('
                  'directory TEXT PRIMARY KEY, version INTEGER NOT NULL)');
          await txn.insert('news_cache_qa_protocols',
              {'directory': _qaDirectory, 'version': 2},
              conflictAlgorithm: sqlite.ConflictAlgorithm.ignore);
          final protocols = await txn.query('news_cache_qa_protocols',
              columns: ['version'],
              where: 'directory=?',
              whereArgs: [_qaDirectory]);
          if (protocols.length != 1 || protocols.single['version'] != 2) {
            throw StateError('Unsupported news cache protocol');
          }
          await txn.execute('CREATE TABLE IF NOT EXISTS news_cache_qa_blobs ('
              'directory TEXT NOT NULL, file TEXT NOT NULL, PRIMARY KEY(directory,file))');
          await txn.execute(
              'CREATE TABLE IF NOT EXISTS news_cache_qa_evictions ('
              'directory TEXT NOT NULL, file TEXT NOT NULL, token TEXT NOT NULL, '
              'state TEXT NOT NULL, PRIMARY KEY(directory,file))');
          await _loadIndex();
          await _replayQaClear(txn);
          return runZoned(action, zoneValues: {_qaTxnKey: txn});
        });
      } catch (error) {
        // Retry only BEGIN failure. Once the callback starts it may have
        // changed files and must never be repeated automatically.
        if (transactionStarted ||
            attempt >= 39 ||
            !error.toString().toLowerCase().contains('database is locked'))
          rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }

  Future<void> _publishQaIndex() async {
    if (!_qaIndexVerified && !_qaIndexMissing)
      throw StateError('Unverified index');
    final encoded = <String, dynamic>{
      for (final e in _index!.entries) e.key: e.value.toJson()
    };
    final suffix = base64UrlEncode(
        List<int>.generate(18, (_) => Random.secure().nextInt(256)));
    final next = File('${_root!.path}/.index.$suffix.tmp');
    await next.writeAsString(jsonEncode(encoded), flush: true);
    await next.rename('${_root!.path}/$_indexName');
    _qaIndexMissing = false;
    _qaIndexVerified = true;
  }

  Future<void> _replayQaClear(sqlite.Transaction txn) async {
    final rows = await txn.query('news_cache_qa_clear_intents',
        where: 'directory=?', whereArgs: [_qaDirectory]);
    if (rows.isEmpty) return;
    final decoded = jsonDecode(rows.single['snapshot'] as String);
    if (decoded is! Map) throw StateError('Invalid clear intent');
    if (!_qaIndexVerified && (!_qaIndexMissing || decoded.isNotEmpty))
      throw StateError('Unverified index');
    for (final entry in decoded.entries) {
      final current = _index![entry.key];
      if (current != null && current.revision == entry.value)
        _index!.remove(entry.key);
    }
    // Only the index is changed. Orphaned blobs stay until a separately
    // guarded collector can prove no active reader or newer publication.
    await _publishQaIndex();
    await txn.delete('news_cache_qa_clear_intents',
        where: 'directory=?', whereArgs: [_qaDirectory]);
  }

  Future<T> _mutate<T>(Future<T> Function() action) {
    final operation =
        _mutations.then((_) => _immutableQa ? _qaGuard(action) : action());
    _mutations =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
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
    if (_immutableQa) {
      _legacyQaRoot = legacyQaRootOverride?.call() ??
          (override == null
              ? Directory(
                  '${(await getTemporaryDirectory()).path}/$directoryName')
              : null);
    }
    _root = override ??
        Directory(
          '${(await getTemporaryDirectory()).path}/${_immutableQa ? '${directoryName}_immutable_qa_v2' : directoryName}',
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
    final mem = _immutableQa ? null : _memory.peek(key);
    if (mem != null) return mem;
    await _mutations;
    if (!_current(key.path, clearEpoch, pathEpoch)) return null;
    await ensureReady();
    if (!_current(key.path, clearEpoch, pathEpoch)) return null;
    if (_immutableQa) {
      try {
        return await _qaGuard(() async {
          final current = await _peekDisk(key, clearEpoch, pathEpoch);
          if (current != null || !_current(key.path, clearEpoch, pathEpoch))
            return current;
          final suppressed = await _qaTransaction.query(
              'news_cache_qa_legacy_suppression',
              columns: ['path'],
              where: 'directory=? AND path IN (?, ?)',
              whereArgs: [_qaDirectory, '', key.path]);
          if (suppressed.any((row) => row['path'] == '')) return null;
          if (suppressed.isNotEmpty) {
            final kept = await _qaTransaction.query('news_cache_qa_legacy_keep',
                where: 'directory=? AND path=? AND version=?',
                whereArgs: [_qaDirectory, key.path, key.version],
                limit: 1);
            if (kept.isEmpty) return null;
          }
          return _peekLegacyQa(key);
        });
      } catch (_) {
        // An unverified in-memory copy may have been cleared by another engine.
        return null;
      }
    }
    return _peekDisk(key, clearEpoch, pathEpoch);
  }

  Future<Uint8List?> _peekDisk(
      NewsImageCacheKey key, int clearEpoch, int pathEpoch) async {
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

  /// Memory → disk → [fetch], with single-flight via [NewsImageBytesCache].
  /// Read only: no copying, publication or deletion. Legacy writers do not
  /// participate in this lock, so these bytes are not an integrity snapshot.
  Future<Uint8List?> _peekLegacyQa(NewsImageCacheKey key) async {
    final root = _legacyQaRoot;
    if (root == null) return null;
    try {
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
          FileSystemEntityType.directory) return null;
      final index = File('${root.path}/$_indexName');
      if (await FileSystemEntity.type(index.path, followLinks: false) !=
          FileSystemEntityType.file) return null;
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is! Map || decoded[key.id] is! Map) return null;
      final data = decoded[key.id] as Map;
      final name = '${_fileId(key.id)}.bin';
      if (data['file'] != name ||
          data['path'] != key.path ||
          data['version'] != key.version) return null;
      final file = File('${root.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          File(await file.resolveSymbolicLinks()).parent.path !=
              await root.resolveSymbolicLinks()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

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

    if (_immutableQa) {
      // Epoch capture and the eventual publish are both protected by the
      // same shared database lock, even though the fetch itself is not.
      final generation = await _qaGuard(() => _qaGeneration(key.path));
      if (!current()) return null;
      final bytes = await fetch();
      if (!current() || bytes == null || bytes.isEmpty) return null;
      var accepted = false;
      await _mutate(() async {
        if (!current() || await _qaGeneration(key.path) != generation) return;
        // Publication failure does not make fetched bytes unusable for this
        // display; no API here promises that disk persistence succeeded.
        await _writeImmutableQa(key, bytes);
        accepted = current() && await _qaGeneration(key.path) == generation;
      });
      return accepted ? bytes : null;
    }
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
    return _mutate(() => _write(key, bytes));
  }

  Future<void> _putGuarded(
          NewsImageCacheKey key, Uint8List bytes, bool Function() current) =>
      _mutate(() async {
        if (!current()) return;
        await ensureReady();
        if (!current()) return;
        _memory.put(key, bytes);
        await _write(key, bytes);
      });

  Future<void> _write(NewsImageCacheKey key, Uint8List bytes,
      {bool allowBudgetRetry = true}) async {
    await ensureReady();
    if (_immutableQa) {
      await _writeImmutableQa(key, bytes);
      return;
    }
    // Do not evict existing entries for a new image that cannot fit.
    if (bytes.length > maxTotalBytes && !_index!.containsKey(key.id)) return;
    final budget = debugOptionalBudget ??
        (_rootOverride == null ? OptionalImageCacheBudget.instance : null);
    final release = budget?.reserve(bytes.length);
    if (budget != null && release == null) {
      final pending = budget.pendingInitialMeasurement;
      if (allowBudgetRetry && pending != null && _pendingBudgetRetries < 16) {
        final clearEpoch = _clearEpoch;
        final pathEpoch = _pathEpoch[key.path] ?? 0;
        _pendingBudgetRetries++;
        unawaited(() async {
          try {
            await pending.timeout(const Duration(seconds: 3));
            await _mutate(() async {
              if (!_current(key.path, clearEpoch, pathEpoch) ||
                  !identical(_memory.peek(key), bytes)) return;
              await _write(key, bytes, allowBudgetRetry: false);
            });
          } catch (_) {
            // Persistence is optional; the displayed image stays in memory.
          } finally {
            _pendingBudgetRetries--;
          }
        }());
      }
      return;
    }
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
    } catch (e) {
      debugPrint('[news-img] disk put failed type=${e.runtimeType}');
    } finally {
      release?.call();
    }
  }

  /// A copy-on-write experiment: old blobs remain untouched, including after
  /// a crash. All writers must share [immutableQaDatabase]; therefore this is
  /// test-only and is not yet connected to the application's three caches.
  Future<bool> _writeImmutableQa(NewsImageCacheKey key, Uint8List bytes) async {
    try {
      if (!_qaIndexVerified && !_qaIndexMissing)
        throw StateError('Unverified index');
      if (bytes.length > maxTotalBytes && !_index!.containsKey(key.id))
        return false;
      final name = '${_fileId(key.id)}.${sha256.convert(bytes)}.bin';
      final pending = await _qaTransaction.query('news_cache_qa_evictions',
          where: 'directory=? AND file=?',
          whereArgs: [_qaDirectory, name],
          limit: 1);
      if (pending.isNotEmpty) return false;
      final blob = File('${_root!.path}/$name');
      if (await FileSystemEntity.type(blob.path, followLinks: false) ==
          FileSystemEntityType.link) return false;
      if (!await blob.exists()) {
        final temp = File(
            '${_root!.path}/.$name.${DateTime.now().microsecondsSinceEpoch}.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(blob.path);
      }
      await _qaTransaction.insert(
          'news_cache_qa_blobs', {'directory': _qaDirectory, 'file': name},
          conflictAlgorithm: sqlite.ConflictAlgorithm.ignore);
      _index![key.id] = _IndexEntry(
          file: name,
          bytes: bytes.length,
          path: key.path,
          version: key.version,
          lastAccess: DateTime.now().toUtc(),
          revision: base64UrlEncode(
              List<int>.generate(18, (_) => Random.secure().nextInt(256))));
      await debugBeforeImmutablePublish?.call();
      await _publishQaIndex();
      await debugAfterImmutablePublish?.call();
      return true;
    } catch (e) {
      // A later read must use the actually published index, not an aborted one.
      await _loadIndex();
      debugPrint('[news-img] immutable QA write failed type=${e.runtimeType}');
      return false;
    }
  }

  /// Test-only collector. A durable intent blocks publication of the same
  /// immutable blob before it is staged. Untracked, legacy and referenced
  /// files are never candidates. This is not a global quota implementation.
  Future<int> collectQaOrphans({required bool allOperationsParticipate}) async {
    if (!_immutableQa || !allOperationsParticipate) return 0;
    var freed = 0;
    try {
      freed += await recoverQaOrphans(allOperationsParticipate: true);
      for (;;) {
        final candidate = await _qaGuard<(String, String)?>(() async {
          if (!_qaIndexVerified ||
              await FileSystemEntity.type(_root!.path, followLinks: false) !=
                  FileSystemEntityType.directory) return null;
          final rows = await _qaTransaction.query('news_cache_qa_blobs',
              where: 'directory=?', whereArgs: [_qaDirectory]);
          for (final row in rows) {
            final name = row['file'];
            if (name is! String ||
                !RegExp(r'^[a-f0-9]{40}\.[a-f0-9]{64}\.bin$').hasMatch(name) ||
                _index!.values.any((entry) => entry.file == name)) continue;
            final previous = await _qaTransaction.query(
                'news_cache_qa_evictions',
                where: 'directory=? AND file=?',
                whereArgs: [_qaDirectory, name]);
            if (previous.isNotEmpty) continue;
            final file = File('${_root!.path}/$name');
            if (await FileSystemEntity.type(file.path, followLinks: false) !=
                    FileSystemEntityType.file ||
                File(await file.resolveSymbolicLinks()).parent.path !=
                    await _root!.resolveSymbolicLinks()) continue;
            final token = base64UrlEncode(
                List<int>.generate(18, (_) => Random.secure().nextInt(256)));
            await _qaTransaction.insert('news_cache_qa_evictions', {
              'directory': _qaDirectory,
              'file': name,
              'token': token,
              'state': 'intent'
            });
            return (name, token);
          }
          return null;
        });
        if (candidate == null) break;
        await debugAfterCollectorIntent?.call();
        final (name, token) = candidate;
        final staged = File('${_root!.path}/.news-evict-$token');
        final size = await _qaGuard<int?>(() async {
          if (_index!.values.any((entry) => entry.file == name)) return null;
          final journal = await _qaTransaction.query('news_cache_qa_evictions',
              where: 'directory=? AND file=? AND token=? AND state=?',
              whereArgs: [_qaDirectory, name, token, 'intent']);
          final original = File('${_root!.path}/$name');
          if (journal.length != 1 ||
              await FileSystemEntity.type(original.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              await FileSystemEntity.type(staged.path, followLinks: false) !=
                  FileSystemEntityType.notFound ||
              File(await original.resolveSymbolicLinks()).parent.path !=
                  await _root!.resolveSymbolicLinks()) return null;
          final size = await original.length();
          await original.rename(staged.path);
          await debugAfterCollectorRenameBeforeCommit?.call();
          await _qaTransaction.update(
              'news_cache_qa_evictions', {'state': 'staged'},
              where: 'directory=? AND file=? AND token=?',
              whereArgs: [_qaDirectory, name, token]);
          return size;
        });
        if (size == null) break;
        await debugAfterCollectorRename?.call();
        final deleted = await _qaGuard<bool>(() async {
          if (!_qaIndexVerified ||
              _index!.values.any((entry) => entry.file == name)) return false;
          final journal = await _qaTransaction.query('news_cache_qa_evictions',
              where: 'directory=? AND file=? AND token=? AND state=?',
              whereArgs: [_qaDirectory, name, token, 'staged']);
          if (journal.length != 1 ||
              await FileSystemEntity.type(staged.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              File(await staged.resolveSymbolicLinks()).parent.path !=
                  await _root!.resolveSymbolicLinks()) return false;
          await staged.delete();
          if (await FileSystemEntity.type(staged.path, followLinks: false) !=
              FileSystemEntityType.notFound) return false;
          await debugAfterCollectorUnlinkBeforeCommit?.call();
          await _qaTransaction.delete('news_cache_qa_evictions',
              where: 'directory=? AND file=? AND token=? AND state=?',
              whereArgs: [_qaDirectory, name, token, 'staged']);
          await _qaTransaction.delete('news_cache_qa_blobs',
              where: 'directory=? AND file=?', whereArgs: [_qaDirectory, name]);
          return true;
        });
        if (!deleted) break;
        freed += size;
      }
    } catch (_) {
      // Unknown or interrupted entries remain protected by their intent.
    }
    return freed;
  }

  /// Resume only journalled v2 orphans. An interrupted intent may be
  /// cancelled while its original still exists; ambiguous states stay pinned.
  /// Counts only an unlink completed in this call after transaction commit.
  @visibleForTesting
  Future<int> recoverQaOrphans({required bool allOperationsParticipate}) async {
    if (!_immutableQa || !allOperationsParticipate) return 0;
    try {
      return await _qaGuard<int>(() async {
        if (!_qaIndexVerified ||
            await FileSystemEntity.type(_root!.path, followLinks: false) !=
                FileSystemEntityType.directory) return 0;
        final rows = await _qaTransaction.query('news_cache_qa_evictions',
            where: 'directory=?', whereArgs: [_qaDirectory]);
        var freed = 0;
        for (final row in rows) {
          final name = row['file'], token = row['token'], state = row['state'];
          if (name is! String ||
              token is! String ||
              !RegExp(r'^[a-f0-9]{40}\.[a-f0-9]{64}\.bin$').hasMatch(name) ||
              !RegExp(r'^[A-Za-z0-9_-]{24}$').hasMatch(token) ||
              (state != 'intent' && state != 'staged')) continue;
          final sameToken = await _qaTransaction.query(
              'news_cache_qa_evictions',
              columns: ['file'],
              where: 'directory=? AND token=?',
              whereArgs: [_qaDirectory, token]);
          if (sameToken.length != 1) continue;
          final registrations = await _qaTransaction.query(
              'news_cache_qa_blobs',
              where: 'directory=? AND file=?',
              whereArgs: [_qaDirectory, name]);
          if (registrations.length != 1) continue;
          final original = File('${_root!.path}/$name');
          final staged = File('${_root!.path}/.news-evict-$token');
          final originalType =
              await FileSystemEntity.type(original.path, followLinks: false);
          final stagedType =
              await FileSystemEntity.type(staged.path, followLinks: false);
          if (state == 'intent' &&
              originalType == FileSystemEntityType.file &&
              stagedType == FileSystemEntityType.notFound) {
            await _qaTransaction.delete('news_cache_qa_evictions',
                where: 'directory=? AND file=? AND token=? AND state=?',
                whereArgs: [_qaDirectory, name, token, state]);
            continue;
          }
          if (!_index!.values.any((entry) => entry.file == name) &&
              originalType == FileSystemEntityType.notFound &&
              stagedType == FileSystemEntityType.notFound) {
            // The OS or an interrupted unlink removed both paths. Retire only
            // metadata; there is no proof of bytes freed in this invocation.
            await _qaTransaction.delete('news_cache_qa_evictions',
                where: 'directory=? AND file=? AND token=? AND state=?',
                whereArgs: [_qaDirectory, name, token, state]);
            await _qaTransaction.delete('news_cache_qa_blobs',
                where: 'directory=? AND file=?',
                whereArgs: [_qaDirectory, name]);
            continue;
          }
          if (_index!.values.any((entry) => entry.file == name) ||
              originalType != FileSystemEntityType.notFound ||
              stagedType != FileSystemEntityType.file ||
              File(await staged.resolveSymbolicLinks()).parent.path !=
                  await _root!.resolveSymbolicLinks()) continue;
          final size = await staged.length();
          await staged.delete();
          if (await FileSystemEntity.type(staged.path, followLinks: false) !=
              FileSystemEntityType.notFound) continue;
          await _qaTransaction.delete('news_cache_qa_evictions',
              where: 'directory=? AND file=? AND token=? AND state=?',
              whereArgs: [_qaDirectory, name, token, state]);
          await _qaTransaction.delete('news_cache_qa_blobs',
              where: 'directory=? AND file=?', whereArgs: [_qaDirectory, name]);
          freed += size;
        }
        return freed;
      });
    } catch (_) {
      return 0;
    }
  }

  Future<void> invalidatePath(String path) {
    _pathEpoch[path] = (_pathEpoch[path] ?? 0) + 1;
    _memory.invalidatePath(path);
    if (_immutableQa) return _removeQaTwoPhase(path: path);
    return _mutate(() => _invalidatePath(path));
  }

  Future<void> _invalidatePath(String path) async {
    await ensureReady();
    if (_immutableQa) await _qaBump(path);
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
    if (_immutableQa)
      return _removeQaTwoPhase(path: path, keepVersion: keepVersion);
    return _mutate(() => _pruneOtherVersions(path, keepVersion));
  }

  Future<void> _pruneOtherVersions(String path, String keepVersion) async {
    await ensureReady();
    if (_immutableQa) await _qaBump(path);
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
    if (_immutableQa) return _removeQaTwoPhase();
    return _mutate(_clear);
  }

  Future<void> _removeQaTwoPhase({String? path, String? keepVersion}) async {
    await _mutations;
    await _qaGuard(() async {
      if (!_qaIndexVerified && !_qaIndexMissing)
        throw StateError('Unverified index');
      await _qaBump(path ?? '');
      await _qaTransaction.insert('news_cache_qa_legacy_suppression',
          {'directory': _qaDirectory, 'path': path ?? ''},
          conflictAlgorithm: sqlite.ConflictAlgorithm.ignore);
      if (path != null && keepVersion != null) {
        await _qaTransaction.insert('news_cache_qa_legacy_keep',
            {'directory': _qaDirectory, 'path': path, 'version': keepVersion},
            conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
      } else if (path != null) {
        await _qaTransaction.delete('news_cache_qa_legacy_keep',
            where: 'directory=? AND path=?', whereArgs: [_qaDirectory, path]);
      }
      final snapshot = {
        for (final e in _index!.entries)
          if (path == null ||
              (e.value.path == path &&
                  (keepVersion == null || e.value.version != keepVersion)))
            e.key: e.value.revision
      };
      await _qaTransaction.insert('news_cache_qa_clear_intents',
          {'directory': _qaDirectory, 'snapshot': jsonEncode(snapshot)},
          conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
    });
    await debugAfterClearIntent?.call();
    // Every guarded operation replays an existing intent before acting.
    await _qaGuard(() async {});
  }

  Future<void> _clear() async {
    await ensureReady();
    if (_immutableQa) await _qaBump('');
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
    _qaIndexVerified = false;
    _qaIndexMissing = false;
    final file = File('${_root!.path}/$_indexName');
    if (!_immutableQa) {
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
            map[entry.key.toString()] =
                _IndexEntry.fromJson(Map<String, dynamic>.from(value));
          }
        }
        _index = map;
      } catch (_) {
        _index = {};
      }
      return;
    }
    final indexType =
        await FileSystemEntity.type(file.path, followLinks: false);
    if (indexType == FileSystemEntityType.notFound) {
      _qaIndexMissing = true;
      _index = {};
      return;
    }
    if (indexType != FileSystemEntityType.file) {
      _index = {};
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final map = <String, _IndexEntry>{};
      var valid = decoded is Map &&
          await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file;
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final value = entry.value;
          if (entry.key is! String ||
              value is! Map ||
              value['file'] is! String ||
              (value['file'] as String).isEmpty ||
              value['path'] is! String ||
              value['version'] is! String) {
            valid = false;
            continue;
          }
          map[entry.key as String] =
              _IndexEntry.fromJson(Map<String, dynamic>.from(value));
        }
      }
      _index = map;
      _qaIndexVerified = valid;
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
    this.revision = '',
  });

  final String file;
  final int bytes;
  final String path;
  final String version;
  DateTime lastAccess;
  final String revision;

  Map<String, dynamic> toJson() => {
        'file': file,
        'bytes': bytes,
        'path': path,
        'version': version,
        'lastAccess': lastAccess.toIso8601String(),
        if (revision.isNotEmpty) 'revision': revision,
      };

  factory _IndexEntry.fromJson(Map<String, dynamic> json) {
    return _IndexEntry(
      file: (json['file'] ?? '').toString(),
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      path: (json['path'] ?? '').toString(),
      version: (json['version'] ?? '0').toString(),
      revision: (json['revision'] ?? '').toString(),
      lastAccess:
          DateTime.tryParse((json['lastAccess'] ?? '').toString())?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}
