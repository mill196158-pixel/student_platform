import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';

/// Explicitly pinned copies live outside the OS-purgeable cache directory.
/// Callers must supply an exact session/receipt check and a trustworthy free
/// space provider. This store never removes or rewrites legacy files.
class PinnedMediaStore {
  PinnedMediaStore({required this.db, required this.supportRoot, required this.legacy,
    required String project, required this.uid, required this.sessionId,
    required this.permit, required this.freeBytes,
    required this.verifyLegacyProvenance}) : project = _normalize(project);
  final Database db;
  final Directory supportRoot;
  final MediaCacheProtection legacy;
  final String project, uid, sessionId;
  final bool Function() permit;
  final Future<int?> Function(Directory) freeBytes;
  /// Must verify a durable receipt binding this particular source to the
  /// normalized project, owner, session and object; legacy filenames alone
  /// are insufficient evidence. No permissive default is provided.
  final Future<bool> Function(File source, String project, String uid,
      String sessionId, String key) verifyLegacyProvenance;
  @visibleForTesting
  Future<void> Function()? debugAfterCopy;
  @visibleForTesting
  Future<void> Function()? debugBeforePublish;
  @visibleForTesting
  Future<void> Function()? debugDuringPublish;

  static String _normalize(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.hasQuery || uri.hasFragment) return '';
    return uri.toString().replaceFirst(RegExp(r'/+$'), '');
  }

  String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
  String _objectId(String key) => _hash(jsonEncode([project, uid, key]));
  String get _sessionDigest => _hash(jsonEncode([project, uid, sessionId]));
  String _proof(String key, String checksum) => jsonEncode({
    'v': 1, 'object': _objectId(key),
    'session': _sessionDigest, 'sha256': checksum,
  });
  Directory get _folder => Directory('${supportRoot.path}/pinned_media_v1/${_hash(project)}/${_hash(uid)}');
  File _data(String key, String checksum) => File('${_folder.path}/${_objectId(key)}.$checksum.bin');
  File _receipt(String key) => File('${_folder.path}/${_objectId(key)}.$_sessionDigest.proof');
  bool _current() {
    try { return identical(db, legacy.db) && project.isNotEmpty && project == _normalize(legacy.project) &&
        uid.isNotEmpty && sessionId.isNotEmpty && permit(); }
    catch (_) { return false; }
  }
  Future<String> _checksum(File file) async => (await sha256.bind(file.openRead()).first).toString();

  Future<bool> _safeFolder() async {
    final base = supportRoot.absolute;
    final levels = [base, Directory('${base.path}/pinned_media_v1'),
      Directory('${base.path}/pinned_media_v1/${_hash(project)}'), _folder.absolute];
    for (final directory in levels) {
      if (await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.directory) return false;
    }
    final canonical = await base.resolveSymbolicLinks();
    final child = await _folder.resolveSymbolicLinks();
    return child.startsWith('$canonical${Platform.pathSeparator}');
  }

  Future<bool> _ensureSafeFolder() async {
    final base = supportRoot.absolute;
    if (await FileSystemEntity.type(base.path, followLinks: false) != FileSystemEntityType.directory) return false;
    final canonical = await base.resolveSymbolicLinks();
    for (final dir in [Directory('${base.path}/pinned_media_v1'),
      Directory('${base.path}/pinned_media_v1/${_hash(project)}'), _folder.absolute]) {
      var type = await FileSystemEntity.type(dir.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await dir.create();
        type = await FileSystemEntity.type(dir.path, followLinks: false);
      }
      if (type != FileSystemEntityType.directory ||
          !(await dir.resolveSymbolicLinks()).startsWith('$canonical${Platform.pathSeparator}')) return false;
    }
    return _safeFolder();
  }

  /// Copies a verified legacy object. A crash can leave a partial file or a
  /// complete copy without proof; neither is returned by [readPinned].
  Future<bool> pinFromLegacy(String key) async {
    if (key.isEmpty || !_current()) return false;
    try {
        if (!_current()) return false;
        final source = await legacy.verifiedExistingFile(uid, key, _current);
        if (source == null || !_current()) return false;
        if (!await verifyLegacyProvenance(source, project, uid, sessionId, key) || !_current()) return false;
        final size = await source.length();
        if (!_current() || size <= 0) return false;
        final available = await freeBytes(supportRoot);
        if (!_current() || available == null || available < size + 1048576) return false;
        final before = await _checksum(source);
        if (!_current()) return false;
        if (!await _ensureSafeFolder() || !_current()) return false;
        final receipt = _receipt(key);
        final initialType = await FileSystemEntity.type(receipt.path, followLinks: false);
        if (!_current() || (initialType != FileSystemEntityType.notFound && initialType != FileSystemEntityType.file)) return false;
        final initialProof = initialType == FileSystemEntityType.file ? await receipt.readAsString() : null;
        if (!_current()) return false;
        final random = Random.secure();
        final nonce = base64UrlEncode(List<int>.generate(18, (_) => random.nextInt(256)));
        final temp = File('${_folder.path}/${_objectId(key)}.$nonce.tmp');
        final proofTemp = File('${receipt.path}.$nonce.tmp');
        try {
          await temp.create(exclusive: true);
          if (!_current()) return false;
          await source.copy(temp.path);
          await debugAfterCopy?.call();
          if (!_current()) return false;
          final copied = await _checksum(temp);
          if (!_current()) return false;
          final after = await _checksum(source);
          if (!_current() || before != copied || before != after) return false;
          if (!await verifyLegacyProvenance(source, project, uid, sessionId, key) || !_current()) return false;
          await debugBeforePublish?.call();
          return await db.transaction((txn) async {
          // Another engine can have published a newer version while this
          // job was copying. Recheck before changing the durable pointer.
          if (!_current() || await _checksum(source) != copied || !_current()) return false;
          await debugDuringPublish?.call();
          if (!_current()) return false;
          final latestType = await FileSystemEntity.type(receipt.path, followLinks: false);
          if (latestType != FileSystemEntityType.notFound && latestType != FileSystemEntityType.file) return false;
          final latestProof = latestType == FileSystemEntityType.file ? await receipt.readAsString() : null;
          if (!_current() || latestProof != initialProof) return false;
          final destination = _data(key, copied);
          final type = await FileSystemEntity.type(destination.path, followLinks: false);
          if (!_current() || (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file)) return false;
          if (type == FileSystemEntityType.file) {
            if (!_current() || await _checksum(destination) != copied) return false;
          } else {
            if (!_current()) return false;
            await temp.rename(destination.path);
          }
          if (!_current()) return false;
          final receiptType = await FileSystemEntity.type(receipt.path, followLinks: false);
          if (!_current() || (receiptType != FileSystemEntityType.notFound && receiptType != FileSystemEntityType.file)) return false;
          if (receiptType == FileSystemEntityType.file &&
              await receipt.readAsString() == _proof(key, copied)) {
            if (!_current()) return false;
            await PinnedAccessFence(db).markPinned(txn, project, uid, key, copied);
            return _current();
          }
          await proofTemp.create(exclusive: true);
          if (!_current()) return false;
          await proofTemp.writeAsString(_proof(key, copied), flush: true);
          if (!_current()) return false;
          await proofTemp.rename(receipt.path);
          if (!_current()) return false;
          await PinnedAccessFence(db).markPinned(txn, project, uid, key, copied);
          return _current();
          });
        } finally {
          if (await temp.exists()) await temp.delete();
          if (await proofTemp.exists()) await proofTemp.delete();
        }
    } on FileSystemException { return false; }
  }

  Future<Uint8List?> readPinned(String key) async {
    if (key.isEmpty || !_current()) return null;
    try {
      final receipt = _receipt(key);
      if (!await _safeFolder() || !_current()) return null;
      if (await FileSystemEntity.type(receipt.path, followLinks: false) != FileSystemEntityType.file || !_current()) return null;
      final proofText = await receipt.readAsString();
      if (!_current()) return null;
      final decoded = jsonDecode(proofText);
      if (decoded is! Map || decoded['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(decoded['sha256'] as String)) return null;
      final data = _data(key, decoded['sha256'] as String);
      if (await FileSystemEntity.type(data.path, followLinks: false) != FileSystemEntityType.file || !_current()) return null;
      final bytes = await data.readAsBytes();
      final checksum = sha256.convert(bytes).toString();
      return _current() && bytes.isNotEmpty && proofText == _proof(key, checksum)
          ? bytes : null;
    } on FileSystemException { return null; } on FormatException { return null; }
  }

  /// The returned versioned file is immutable and currently never evicted.
  /// Callers must also recheck their durable access fence before using it.
  Future<String?> verifiedPathForBytes(String key, Uint8List expected) async {
    final actual = await readPinned(key);
    if (actual == null || !_current() || sha256.convert(actual) != sha256.convert(expected)) return null;
    final file = _data(key, sha256.convert(actual).toString());
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file || !_current()) return null;
    return file.path;
  }
}
