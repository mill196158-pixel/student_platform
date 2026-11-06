import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/chat_tab.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

class _Repo implements LearningRepository {
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('team chat suppresses automatic mark-read only in QA', (tester) async {
    await initializeDateFormatting('ru');
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    const keyboard = MethodChannel('keyboard_image_channel');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    messenger.setMockMethodCallHandler(keyboard, (_) async => null);
    var markCalls = 0, chatReads = 0;
    await tester.runAsync(() => Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/mark_chat_read')) markCalls++;
        if (request.url.path.endsWith('/chats')) {
          chatReads++;
          return http.Response('{"id":"chat"}', 200, request: request,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('[]', 200, request: request,
            headers: {'content-type': 'application/json'});
      })));
    await signInWithFileSession(Supabase.instance.client, 'owner', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    const team = Team(id: 'team', name: 'Team', teacher: '', groupCode: '', icon: 'T');
    final cubit = TeamCubit(team, repository: _Repo());
    cubit.emit(TeamState(team: team, chatHasSnapshot: true, chat: [Message(id: 'm',
      chatId: 'chat', authorId: 'owner', authorLogin: '', authorName: 'Author',
      text: 'Team message', at: DateTime.utc(2026))]));
    await tester.pumpWidget(MaterialApp(home: BlocProvider.value(value: cubit,
      child: const Scaffold(body: ChatTab()))));
    for (var i=0; i<30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(find.text('Team message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i=0; i<30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(chatReads, greaterThan(0));
    expect(markCalls, qaNoAutomaticWrites ? 0 : greaterThan(0));
    await cubit.close();
    messenger.setMockMethodCallHandler(links, null);
    messenger.setMockMethodCallHandler(keyboard, null);
  });
}
