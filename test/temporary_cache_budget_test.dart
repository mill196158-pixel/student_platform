import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/temporary_cache_budget.dart';

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

}
