import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'dart:async';
import '../../../services/chat_file_access.dart';

class AuthorizedFileImageProvider
    extends ImageProvider<AuthorizedFileImageProvider> {
  AuthorizedFileImageProvider(this.url)
      : user = ChatFileAccess.userId,
        epoch = ChatFileAccess.generation,
        sessionBinding = ChatFileAccess.currentSessionBinding;
  final String url;
  final String? user;
  final int epoch;
  final String? sessionBinding;
  @override
  Future<AuthorizedFileImageProvider> obtainKey(
      ImageConfiguration configuration) async {
    // Check permission even when decoded pixels already exist in ImageCache.
    await ChatFileAccess.authorize(url);
    if (!ChatFileAccess.isViewerCurrent(url,
        user: user, epoch: epoch, sessionBinding: sessionBinding)) {
      throw StateError('Сессия изменилась.');
    }
    return this;
  }

  @override
  ImageStreamCompleter loadImage(
          AuthorizedFileImageProvider key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);
  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
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
      other.sessionBinding == sessionBinding;
  @override
  int get hashCode => Object.hash(url, user, epoch, sessionBinding);
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

  @override
  void initState() {
    super.initState();
    _revoked = ChatFileAccess.isAccessRevoked(widget.imageUrl);
    _user = ChatFileAccess.userId;
    _generation = ChatFileAccess.generation;
    ChatFileAccess.accessChanges.addListener(_accessChanged);
  }

  @override
  void didUpdateWidget(covariant AuthorizedFileImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _revoked = ChatFileAccess.isAccessRevoked(widget.imageUrl);
    }
  }

  void _accessChanged() {
    final revoked = ChatFileAccess.isAccessRevoked(widget.imageUrl);
    final user = ChatFileAccess.userId;
    final generation = ChatFileAccess.generation;
    if (mounted &&
        (revoked != _revoked || user != _user || generation != _generation)) {
      setState(() {
        _revoked = revoked;
        _user = user;
        _generation = generation;
        _attempt++;
      });
    }
  }

  @override
  void dispose() {
    ChatFileAccess.accessChanges.removeListener(_accessChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = AuthorizedFileImageProvider(widget.imageUrl);
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
    if (_revoked) return error(StateError('Файл недоступен'));
    return Image(
      key: ValueKey(_attempt),
      image: provider,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      frameBuilder: (context, child, frame, sync) => sync || frame != null
          ? child
          : widget.placeholder?.call(context, widget.imageUrl) ??
              const Center(child: ProductLoadingIndicator(size: 72)),
      errorBuilder: (context, problem, stack) => error(problem),
    );
  }
}
