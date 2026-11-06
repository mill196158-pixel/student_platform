import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/info/home_content_snapshot_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real SQLite snapshots are isolated, atomic and denied across reopen',
      () async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('home_content_qa_');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final now = DateTime.now().toUtc();
    Session sessionFor(String sid) {
      final claims = {
        'iss': 'https://a.invalid/auth/v1',
        'sub': 'a',
        'session_id': sid,
        'aud': 'authenticated',
        'role': 'authenticated',
        'iat': now.millisecondsSinceEpoch ~/ 1000 - 3600,
        'exp': now.millisecondsSinceEpoch ~/ 1000 + 3600
      };
      final encoded =
          base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
      return fakeSession('a', access: 'header.$encoded.signature');
    }

    var session = sessionFor('11111111-1111-1111-1111-111111111111');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    var binding = OfflineSessionBinding.fromSession(
        session, 'https://a.invalid/auth/v1')!;
    final path = '${dir.path}/content.db';
    var db = await openHomeContentSnapshotDatabase(path,
        factory: databaseFactoryFfi);
    HomeContentSnapshotStore make({String project = 'https://a.invalid'}) =>
        HomeContentSnapshotStore(
            db: db,
            scope: scope,
            currentBinding: () => binding,
            project: project);
    var store = make();
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    HomeContentSnapshot value(String text, int byte) => HomeContentSnapshot([
          {'title': text}
        ], {
          'asset-v1': Uint8List.fromList([byte])
        });
    final bigBytes = Uint8List.fromList(
        List<int>.generate(3 * 1024 * 1024 + 17, (i) => i % 251));
    final bigTicket = (await store.begin('promo', isCurrent: () => true))!;
    expect(
        await store.commit(
            bigTicket,
            HomeContentSnapshot([
              {'title': 'big'}
            ], {
              'big': bigBytes
            })),
        true);
    expect((await store.read('promo', caps))!.images['big'], bigBytes);
    final rejectedTicket = (await store.begin('promo', isCurrent: () => true))!;
    expect(
        await store.commit(
            rejectedTicket,
            HomeContentSnapshot([
              {'title': 'oversized'}
            ], {
              'big': Uint8List(8 * 1024 * 1024 + 1)
            })),
        false);
    expect((await store.read('promo', caps))!.images['big'], bigBytes);
    final stale = (await store.begin('news', isCurrent: () => true))!;
    final latest = (await store.begin('news', isCurrent: () => true))!;
    expect(await store.commit(latest, value('latest', 7)), isTrue);
    expect(await store.commit(stale, value('stale', 9)), isFalse);
    var live = true;
    final interrupted = (await store.begin('news', isCurrent: () => live))!;
    live = false;
    expect(await store.commit(interrupted, value('cancelled', 10)), isFalse);
    expect((await store.read('news', caps))!.rows.single['title'], 'latest');
    final db2 = await openHomeContentSnapshotDatabase(path,
        factory: databaseFactoryFfi);
    final other = HomeContentSnapshotStore(
        db: db2,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://a.invalid');
    final oldDeny = (await store.begin('news', isCurrent: () => true))!;
    final concurrent = (await other.begin('news', isCurrent: () => true))!;
    expect(await other.commit(concurrent, value('newer', 11)), isTrue);
    expect(await store.deny(oldDeny), isTrue);
    expect(await store.read('news', caps), isNull);
    expect(
        await store.commit((await store.begin('news', isCurrent: () => true))!,
            value('newer', 11)),
        isTrue);
    final denialBeforeNewBegin =
        (await store.begin('news', isCurrent: () => true))!;
    final failedNewer = (await other.begin('news', isCurrent: () => true))!;
    expect(await store.deny(denialBeforeNewBegin), isTrue);
    expect(await other.commit(failedNewer, value('invalid', 1)), isFalse);
    expect(await store.read('news', caps), isNull);
    await db.close();
    db = await openHomeContentSnapshotDatabase(path,
        factory: databaseFactoryFfi);
    store = make();
    expect((await store.read('promo', caps))!.images['big'], bigBytes);
    expect(await store.read('news', caps), isNull);
    expect(
        await store.commit((await store.begin('news', isCurrent: () => true))!,
            value('newer', 11)),
        isTrue);
    await db2.close();
    expect(
        await store.commit((await store.begin('promo', isCurrent: () => true))!,
            value('promo', 8)),
        isTrue);
    expect((await store.read('news', caps))!.images['asset-v1'], [11]);
    expect((await store.read('promo', caps))!.rows.single['title'], 'promo');
    expect(await make(project: 'https://b.invalid').read('news', caps), isNull);
    final originalBinding = binding;
    binding = OfflineSessionBinding(
        issuer: binding.issuer,
        userId: 'a',
        sessionId: 'another',
        notBefore: binding.notBefore,
        expiresAt: binding.expiresAt);
    expect(await store.read('news', caps), isNull);
    binding = originalBinding;
    session = sessionFor('22222222-2222-2222-2222-222222222222');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    expect(await store.read('news', caps), isNull);
    expect(await store.begin('news', isCurrent: () => true), isNull);
    session = sessionFor('11111111-1111-1111-1111-111111111111');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    final captured = scope.capture()!;
    expect(scope.matchesSession(captured, session), isTrue);
    expect(
        scope.matchesSession(
            captured, sessionFor('22222222-2222-2222-2222-222222222222')),
        isFalse);
    final oldSessionTicket =
        (await store.begin('news', isCurrent: () => true))!;
    session = sessionFor('22222222-2222-2222-2222-222222222222');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await store.deny(oldSessionTicket), isFalse);
    session = sessionFor('11111111-1111-1111-1111-111111111111');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await store.deny(oldSessionTicket), isFalse);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    var barrierOpen = true;
    final denial = (await store.begin('news', isCurrent: () => barrierOpen))!;
    barrierOpen = false;
    expect(await store.commit(denial, value('late', 12)), isFalse);
    expect(await store.deny(denial), isTrue);
    await db.close();
    db = await openHomeContentSnapshotDatabase(path,
        factory: databaseFactoryFfi);
    store = make();
    expect(await store.read('news', caps), isNull);
    expect((await db.query('home_content_image')).length, 2);
    expect((await store.read('promo', caps))!.rows.single['title'], 'promo');
    await db.close();
    scope.dispose();
    await events.close();
    final resolved = await dir.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved
        .startsWith('$temp${Platform.pathSeparator}home_content_qa_')) {
      throw StateError('Unexpected test directory');
    }
    await dir.delete(recursive: true);
  });
}
