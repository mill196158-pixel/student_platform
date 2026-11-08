import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:student_platform/src/ui/chats/core/source_snapshot_attachment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final target in ['snapshot', 'logout']) {
    for (final write in [true, false]) {
      test(
          'WAL guard serializes $target with ${write ? 'write' : 'read-only'} callback',
          () async {
        final root = await Directory.systemTemp.createTemp('guard-wal-');
        final mediaPath = '${root.path}/media.db',
            chatPath = '${root.path}/chat.db';
        Future<Database> open(String path) =>
            databaseFactoryFfi.openDatabase(path,
                options: OpenDatabaseOptions(
                    singleInstance: false,
                    onConfigure: (db) async {
                      final wal = await db.rawQuery('PRAGMA journal_mode=WAL');
                      expect(wal.single.values.single.toString().toLowerCase(),
                          'wal');
                      await db.execute('PRAGMA busy_timeout=0');
                    }));
        final media = await open(mediaPath), mediaOther = await open(mediaPath);
        final chat = await open(chatPath);
        addTearDown(() async {
          await media.close();
          await mediaOther.close();
          await chat.close();
          await root.delete(recursive: true);
        });
        await media.execute(
            'CREATE TABLE media_cache_logout_tombstones (project TEXT, uid TEXT, sid TEXT)');
        await media.execute('CREATE TABLE publication (value INTEGER)');
        await chat.execute(
            'CREATE TABLE chat_server_attempt (project TEXT, uid TEXT, sid TEXT, chat TEXT, seq INTEGER, blocked INTEGER)');
        await chat.execute(
            'CREATE TABLE chat_server_snapshot (project TEXT, uid TEXT, sid TEXT, chat TEXT, payload TEXT)');
        await chat.insert('chat_server_attempt', {
          'project': 'p',
          'uid': 'u',
          'sid': 's',
          'chat': 'c',
          'seq': 1,
          'blocked': 0
        });
        await chat.insert('chat_server_snapshot', {
          'project': 'p',
          'uid': 'u',
          'sid': 's',
          'chat': 'c',
          'payload': jsonEncode([
            {
              'id': 'm',
              'chat_id': 'c',
              'delivery_status': 'sent',
              'attachments': [
                {
                  'id': 'f',
                  'chat_id': 'c',
                  'message_id': 'm',
                  'file_key': 'k',
                  'file_url': 'https://example.invalid/k',
                  'is_deleted': false,
                  'deletion_verified': true
                }
              ]
            }
          ])
        });
        final path = await attachSourceSnapshot(media, chat);
        expect(path, isNotNull);
        const source = SourceAttachmentIdentity(
            project: 'p',
            uid: 'u',
            sid: 's',
            chatId: 'c',
            messageId: 'm',
            fileId: 'f',
            fileKey: 'k',
            fileUrl: 'https://example.invalid/k');
        final guard = SourceAttachmentGuard(media,
            attachedSnapshot: true, attachedSnapshotPath: path);
        final ready = Completer<void>(), proceed = Completer<void>();
        final operation = guard.run(source, () => true, (txn, _) async {
          if (write) await txn.insert('publication', {'value': 1});
          ready.complete();
          await proceed.future;
          return true;
        });
        await ready.future.timeout(const Duration(seconds: 5));
        Future<bool> update() async {
          try {
            if (target == 'snapshot') {
              await chat
                  .update('chat_server_attempt', {'seq': 2, 'blocked': 1});
            } else {
              await mediaOther.insert('media_cache_logout_tombstones',
                  {'project': 'p', 'uid': 'u', 'sid': 's'});
            }
            return true;
          } catch (_) {
            return false;
          }
        }

        final rival = update();
        final before = await Future.any<bool?>([
          rival,
          Future<bool?>.delayed(const Duration(milliseconds: 250), () => null)
        ]);
        proceed.complete();
        final accepted = await operation;
        final rivalSucceeded = await rival;
        expect(before, isNot(isTrue),
            reason:
                'writer must not commit while source guard transaction is active');
        if (before == true) {
          expect(accepted, isNull,
              reason: 'cannot publish after a concurrent change committed');
          expect(await media.query('publication'), isEmpty);
        } else {
          expect(accepted, isTrue,
              reason: 'transaction serialized before the competing change');
        }
        if (!rivalSucceeded) expect(await update(), isTrue);
        expect(
            await guard.run(source, () => true, (_, __) async => true), isNull,
            reason: 'a committed invalidation must reject subsequent reads');
      });
    }
  }
}
