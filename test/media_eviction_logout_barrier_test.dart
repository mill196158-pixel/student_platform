import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('logout waits for recovery transaction and tombstones the old SID',
      () async {
    final root = await Directory.systemTemp.createTemp('media-logout-barrier-');
    final path = '${root.path}/test.db';
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final secondDb = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    var uid = 'a';
    var sid = 'old';
    var permitted = true;
    MediaCacheProtection make(Database database) => MediaCacheProtection(
        db: database,
        root: root,
        project: 'project',
        databaseToken: 'new',
        currentOwner: () => uid,
        currentSessionId: () => sid);
    final store = make(db), logoutStore = make(secondDb);
    addTearDown(() async {
      await secondDb.close();
      await db.close();
      await root.delete(recursive: true);
    });
    await store.initialize();
    await db.execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY)');
    final dir = Directory('${root.path}/authorized_chat_files/a');
    await dir.create(recursive: true);
    final hash = store.digest('a', 'key');
    const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    final staged = File('${dir.path}/.evict-$token-$hash');
    final original = File('${dir.path}/$hash');
    await staged.writeAsBytes([1, 2, 3]);
    await db.insert('media_cache_eviction_journal', {
      'token': token,
      'project': 'project',
      'uid': 'a',
      'digest': hash,
      'sid': 'old',
      'database_token': 'dead',
      'state': 'staging',
      'size': 3
    });
    final entered = Completer<void>(), release = Completer<void>();
    store.debugBeforeRecoveryRename = () async {
      entered.complete();
      await release.future;
    };
    final recovery = store.recoverInterruptedEvictions('a', () => permitted,
        mayRestore: (_) => true);
    await entered.future;
    // A different owner is never deleted by a busy logout barrier. SQLite
    // may serialize its metadata writes, so do not claim parallel progress.
    final bDir = Directory('${root.path}/authorized_chat_files/b');
    await bDir.create(recursive: true);
    final bStore = MediaCacheProtection(
        db: secondDb,
        root: root,
        project: 'other-project',
        databaseToken: 'b',
        currentOwner: () => 'b',
        currentSessionId: () => 'b-session');
    final bFile = File('${bDir.path}/${bStore.digest('b', 'key')}');
    await bFile.writeAsBytes([8]);
    expect(await bFile.readAsBytes(), [8]);
    var cleaned = false, signedOut = false;
    final logout = runLogoutCleanup(
        memoryFence: () {
          permitted = false;
        },
        durableRevoke: () => logoutStore.markSessionLoggedOut('a', 'old',
            stillCurrent: () => true),
        cleanups: [
          () async {
            cleaned = true;
            await dir.delete(recursive: true);
          }
        ],
        signOut: () async {
          signedOut = true;
        },
        clearSession: () {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cleaned, isFalse);
    release.complete();
    expect(await recovery, 0);
    final firstResult = await logout;
    if (firstResult == LogoutCleanupResult.blockedBeforeSignOut) {
      expect(cleaned, isFalse);
      expect(signedOut, isFalse);
      expect(
          await runLogoutCleanup(
              durableRevoke: () => logoutStore.markSessionLoggedOut('a', 'old',
                  stillCurrent: () => true),
              cleanups: [
                () async {
                  cleaned = true;
                  await dir.delete(recursive: true);
                }
              ],
              signOut: () async {
                signedOut = true;
              },
              clearSession: () {}),
          LogoutCleanupResult.signedOut);
    } else {
      expect(firstResult, LogoutCleanupResult.signedOut);
    }
    expect(signedOut, isTrue);
    expect(await original.exists(), isFalse);
    expect(await bFile.readAsBytes(), [8]);
    expect(await db.query('media_cache_logout_tombstones'), hasLength(1));
    // Both a new SID for A and an intervening B are denied restoration of A's journal.
    permitted = true;
    uid = 'b';
    sid = 'b-session';
    expect(
        await store.recoverInterruptedEvictions('a', () => permitted,
            mayRestore: (_) => true),
        0);
    uid = 'a';
    sid = 'new';
    expect(
        await store.recoverInterruptedEvictions('a', () => permitted,
            mayRestore: (_) => true),
        0);
    sid = 'old';
    expect(
        await store.recoverInterruptedEvictions('a', () => permitted,
            mayRestore: (_) => true),
        0);
  });
}
