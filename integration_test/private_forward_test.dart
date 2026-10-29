import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const login = String.fromEnvironment('E2E_LOGIN');
  const other = String.fromEnvironment('E2E_OTHER_LOGIN');
  if (!const bool.fromEnvironment('E2E_LIVE_APPROVED') ||
      !login.startsWith('e2e_') ||
      !other.startsWith('e2e_')) throw StateError('Synthetic fixture required');
  testWidgets(
      'cross-chat forward copies private bytes for a recipient outside source chat',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const base = String.fromEnvironment('SUPABASE_URL'),
        key = String.fromEnvironment('SUPABASE_ANON_KEY'),
        password = String.fromEnvironment('E2E_PASSWORD');
    await Supabase.initialize(url: base, anonKey: key);
    final sb = Supabase.instance.client;
    final recipient = SupabaseClient(base, key);
    addTearDown(() async {
      await recipient.dispose();
      await Supabase.instance.dispose();
    });
    await sb.auth
        .signInWithPassword(email: '$login@student.local', password: password);
    await recipient.auth
        .signInWithPassword(email: '$other@student.local', password: password);
    final row = await sb
        .from('chat_files')
        .select()
        .eq('id', const String.fromEnvironment('E2E_FILE_ID'))
        .single();
    final destination = await sb.rpc('ensure_dm_chat',
        params: {'p_partner': recipient.auth.currentUser!.id}) as String;
    final payload = ForwardPayload(fromChatId: row['chat_id'], items: [
      ForwardItem(
          messageId: row['message_id'],
          authorId: sb.auth.currentUser!.id,
          authorName: 'E2E',
          at: DateTime.now(),
          text: 'E2E forwarded private',
          files: [
            ForwardFileRef(
                id: row['id'],
                url: row['file_url'],
                name: row['file_name'],
                type: row['file_type'],
                size: row['file_size'])
          ])
    ]);
    await ForwardOutbox.putForChat(
        chatId: destination,
        text: payload.encodeForText(),
        fileUrls: [row['file_url']],
        fileIds: [row['id']]);
    await tester.pumpWidget(MaterialApp(
        home: DirectChatScreen(
            peerId: recipient.auth.currentUser!.id,
            peerName: 'E2E recipient',
            initialChatId: destination)));
    for (var i = 0; i < 900; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final finder = find.byTooltip('Отправить');
      if (finder.evaluate().isNotEmpty) {
        final button =
            find.ancestor(of: finder.first, matching: find.byType(IconButton));
        if (button.evaluate().isNotEmpty &&
            tester.widget<IconButton>(button.first).onPressed != null) break;
      }
    }
    await tester.tap(find.byTooltip('Отправить'));
    List rows = [];
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      rows = await recipient
          .from('chat_files')
          .select()
          .eq('chat_id', destination);
      if (rows.any((r) => r['message_id'] != null)) break;
    }
    final forwarded = rows.where((r) => r['message_id'] != null).last;
    expect(forwarded['file_key'], isNot(row['file_key']));
    final access = await recipient.functions.invoke('chat-file-access',
        body: {'action': 'resolve', 'key': forwarded['file_key']});
    final bytes = await http.get(Uri.parse(access.data['url']));
    expect(bytes.statusCode, 200);
    expect(bytes.body, 'E2E private attachment fixture');
    await expectLater(
        recipient.functions.invoke('chat-file-access',
            body: {'action': 'resolve', 'key': row['file_key']}),
        throwsA(isA<FunctionException>()));
    final messages = await recipient.rpc('get_chat_messages_page',
        params: {'p_chat_id': destination}) as List;
    final message =
        messages.singleWhere((m) => m['id'] == forwarded['message_id']);
    expect(message['text'].toString(), contains(forwarded['file_url']));
    expect(message['text'].toString(), isNot(contains(row['file_url'])));
    await sb
        .from('chat_files')
        .update({'is_deleted': true}).eq('id', row['id']);
    try {
      expect(
          (await recipient.functions.invoke('chat-file-access',
                  body: {'action': 'resolve', 'key': forwarded['file_key']}))
              .status,
          200);
    } finally {
      await sb
          .from('chat_files')
          .update({'is_deleted': false}).eq('id', row['id']);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
