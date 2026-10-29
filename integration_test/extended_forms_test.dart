import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/chats/archive_screen.dart';
import 'package:student_platform/src/ui/info/propose_vacancy_screen.dart';
import 'package:student_platform/src/ui/info/my_vacancy_submissions_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/collections/create_collection_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/create_topic_selection_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_review_screen.dart';

// Rendering, scrolling and draft-input coverage. Publishing/role checks are
// separate acceptance cases; this test never claims to cover those actions.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const login = String.fromEnvironment('E2E_LOGIN');
  if (!const bool.fromEnvironment('E2E_LIVE_APPROVED') ||
      url != 'https://gwdanmwluhrcfxbnplwd.supabase.co' ||
      !login.startsWith('e2e_')) {
    throw StateError('Approved synthetic fixture required');
  }
  testWidgets('additional Android forms render, scroll and accept draft input',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: url,
      anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
    );
    final client = Supabase.instance.client;
    await client.auth.signInWithPassword(
      email: '$login@student.local',
      password: const String.fromEnvironment('E2E_PASSWORD'),
    );
    addTearDown(() => Supabase.instance.dispose());
    // Use an existing synthetic DM only for draft context; do not publish
    // academic content to a DM or touch an actual student group.
    final rows = await client
        .from('chat_members')
        .select('chat_id')
        .eq('user_id', client.auth.currentUser!.id)
        .limit(1);
    expect(rows, isNotEmpty);
    final chat = rows.first['chat_id'] as String;
    final screens = <Widget>[
      const ArchiveScreen(),
      const MyVacancySubmissionsScreen(),
      const ProposeVacancyScreen(),
      const CreateCollectionScreen(),
      CreateTopicSelectionScreen(chatId: chat),
      TopicListReviewScreen(chatId: chat, title: 'E2E draft'),
    ];
    for (final screen in screens) {
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(screen.runtimeType),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('ru'), Locale('en')],
        locale: const Locale('ru'),
        home: screen,
      ));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(screen.runtimeType), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: '${screen.runtimeType} load');
      final fields = find.byType(TextFormField);
      if (fields.evaluate().isNotEmpty) {
        await tester.ensureVisible(fields.first);
        await tester.enterText(fields.first, 'E2E draft');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump(const Duration(milliseconds: 400));
      }
      final scrollable = find.byType(Scrollable);
      if (scrollable.evaluate().isNotEmpty) {
        for (var i = 0; i < 6; i++) {
          await tester.drag(scrollable.first, const Offset(0, -450));
          await tester.pump(const Duration(milliseconds: 350));
          expect(tester.takeException(), isNull,
              reason: '${screen.runtimeType} scroll $i');
        }
      }
      debugPrint('E2E form render/scroll PASS: ${screen.runtimeType}');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
}
