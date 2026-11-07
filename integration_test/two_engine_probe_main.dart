import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

const _project = 'https://example.invalid', _uid = 'synthetic', _key = 'chats/test/file';
const _channel = MethodChannel('student_platform/qa_two_engine');

@pragma('vm:entry-point')
Future<void> qaSecondEngine() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await getApplicationSupportDirectory();
  final marker = File('${root.path}/codex_two_engine_result');
  try {
    var rejected = false;
    try { await ChatFileAccess.resolve('https://studentsplatform.storage.yandexcloud.net/chats/test/file'); }
    on StateError catch (e) { rejected = e.message == 'Media protection is not initialized'; }
    if (!rejected) throw StateError('second engine bypassed bootstrap gate');
    final db = await openProjectChatServerDatabase('${await getDatabasesPath()}/two_engine_probe_v1.db');
    final fence = PinnedAccessFence(db, databaseToken: debugProjectChatDatabaseGuard(db));
    if (await fence.canRead(_project, _uid, _key)) throw StateError('pending not visible across engines');
    final token = await fence.begin(_project, _uid, _key);
    await fence.finish(token, allowed: true);
    if (await fence.canRead(_project, _uid, _key)) throw StateError('live pending ignored');
    await db.close();
    await marker.writeAsString('PASS', flush: true);
  } catch (e, s) { await marker.writeAsString('FAIL $e $s', flush: true); }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName != 'com.example.offline_grant_qa') throw StateError('isolated QA package required');
  try {
    final root = await getApplicationSupportDirectory();
    final marker = File('${root.path}/codex_two_engine_result');
    if (await marker.exists()) await marker.delete();
    final db = await openProjectChatServerDatabase('${await getDatabasesPath()}/two_engine_probe_v1.db');
    final fence = PinnedAccessFence(db, databaseToken: debugProjectChatDatabaseGuard(db));
    final token = await fence.begin(_project, _uid, _key);
    var closeRejected = false;
    try { await db.close(); } on StateError { closeRejected = true; }
    if (!closeRejected) throw StateError('live guard closed');
    await _channel.invokeMethod<void>('launch');
    for (var i = 0; i < 200 && !await marker.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!await marker.exists() || await marker.readAsString() != 'PASS') throw StateError('second engine failed: ${await marker.exists() ? await marker.readAsString() : 'timeout'}');
    await fence.finish(token, allowed: false);
    if (await fence.canRead(_project, _uid, _key)) throw StateError('late denial lost');
    final retry = await fence.begin(_project, _uid, _key); await fence.finish(retry, allowed: true);
    if (!await fence.canRead(_project, _uid, _key)) throw StateError('live retry failed');
    await db.close();
    debugPrint('CODEX_TWO_ENGINE_PASS');
    runApp(const MaterialApp(home: Scaffold(body: Text('Isolated two-engine probe: pass'))));
  } catch (e, s) {
    debugPrint('CODEX_TWO_ENGINE_FAIL $e $s');
    runApp(const MaterialApp(home: Scaffold(body: Text('Isolated two-engine probe: fail'))));
  }
}
