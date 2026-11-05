import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var online = false;
  var malformed = false;
  var chatsOnly = false;
  var bulkNull = false;
  const legacyAssignment = '[{"id":"legacy","title":"old"}]';
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'learning_chat_team': '[{"id":"legacy"}]',
      'learning_assign_team': legacyAssignment,
    });
    await Supabase.initialize(
        url: 'https://test.invalid',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false),
        httpClient: MockClient((request) async => bulkNull
            ? http.Response(
                request.url.path.endsWith('/chats')
                    ? '[{"id":"chat"}]'
                    : 'null',
                200,
                request: request,
                headers: {'content-type': 'application/json'})
            : online || (chatsOnly && request.url.path.endsWith('/chats'))
                ? http.Response(malformed ? '{}' : '[]', 200,
                    request: request,
                    headers: {'content-type': 'application/json'})
                : http.Response('{"message":"unavailable"}', 503,
                    request: request,
                    headers: {'content-type': 'application/json'})));
  });
  tearDownAll(() => Supabase.instance.dispose());

  test(
      'scoped mode does not read or overwrite ownerless data on network failure',
      () async {
    online = false;
    final prefs = await SharedPreferences.getInstance();
    final repository = SupabaseLearningRepository(useLegacyTeamCache: false);
    await expectLater(repository.loadChat('team'), throwsA(anything));
    await expectLater(repository.loadAssignments('team'), throwsA(anything));
    expect(prefs.getString('learning_chat_team'), '[{"id":"legacy"}]');
    expect(prefs.getString('learning_assign_team'), legacyAssignment);
  });
  test('scoped mode also does not write legacy keys on successful fetch',
      () async {
    online = true;
    final prefs = await SharedPreferences.getInstance();
    final repository = SupabaseLearningRepository(useLegacyTeamCache: false);
    expect(await repository.loadChat('team'), isEmpty);
    expect(await repository.loadAssignments('team'), isEmpty);
    await repository.saveAssignments('team', []);
    expect(prefs.getString('learning_chat_team'), '[{"id":"legacy"}]');
    expect(prefs.getString('learning_assign_team'), legacyAssignment);
  });
  test('malformed responses are errors and leave old data untouched', () async {
    online = true;
    malformed = true;
    final repository = SupabaseLearningRepository(useLegacyTeamCache: false);
    await expectLater(repository.loadChat('team'), throwsA(anything));
    await expectLater(repository.loadAssignments('team'), throwsA(anything));
    expect(
        (await SharedPreferences.getInstance())
            .getString('learning_assign_team'),
        legacyAssignment);
    malformed = false;
  });
  test('failed team RPC cannot be reported as an empty chat', () async {
    online = false;
    chatsOnly = true;
    await expectLater(
        SupabaseLearningRepository(useLegacyTeamCache: false).loadChat('team'),
        throwsA(anything));
    chatsOnly = false;
  });
  test('null bulk RPC response cannot become an empty chat snapshot', () async {
    bulkNull = true;
    await expectLater(
        SupabaseLearningRepository(useLegacyTeamCache: false).loadChat('team'),
        throwsFormatException);
    bulkNull = false;
  });
  test('default mode retains the old assignments fallback', () async {
    online = false;
    final list = await SupabaseLearningRepository().loadAssignments('team');
    expect(list.single.id, 'legacy');
  });
}
