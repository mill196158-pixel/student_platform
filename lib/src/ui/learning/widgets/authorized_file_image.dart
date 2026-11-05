import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../../services/chat_file_access.dart';

class AuthorizedFileImageProvider
    extends ImageProvider<AuthorizedFileImageProvider> {
  AuthorizedFileImageProvider(this.url)
      : user = ChatFileAccess.userId,
        epoch = ChatFileAccess.generation;
  final String url;
  final String? user;
  final int epoch;
  @override
  Future<AuthorizedFileImageProvider> obtainKey(
      ImageConfiguration configuration) async {
    // Check permission even when decoded pixels already exist in ImageCache.
    await ChatFileAccess.authorize(url);
    if (ChatFileAccess.userId != user || ChatFileAccess.generation != epoch) {
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
            user: user, epoch: epoch);
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
      other.epoch == epoch;
  @override
  int get hashCode => Object.hash(url, user, epoch);
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

  @override
  Widget build(BuildContext context) {
    final provider = AuthorizedFileImageProvider(widget.imageUrl);
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
      errorBuilder: (context, error, stack) => Semantics(
        button: true,
        label: 'Повторить загрузку изображения',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            PaintingBinding.instance.imageCache.evict(provider);
            setState(() => _attempt++);
          },
          child: widget.errorWidget?.call(context, widget.imageUrl, error) ??
              const Icon(Icons.refresh_rounded),
        ),
      ),
    );
  }
}
