import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const approved = bool.fromEnvironment('E2E_LIVE_APPROVED');
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  const login = String.fromEnvironment('E2E_LOGIN');
  const peerLogin = String.fromEnvironment('E2E_PEER_LOGIN');
  const password = String.fromEnvironment('E2E_PASSWORD');
  if (!approved ||
      url != 'https://gwdanmwluhrcfxbnplwd.supabase.co' ||
      !login.startsWith('e2e_') ||
      !peerLogin.startsWith('e2e_') ||
      password.isEmpty ||
      key.isEmpty) {
    throw StateError('Explicit approved synthetic live fixture required');
  }
  testWidgets('real DM screen sends once and receives peer reply',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: url, anonKey: key);
    final me = Supabase.instance.client;
    final peer = SupabaseClient(url, key);
    addTearDown(() async {
      await peer.dispose();
      await Supabase.instance.dispose();
    });
    await me.auth
        .signInWithPassword(email: '$login@student.local', password: password);
    await peer.auth.signInWithPassword(
        email: '$peerLogin@student.local', password: password);
    final peerId = peer.auth.currentUser!.id;
    final chat =
        await me.rpc('ensure_dm_chat', params: {'p_partner': peerId}) as String;
    await me.rpc('block_user', params: {'p_user_id': peerId});
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light().data,
        home: DirectChatScreen(
            peerId: peerId, peerName: 'E2E Synthetic', initialChatId: chat)));
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (finder.evaluate().isNotEmpty) return;
      }
      fail('Expected chat UI not found: $finder');
    }

    await waitFor(find.text('Разблокировать'));
    expect(find.byType(EditableText), findsNothing);
    final unblock = find.widgetWithText(TextButton, 'Разблокировать');
    for (var i = 0; i < 300; i++) {
      if (unblock.evaluate().isNotEmpty &&
          tester.widget<TextButton>(unblock).onPressed != null) break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<TextButton>(unblock).onPressed, isNotNull);
    await tester.tap(find.text('Разблокировать'));
    await waitFor(find.byType(EditableText));
    final text = 'E2E UI ${DateTime.now().microsecondsSinceEpoch}';
    await tester.enterText(find.byType(EditableText).first, text);
    await tester.tap(find.byTooltip('Отправить'));
    // A second immediate press must not duplicate an in-flight message.
    await tester.tap(find.byTooltip('Отправить'));
    List rows = [];
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      rows = await peer
          .rpc('get_chat_messages_page', params: {'p_chat_id': chat}) as List;
      if (rows.any((r) => r['text'] == text)) break;
    }
    expect(rows.where((r) => r['text'] == text).length, 1);
    final reply = '$text reply';
    await peer.rpc('send_message_in_chat_with_files',
        params: {'p_chat_id': chat, 'p_text': reply, 'p_file_ids': <String>[]});
    await waitFor(find.text(reply));
    expect(find.text(reply), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
