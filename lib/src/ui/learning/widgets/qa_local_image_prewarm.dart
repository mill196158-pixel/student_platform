import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../../../services/chat_file_access.dart';
import 'authorized_file_image.dart';

/// Bounded, local-only QA warmup. Display still performs provider authorization.
@visibleForTesting
Future<void> Function()? qaDebugBeforePrewarmInsert;

Future<bool> qaPrewarmLocalImage(String url, {required bool Function() current}) async {
  bool permitted() {
    try { return current(); } catch (_) { return false; }
  }
  // The synchronous hot-ticket path has different invalidation guarantees.
  if (!permitted() || ChatFileAccess.decodedImageExperimentEnabled ||
      ChatFileAccess.keyFor(url) == null) return false;
  final provider = AuthorizedFileImageProvider(url);
  final uid = ChatFileAccess.userId, sid = ChatFileAccess.currentSessionBinding;
  final epoch = ChatFileAccess.generation, client = ChatFileAccess.currentClientIdentity;
  final contentEpoch = ChatFileAccess.qaContentEpoch(url, uid);
  final accessEpoch = ChatFileAccess.qaAccessEpoch(url, uid);
  bool stillCurrent() => permitted() && uid != null && sid != null &&
      identical(client, ChatFileAccess.currentClientIdentity) &&
      ChatFileAccess.qaContentStable(url, uid, contentEpoch) &&
      ChatFileAccess.qaAccessEpoch(url, uid) == accessEpoch &&
      ChatFileAccess.isViewerCurrent(url, user: uid, epoch: epoch, sessionBinding: sid);
  if (!stillCurrent()) return false;
  try {
    final path = await ChatFileAccess.cachedPathForOpen(url, permit: stillCurrent);
    if (path == null || !stillCurrent()) return false;
    final size = await File(path).length();
    if (size <= 0 || size > 8 * 1024 * 1024 || !stillCurrent()) return false;
    final bytes = await ChatFileAccess.readCachedOnly(url,
        permit: stillCurrent, maxBytes: 8 * 1024 * 1024);
    if (bytes == null || bytes.isEmpty || bytes.length > 8 * 1024 * 1024 || !stillCurrent()) return false;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (!stillCurrent() || descriptor.width * descriptor.height > 4000000) return false;
      codec = await descriptor.instantiateCodec();
      if (!stillCurrent() || codec.frameCount != 1) return false;
      final frame = await codec.getNextFrame();
      image = frame.image;
      if (!stillCurrent()) return false;
      if (kDebugMode && qaDebugBeforePrewarmInsert != null) {
        await qaDebugBeforePrewarmInsert!();
        if (!stillCurrent()) return false;
      }
      // Recheck durable deny/pending after decoding; this path never performs HTTP.
      final checkedPath = await ChatFileAccess.cachedPathForOpen(url, permit: stillCurrent);
      if (checkedPath != path || !stillCurrent()) return false;
      final cache = PaintingBinding.instance.imageCache;
      if (cache.containsKey(provider)) return true;
      final decoded = image;
      final completer = cache.putIfAbsent(provider, () =>
          OneFrameImageStreamCompleter(Future.value(ImageInfo(image: decoded))));
      if (completer == null) return false;
      image = null; // ImageInfo owns it after successful insertion.
      return true;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  } catch (_) {
    return false;
  }
}
