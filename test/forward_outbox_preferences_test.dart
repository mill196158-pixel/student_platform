import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_preferences.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'preferences adapter preserves legacy entry until versioned acknowledgement',
      () async {
    const key = 'forward_outbox_a_chat';
    const raw = '{"text":"legacy","files":["file"]}';
    SharedPreferences.setMockInitialValues(
        {key: raw, 'unrelated': 'untouched'});
    final prefs = await SharedPreferences.getInstance();
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final store = ForwardOutboxStore(
        scope,
        ForwardOutboxCoordinator(
            PreferencesForwardOutboxStorage(preferences: () async => prefs)));
    final entry = (await store.peek(scope.capture()!, 'chat'))!;
    expect(entry.text, 'legacy');
    expect(prefs.getString(key), raw);
    expect(await store.acknowledge(entry), ForwardAcknowledgeResult.removed);
    expect(prefs.containsKey(key), isFalse);
    expect(prefs.getString('unrelated'), 'untouched');
    scope.dispose();
    await events.close();
  });
}
