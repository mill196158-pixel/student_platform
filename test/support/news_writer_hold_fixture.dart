import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/durable_optional_media_reservations.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('synthetic process exit with live reservation', () async {
    final root = Platform.environment['SYNTHETIC_NEWS_HOLD_ROOT'];
    if (root == null) return;
    final db = await databaseFactoryFfi.openDatabase('$root/quota.db');
    await DurableOptionalMediaReservations.createSchema(db);
    final coordinator = DurableOptionalMediaReservations(db);
    final revision = (await coordinator.captureRevision('news'))!;
    final hold = await coordinator.reserveIfRevision(namespace: 'news',
        observation: revision, measuredBytes: 0, bytes: 1, limitBytes: 10);
    if (hold == null) throw StateError('No synthetic hold');
    if (Platform.environment['SYNTHETIC_NEWS_HOLD_PHASE'] == 'put') {
      final store = await NewsSqliteImageStore.openOwned(databasePath: '$root/index.db',
          root: Directory('$root/blobs'), factory: databaseFactoryFfi);
      final key = NewsImageCacheKey(path: 'image', version: '1');
      if (!await store.put(key, Uint8List.fromList([5]), await store.capture(key))) {
        throw StateError('Synthetic put failed');
      }
    }
    stdout.writeln('SYNTHETIC_NEWS_HOLD_EXIT');
    await stdout.flush();
    exit(42);
  });
}
