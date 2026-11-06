import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/temporary_cache_budget.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('physical temporary files and persisted history are both counted', () async {
    final root = await Directory.systemTemp.createTemp('quota-measure-');
    addTearDown(() async {
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await root.delete(recursive: true);
      }
    });
    await File('${root.path}/image').writeAsBytes([1, 2, 3]);
    SharedPreferences.setMockInitialValues({
      'chat_msg_cache_v1_owner_chat': 'история',
      'global_draft_texts': 'never read or delete this',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(await TemporaryCacheBudget.measure(root: root, prefs: prefs),
        3 + utf8.encode('история').length);
    expect(prefs.getString('global_draft_texts'), 'never read or delete this');
  });

  test('history database, WAL and SHM are counted as physical files', () async {
    final parent = await Directory.systemTemp.createTemp('quota-sqlite-');
    final root = Directory('${parent.path}/temp');
    await root.create();
    addTearDown(() async {
      if (parent.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await parent.delete(recursive: true);
      }
    });
    final database = File('${parent.path}/chat.db');
    await database.writeAsBytes([1, 2]);
    await File('${database.path}-wal').writeAsBytes([1, 2, 3]);
    await File('${database.path}-shm').writeAsBytes([1, 2, 3, 4]);
    SharedPreferences.setMockInitialValues({});
    expect(await TemporaryCacheBudget.measure(root: root,
        prefs: await SharedPreferences.getInstance(), historyDatabase: database), 9);
  });

  test('cleanup lower bound excludes unsent, unknown and unrelated protected files', () async {
    final root = await Directory.systemTemp.createTemp('quota-classify-');
    final database = await databaseFactoryFfi.openDatabase('${root.path}/history.db');
    addTearDown(() async {
      await database.close();
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await root.delete(recursive: true);
      }
    });
    await database.execute('CREATE TABLE chat_server_snapshot (chat TEXT, payload TEXT)');
    final sent = {'id': 'server', 'delivery_status': 'sent'};
    final pending = {'id': 'local_pending', 'delivery_status': 'failed', 'client_id': 'draft'};
    final payload = jsonEncode([sent]);
    await database.insert('chat_server_snapshot', {'chat': 'chat', 'payload': payload});
    await database.insert('chat_server_snapshot', {'chat': '__chat_summaries__', 'payload': payload});
    await database.insert('chat_server_snapshot', {'chat': 'mixed', 'payload': jsonEncode([pending])});
    final news = Directory('${root.path}/news_images_v1');
    await news.create();
    await File('${news.path}/image').writeAsBytes([1, 2, 3]);
    await File('${root.path}/protected-offline-file').writeAsBytes(List.filled(200, 1));
    SharedPreferences.setMockInitialValues({
      'chat_msg_cache_v1_user_chat': jsonEncode({'messages': [sent, pending, {'id': 'unknown'}]}),
      'global_draft_texts': 'protected',
    });
    final result = await TemporaryCacheBudget.measureProvenTemporary(database,
        root: root, prefs: await SharedPreferences.getInstance());
    expect(result, 3 + utf8.encode(payload).length + utf8.encode(jsonEncode(sent)).length);
  });

  test('news LRU reclaims only older news under budget pressure', () async {
    final root = await Directory.systemTemp.createTemp('quota-news-');
    addTearDown(() async {
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await root.delete(recursive: true);
      }
    });
    final protectedFile = File('${root.path}/protected-draft');
    await protectedFile.writeAsBytes([9, 9]);
    final cache = NewsImageDiskCache(
      rootOverride: () => Directory('${root.path}/news'),
      memory: NewsImageBytesCache(maxEntries: 4),
      debugQuotaUsage: () async => TemporaryCacheBudget.limitBytes + 1,
    );
    const first = NewsImageCacheKey(path: 'first', version: '1');
    const second = NewsImageCacheKey(path: 'second', version: '1');
    await cache.put(first, Uint8List.fromList([1, 2]));
    await cache.put(second, Uint8List.fromList([3, 4]));
    await cache.debugWaitForQuota();
    expect(await cache.peek(first), isNull);
    expect(await protectedFile.readAsBytes(), [9, 9]);
    expect(await cache.peek(second), [3, 4]);
  });

  test('two cache instances retain both indexes and delayed scan does not block reads', () async {
    final root = await Directory.systemTemp.createTemp('quota-two-');
    final started = Completer<void>();
    final finish = Completer<int?>();
    addTearDown(() async {
      if (!finish.isCompleted) finish.complete(null);
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await root.delete(recursive: true);
      }
    });
    final firstCache = NewsImageDiskCache(
      rootOverride: () => root,
      memory: NewsImageBytesCache(maxEntries: 4),
      debugQuotaUsage: () { if (!started.isCompleted) started.complete(); return finish.future; },
    );
    final secondCache = NewsImageDiskCache(
      rootOverride: () => root,
      memory: NewsImageBytesCache(maxEntries: 4),
    );
    const first = NewsImageCacheKey(path: 'first', version: '1');
    const second = NewsImageCacheKey(path: 'second', version: '1');
    await firstCache.put(first, Uint8List.fromList([1]));
    await started.future;
    await secondCache.put(second, Uint8List.fromList([2]));
    expect(await secondCache.peek(first).timeout(const Duration(seconds: 2)), [1]);
    finish.complete(null);
    await firstCache.debugWaitForQuota();
    final fresh = NewsImageDiskCache(rootOverride: () => root,
        memory: NewsImageBytesCache(maxEntries: 4));
    expect(await fresh.peek(first), [1]);
    expect(await fresh.peek(second), [2]);
  });
}
