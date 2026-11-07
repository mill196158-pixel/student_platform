// Standalone synthetic fixture. No application account or network is used.
// Build only with STUDENT_ATTACH_FIXTURE=1; kill the fixture process after
// ATTACH_WAL_KILL_NOW, then launch it again to check WAL recovery.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:student_platform/src/ui/chats/core/source_snapshot_attachment.dart';

const _package = 'com.mill453020.studentplatform.attachfixture';
const _source = SourceAttachmentIdentity(project: 'synthetic-project', uid: 'synthetic-user',
    sid: 'synthetic-session', chatId: 'synthetic-chat', messageId: 'synthetic-message',
    fileId: 'synthetic-file', fileKey: 'synthetic-key', fileUrl: 'https://example.invalid/file');

Future<Database> _open(String path) async {
  return openDatabase(path, singleInstance: false, onConfigure: (db) async {
    final wal = await db.rawQuery('PRAGMA journal_mode=WAL');
    if (wal.length != 1 || wal.single.values.single.toString().toLowerCase() != 'wal') {
      throw StateError('WAL unavailable');
    }
    await db.execute('PRAGMA synchronous=FULL');
    await db.execute('PRAGMA busy_timeout=0');
  });
}

Future<void> _setup(Database media, Database chat) async {
  await media.execute('CREATE TABLE probe (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)');
  await media.insert('probe', {'id': 1, 'value': 0});
  await media.execute('CREATE TABLE media_cache_logout_tombstones (project TEXT, uid TEXT, sid TEXT)');
  await chat.execute('CREATE TABLE chat_server_attempt (project TEXT, uid TEXT, sid TEXT, chat TEXT, seq INTEGER, blocked INTEGER)');
  await chat.execute('CREATE TABLE chat_server_snapshot (project TEXT, uid TEXT, sid TEXT, chat TEXT, payload TEXT)');
  await chat.insert('chat_server_attempt', {'project': _source.project, 'uid': _source.uid,
    'sid': _source.sid, 'chat': _source.chatId, 'seq': 1, 'blocked': 0});
  await chat.insert('chat_server_snapshot', {'project': _source.project, 'uid': _source.uid,
    'sid': _source.sid, 'chat': _source.chatId, 'payload': jsonEncode([
      {'id': _source.messageId, 'chat_id': _source.chatId, 'delivery_status': 'sent',
        'attachments': [{'id': _source.fileId, 'chat_id': _source.chatId,
          'message_id': _source.messageId, 'file_key': _source.fileKey,
          'file_url': _source.fileUrl, 'is_deleted': false, 'deletion_verified': true}]}
    ])});
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid || (await PackageInfo.fromPlatform()).packageName != _package) {
    throw StateError('Dedicated synthetic Android package required');
  }
  final status = ValueNotifier<String>('Preparing isolated WAL fixture');
  runApp(MaterialApp(home: Scaffold(body: Center(child: ValueListenableBuilder<String>(
    valueListenable: status, builder: (_, value, __) => Text(value, textAlign: TextAlign.center))))));
  try {
    final prefs = await SharedPreferences.getInstance();
    final armed = prefs.getBool('attach_wal_armed') == true;
    final base = await getApplicationSupportDirectory();
    final Directory root;
    if (armed) {
      final path = prefs.getString('attach_wal_root');
      if (path == null || !path.startsWith('${base.path}${Platform.pathSeparator}attach_wal_')) {
        throw StateError('Missing fixture directory');
      }
      root = Directory(path);
      if (!await root.exists()) throw StateError('Fixture directory unavailable');
    } else {
      root = await base.createTemp('attach_wal_');
    }
    final media = await _open('${root.path}/media.db');
    final chat = await _open('${root.path}/chat.db');
    if (!armed) await _setup(media, chat);
    final attached = await attachSourceSnapshot(media, chat);
    if (attached == null) throw StateError('ATTACH failed');
    final guard = SourceAttachmentGuard(media, attachedSnapshot: true, attachedSnapshotPath: attached);
    if (armed) {
      final value = (await media.query('probe')).single['value'];
      final seq = (await chat.query('chat_server_attempt')).single['seq'];
      if (value != 0 || seq != 1 || await guard.capture(_source, () => true) == null) {
        throw StateError('Uncommitted state survived or source unavailable');
      }
      if (await chat.update('chat_server_attempt', {'seq': 2}) != 1 ||
          await guard.run(_source, () => true, (_, __) async => true, expectedSequence: 1) != null) {
        throw StateError('Post-crash writer/sequence check failed');
      }
      await media.close();
      await chat.close();
      await prefs.setBool('attach_wal_armed', false);
      debugPrint('ATTACH_WAL_RECOVERY_PASS');
      status.value = 'ATTACH + WAL recovery: PASS';
      return;
    }
    final started = Completer<void>();
    final never = Completer<void>();
    unawaited(guard.run<bool>(_source, () => true, (txn, seq) async {
      if (seq != 1) throw StateError('Unexpected sequence');
      await txn.update('probe', {'value': 1}, where: 'id=1');
      started.complete();
      await never.future;
      return true;
    }).then<void>((_) {}));
    await started.future.timeout(const Duration(seconds: 10));
    final competing = chat.update('chat_server_attempt', {'seq': 2})
        .then((_) => true, onError: (Object _) => false);
    final outcome = await Future.any<bool?>([competing,
      Future<bool?>.delayed(const Duration(milliseconds: 500), () => null)]);
    if (outcome == true) throw StateError('Concurrent writer passed the held transaction');
    if (!await prefs.setString('attach_wal_root', root.path) ||
        !await prefs.setBool('attach_wal_armed', true)) throw StateError('Could not arm fixture');
    debugPrint('ATTACH_WAL_KILL_NOW');
    status.value = 'ATTACH + WAL armed. Kill this fixture process, then reopen it.';
  } catch (error, stack) {
    debugPrint('ATTACH_WAL_FAIL $error $stack');
    status.value = 'ATTACH + WAL fixture: FAIL';
  }
}
