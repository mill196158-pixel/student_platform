import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'inflight_only.dart';
import '../core/offline_auth_error_receipt.dart';

/// Resolves only the application's private object namespace. Signed URLs are
/// ephemeral and never become message metadata or persistent cache keys.
class ChatFileAccess {
  static const storageHost = 'studentsplatform.storage.yandexcloud.net';
  static int generation = 0;
  static bool _logoutFenced = false;
  static bool _logoutFenceInProgress = false;
  static Object? _logoutFenceOwner;
  static final _resolving = InflightOnly<
      (String, String, int, String, SupabaseClient, int), String>();
  static final _leaseClock = Stopwatch()..start();
  static final _leases = LinkedHashMap<
      (String, String, int, String, SupabaseClient), (String, int)>();
  static final _revisions =
      <(String, String, int, String, SupabaseClient), int>{};
  static SupabaseClient? _observedClient;
  static StreamSubscription<AuthState>? _authSubscription;
  static (String?, String?)? _observedIdentity;
  static bool _acceptedAuthReceipt = false;
  static bool _receiptListenerAttached = false;

  static void _fenceAuthError() {
    _acceptedAuthReceipt = false;
    _logoutFenced = true;
    generation++;
    _resolving.clear();
    _leases.clear();
    _revisions.clear();
    _pendingTickets.clear();
    accessChanges.value++;
  }

  static void _receiptChanged() {
    if (_acceptedAuthReceipt) _fenceAuthError();
  }

  static void _observeAuth(SupabaseClient client) {
    if (identical(_observedClient, client)) return;
    final old = _authSubscription;
    if (old != null) unawaited(old.cancel());
    _observedClient = client;
    final session = client.auth.currentSession;
    _observedIdentity = (session?.user.id, _sessionId(session));
    _authSubscription = client.auth.onAuthStateChange.listen((event) {
      if (!identical(_observedClient, client)) return;
      final identity = (event.session?.user.id, _sessionId(event.session));
      final newSignIn = !_logoutFenceInProgress &&
          _logoutFenced &&
          event.event == AuthChangeEvent.signedIn &&
          identity.$1 != null;
      if (identity != _observedIdentity || newSignIn) {
        _observedIdentity = identity;
        if (!_logoutFenceInProgress &&
            event.event == AuthChangeEvent.signedIn &&
            identity.$1 != null) {
          _logoutFenced = false;
        }
        generation++;
        _resolving.clear();
        _leases.clear();
        _revisions.clear();
        _noOffline.clear();
        _pendingTickets.clear();
        _unsupportedProtocol.clear();
        accessChanges.value++;
      }
    }, onError: (Object error, StackTrace stack) {
      if (!identical(_observedClient, client)) return;
      // The SDK wraps security and transport failures alike. A stream error
      // alone cannot establish an offline permit, even if it is retryable.
      // Preserve the original stream-listener semantics outside the explicit
      // QA admission path: without an onError, Dart reports to this zone.
      if (!OfflineAuthErrorReceipt.instance.strict) {
        Zone.current.handleUncaughtError(error, stack);
        return;
      }
      if (OfflineAuthErrorReceipt.instance.accepts(error)) {
        if (!_receiptListenerAttached) {
          OfflineAuthErrorReceipt.instance.addListener(_receiptChanged);
          _receiptListenerAttached = true;
        }
        _acceptedAuthReceipt = true;
      } else {
        _fenceAuthError();
      }
    });
  }

  static String? get currentSessionBinding {
    try {
      final client = Supabase.instance.client;
      _observeAuth(client);
      return _sessionId(client.auth.currentSession);
    } catch (_) {
      return null;
    }
  }

  /// Notifies mounted attachment viewers when a previously shown file is
  /// explicitly denied, so they can remove decoded pixels immediately.
  static final ValueNotifier<int> accessChanges = ValueNotifier<int>(0);
  static bool isAccessRevoked(String url) {
    final uid = userId, key = keyFor(url);
    return key != null &&
        (_logoutFenced || uid == null || _noOffline.contains('$uid:$key'));
  }

  /// Invalidates active and new private-file operations without deleting data.
  /// The fence remains if durable logout cannot finish.
  static Object fenceForLogout() {
    // Bind the auth listener before the first await of the logout barrier.
    currentSessionBinding;
    _logoutFenced = true;
    _logoutFenceInProgress = true;
    final owner = Object();
    _logoutFenceOwner = owner;
    generation++;
    _resolving.clear();
    _leases.clear();
    _revisions.clear();
    _pendingTickets.clear();
    accessChanges.value++;
    return owner;
  }

  /// Called only after sign-out is confirmed and no old session remains.
  static void completeLogoutFence(Object owner) {
    if (identical(_logoutFenceOwner, owner) && userId == null) {
      _logoutFenceInProgress = false;
      _logoutFenceOwner = null;
    }
  }

  /// The caller must capture both values when opening a viewer. A later logout
  /// or account switch must not keep showing that viewer's earlier pixels.
  static bool isViewerCurrent(String url,
      {required String? user,
      required int epoch,
      required String? sessionBinding}) {
    if (keyFor(url) == null) return true;
    return user != null &&
        user == userId &&
        epoch == generation &&
        sessionBinding != null &&
        sessionBinding == currentSessionBinding &&
        !isAccessRevoked(url);
  }

  static final Map<String, Future<void>> _ownerFileQueues = {};
  static int _temporaryFileSequence = 0;

  /// Serializes filesystem writes, revoke and logout for one local owner.
  /// A newer session for the same account is queued behind the old logout.
  static Future<T> _withOwnerFiles<T>(String uid, Future<T> Function() run) {
    final before = _ownerFileQueues[uid] ?? Future<void>.value();
    final result = before.then<T>((_) => run());
    final barrier =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _ownerFileQueues[uid] = barrier;
    unawaited(barrier.then((_) {
      if (identical(_ownerFileQueues[uid], barrier))
        _ownerFileQueues.remove(uid);
    }));
    return result;
  }

  /// JWT claims are used only to bind a local receipt to the current session;
  /// this does not verify the token or grant server access.
  static String? _sessionId(Session? session) {
    if (session == null) return null;
    try {
      final parts = session.accessToken.split('.');
      if (parts.length != 3) return null;
      final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (claims is! Map || claims['sub'] != session.user.id) return null;
      final sid = claims['session_id'];
      if (sid is! String || !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(sid))
        return null;
      return sid.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static File _receiptFile(File file) => File('${file.path}.grant');
  static File _deniedFile(File file) => File('${file.path}.denied');
  static File _pendingFile(File file) => File('${file.path}.pending');
  static final _pendingTickets = <String, String>{};
  static final _unsupportedProtocol = <String>{};
  static final _liveChecks = <String, int>{};
  @visibleForTesting
  static bool debugFailDenialPersistence = false;
  @visibleForTesting
  static http.Client Function()? debugHttpClientFactory;
  @visibleForTesting
  static Future<void> Function()? debugBeforeForwardReturn;

  static Future<bool> _hasDenyMarker(File file) async {
    try {
      return await FileSystemEntity.type(_deniedFile(file).path,
              followLinks: false) !=
          FileSystemEntityType.notFound;
    } catch (_) {
      // Inaccessible marker state is not evidence that access is permitted.
      return true;
    }
  }

  static Future<bool> _hasReceipt(File file, String sid) async {
    try {
      final receipt = _receiptFile(file);
      final pending = _pendingFile(file);
      final hasPending =
          await FileSystemEntity.type(pending.path, followLinks: false) !=
              FileSystemEntityType.notFound;
      final proof = hasPending
          ? (_pendingTickets[pending.path] == sid ? pending : null)
          : receipt;
      return !await _hasDenyMarker(file) &&
          proof != null &&
          await proof.readAsString() == 'chat-file-grant-v2:$sid' &&
          await file.length() > 0;
    } catch (_) {
      // Missing, corrupted or unreadable receipts never authorize local reads.
      return false;
    }
  }

  static Future<void> _beginRevalidation(
          String url, String uid, String? sid, bool Function() current) =>
      _withOwnerFiles(uid, () async {
        if (!current()) throw StateError('Session changed.');
        final file = await _cachedFile(url, uid);
        if (file == null || !current()) throw StateError('Session changed.');
        final grant = _receiptFile(file);
        final pending = _pendingFile(file);
        await file.parent.create(recursive: true);
        if (!current()) throw StateError('Session changed.');
        if (!await grant.exists()) {
          if (await FileSystemEntity.type(pending.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            final tmp = File('${pending.path}.tmp.${_temporaryFileSequence++}');
            try {
              await tmp.writeAsString('chat-file-pending-v1', flush: true);
              if (!current()) throw StateError('Session changed.');
              await tmp.rename(pending.path);
            } finally {
              if (await tmp.exists()) await tmp.delete();
            }
          }
          if (!current()) throw StateError('Session changed.');
          return;
        }
        final mayRead = sid != null && await _hasReceipt(file, sid);
        if (await FileSystemEntity.type(pending.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          await grant.rename('${grant.path}.stale.${_temporaryFileSequence++}');
        } else {
          await grant.rename(pending.path);
          if (mayRead && current()) _pendingTickets[pending.path] = sid;
        }
        if (!current()) throw StateError('Session changed.');
      });

  // A completed transport failure carries no denial. Restore only the
  // exact pre-existing grant, and only when no earlier request is still live.
  static Future<void> _restoreAfterTransportFailure(
      String url, String uid, String? sid, bool Function() current) async {
    if (sid == null || !current()) return;
    await _withOwnerFiles(uid, () async {
      if (!current() ||
          isAccessRevoked(url) ||
          _unsupportedProtocol.contains('$uid:${keyFor(url)}') ||
          (_liveChecks['$uid:${keyFor(url)}'] ?? 0) != 0) return;
      final file = await _cachedFile(url, uid);
      if (file == null || !current()) return;
      final pending = _pendingFile(file);
      try {
        if (_pendingTickets[pending.path] != sid ||
            await _hasDenyMarker(file) ||
            await pending.readAsString() != 'chat-file-grant-v2:$sid' ||
            !current() ||
            isAccessRevoked(url) ||
            (_liveChecks['$uid:${keyFor(url)}'] ?? 0) != 0) return;
        await pending.rename(_receiptFile(file).path);
        _pendingTickets.remove(pending.path);
      } on FileSystemException {
        // A failure to persist the transition leaves pending fail-closed.
      }
    });
  }

  static Future<void> _writeReceipt(File file, String sid) async {
    final receipt = _receiptFile(file);
    final tmp = File('${receipt.path}.tmp.${_temporaryFileSequence++}');
    try {
      await tmp.writeAsString('chat-file-grant-v2:$sid', flush: true);
      await tmp.rename(receipt.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  static void _invalidateLease(
      (String, String, int, String, SupabaseClient) id) {
    _leases.remove(id);
    _revisions[id] = (_revisions[id] ?? 0) + 1;
  }

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

  static final _forwardTemps = <String, (Directory, String, String?, int)>{};
  static Future<File> forwardTemp(String url) async {
    final uid = userId, epoch = generation, sid = currentSessionBinding;
    if (uid == null) throw StateError('Authentication required');
    bool current() =>
        isViewerCurrent(url, user: uid, epoch: epoch, sessionBinding: sid);
    final bytes = await readBytes(url);
    if (!current()) throw StateError('Session changed.');
    // Never nest this queue around readBytes: it also uses _withOwnerFiles.
    // Creation and publication must be serialized behind a pending logout for
    // the same owner, so an old cleanup cannot erase a new session's temp.
    return _withOwnerFiles(uid, () async {
      if (!current()) throw StateError('Session changed.');
      final root = await getApplicationCacheDirectory();
      if (!current()) throw StateError('Session changed.');
      final parent = Directory('${root.path}/authorized_chat_files/$uid');
      await parent.create(recursive: true);
      if (!current()) throw StateError('Session changed.');
      final dir = await parent.createTemp('forward_');
      final name = Uri.parse(url)
          .pathSegments
          .last
          .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final file = File('${dir.path}/${name.isEmpty ? 'file' : name}');
      try {
        if (!current()) throw StateError('Session changed.');
        await file.writeAsBytes(bytes, flush: true);
        await debugBeforeForwardReturn?.call();
        if (!current()) throw StateError('Session changed.');
        _forwardTemps[file.path] = (dir, uid, sid, epoch);
        return file;
      } catch (_) {
        if (await dir.exists()) await dir.delete(recursive: true);
        rethrow;
      }
    });
  }

  static Future<void> releaseForwardTemp(String path) async {
    final entry = _forwardTemps[path];
    if (entry == null) return;
    await _withOwnerFiles(entry.$2, () async {
      if (_forwardTemps[path] != entry) return;
      _forwardTemps.remove(path);
      if (await entry.$1.exists()) await entry.$1.delete(recursive: true);
    });
  }

  static final _noOffline = <String>{};
  static Future<void> clear() async {
    final uid = userId;
    generation++;
    _resolving.clear();
    _leases.clear();
    _revisions.clear();
    _noOffline.clear();
    _pendingTickets.clear();
    _unsupportedProtocol.clear();
    accessChanges.value++;
    // Enqueue before the first await so a fresh session for the same user
    // cannot be erased by delayed cleanup from the previous session.
    final cleanup = uid == null
        ? Future<void>.value()
        : _withOwnerFiles(uid, () async {
            final root = await getApplicationCacheDirectory();
            final directory =
                Directory('${root.path}/authorized_chat_files/$uid');
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
            _forwardTemps.removeWhere((_, entry) => entry.$2 == uid);
          });
    await cleanup;
  }

  /// Simulates a new process without clearing persisted files or receipts.
  @visibleForTesting
  static void debugResetProcessMemory() {
    _logoutFenced = false;
    _logoutFenceInProgress = false;
    _logoutFenceOwner = null;
    generation++;
    _resolving.clear();
    _leases.clear();
    _revisions.clear();
    _noOffline.clear();
    _pendingTickets.clear();
    _unsupportedProtocol.clear();
    accessChanges.value++;
  }

  static Future<void> discardUnreadableImage(
    String url, {
    required String? user,
    required int epoch,
    required String? sessionBinding,
    required Uint8List expectedBytes,
  }) async {
    if (user == null ||
        !isViewerCurrent(url,
            user: user, epoch: epoch, sessionBinding: sessionBinding)) return;
    final expected = crypto.sha256.convert(expectedBytes);
    await _withOwnerFiles(user, () async {
      try {
        if (!isViewerCurrent(url,
            user: user, epoch: epoch, sessionBinding: sessionBinding)) return;
        final file = await _cachedFile(url, user);
        if (file == null || !await file.exists()) return;
        final current = await file.readAsBytes();
        if (crypto.sha256.convert(current) != expected ||
            !isViewerCurrent(url,
                user: user,
                epoch: epoch,
                sessionBinding: sessionBinding)) return;
        // Do not delete data from a stale decoder: preserve the exact corrupt
        // copy and only quarantine it if its bytes still match this decoder.
        await file
            .rename('${file.path}.unreadable.${_temporaryFileSequence++}');
        final receipt = _receiptFile(file);
        if (await receipt.exists()) await receipt.delete();
      } on FileSystemException {
        // Preserve the original decoder error.
      }
    });
  }

  static Future<File?> _cachedFile(String url, String? uid) async {
    if (keyFor(url) == null || uid == null) return null;
    final root = await getApplicationCacheDirectory();
    final digest =
        crypto.sha256.convert(utf8.encode('$uid:${keyFor(url) ?? url}'));
    return File('${root.path}/authorized_chat_files/$uid/$digest');
  }

  /// Reads an already authorized copy without initiating any network request.
  /// [permit] must remain true for the entire read; callers must also hide
  /// decoded content when that permit or the attachment access is revoked.
  static Future<Uint8List?> readCachedOnly(String url,
      {required bool Function() permit}) async {
    final uid = userId;
    final sid = currentSessionBinding;
    final epoch = generation;
    bool current() => uid != null && !_unsupportedProtocol.contains('$uid:${keyFor(url)}') &&
        permit() && isViewerCurrent(url,
        user: uid, epoch: epoch, sessionBinding: sid);
    if (uid == null || sid == null || keyFor(url) == null || !current()) {
      return null;
    }
    return _withOwnerFiles(uid, () async {
      try {
        if (!current()) return null;
        final file = await _cachedFile(url, uid);
        if (file == null || !current() || !await _hasReceipt(file, sid) || !current()) {
          return null;
        }
        final bytes = await file.readAsBytes();
        return current() && await _hasReceipt(file, sid) && current() ? bytes : null;
      } on FileSystemException {
        return null;
      }
    });
  }

  /// Returns only a previously granted cache path; never contacts the server.
  /// The caller must recheck its access ticket immediately before handing the
  /// path to an external viewer, which may retain the bytes after export.
  static Future<String?> cachedPathForOpen(String url,
      {required bool Function() permit}) async {
    final uid = userId;
    final sid = currentSessionBinding;
    final epoch = generation;
    bool current() => uid != null && !_unsupportedProtocol.contains('$uid:${keyFor(url)}') &&
        permit() && isViewerCurrent(url, user: uid, epoch: epoch, sessionBinding: sid);
    if (uid == null || sid == null || keyFor(url) == null || !current()) return null;
    return _withOwnerFiles(uid, () async {
      try {
        if (!current()) return null;
        final file = await _cachedFile(url, uid);
        if (file == null || !current() || !await _hasReceipt(file, sid) || !current()) return null;
        return file.path;
      } on FileSystemException {
        return null;
      }
    });
  }

  static Future<bool> _receiptAvailable(
      String url, String? uid, String? sid, bool Function() current) async {
    if (uid == null ||
        sid == null ||
        keyFor(url) == null ||
        _unsupportedProtocol.contains('$uid:${keyFor(url)}') ||
        !current()) return false;
    return _withOwnerFiles(uid, () async {
      if (!current() || isAccessRevoked(url)) return false;
      final file = await _cachedFile(url, uid);
      if (file == null || !current() || isAccessRevoked(url)) return false;
      final allowed = await _hasReceipt(file, sid);
      return allowed && current() && !isAccessRevoked(url);
    });
  }

  static Future<void> _recordAuthorizedCopy(
      String url, String uid, String? sid, bool Function() current) async {
    if (!current()) return;
    await _withOwnerFiles(uid, () async {
      if (!current()) return;
      final file = await _cachedFile(url, uid);
      if (file == null || !current()) return;
      try {
        if (await file.exists() &&
            await file.length() > 0 &&
            current() &&
            sid != null &&
            (_liveChecks['$uid:${keyFor(url)}'] ?? 0) == 0) {
          await _writeReceipt(file, sid);
          if (!current()) return;
          final pending = _pendingFile(file);
          // A timed-out older request may still return a denial. Keep the
          // write-ahead fence until every earlier request has completed.
          if ((_liveChecks['$uid:${keyFor(url)}'] ?? 0) == 0) {
            if (await pending.exists()) await pending.delete();
            _pendingTickets.remove(pending.path);
          }
        }
        final denied = _deniedFile(file);
        if (current() && await denied.exists() && current())
          await denied.delete();
      } catch (_) {
        // Disk persistence is best effort; the successful network response
        // may still be used, but it will not authorize a later local read.
      }
    });
  }

  static Future<void> _denyLocalCopy(String url, String uid, String key,
      (String, String, int, String, SupabaseClient) id) {
    _invalidateLease(id);
    _noOffline.add('$uid:$key');
    accessChanges.value++;
    return _withOwnerFiles(uid, () async {
      final file = await _cachedFile(url, uid);
      if (file == null) return;
      try {
        await file.parent.create(recursive: true);
        if (debugFailDenialPersistence)
          throw const FileSystemException('injected marker failure');
        final denied = _deniedFile(file);
        final tmp = File('${denied.path}.tmp.${_temporaryFileSequence++}');
        try {
          await tmp.writeAsString('revoked', flush: true);
          await tmp.rename(denied.path);
        } finally {
          if (await tmp.exists()) await tmp.delete();
        }
      } on FileSystemException {
        // Retain bytes and attempt to quarantine the whole owner directory if
        // an individual deny marker cannot be persisted.
        final dir = file.parent;
        try {
          if (debugFailDenialPersistence)
            throw const FileSystemException('injected quarantine failure');
          if (await dir.exists()) {
            await dir.rename(
                '${dir.path}.quarantined.${DateTime.now().microsecondsSinceEpoch}');
          }
        } catch (_) {}
      }
    });
  }

  static Future<bool> _offlineCopy(
      Object error, String url, File? file, String? uid, int epoch) async {
    if (!_offline(error) ||
        file == null ||
        uid == null ||
        _unsupportedProtocol.contains('$uid:${keyFor(url)}')) return false;
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final sid = _sessionId(session);
      if (sid == null || session?.user.id != uid) return false;
      return await _withOwnerFiles(
          uid,
          () async =>
              isViewerCurrent(url,
                  user: uid, epoch: epoch, sessionBinding: sid) &&
              await _hasReceipt(file, sid) &&
              isViewerCurrent(url,
                  user: uid, epoch: epoch, sessionBinding: sid));
    } catch (_) {
      return false;
    }
  }

  static bool _explicitDenial(Object error) =>
      error is FunctionException &&
      (error.status == 401 ||
          (error.status == 403 &&
              error.details is Map &&
              (error.details as Map)['error'] == 'file_unavailable' &&
              (error.details as Map)['reason'] == 'access_denied_v1'));

  static bool _offline(Object error) =>
      error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException ||
      (error is FunctionException &&
          error.status == 503 &&
          error.details is Map &&
          (error.details as Map)['error'] == 'service_unavailable' &&
          (error.details as Map)['accessPolicyVersion'] == 1);

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
      final key = keyFor(url);
      return !_logoutFenced &&
          uid != null &&
          uid.isNotEmpty &&
          key != null &&
          token != null &&
          uid == userId &&
          session?.user.id == uid &&
          generation == epoch &&
          session?.accessToken == token &&
          _sessionId(session) != null &&
          !_noOffline.contains('$uid:$key');
    } catch (_) {
      return false;
    }
  }

  static void _revalidateInBackground(String url) {
    unawaited(
        resolve(url).then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  static Future<void> authorize(String url) async {
    if (keyFor(url) != null && _logoutFenced) {
      throw StateError('Выход из аккаунта не завершён.');
    }
    final uid = userId, epoch = generation;
    final token = _currentAccessToken();
    final key = keyFor(url);
    final authClient = key == null ? null : Supabase.instance.client;
    if (authClient != null) _observeAuth(authClient);
    final id = uid != null && token != null && key != null && authClient != null
        ? (uid, token, epoch, key, authClient)
        : null;
    final revision = id == null ? 0 : (_revisions[id] ?? 0);
    bool current() =>
        key == null ||
        (id != null &&
            identical(authClient, Supabase.instance.client) &&
            uid == userId &&
            epoch == generation &&
            token == _currentAccessToken() &&
            (_revisions[id] ?? 0) == revision);
    try {
      final sid = _sessionId(authClient?.auth.currentSession);
      if (await _receiptAvailable(url, uid, sid, current)) {
        if (!current()) throw StateError('Сессия изменилась.');
        _revalidateInBackground(url);
        return;
      }
      await resolve(url);
      if (!current()) throw StateError('Сессия изменилась.');
    } catch (error) {
      if (!current()) rethrow;
      final cached = await _cachedFile(url, uid);
      if (!current() ||
          !await _offlineCopy(error, url, cached, uid, epoch) ||
          !current() ||
          !_offlineOwnerCurrent(url, uid, epoch, token)) rethrow;
    }
  }

  static Future<String> resolve(String url) async {
    final key = keyFor(url);
    if (key == null) return url;
    if (_logoutFenced) throw StateError('Выход из аккаунта не завершён.');
    final uid = userId, epoch = generation;
    if (uid == null) throw StateError('Войдите, чтобы открыть вложение.');
    final token = _currentAccessToken();
    if (token == null) throw StateError('Войдите, чтобы открыть вложение.');
    final client = Supabase.instance.client;
    _observeAuth(client);
    final id = (uid, token, epoch, key, client);
    final revision = _revisions[id] ?? 0;
    final sessionExpiry = client.auth.currentSession?.expiresAt;
    final lease = _leases[id];
    if (lease != null &&
        sessionExpiry != null &&
        sessionExpiry * 1000 > DateTime.now().millisecondsSinceEpoch &&
        _leaseClock.elapsedMilliseconds < lease.$2) return lease.$1;
    _leases.remove(id);
    final started = _leaseClock.elapsedMilliseconds;
    final resolved = await _resolving.run(
        (uid, token, epoch, key, client, revision),
        () => _resolveOnce(
            url, key, uid, epoch, token, client, id, revision, started));
    if (!identical(client, Supabase.instance.client) ||
        uid != userId ||
        epoch != generation ||
        token != _currentAccessToken() ||
        (_revisions[id] ?? 0) != revision) {
      throw StateError('Сессия изменилась.');
    }
    return resolved;
  }

  static Future<String> _resolveOnce(
      String url,
      String key,
      String uid,
      int epoch,
      String token,
      SupabaseClient client,
      (String, String, int, String, SupabaseClient) id,
      int revision,
      int started) async {
    late final FunctionResponse response;
    var timedOut = false;
    try {
      await _beginRevalidation(
          url,
          uid,
          _sessionId(client.auth.currentSession),
          () =>
              identical(client, Supabase.instance.client) &&
              uid == userId &&
              epoch == generation &&
              token == _currentAccessToken() &&
              (_revisions[id] ?? 0) == revision);
      final checkKey = '$uid:$key';
      _liveChecks[checkKey] = (_liveChecks[checkKey] ?? 0) + 1;
      final request = client.functions
          .invoke('chat-file-access', body: {'action': 'resolve', 'key': key});
      void finished() {
        final remaining = (_liveChecks[checkKey] ?? 1) - 1;
        if (remaining <= 0) {
          _liveChecks.remove(checkKey);
        } else {
          _liveChecks[checkKey] = remaining;
        }
      }

      unawaited(request.then<void>((_) => finished(),
          onError: (Object _, StackTrace __) => finished()));
      // Observe denials even if the waiting caller has already timed out.
      // The observer never downloads or returns data and only acts on the
      // exact session that initiated this request.
      bool current() {
        try {
          return identical(client, Supabase.instance.client) &&
              uid == userId &&
              epoch == generation &&
              client.auth.currentSession?.accessToken == token;
        } catch (_) {
          return false;
        }
      }

      Future<void> revoke() async {
        if (!current()) return;
        try {
          await _denyLocalCopy(url, uid, key, id);
        } catch (_) {}
      }

      unawaited(request.then<void>((lateResponse) async {
        if (!timedOut || !current() || (_revisions[id] ?? 0) != revision)
          return;
        final data = lateResponse.data;
        final value = data is Map ? data['url'] : null;
        final uri = value is String ? Uri.tryParse(value) : null;
        if (data is! Map ||
            data['accessPolicyVersion'] != 1 ||
            uri == null ||
            uri.scheme != 'https' ||
            uri.host != storageHost ||
            keyFor(uri.toString()) != key) return;
        await _restoreAfterTransportFailure(
            url,
            uid,
            _sessionId(client.auth.currentSession),
            () => current() && (_revisions[id] ?? 0) == revision);
      }, onError: (Object error, StackTrace _) async {
        if (timedOut && _explicitDenial(error)) {
          await revoke();
        } else if (timedOut && _offline(error) && current()) {
          await _restoreAfterTransportFailure(
              url, uid, _sessionId(client.auth.currentSession), current);
        } else if (timedOut &&
            error is FunctionException &&
            error.status == 403 &&
            current()) {
          _unsupportedProtocol.add('$uid:$key');
          accessChanges.value++;
        }
      }));
      response = await request.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          timedOut = true;
          throw TimeoutException(
              'Проверка доступа заняла слишком много времени.');
        },
      );
    } on FunctionException catch (error) {
      if (!_explicitDenial(error) &&
          error.status == 403 &&
          identical(client, Supabase.instance.client) &&
          uid == userId &&
          epoch == generation &&
          token == _currentAccessToken()) {
        _unsupportedProtocol.add('$uid:$key');
        accessChanges.value++;
      }
      if (_explicitDenial(error) &&
          identical(client, Supabase.instance.client) &&
          uid == userId &&
          epoch == generation &&
          token == _currentAccessToken()) {
        try {
          await _denyLocalCopy(url, uid, key, id);
        } catch (_) {}
      }
      if (_offline(error)) {
        await _restoreAfterTransportFailure(
            url,
            uid,
            _sessionId(client.auth.currentSession),
            () =>
                identical(client, Supabase.instance.client) &&
                uid == userId &&
                epoch == generation &&
                token == _currentAccessToken() &&
                (_revisions[id] ?? 0) == revision);
      }
      rethrow;
    } catch (error) {
      if (_offline(error)) {
        await _restoreAfterTransportFailure(
            url,
            uid,
            _sessionId(client.auth.currentSession),
            () =>
                identical(client, Supabase.instance.client) &&
                uid == userId &&
                epoch == generation &&
                token == _currentAccessToken() &&
                (_revisions[id] ?? 0) == revision);
      }
      rethrow;
    }
    if (!identical(client, Supabase.instance.client) ||
        userId != uid ||
        generation != epoch ||
        token != _currentAccessToken() ||
        (_revisions[id] ?? 0) != revision)
      throw StateError('Сессия изменилась.');
    final resolved = response.data is Map ? response.data['url'] : null;
    final uri = resolved is String ? Uri.tryParse(resolved) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != storageHost ||
        keyFor(uri.toString()) != key) throw StateError('Файл недоступен.');
    final result = uri.toString();
    if (response.data is! Map || response.data['accessPolicyVersion'] != 1) {
      _unsupportedProtocol.add('$uid:$key');
      final stale = await _cachedFile(url, uid);
      if (stale != null) _pendingTickets.remove(_pendingFile(stale).path);
      accessChanges.value++;
      return result;
    }
    bool stillCurrent() =>
        identical(client, Supabase.instance.client) &&
        uid == userId &&
        epoch == generation &&
        token == _currentAccessToken() &&
        (_revisions[id] ?? 0) == revision;
    // A fresh successful check may restore a previously denied local copy.
    try {
      await _recordAuthorizedCopy(
          url, uid, _sessionId(client.auth.currentSession), stillCurrent);
    } catch (_) {
      // Local receipt persistence failure never invalidates a server grant.
    }
    if (!stillCurrent()) throw StateError('Сессия изменилась.');
    final changed = _noOffline.remove('$uid:$key') |
        _unsupportedProtocol.remove('$uid:$key');
    if (changed) accessChanges.value++;
    final expiresIn = response.data is Map ? response.data['expiresIn'] : null;
    final sessionExpiry = client.auth.currentSession?.expiresAt;
    if (response.data is Map &&
        response.data['cacheable'] == true &&
        expiresIn is int &&
        expiresIn > 0 &&
        sessionExpiry != null &&
        (_revisions[id] ?? 0) == revision) {
      final remainingSession =
          sessionExpiry * 1000 - DateTime.now().millisecondsSinceEpoch;
      final ttl = [20000, expiresIn * 1000, remainingSession]
          .reduce((a, b) => a < b ? a : b);
      final until = started + ttl;
      if (ttl > 0 && until > _leaseClock.elapsedMilliseconds) {
        _leases.remove(id);
        _leases[id] = (result, until);
        while (_leases.length > 64) {
          _leases.remove(_leases.keys.first);
        }
      }
    }
    return result;
  }

  static Future<Uint8List> readBytes(String url) async {
    if (keyFor(url) != null && _logoutFenced) {
      throw StateError('Выход из аккаунта не завершён.');
    }
    final uid = userId, epoch = generation;
    final token = _currentAccessToken();
    final key = keyFor(url);
    final authClient = key == null ? null : Supabase.instance.client;
    if (authClient != null) _observeAuth(authClient);
    final id = uid != null && token != null && key != null && authClient != null
        ? (uid, token, epoch, key, authClient)
        : null;
    final revision = id == null ? 0 : (_revisions[id] ?? 0);
    bool current() =>
        key == null ||
        (id != null &&
            identical(authClient, Supabase.instance.client) &&
            uid == userId &&
            epoch == generation &&
            token == _currentAccessToken() &&
            (_revisions[id] ?? 0) == revision);
    final cached = await _cachedFile(url, uid);
    final client = debugHttpClientFactory?.call() ?? http.Client();
    try {
      if (!current()) throw StateError('Сессия изменилась.');
      final sid = _sessionId(authClient?.auth.currentSession);
      if (uid != null &&
          sid != null &&
          cached != null &&
          await _receiptAvailable(url, uid, sid, current)) {
        final local = await _withOwnerFiles<Uint8List?>(uid, () async {
          if (!current() ||
              isAccessRevoked(url) ||
              _unsupportedProtocol.contains('$uid:$key') ||
              !await _hasReceipt(cached, sid)) return null;
          try {
            final bytes = await cached.readAsBytes();
            return current() &&
                    !isAccessRevoked(url) &&
                    !_unsupportedProtocol.contains('$uid:$key') &&
                    bytes.isNotEmpty
                ? bytes
                : null;
          } on FileSystemException {
            return null;
          }
        });
        if (local != null &&
            current() &&
            !isAccessRevoked(url) &&
            !_unsupportedProtocol.contains('$uid:$key')) {
          _revalidateInBackground(url);
          return local;
        }
      }
      final resolved = await resolve(url);
      if (!current()) throw StateError('Сессия изменилась.');
      if (cached != null &&
          !_unsupportedProtocol.contains('$uid:$key') &&
          await cached.exists()) {
        final bytes = await cached.readAsBytes();
        if (!current()) throw StateError('Сессия изменилась.');
        return bytes;
      }
      final response = await client
          .send(http.Request('GET', Uri.parse(resolved)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        if (id != null && current() && _leases[id]?.$1 == resolved)
          _invalidateLease(id);
        throw HttpException('Файл недоступен (${response.statusCode}).');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > 100 * 1024 * 1024)
          throw StateError('Файл слишком большой.');
        bytes.add(chunk);
      }
      if (!current()) throw StateError('Сессия изменилась.');
      final result = bytes.takeBytes();
      if (cached != null &&
          uid != null &&
          !_unsupportedProtocol.contains('$uid:$key') &&
          !isAccessRevoked(url)) {
        await _withOwnerFiles(uid, () async {
          if (!current() || isAccessRevoked(url))
            throw StateError('Сессия изменилась.');
          await cached.parent.create(recursive: true);
          final tmp = File('${cached.path}.tmp.${_temporaryFileSequence++}');
          try {
            await tmp.writeAsBytes(result, flush: true);
            if (!current() || isAccessRevoked(url))
              throw StateError('Сессия изменилась.');
            await tmp.rename(cached.path);
            if (!current() || isAccessRevoked(url))
              throw StateError('Сессия изменилась.');
            if (sid != null && (_liveChecks['$uid:$key'] ?? 0) == 0) {
              try {
                await _writeReceipt(cached, sid);
                if (!current() || isAccessRevoked(url))
                  throw StateError('Session changed.');
                final pending = _pendingFile(cached);
                if (await pending.exists()) await pending.delete();
                _pendingTickets.remove(pending.path);
              } catch (_) {
                // Do not lose a successful download if disk receipt fails.
              }
            }
          } finally {
            if (await tmp.exists()) await tmp.delete();
          }
        });
      }
      if (!current()) throw StateError('Сессия изменилась.');
      return result;
    } catch (error) {
      if (!current() ||
          !await _offlineCopy(error, url, cached, uid, epoch) ||
          !current()) rethrow;
      final bytes = await cached!.readAsBytes();
      if (!current() ||
          !await _offlineCopy(error, url, cached, uid, epoch) ||
          !current() ||
          !_offlineOwnerCurrent(url, uid, epoch, token))
        throw StateError('Сессия изменилась.');
      return bytes;
    } finally {
      client.close();
    }
  }
}
