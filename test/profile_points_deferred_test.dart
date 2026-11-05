import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'home_progressive_loading_test.dart' show signIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var pointsCalls = 0;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'user':
          jsonEncode({'id': 'owner', 'name': 'Тест', 'group_name': 'Группа'}),
    });
    await Supabase.initialize(
      url: 'https://profile.test',
      publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false, detectSessionInUri: false),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('get_my_points_summary')) {
          pointsCalls++;
          return http.Response(
              '{"user_id":"owner","balance":3,"entries":[]}', 200,
              request: request, headers: {'content-type': 'application/json'});
        }
        final body = request.url.path.endsWith('/users') ? 'null' : '[]';
        return http.Response(body, 200,
            request: request, headers: {'content-type': 'application/json'});
      }),
    );
    await signIn(Supabase.instance.client, 'owner');
  });
  tearDownAll(() => Supabase.instance.dispose());

  testWidgets('profile never flashes or loads deferred points', (tester) async {
    final active = ValueNotifier<bool>(false);
    addTearDown(active.dispose);
    await tester
        .pumpWidget(MaterialApp(home: ProfileScreen(activeListenable: active)));
    expect(find.textContaining('балл'), findsNothing);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('балл'), findsNothing);
    }
    active.value = true;
    await tester.pump();
    final refresh = find.byTooltip('Обновить');
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('балл'), findsNothing);
    }
    expect(pointsCalls, 0);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
