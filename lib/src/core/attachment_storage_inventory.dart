import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Approximate named file lengths across all accounts, for display only.
class AttachmentStorageReport {
  const AttachmentStorageReport({
    this.authorizedFilesBytes,
    this.viewerFilesBytes,
    this.downloadedFilesBytes,
  });

  final int? authorizedFilesBytes;
  final int? viewerFilesBytes;
  final int? downloadedFilesBytes;
}

/// Separate from the admission collector: these directories may contain drafts,
/// access receipts, offline files and exports still open in other apps.
class AttachmentStorageInventory {
  AttachmentStorageInventory._(this._cacheRoot, this._platformRoot,
      this._entryLimit, this._depthLimit, this._timeout);

  static final shared = AttachmentStorageInventory._(
      getApplicationCacheDirectory, true, 4096, 12, const Duration(seconds: 3));

  @visibleForTesting
  factory AttachmentStorageInventory.forTesting({
    required Future<Directory> Function() cacheRoot,
    bool platformRoot = false,
    int entryLimit = 4096,
    int depthLimit = 12,
    Duration timeout = const Duration(seconds: 3),
  }) {
    return AttachmentStorageInventory._(
        cacheRoot, platformRoot, entryLimit, depthLimit, timeout);
  }

  final Future<Directory> Function() _cacheRoot;
  final bool _platformRoot;
  final int _entryLimit, _depthLimit;
  final Duration _timeout;
  Future<AttachmentStorageReport>? _pending;

  Future<AttachmentStorageReport> collect() {
    final existing = _pending;
    if (existing != null) return existing;
    final scan = _AttachmentWalk(this);
    final raw = Future<void>.microtask(scan.measure);
    final observation = raw
        .then((_) => scan.report)
        .timeout(_timeout, onTimeout: () => scan.report);
    _pending = observation;
    // An unresponsive OS request can outlive the UI deadline. Coalesce until
    // the real walk settles so repeated refreshes do not start more IO.
    unawaited(raw.then<void>((_) {
      if (identical(_pending, observation)) _pending = null;
    }));
    return observation;
  }
}

class _AttachmentWalk {
  _AttachmentWalk(this.inventory);

  final AttachmentStorageInventory inventory;
  final Stopwatch _clock = Stopwatch()..start();
  final _sizes = <String, int?>{};
  static const _categories = {
    'authorized_chat_files',
    'chat_files',
    'downloaded_chat_files'
  };

  bool get _inTime => _clock.elapsed < inventory._timeout;

  AttachmentStorageReport get report => AttachmentStorageReport(
        authorizedFilesBytes: _sizes['authorized_chat_files'],
        viewerFilesBytes: _sizes['chat_files'],
        downloadedFilesBytes: _sizes['downloaded_chat_files'],
      );

  Future<bool> _ordinaryDirectory(Directory dir) async =>
      _inTime &&
      await FileSystemEntity.type(dir.path, followLinks: false) ==
          FileSystemEntityType.directory &&
      _inTime &&
      path.equals(await dir.resolveSymbolicLinks(), dir.path) &&
      _inTime;

  Future<void> measure() async {
    try {
      final supplied = (await inventory._cacheRoot()).absolute;
      if (!_inTime ||
          await FileSystemEntity.type(supplied.path, followLinks: false) !=
              FileSystemEntityType.directory) return;
      final canonical = path.normalize(await supplied.resolveSymbolicLinks());
      if (!path.isAbsolute(canonical) ||
          (!inventory._platformRoot &&
              !path.equals(supplied.path, canonical))) {
        return;
      }
      final parent = Directory(canonical);
      if (!await _ordinaryDirectory(parent)) return;
      final present = <String>{};
      var count = 0;
      await for (final entry in parent.list(followLinks: false)) {
        if (!_inTime || ++count > inventory._entryLimit) return;
        final name = path.basename(entry.path);
        if (_categories.contains(name)) present.add(name);
      }
      if (!await _ordinaryDirectory(parent)) return;
      await Future.wait(_categories.map((name) async {
        if (!_inTime) return;
        if (!present.contains(name)) {
          _sizes[name] = 0;
          return;
        }
        try {
          _sizes[name] =
              await _directoryBytes(Directory(path.join(canonical, name)));
        } on FileSystemException {
          // An incomplete category remains unknown.
        }
      }));
    } catch (_) {
      // Plugin and filesystem failures must not turn into a zero measurement.
    }
  }

  Future<int?> _directoryBytes(Directory directory) async {
    var count = 0;
    Future<int?> visit(Directory dir, int depth) async {
      if (depth > inventory._depthLimit || !await _ordinaryDirectory(dir)) {
        return null;
      }
      var total = 0;
      await for (final entry in dir.list(followLinks: false)) {
        if (!_inTime || ++count > inventory._entryLimit) return null;
        if (!path.equals(path.dirname(entry.path), dir.path)) return null;
        final int? length;
        if (entry is Directory) {
          length = await visit(entry, depth + 1);
        } else if (entry is File) {
          if (await FileSystemEntity.type(entry.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              !_inTime ||
              !path.equals(await entry.resolveSymbolicLinks(), entry.path) ||
              !_inTime) return null;
          length = await entry.length();
          if (!_inTime ||
              await FileSystemEntity.type(entry.path, followLinks: false) !=
                  FileSystemEntityType.file) return null;
        } else {
          return null;
        }
        if (length == null || length < 0 || length > 9007199254740991 - total) {
          return null;
        }
        total += length;
      }
      return await _ordinaryDirectory(dir) ? total : null;
    }

    return visit(directory, 0);
  }
}
