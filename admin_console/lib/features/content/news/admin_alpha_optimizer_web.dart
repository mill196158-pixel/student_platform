// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'admin_image_worker_lock.dart';

Future<Uint8List?> optimizeAdminAlpha(Uint8List original,
    {Listenable? invalidation, bool Function()? isCurrent}) async {
  if (original.length > 10 * 1024 * 1024 || !acquireAdminImageWorker()) return null;
  html.Worker? worker;
  StreamSubscription<html.MessageEvent>? messages;
  StreamSubscription<html.Event>? errors;
  void Function()? removeListener;
  try {
    final base = Uri.tryParse(html.document.baseUri ?? '');
    if (base == null || base.origin != Uri.base.origin) return null;
    worker = html.Worker(base.resolve('admin_alpha_optimizer_worker.js').toString());
    final result = Completer<Uint8List?>();
    void check() {
      var current = false;
      try { current = isCurrent?.call() ?? true; } catch (_) {}
      if (!current && !result.isCompleted) {
        worker?.terminate();
        result.complete(null);
      }
    }
    invalidation?.addListener(check);
    removeListener = () => invalidation?.removeListener(check);
    check();
    if (result.isCompleted) return null;
    messages = worker.onMessage.listen((event) {
      if (result.isCompleted) return;
      final data = event.data;
      if (data is ByteBuffer) {
        final bytes = data.asUint8List();
        if (bytes.length >= 20 && bytes.length < original.length &&
            bytes.length <= 5 * 1024 * 1024 &&
            String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
            String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP' &&
            ByteData.sublistView(bytes).getUint32(4, Endian.little) + 8 == bytes.length) {
          result.complete(bytes);
          return;
        }
      }
      result.complete(null);
    });
    errors = worker.onError.listen((_) { if (!result.isCompleted) result.complete(null); });
    worker.postMessage(Uint8List.fromList(original).buffer);
    return await result.future.timeout(const Duration(seconds: 15), onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    removeListener?.call();
    await messages?.cancel();
    await errors?.cancel();
    worker?.terminate();
    releaseAdminImageWorker();
  }
}
