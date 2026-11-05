// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

bool _running = false;

Future<Uint8List?> optimizeAdminPhoto(Uint8List original) async {
  if (_running) return null;
  _running = true;
  html.Worker? worker;
  StreamSubscription<html.MessageEvent>? messageSub;
  StreamSubscription<html.Event>? errorSub;
  try {
    final base = Uri.tryParse(html.document.baseUri ?? '');
    if (base == null || base.origin != Uri.base.origin) return null;
    worker = html.Worker(base.resolve('admin_photo_optimizer_worker.js').toString());
    final result = Completer<Uint8List?>();
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
    worker.postMessage(Uint8List.fromList(original).buffer);
    return await result.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    await messageSub?.cancel();
    await errorSub?.cancel();
    worker?.terminate();
    _running = false;
  }
}
