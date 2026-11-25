import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/data/personal_diary_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('reads own key-only receipts and respects explicit legacy flags',
      () async {
    var requests = 0;
    final client = SupabaseClient('http://127.0.0.1:55321', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      requests++;
      expect(request.url.path, '/rest/v1/assignment_done');
      expect(request.url.queryParameters['user_id'], 'eq.student');
      expect(
          request.url.queryParameters['assignment_id'], 'in.("a","b","c","d")');
      expect(request.url.queryParameters['select'], '*');
      return http.Response(
          jsonEncode([
            {'assignment_id': 'a', 'user_id': 'student'},
            {'assignment_id': 'b', 'user_id': 'student', 'done': null},
            {'assignment_id': 'c', 'user_id': 'student', 'done': false},
            {'assignment_id': 'd', 'user_id': 'student', 'done': true},
          ]),
          200,
          request: request,
          headers: {'content-type': 'application/json'});
    }));
    addTearDown(client.dispose);
    final diary = PersonalDiaryService(client: client);
    expect(await diary.loadCompletedAssignmentIds('', ['a']), isEmpty);
    expect(await diary.loadCompletedAssignmentIds('student', []), isEmpty);
    expect(
        await diary.loadCompletedAssignmentIds('student', ['a', 'b', 'c', 'd']),
        {'a', 'b', 'd'});
    expect(requests, 1);
  });
}
