import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/learning/draft_session_owner.dart';
import 'package:student_platform/src/ui/learning/account_draft_store.dart';
import 'package:student_platform/src/ui/learning/draft_recovery_journal.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FailOnceStore extends InMemorySharedPreferencesStore {
  _FailOnceStore() : super.empty();
  int attempts = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.startsWith('flutter.account_draft_v1_') && ++attempts == 1) return false;
    return super.setValue(type, key, value);
  }
}

class _SlowJournal extends DraftRecoveryJournal {
  _SlowJournal(Future<Database> Function() open) : super(open: open);
  final committed = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> appendOperation({required String project, required String owner,
      required String sessionId, required String conversation,
      required Map<String, dynamic> draft, required bool Function() permitted,
      String? streamId}) async {
    final result = await super.appendOperation(project: project, owner: owner,
        sessionId: sessionId, conversation: conversation, draft: draft,
        permitted: permitted, streamId: streamId);
    if (result != null) {
      committed.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) open.overrideFor(
      OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  sqfliteFfiInit();
  test('project issuer is identical with and without a trailing slash', () {
    expect(normalizeDraftProject('https://example.test/'), 'https://example.test');
    expect(normalizeDraftProject('https://example.test'), 'https://example.test');
  });
  test('lease accepts same-SID refresh, refuses logout and later sign-in', () async {
    final previousStore = SharedPreferencesStorePlatform.instance;
    final platform = _FailOnceStore();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = platform;
    addTearDown(() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previousStore;
    });
    await Supabase.initialize(url: SupabaseConfig.url, publishableKey: 'test',
        httpClient: MockClient((request) async => http.Response('{}', 200)),
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final client = Supabase.instance.client;
    const uid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const sid = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    String session(String nonce) => jsonEncode({
      'access_token': '${part({'alg': 'none'})}.${part({
        'iss': '${SupabaseConfig.url}/auth/v1', 'sub': uid, 'session_id': sid,
        'aud': 'authenticated', 'role': 'authenticated', 'iat': now,
        'exp': now + 3600, 'nonce': nonce,
      })}.sig',
      'refresh_token': 'test', 'token_type': 'bearer', 'expires_at': now + 3600,
      'user': {'id': uid, 'aud': 'authenticated', 'app_metadata': {},
        'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'},
    });
    await client.auth.setInitialSession(session('one'));
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, client.auth.currentSession));
    final lease = DraftSessionOwner.capture(scope)!;
    expect(lease.canRead, isTrue);
    final store = AccountDraftStore();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final journal = DraftRecoveryJournal(open: () async => db);
    var errors = 0, journalErrors = 0;
    final writer = AccountDraftWriter(store, lease, 'conversation',
        onFailure: () => errors++, onJournalFailure: () => journalErrors++, journal: journal);
    writer.save({'text': 'saved', 'files': [], 'reply': null});
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(platform.attempts, 2);
    expect(errors, 0);
    expect((await store.read(SupabaseConfig.url, uid, 'conversation', () => true))?['text'], 'saved');
    final slowJournal = _SlowJournal(() async => db);
    final slowWriter = AccountDraftWriter(store, lease, 'slow-conversation', journal: slowJournal);
    await client.auth.signOut(scope: SignOutScope.local);
    slowWriter.save({'text': 'slow receipt', 'files': [], 'reply': null});
    await slowJournal.committed.future;
    await client.auth.setInitialSession(session('one-refresh'));
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, client.auth.currentSession));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await store.read(SupabaseConfig.url, uid, 'slow-conversation', () => true))?['text'], 'slow receipt');
    slowJournal.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await journal.pending(project: SupabaseConfig.url, owner: uid,
        conversation: 'slow-conversation', permitted: () => true), isEmpty,
        reason: 'late journal receipt resolves only after identical canonical save');
    slowWriter.close();
    await client.auth.setInitialSession(session('two'));
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, client.auth.currentSession));
    expect(lease.canSave, isTrue);
    await client.auth.signOut(scope: SignOutScope.local);
    expect(lease.canJournal, isTrue);
    writer.save({'text': 'saved during gap', 'files': [], 'reply': null});
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final gapRows = await journal.pending(project: SupabaseConfig.url, owner: uid,
        conversation: 'conversation', permitted: () => true);
    expect(gapRows.single['draft'], containsPair('text', 'saved during gap'));
    await client.auth.setInitialSession(session('three'));
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, client.auth.currentSession));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect((await store.read(SupabaseConfig.url, uid, 'conversation', () => true))?['text'],
        'saved during gap');
    expect(await journal.pending(project: SupabaseConfig.url, owner: uid,
        conversation: 'conversation', permitted: () => true), isEmpty,
        reason: 'a matching confirmed canonical snapshot resolves its journal entry');
    await client.auth.signOut(scope: SignOutScope.local);
    for (var i = 0; i < 30; i++) {
      writer.save({'text': 'gap edit $i', 'files': [], 'reply': null});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final latestStream = await journal.pending(project: SupabaseConfig.url, owner: uid,
        conversation: 'conversation', permitted: () => true);
    expect(latestStream, hasLength(1));
    expect(latestStream.single['draft'], containsPair('text', 'gap edit 29'));
    for (var i = 1; i < DraftRecoveryJournal.maxOwnerEntries; i++) {
      expect(await journal.append(project: SupabaseConfig.url, owner: uid,
          sessionId: sid, conversation: 'conversation', draft: {'text': 'entry $i'},
          permitted: () => true), isTrue);
    }
    writer.save({'text': 'still held in memory', 'files': [], 'reply': null});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(journalErrors, 0, reason: 'a newer complete snapshot replaces only the same writer stream');
    final fullRows = await journal.pending(project: SupabaseConfig.url, owner: uid,
        conversation: 'conversation', permitted: () => true);
    expect(fullRows, hasLength(DraftRecoveryJournal.maxOwnerEntries));
    expect(fullRows.any((row) => (row['draft'] as Map)['text'] == 'still held in memory'), isTrue);
    await client.auth.setInitialSession(session('four'));
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, client.auth.currentSession));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await store.read(SupabaseConfig.url, uid, 'conversation', () => true))?['text'],
        'still held in memory');
    scope.invalidateForSignOut();
    expect(lease.canRead, isFalse);
    expect(lease.canSave, isFalse);
    writer.close();
    events.add(AuthState(AuthChangeEvent.signedOut, null));
    events.add(AuthState(AuthChangeEvent.signedIn, client.auth.currentSession));
    expect(lease.canSave, isFalse);
    scope.dispose();
    await events.close();
  });
}
