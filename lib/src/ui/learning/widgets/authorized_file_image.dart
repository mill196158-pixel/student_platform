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
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
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

class AuthorizedFileImage extends StatelessWidget {
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
  Widget build(BuildContext context) => Image(
        image: AuthorizedFileImageProvider(imageUrl),
        fit: fit,
        width: width,
        height: height,
        frameBuilder: (context, child, frame, sync) => sync || frame != null
            ? child
            : placeholder?.call(context, imageUrl) ??
                const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error, stack) =>
            errorWidget?.call(context, imageUrl, error) ??
            const Icon(Icons.broken_image),
      );
}
