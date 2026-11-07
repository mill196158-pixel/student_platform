import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/deadline_projection_store.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'home_progressive_loading_test.dart' show signIn;

class _Repository extends ChatGroupActionsRepository {
  _Repository(SupabaseClient client, DeadlineProjectionStore store, String project)
      : super(client: client, project: project, openDeadlineStore: () async => store);
  final pending = Completer<List<GroupActionDeadline>>();
  @override Future<List<GroupActionDeadline>> listMyGroupActionDeadlines({DateTime? from, DateTime? to}) => pending.future;
}
GroupActionDeadline action(String id) => GroupActionDeadline(eventType: 'collection_deadline',
    entityId: id, title: id, occursAt: DateTime(2026, 11, 5));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  sqfliteFfiInit();
  late DeadlineProjectionStore store;
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('deadline-consumer-');
    store = await DeadlineProjectionStore.open(databasePath: '${dir.path}/snapshots.db', factory: databaseFactoryFfi);
  });
  tearDown(() async { await store.db.close(); });
  for (final returnA in [false, true]) {
    test('old response cannot write after A to B, return to A=$returnA', () async {
      final client = SupabaseClient('https://example.invalid', 'test', authOptions: const AuthClientOptions(autoRefreshToken: false));
      await signIn(client, 'owner-a');
      final repo = _Repository(client, store, 'https://example.invalid');
      final result = repo.listMyGroupActionDeadlinesCached(strict: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await signIn(client, 'owner-b');
      if (returnA) await signIn(client, 'owner-a');
      repo.pending.complete([action('old')]);
      await expectLater(result, throwsStateError);
      expect(await repo.peekCachedDeadlines(), isEmpty);
      await client.dispose();
    });
  }
  test('confirmed online snapshot works offline and is project scoped', () async {
    final a = SupabaseClient('https://a.invalid', 'test', authOptions: const AuthClientOptions(autoRefreshToken: false));
    final b = SupabaseClient('https://b.invalid', 'test', authOptions: const AuthClientOptions(autoRefreshToken: false));
    await signIn(a, 'same'); await signIn(b, 'same');
    final repoA = _Repository(a, store, 'https://a.invalid');
    final repoB = _Repository(b, store, 'https://b.invalid');
    final result = repoA.listMyGroupActionDeadlinesCached(strict: true);
    repoA.pending.complete([action('only-a')]);
    expect((await result).single.title, 'only-a');
    expect((await repoA.peekCachedDeadlines()).single.title, 'only-a');
    expect(await repoB.peekCachedDeadlines(), isEmpty);
    await a.dispose(); await b.dispose();
  });
  for (final returnA in [false, true]) {
    test('delete marks original owner dirty before delayed RPC, return to A=$returnA', () async {
      final started = Completer<void>(), release = Completer<void>();
      final client = SupabaseClient('https://example.invalid', 'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            started.complete(); await release.future;
            return http.Response('{}', 200, request: request, headers: {'content-type': 'application/json'});
          }));
      await signIn(client, 'owner-a');
      final repo = _Repository(client, store, 'https://example.invalid');
      final warm = repo.listMyGroupActionDeadlinesCached(strict: true);
      repo.pending.complete([action('old')]); await warm;
      final deleting = repo.deleteGroupAction(kind: 'collection', entityId: 'old');
      await started.future;
      expect(await repo.peekCachedDeadlines(), isEmpty);
      await signIn(client, 'owner-b');
      if (returnA) await signIn(client, 'owner-a');
      release.complete(); await deleting;
      await signIn(client, 'owner-a');
      expect(await repo.peekCachedDeadlines(), isEmpty);
      expect(await store.revision('https://example.invalid', 'owner-b'), 0);
      await client.dispose();
    });
  }
}
