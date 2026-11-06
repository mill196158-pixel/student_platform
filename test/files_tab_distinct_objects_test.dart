import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/files_tab.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Files tab retains distinct objects with equal names and sizes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => Supabase.initialize(
      url: 'https://files-test.invalid',
      publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false, detectSessionInUri: false),
      httpClient: MockClient((request) async =>
          http.Response('[]', 200, request: request)),
    ));
    addTearDown(() async => Supabase.instance.dispose());
    const team = Team(id: 'team', name: 'Team', teacher: '', groupCode: '', icon: '');
    final cubit = TeamCubit(team);
    addTearDown(cubit.close);
    ChatFile file(String id, String key, String url) => ChatFile(
      id: id, chatId: 'chat', messageId: 'message',
      fileName: 'same.pdf', fileKey: key, fileUrl: url,
      fileType: 'application/pdf', fileSize: 987877,
      uploadedBy: 'user', uploadedAt: DateTime.utc(2026),
    );
    const base = 'https://studentsplatform.storage.yandexcloud.net/';
    final files = [
      file('a', 'chats/test/First.pdf', '${base}chats/test/First.pdf'),
      file('b', 'chats/test/second.pdf', '${base}chats/test/second.pdf'),
      file('c', 'chats/test/first.pdf', '${base}chats/test/first.pdf'),
      file('a-repeat', '', '${base}chats/test/First.pdf'),
    ];
    final message = Message(id: 'message', chatId: 'chat', authorId: 'user',
      authorLogin: '', authorName: 'User', text: '', at: DateTime.utc(2026),
      attachments: files);
    cubit.emit(TeamState(team: team, chat: [message], chatHasSnapshot: true));
    await tester.pumpWidget(MaterialApp(home: BlocProvider.value(
      value: cubit, child: const Scaffold(body: FilesTab(isActive: false)))));
    await tester.tap(find.text('Файлы'));
    await tester.pump();
    expect(find.text('same.pdf'), findsNWidgets(3),
      reason: 'different keys are distinct, including case; the same URL/key is one object');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('primary rows use case-sensitive keys and merge a message alias', () {
    const base = 'https://studentsplatform.storage.yandexcloud.net/';
    Map<String, Object> row(String id, String key) => {
      'id': id, 'chat_id': 'chat', 'message_id': 'message',
      'file_name': 'same.pdf', 'file_key': key, 'file_url': '$base$key',
      'file_type': 'application/pdf', 'file_size': 987877,
      'uploaded_by': 'user', 'uploaded_at': '2026-01-01T00:00:00Z',
      'is_deleted': false,
    };
    final rows = [row('one', 'chats/test/Case.pdf'), row('two', 'chats/test/case.pdf')];
    final alias = ChatFile.fromJson({...rows.first, 'id': 'alias', 'file_key': ''});
    final result = mergeFilesByObjectIdentity(
        rows.map((row) => ChatFile.fromJson(row)), [alias]);
    expect(result.map((file) => file.id), ['one', 'two'],
      reason: 'both case-distinct source rows survive, and the message alias is merged');
  });

  test('conflicting or absent identities are not collapsed by name', () {
    const base = 'https://studentsplatform.storage.yandexcloud.net/';
    ChatFile file(String id, String key, String url) => ChatFile(
      id: id, chatId: 'chat', messageId: null, fileName: 'same.pdf', fileKey: key,
      fileUrl: url, fileType: 'application/pdf', fileSize: 20,
      uploadedBy: 'user', uploadedAt: DateTime.utc(2026),
    );
    final rows = [
      file('a', 'chats/test/a.pdf', '${base}chats/test/a.pdf'),
      file('b', 'chats/test/a.pdf', '${base}chats/test/b.pdf'),
      file('', '', ''),
      file('', '', ''),
    ];
    expect(mergeFilesByObjectIdentity(rows, const []), hasLength(4));
  });

  test('unverified URLs do not collapse against a key or another URL', () {
    ChatFile file(String id, String url) => ChatFile(
      id: id, chatId: 'chat', messageId: null, fileName: 'same.pdf',
      fileKey: 'chats/test/same.pdf', fileUrl: url,
      fileType: 'application/pdf', fileSize: 20,
      uploadedBy: 'user', uploadedAt: DateTime.utc(2026),
    );
    final rows = [
      file('key-only', ''),
      file('first', 'https://other.test/first.pdf'),
      file('second', 'https://other.test/second.pdf'),
    ];
    expect(mergeFilesByObjectIdentity(rows, const []), hasLength(3));
  });
}
