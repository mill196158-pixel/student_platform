import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('synthetic media eviction crash after durable journal and rename',
      () async {
    sqfliteFfiInit();
    final path = Platform.environment['SYNTHETIC_MEDIA_CRASH_ROOT'];
    if (path == null || path.isEmpty)
      throw StateError('Synthetic test root required');
    final root = Directory(path);
    final database =
        await databaseFactoryFfi.openDatabase('${root.path}/test.db');
    final store = MediaCacheProtection(
        db: database,
        root: root,
        project: 'project',
        databaseToken: 'crashed-guard',
        currentOwner: () => 'owner',
        currentSessionId: () => 'sid');
    await store.initialize();
    await database
        .execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY)');
    final directory = Directory('${root.path}/authorized_chat_files/owner');
    await directory.create(recursive: true);
    final file = File('${directory.path}/${store.digest('owner', 'key')}');
    await file.writeAsBytes([11, 22, 33], flush: true);
    if (!await store.registerPinned('owner', 'key', () => true) ||
        !await store.unpin('owner', 'key',
            explicitlyAllowed: true, permit: () => true)) {
      throw StateError('Synthetic setup failed');
    }
    store.debugAfterEvictionRename = () async {
      stdout.writeln('SYNTHETIC_MEDIA_STAGED');
      await stdout.flush();
      exit(86);
    };
    await store.evict('owner', 1,
        allOperationsParticipate: true, permit: () => true);
    throw StateError('Synthetic crash point was not reached');
  });
}
