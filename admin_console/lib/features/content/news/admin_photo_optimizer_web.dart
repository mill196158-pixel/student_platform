// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'admin_image_worker_lock.dart';

Future<Uint8List?> optimizeAdminPhoto(Uint8List original,
    {bool targetBudget = false, Listenable? invalidation, bool Function()? isCurrent}) async {
  if (!acquireAdminImageWorker()) return null;
  html.Worker? worker;
  StreamSubscription<html.MessageEvent>? messageSub;
  StreamSubscription<html.Event>? errorSub;
  void Function()? removeListener;
  try {
    final base = Uri.tryParse(html.document.baseUri ?? '');
    if (base == null || base.origin != Uri.base.origin) return null;
    worker = html.Worker(base.resolve('admin_photo_optimizer_worker.js').toString());
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
    messageSub = worker.onMessage.listen((event) {
      if (result.isCompleted) return;
      final data = event.data;
      if (data is ByteBuffer) {
        final bytes = data.asUint8List();
        if (bytes.length < original.length && bytes.length >= 3 &&
            bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
          result.complete(bytes);
          return;
        }
      }
      result.complete(null);
    });
    errorSub = worker.onError.listen((_) {
      if (!result.isCompleted) result.complete(null);
    });
    // Structured clone a copy; the original must remain available on failure.
    final copy = Uint8List.fromList(original).buffer;
    worker.postMessage(targetBudget ? {'mode': 'budget', 'bytes': copy} : copy);
    return await result.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    removeListener?.call();
    await messageSub?.cancel();
    await errorSub?.cancel();
    worker?.terminate();
    releaseAdminImageWorker();
  }
}
