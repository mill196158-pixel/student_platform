import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A one-way device-local safety circuit for degraded online mode.
/// Once tripped, old pinned copies stay disabled until a separately reviewed
/// recovery/migration exists. Legacy cache and network are unaffected.
class PinnedArchiveQuarantine {
  PinnedArchiveQuarantine(this.supportRoot);
  final Directory supportRoot;
  static const _contents = 'pinned-archive-disabled-v1';
  File get _marker => File('${supportRoot.path}/pinned-archive-disabled-v1');

  Future<bool> _safeRoot() async =>
      await FileSystemEntity.type(supportRoot.path, followLinks: false) == FileSystemEntityType.directory;

  /// Any I/O uncertainty is treated as disabled.
  Future<bool> isDisabled() async {
    try {
      if (!await _safeRoot()) return true;
      return await FileSystemEntity.type(_marker.path, followLinks: false) != FileSystemEntityType.notFound;
    } catch (_) { return true; }
  }

  /// Must complete successfully before a request may bypass the DB fence.
  Future<bool> trip() async {
    File? temp;
    try {
      if (!await _safeRoot()) return false;
      final existing = await FileSystemEntity.type(_marker.path, followLinks: false);
      if (existing == FileSystemEntityType.file && await _marker.readAsString() == _contents) return true;
      if (existing != FileSystemEntityType.notFound) return false;
      final r = Random.secure();
      final nonce = base64UrlEncode(List<int>.generate(18, (_) => r.nextInt(256)));
      temp = File('${_marker.path}.$nonce.tmp');
      await temp.create(exclusive: true);
      await temp.writeAsString(_contents, flush: true);
      await temp.rename(_marker.path);
      return await FileSystemEntity.type(_marker.path, followLinks: false) == FileSystemEntityType.file &&
          await _marker.readAsString() == _contents;
    } catch (_) {
      // Another engine may have published the same marker first.
      try {
        return await _safeRoot() &&
            await FileSystemEntity.type(_marker.path, followLinks: false) == FileSystemEntityType.file &&
            await _marker.readAsString() == _contents;
      } catch (_) { return false; }
    }
    finally { try { if (temp != null && await temp.exists()) await temp.delete(); } catch (_) {} }
  }
}
