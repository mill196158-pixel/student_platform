import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'chat_file_offline_policy.dart';

/// Resolves only the application's private object namespace. Signed URLs are
/// ephemeral and never become message metadata or persistent cache keys.
class ChatFileAccess {
  static const storageHost = 'studentsplatform.storage.yandexcloud.net';
  static int generation = 0;
  static String? get userId {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static String? keyFor(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host != storageHost ||
        !(uri.path.startsWith('/chats/') || uri.path.startsWith('/diaries/')))
      return null;
    return Uri.decodeComponent(uri.path.substring(1));
  }

  static final _forwardTemps = <String, Directory>{};
  static Future<File> forwardTemp(String url) async {
    final uid = userId, epoch = generation;
    if (uid == null) throw StateError('Authentication required');
    final bytes = await readBytes(url);
    final root = await getApplicationCacheDirectory();
    final parent = Directory('${root.path}/authorized_chat_files/$uid');
    await parent.create(recursive: true);
    final dir = await parent.createTemp('forward_');
    final name = Uri.parse(url)
        .pathSegments
        .last
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final file = File('${dir.path}/${name.isEmpty ? 'file' : name}');
    try {
      if (uid != userId || epoch != generation)
        throw StateError('Сессия изменилась.');
      await file.writeAsBytes(bytes, flush: true);
      if (uid != userId || epoch != generation)
        throw StateError('Сессия изменилась.');
      _forwardTemps[file.path] = dir;
      return file;
    } catch (_) {
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    }
  }

  static Future<void> releaseForwardTemp(String path) async {
    final dir = _forwardTemps.remove(path);
    if (dir != null && await dir.exists()) await dir.delete(recursive: true);
  }

  static final _noOffline = <String>{};
  static Future<void> clear() async {
    final uid = userId;
    generation++;
    _noOffline.clear();
    for (final path in _forwardTemps.keys.toList()) {
      await releaseForwardTemp(path);
    }
    if (uid == null) return;
    final root = await getApplicationCacheDirectory();
    final directory = Directory('${root.path}/authorized_chat_files/$uid');
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static Future<void> _purge(String url, String? uid) async {
    try {
      final file = await _cachedFile(url, uid);
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {
      // Cache cleanup must never replace the original access denial.
    }
  }

  static Future<void> discardUnreadableImage(
    String url, {
    required String? user,
    required int epoch,
  }) async {
    if (user != userId || epoch != generation) return;
    await _purge(url, user);
  }

  static Future<File?> _cachedFile(String url, String? uid) async {
    if (keyFor(url) == null || uid == null) return null;
    final root = await getApplicationCacheDirectory();
    final digest =
        crypto.sha256.convert(utf8.encode('$uid:${keyFor(url) ?? url}'));
    return File('${root.path}/authorized_chat_files/$uid/$digest');
  }

  static Future<bool> _offlineCopy(
      Object error, String url, File? file, String? uid, int epoch) async {
    if (!_offline(error) || file == null) return false;
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return false;
      final session = Supabase.instance.client.auth.currentSession;
      final expires = session?.expiresAt;
      final key = keyFor(url);
      return canUseOfflineChatFile(
        error: error,
        owner: uid,
        currentOwner: userId,
        sessionOwner: session?.user.id,
        epoch: epoch,
        currentEpoch: generation,
        isPrivateKey: key != null,
        cacheable: !_noOffline.contains('$uid:$key'),
        length: stat.size,
        modified: stat.modified,
        sessionExpiresAt: expires == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(expires * 1000),
        now: DateTime.now(),
      );
    } catch (_) {
      return false;
    }
  }

  static bool _offline(Object error) =>
      error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException;

  static String? _currentAccessToken() {
    try {
      return Supabase.instance.client.auth.currentSession?.accessToken;
    } catch (_) {
      return null;
    }
  }

  static bool _offlineOwnerCurrent(
      String url, String? uid, int epoch, String? token) {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final expiry = session?.expiresAt;
      final key = keyFor(url);
      return uid != null && uid.isNotEmpty && key != null && token != null &&
          uid == userId && session?.user.id == uid && generation == epoch &&
          session?.accessToken == token &&
          expiry != null && expiry * 1000 > DateTime.now().millisecondsSinceEpoch &&
          !_noOffline.contains('$uid:$key');
    } catch (_) {
      return false;
    }
  }
  static Future<void> authorize(String url) async {
    final uid = userId, epoch = generation;
    final token = _currentAccessToken();
    try {
      await resolve(url);
    } catch (error) {
      final cached = await _cachedFile(url, uid);
      if (!await _offlineCopy(error, url, cached, uid, epoch) ||
          !_offlineOwnerCurrent(url, uid, epoch, token)) rethrow;
    }
  }

  static Future<String> resolve(String url) async {
    final key = keyFor(url);
    if (key == null) return url;
    final uid = userId, epoch = generation;
    if (uid == null) throw StateError('Войдите, чтобы открыть вложение.');
    final token = _currentAccessToken();
    late final FunctionResponse response;
    try {
      final request = Supabase.instance.client.functions
          .invoke('chat-file-access', body: {'action': 'resolve', 'key': key});
      // Observe denials even if the waiting caller has already timed out.
      // The observer never downloads or returns data and only acts on the
      // exact session that initiated this request.
      bool current() {
        try {
          return uid == userId && epoch == generation && token != null &&
              Supabase.instance.client.auth.currentSession?.accessToken == token;
        } catch (_) {
          return false;
        }
      }
      Future<void> revoke() async {
        if (!current()) return;
        _noOffline.add('$uid:$key');
        try {
          final file = await _cachedFile(url, uid);
          if (current() && file != null && await file.exists() && current()) {
            await file.delete();
          }
        } catch (_) {}
      }
      unawaited(request.then<void>((result) async {
        if (result.data is Map && result.data['cacheable'] == false) {
          await revoke();
        }
      }, onError: (Object error, StackTrace _) async {
        if (error is FunctionException &&
            (error.status == 401 || error.status == 403 || error.status == 404)) {
          await revoke();
        }
      }));
      response = await request.timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('Проверка доступа заняла слишком много времени.'),
          );
    } on FunctionException catch (error) {
      if ((error.status == 401 || error.status == 403 || error.status == 404) &&
          uid == userId && epoch == generation && token != null &&
          token == _currentAccessToken()) {
        _noOffline.add('$uid:$key');
        await _purge(url, uid);
      }
      rethrow;
    }
    if (userId != uid || generation != epoch || token == null ||
        token != _currentAccessToken())
      throw StateError('Сессия изменилась.');
    if (response.data is Map && response.data['cacheable'] == false) {
      _noOffline.add('$uid:${keyFor(url) ?? url}');
      await _purge(url, uid);
    }
    final resolved = response.data is Map ? response.data['url'] : null;
    final uri = resolved is String ? Uri.tryParse(resolved) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != storageHost ||
        keyFor(uri.toString()) != key) throw StateError('Файл недоступен.');
    return uri.toString();
  }

  static Future<Uint8List> readBytes(String url) async {
    final uid = userId, epoch = generation;
    final token = _currentAccessToken();
    final cached = await _cachedFile(url, uid);
    final client = http.Client();
    try {
      final resolved = await resolve(url);
      if (cached != null && await cached.exists()) {
        final bytes = await cached.readAsBytes();
        if (uid != userId || epoch != generation)
          throw StateError('Сессия изменилась.');
        return bytes;
      }
      final response = await client
          .send(http.Request('GET', Uri.parse(resolved)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200)
        throw HttpException('Файл недоступен (${response.statusCode}).');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > 100 * 1024 * 1024)
          throw StateError('Файл слишком большой.');
        bytes.add(chunk);
      }
      if (keyFor(url) != null && (uid != userId || epoch != generation))
        throw StateError('Сессия изменилась.');
      final result = bytes.takeBytes();
      if (cached != null &&
          !_noOffline.contains('$uid:${keyFor(url) ?? url}')) {
        await cached.parent.create(recursive: true);
        if (uid != userId || epoch != generation)
          throw StateError('Сессия изменилась.');
        await cached.writeAsBytes(result, flush: true);
        if (uid != userId || epoch != generation) {
          if (await cached.exists()) await cached.delete();
          throw StateError('Сессия изменилась.');
        }
      }
      if (keyFor(url) != null && (uid != userId || epoch != generation))
        throw StateError('Сессия изменилась.');
      return result;
    } catch (error) {
      if (!await _offlineCopy(error, url, cached, uid, epoch)) rethrow;
      final bytes = await cached!.readAsBytes();
      if (!await _offlineCopy(error, url, cached, uid, epoch) ||
          !_offlineOwnerCurrent(url, uid, epoch, token))
        throw StateError('Сессия изменилась.');
      return bytes;
    } finally {
      client.close();
    }
  }
}
