import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cold_start_session_test.dart' show sessionFixture;

class _Repository implements LearningRepository {
  final result = Completer<Message?>();
  @override
  Future<Message?> loadMessageById(String teamId, String messageId) =>
      result.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://test.invalid',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false));
    await Supabase.instance.client.auth.setInitialSession(jsonEncode(
        sessionFixture(DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000)));
  });
  tearDownAll(() => Supabase.instance.dispose());

  test('late refresh cannot insert message after owner scope invalidates',
      () async {
    final repo = _Repository();
    final cubit = TeamCubit(
        const Team(
            id: 'team-test',
            name: 'Team',
            teacher: '',
            groupCode: '',
            icon: ''),
        repository: repo);
    addTearDown(cubit.close);
    var current = true;
    final pending =
        cubit.refreshMessageById('message', isCurrent: () => current);
    current = false;
    repo.result.complete(Message(
        id: 'message',
        chatId: 'chat',
        authorId: 'author',
        authorLogin: '',
        authorName: '',
        text: 'old',
        at: DateTime.utc(2026)));
    await pending;
    expect(cubit.state.chat, isEmpty);
  });
}
