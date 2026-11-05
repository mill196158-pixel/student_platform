import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/legacy_user_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('only the current owner can read the legacy profile', () async {
    SharedPreferences.setMockInitialValues({'user': jsonEncode({'id': 'a', 'name': 'A'})});
    Session? current = fakeSession('a');
    expect((await LegacyUserCache.read(currentSession: () => current))?['name'], 'A');
    current = fakeSession('b');
    expect(await LegacyUserCache.read(currentSession: () => current), isNull);
    current = null;
    expect(await LegacyUserCache.read(currentSession: () => current), isNull);
  });

  test('delayed preferences cannot return data after account or token changes', () async {
    SharedPreferences.setMockInitialValues({'user': jsonEncode({'id': 'a'})});
    for (final next in [fakeSession('b'), fakeSession('a', access: 'new')]) {
      Session? current = fakeSession('a');
      final delayed = Completer<SharedPreferences>();
      final result = LegacyUserCache.read(currentSession: () => current,
          preferences: () => delayed.future);
      current = next;
      delayed.complete(await SharedPreferences.getInstance());
      expect(await result, isNull);
    }
  });
}
