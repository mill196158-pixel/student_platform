import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/in_memory_realtime_socket.dart';

class _Assignments implements LearningRepository {
  bool done = false;
  int loads = 0;

  @override
  Future<List<Message>> loadChat(String teamId) async => [];

  @override
  Future<List<Assignment>> loadAssignments(String teamId) async {
    loads++;
    return [
      Assignment(
          id: 'task',
          title: 'Survey',
          description: '',
          published: true,
          votes: 0,
          completedByMe: done,
          createdBy: 'staff',
          createdAt: DateTime.utc(2026))
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('the open team refreshes updated, removed and inserted receipts',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:1',
        publishableKey: 'test',
        httpClient: MockClient((_) async => http.Response('[]', 200,
            headers: {'content-type': 'application/json'})),
        realtimeClientOptions: RealtimeClientOptions(
            transport: (_, __) => InMemoryRealtimeSocket()),
        authOptions: const FlutterAuthClientOptions(
            detectSessionInUri: false,
            autoRefreshToken: false,
            localStorage: EmptyLocalStorage()));
    addTearDown(() => Supabase.instance.dispose());
    final repo = _Assignments();
    final cubit = TeamCubit(
        const Team(
            id: 'team', name: 'Survey', teacher: '', groupCode: '', icon: ''),
        repository: repo);
    addTearDown(cubit.close);
    await cubit.init();
    if (cubit.state.assignments.isEmpty) {
      await cubit.stream.firstWhere((state) => state.assignments.isNotEmpty);
    }
    expect(cubit.state.doneAssignmentIds, isEmpty);
    final channel = Supabase.instance.client
        .getChannels()
        // The pinned SDK exposes the channel topic for diagnostics.
        // ignore: invalid_use_of_internal_member
        .singleWhere((ch) => ch.topic == 'realtime:public:assignment_done');
    for (final event in ['UPDATE', 'DELETE', 'INSERT']) {
      final before = repo.loads;
      final done = event != 'DELETE';
      repo.done = done;
      channel.trigger(event, {
        'schema': 'public',
        'table': 'assignment_done',
        'type': event,
        'commit_timestamp': '2026-11-25T12:00:00Z',
        'columns': [
          {'name': 'done', 'type': 'bool'}
        ],
        if (event != 'DELETE') 'record': {'done': true},
        if (event != 'INSERT') 'old_record': {'done': event == 'DELETE'}
      });
      expect(repo.loads, before + 1,
          reason: '$event must request a new server snapshot');
      if (cubit.state.doneAssignmentIds.contains('task') != done) {
        await cubit.stream.firstWhere(
            (state) => state.doneAssignmentIds.contains('task') == done);
      }
      expect(cubit.state.doneAssignmentIds, done ? {'task'} : isEmpty);
    }
  });
}
