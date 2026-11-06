import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show SynchronousFuture, visibleForTesting, kDebugMode;
import 'dart:async';
import 'dart:convert';
import '../../../services/chat_file_access.dart';
import 'reentry_image_gate.dart';

class AuthorizedFileImageProvider
    extends ImageProvider<AuthorizedFileImageProvider> {
  @visibleForTesting
  static Future<void> Function(String)? debugAuthorize;
  AuthorizedFileImageProvider(this.url)
      : user = ChatFileAccess.userId,
        epoch = ChatFileAccess.generation,
        sessionBinding = ChatFileAccess.currentSessionBinding,
        clientIdentity = ChatFileAccess.currentClientIdentity,
        _cancelledNonce = null;
  AuthorizedFileImageProvider._cancelled(AuthorizedFileImageProvider old)
      : url = old.url,
        user = old.user,
        epoch = old.epoch,
        sessionBinding = old.sessionBinding,
        clientIdentity = old.clientIdentity,
        _cancelledNonce = Object();
  final String url;
  final String? user;
  final int epoch;
  final String? sessionBinding;
  final Object? clientIdentity;
  final Object? _cancelledNonce;
  bool get _ownerChanged {
    try {
      return user != ChatFileAccess.userId ||
          epoch != ChatFileAccess.generation ||
          sessionBinding != ChatFileAccess.currentSessionBinding ||
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
    }
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
    if (key._cancelledNonce != null) {
      final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=');
      final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      return codec;
    }
    final bytes = await ChatFileAccess.readBytes(url);
    try {
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
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
      identical(other.clientIdentity, clientIdentity) &&
      identical(other._cancelledNonce, _cancelledNonce);
  @override
  int get hashCode => Object.hash(
      url, user, epoch, sessionBinding, clientIdentity, _cancelledNonce);
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
      _provider = AuthorizedFileImageProvider(widget.imageUrl);
    }
  }

  void _accessChanged() {
    final revoked = ChatFileAccess.isAccessRevoked(widget.imageUrl);
    final user = ChatFileAccess.userId;
    final generation = ChatFileAccess.generation;
    if (!ChatFileAccess.decodedImageExperimentEnabled) {
      if (mounted &&
          (revoked != _revoked || user != _user || generation != _generation)) {
        setState(() {
          _revoked = revoked;
          _user = user;
          _generation = generation;
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
