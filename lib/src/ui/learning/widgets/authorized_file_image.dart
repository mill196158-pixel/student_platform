import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show SynchronousFuture, visibleForTesting, kDebugMode;
import 'dart:async';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException, Supabase;
import '../../../services/chat_file_access.dart';
import 'reentry_image_gate.dart';

class _QaContentChanged extends StateError {
  _QaContentChanged() : super('Копия файла изменилась.');
}

enum _QaOwnerStatus { current, stale, unknown }

class AuthorizedFileImageProvider
    extends ImageProvider<AuthorizedFileImageProvider> {
  static String? _qaToken() {
    try {
      if (kDebugMode && const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') && debugQaToken != null) {
        return debugQaToken!();
      }
      return Supabase.instance.client.auth.currentSession?.accessToken;
    } catch (_) { return null; }
  }
  @visibleForTesting
  static Future<void> Function(String)? debugAuthorize;
  @visibleForTesting
  static String? Function()? debugQaToken;
  @visibleForTesting
  static Future<void> Function()? debugQaAfterDecode;
  @visibleForTesting
  static Future<ui.Codec> Function()? debugQaCodec;
  AuthorizedFileImageProvider(this.url)
      : user = ChatFileAccess.userId,
        epoch = ChatFileAccess.generation,
        sessionBinding = ChatFileAccess.currentSessionBinding,
        clientIdentity = ChatFileAccess.currentClientIdentity,
        contentEpoch = ChatFileAccess.qaContentEpoch(url, ChatFileAccess.userId),
        accessEpoch = ChatFileAccess.qaAccessEpoch(url, ChatFileAccess.userId),
        _qaCredential = const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') ? _qaToken() : null,
        _cancelledNonce = null;
  AuthorizedFileImageProvider._cancelled(AuthorizedFileImageProvider old)
      : url = old.url,
        user = old.user,
        epoch = old.epoch,
        sessionBinding = old.sessionBinding,
        clientIdentity = old.clientIdentity,
        contentEpoch = old.contentEpoch,
        accessEpoch = old.accessEpoch,
        _qaCredential = old._qaCredential,
        _cancelledNonce = Object();
  final String url;
  final String? user;
  final int epoch;
  final String? sessionBinding;
  final Object? clientIdentity;
  final int contentEpoch, accessEpoch;
  final String? _qaCredential;
  final Object? _cancelledNonce;
  bool get _qaRevisionCurrent => !const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') ||
      ChatFileAccess.keyFor(url) == null ||
      (ChatFileAccess.qaContentStable(url, user, contentEpoch) &&
       ChatFileAccess.qaAccessEpoch(url, user) == accessEpoch);
  _QaOwnerStatus get _qaOwnerStatus {
    if (user == null || sessionBinding == null || clientIdentity == null ||
        _qaCredential == null || _qaCredential!.isEmpty) return _QaOwnerStatus.unknown;
    try {
      final client = Supabase.instance.client;
      final session = client.auth.currentSession;
      final sid = ChatFileAccess.currentSessionBinding;
      final token = _qaToken();
      if (session == null || session.user.id.isEmpty || token == null || token.isEmpty || sid == null) {
        return _QaOwnerStatus.unknown;
      }
      return !identical(client, clientIdentity) || session.user.id != user ||
          sid != sessionBinding || ChatFileAccess.generation != epoch ||
          token != _qaCredential ? _QaOwnerStatus.stale : _QaOwnerStatus.current;
    } catch (_) { return _QaOwnerStatus.unknown; }
  }
  bool get _qaCanDisplay => _qaRevisionCurrent &&
      (!const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') ||
       ChatFileAccess.keyFor(url) == null || _qaOwnerStatus == _QaOwnerStatus.current);
  bool _qaExpectedDenial(Object error) {
    if (!const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') ||
        user == null || sessionBinding == null || clientIdentity == null ||
        _qaCredential == null || _qaCredential!.isEmpty || error is! FunctionException ||
        !(error.status == 401 || (error.status == 403 && error.details is Map &&
          (error.details as Map)['error'] == 'file_unavailable' &&
          (error.details as Map)['reason'] == 'access_denied_v1'))) return false;
    final status = _qaOwnerStatus;
    return status == _QaOwnerStatus.stale ||
        (status == _QaOwnerStatus.current && ChatFileAccess.isAccessRevoked(url));
  }
  bool get _ownerChanged {
    try {
      return user != ChatFileAccess.userId ||
          epoch != ChatFileAccess.generation ||
          sessionBinding != ChatFileAccess.currentSessionBinding ||
          (const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') && _qaCredential != _qaToken()) ||
          !identical(clientIdentity, ChatFileAccess.currentClientIdentity);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AuthorizedFileImageProvider> obtainKey(
      ImageConfiguration configuration) {
    final cache = PaintingBinding.instance.imageCache.statusForKey(this);
    if (!cache.pending &&
        (cache.live || cache.keepAlive) &&
        ChatFileAccess.canShowDecodedImage(url,
            user: user,
            epoch: epoch,
            sessionBinding: sessionBinding,
            clientIdentity: clientIdentity)) {
      ChatFileAccess.revalidateDecodedImage(url);
      return SynchronousFuture(this);
    }
    return _obtainAuthorizedKey();
  }

  Future<AuthorizedFileImageProvider> _obtainAuthorizedKey() async {
    if (const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') && ChatFileAccess.keyFor(url) != null) {
      final status = _qaOwnerStatus;
      if (status == _QaOwnerStatus.stale) return AuthorizedFileImageProvider._cancelled(this);
      if (status != _QaOwnerStatus.current) throw ChatFileSessionChanged();
    }
    if (!_qaRevisionCurrent && !_ownerChanged) return AuthorizedFileImageProvider._cancelled(this);
    // Never dispatch a request under new credentials for a provider captured
    // by an earlier session.
    if (ChatFileAccess.keyFor(url) != null && _ownerChanged) {
      if (const bool.fromEnvironment('CHAT_REENTRY_GATE_QA')) {
        return AuthorizedFileImageProvider._cancelled(this);
      }
      throw ChatFileSessionChanged();
    }
    // Check permission even when decoded pixels already exist in ImageCache.
    try {
      if (kDebugMode &&
          const bool.fromEnvironment('CHAT_REENTRY_GATE_QA') &&
          debugAuthorize != null) {
        await debugAuthorize!(url);
      } else {
        await ChatFileAccess.authorize(url);
      }
    } on ChatFileSessionChanged {
      if (_ownerChanged) {
        if (const bool.fromEnvironment('CHAT_REENTRY_GATE_QA')) {
          return AuthorizedFileImageProvider._cancelled(this);
        }
        rethrow;
      }
      rethrow;
    } catch (error) {
      if (_qaExpectedDenial(error)) return AuthorizedFileImageProvider._cancelled(this);
      rethrow;
    }
    if (const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') && ChatFileAccess.keyFor(url) != null) {
      final status = _qaOwnerStatus;
      if (status == _QaOwnerStatus.stale) return AuthorizedFileImageProvider._cancelled(this);
      if (status != _QaOwnerStatus.current) throw ChatFileSessionChanged();
    }
    if (!_qaRevisionCurrent && !_ownerChanged) return AuthorizedFileImageProvider._cancelled(this);
    if (!ChatFileAccess.isViewerCurrent(url,
        user: user, epoch: epoch, sessionBinding: sessionBinding)) {
      if (const bool.fromEnvironment('CHAT_REENTRY_GATE_QA') && _ownerChanged) {
        return AuthorizedFileImageProvider._cancelled(this);
      }
      throw StateError('Сессия изменилась.');
    }
    return this;
  }

  @override
  ImageStreamCompleter loadImage(
          AuthorizedFileImageProvider key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode, key), scale: 1);
  Future<ui.Codec> _load(
      ImageDecoderCallback decode, AuthorizedFileImageProvider key) async {
    Future<ui.Codec> cancelled() async {
      final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=');
      final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      return codec;
    }
    if (key._cancelledNonce != null) return cancelled();
    if (const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') &&
        ChatFileAccess.keyFor(url) != null) {
      final ownerStatus = _qaOwnerStatus;
      if (ownerStatus == _QaOwnerStatus.stale) return cancelled();
      if (ownerStatus != _QaOwnerStatus.current) throw ChatFileSessionChanged();
    }
    late final Uint8List bytes;
    try {
      bytes = await ChatFileAccess.readBytes(url);
    } catch (error) {
      if (_qaExpectedDenial(error)) return cancelled();
      rethrow;
    }
    if (!_qaCanDisplay) {
      final status = _qaOwnerStatus;
      if (status == _QaOwnerStatus.stale || status == _QaOwnerStatus.current) return cancelled();
      throw ChatFileSessionChanged();
    }
    try {
      final codec = kDebugMode && const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') && debugQaCodec != null
          ? await debugQaCodec!()
          : await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      if (kDebugMode && const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') && debugQaAfterDecode != null) {
        await debugQaAfterDecode!();
      }
      if (!_qaCanDisplay) { codec.dispose(); throw _QaContentChanged(); }
      return codec;
    } on _QaContentChanged {
      final status = _qaOwnerStatus;
      if (status == _QaOwnerStatus.stale || status == _QaOwnerStatus.current) return cancelled();
      throw ChatFileSessionChanged();
    } catch (decodeError) {
      try {
        await ChatFileAccess.discardUnreadableImage(url,
            user: user,
            epoch: epoch,
            sessionBinding: sessionBinding,
            expectedBytes: bytes);
      } on Exception catch (error) {
        debugPrint('[chat-image] Cache cleanup failed: ${error.runtimeType}');
      }
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AuthorizedFileImageProvider &&
      other.url == url &&
      other.user == user &&
      other.epoch == epoch &&
      other.sessionBinding == sessionBinding &&
        other.contentEpoch == contentEpoch && other.accessEpoch == accessEpoch &&
      other._qaCredential == _qaCredential &&
      identical(other.clientIdentity, clientIdentity) &&
      identical(other._cancelledNonce, _cancelledNonce);
  @override
  int get hashCode => Object.hash(
      url, user, epoch, sessionBinding, clientIdentity, contentEpoch, accessEpoch, _qaCredential, _cancelledNonce);
  @override
  String toString() => 'AuthorizedFileImageProvider';
}

class AuthorizedFileImage extends StatefulWidget {
  const AuthorizedFileImage(
      {super.key,
      required this.imageUrl,
      this.fit,
      this.width,
      this.height,
      this.placeholder,
      this.errorWidget});
  final String imageUrl;
  final BoxFit? fit;
  final double? width, height;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;

  @override
  State<AuthorizedFileImage> createState() => _AuthorizedFileImageState();
}

class _AuthorizedFileImageState extends State<AuthorizedFileImage> {
  int _attempt = 0;
  bool _revoked = false;
  String? _user;
  int _generation = 0;
  int _contentEpoch = 0, _accessEpoch = 0;
  late AuthorizedFileImageProvider _provider;
  ReentryImageObserver? _reentryObserver;
  Object? _reentryTicket;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ReentryImageScope.maybeOf(context);
    if (!identical(next, _reentryObserver)) {
      _reentryObserver?.finish(_reentryTicket);
      _reentryObserver = next;
      _reentryTicket = next?.begin();
    }
  }

  void _finishReentry() {
    _reentryObserver?.finish(_reentryTicket);
    _reentryTicket = null;
  }

  @override
  void initState() {
    super.initState();
    _revoked = ChatFileAccess.isAccessRevoked(widget.imageUrl);
    _user = ChatFileAccess.userId;
    _generation = ChatFileAccess.generation;
    _contentEpoch = ChatFileAccess.qaContentEpoch(widget.imageUrl, _user);
    _accessEpoch = ChatFileAccess.qaAccessEpoch(widget.imageUrl, _user);
    _provider = AuthorizedFileImageProvider(widget.imageUrl);
    ChatFileAccess.accessChanges.addListener(_accessChanged);
  }

  @override
  void didUpdateWidget(covariant AuthorizedFileImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _finishReentry();
      _reentryTicket = _reentryObserver?.begin();
      _revoked = ChatFileAccess.isAccessRevoked(widget.imageUrl);
      _contentEpoch = ChatFileAccess.qaContentEpoch(widget.imageUrl, ChatFileAccess.userId);
      _accessEpoch = ChatFileAccess.qaAccessEpoch(widget.imageUrl, ChatFileAccess.userId);
      _provider = AuthorizedFileImageProvider(widget.imageUrl);
    }
  }

  void _accessChanged() {
    final revoked = ChatFileAccess.isAccessRevoked(widget.imageUrl);
    final user = ChatFileAccess.userId;
    final generation = ChatFileAccess.generation;
    final contentEpoch = ChatFileAccess.qaContentEpoch(widget.imageUrl, user);
    final accessEpoch = ChatFileAccess.qaAccessEpoch(widget.imageUrl, user);
    if (!ChatFileAccess.decodedImageExperimentEnabled) {
      if (mounted &&
          (revoked != _revoked || user != _user || generation != _generation ||
           contentEpoch != _contentEpoch || accessEpoch != _accessEpoch)) {
        setState(() {
          _revoked = revoked;
          _user = user;
          _generation = generation;
          _contentEpoch = contentEpoch;
          _accessEpoch = accessEpoch;
          _attempt++;
        });
      }
      return;
    }
    if (mounted) {
      if (revoked || user != _user || generation != _generation) {
        PaintingBinding.instance.imageCache.evict(_provider);
      }
      setState(() {
        _revoked = revoked;
        _user = user;
        _generation = generation;
        _contentEpoch = contentEpoch;
        _accessEpoch = accessEpoch;
        _provider = AuthorizedFileImageProvider(widget.imageUrl);
        _attempt++;
      });
    }
  }

  @override
  void dispose() {
    _finishReentry();
    ChatFileAccess.accessChanges.removeListener(_accessChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = ChatFileAccess.decodedImageExperimentEnabled
        ? _provider
        : AuthorizedFileImageProvider(widget.imageUrl);
    Widget error(Object error) => Semantics(
          button: true,
          label: 'Повторить загрузку изображения',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              PaintingBinding.instance.imageCache.evict(provider);
              if (_revoked) {
                unawaited(
                    ChatFileAccess.resolve(widget.imageUrl).then<void>((_) {
                  if (mounted) setState(() => _attempt++);
                }, onError: (Object _, StackTrace __) {}));
              } else {
                setState(() => _attempt++);
              }
            },
            child: widget.errorWidget?.call(context, widget.imageUrl, error) ??
                const Icon(Icons.refresh_rounded),
          ),
        );
    if (_revoked) {
      _finishReentry();
      return error(StateError('Файл недоступен'));
    }
    return Image(
      key: ValueKey(_attempt),
      image: provider,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      frameBuilder: (context, child, frame, sync) {
        if (sync || frame != null) {
          if (!provider._qaCanDisplay) {
            return widget.placeholder?.call(context, widget.imageUrl) ??
                const Center(child: ProductLoadingIndicator(size: 72));
          }
          _finishReentry();
          return child;
        }
        return widget.placeholder?.call(context, widget.imageUrl) ??
            const Center(child: ProductLoadingIndicator(size: 72));
      },
      errorBuilder: (context, problem, stack) {
        _finishReentry();
        return error(problem);
      },
    );
  }
}
