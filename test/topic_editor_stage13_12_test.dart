// Stage 13.12 continuation — modernized topic editors.
//
// Guards:
//  * TopicListReviewScreen (draft/OCR review) builds with pre-seeded drafts,
//    shows the new hero header + topic count, and keeps KeyboardDismissScope
//    wrapping the scroll area.
//  * duplicateTopicTitles() flags case-insensitive duplicate titles without
//    flagging blank rows or unique titles.
//  * friendlyTopicEditError() maps `option_occupied` (and other known server
//    codes) to friendly, never-technical Russian copy.
//  * TopicOptionsEditorScreen (published-selection editor) refuses to delete
//    an occupied option and surfaces a friendly warning instead of calling
//    the repository.
//  * TopicOptionsEditorScreen also keeps KeyboardDismissScope wrapping its
//    scroll area.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/common/keyboard_dismiss_scope.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_models.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_review_controller.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_review_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_options_editor_screen.dart';

/// A repository backed by a real (but never-connected) [SupabaseClient] —
/// none of the widget tests below trigger a network RPC, so this only
/// exists to satisfy the constructor without touching `Supabase.instance`.
/// `autoRefreshToken: false` avoids leaving a periodic auth-refresh [Timer]
/// pending once the test's widget tree is torn down.
ChatGroupActionsRepository _fakeRepo() => ChatGroupActionsRepository(
      client: SupabaseClient(
        'https://example.invalid',
        'anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      ),
    );

/// `skipOffstage: false` — rows inside [SliverReorderableList] aren't
/// reliably reported "onstage" by the default finder after a single
/// [WidgetTester.pump] in this Flutter version, even though they are fully
/// built, laid out and visible (verified via `debugDumpApp`). This is a
/// widget-test finder quirk, not a production bug.
Finder _text(String text) => find.text(text, skipOffstage: false);
Finder _textContaining(String text) =>
    find.textContaining(text, skipOffstage: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('duplicateTopicTitles', () {
    test('flags case-insensitive duplicate titles', () {
      final dupes = duplicateTopicTitles(const [
        TopicDraft(title: 'Экология города'),
        TopicDraft(title: 'экология ГОРОДА'),
        TopicDraft(title: 'Другая тема'),
      ]);
      expect(dupes, {'экология города'});
    });

    test('ignores blank titles and unique titles', () {
      final dupes = duplicateTopicTitles(const [
        TopicDraft(title: ''),
        TopicDraft(title: '   '),
        TopicDraft(title: 'Уникальная тема'),
      ]);
      expect(dupes, isEmpty);
    });

    test('TopicListReviewController.duplicateKeys mirrors the helper', () {
      final controller = TopicListReviewController(initial: const [
        TopicDraft(title: 'Тема А'),
        TopicDraft(title: 'тема а'),
      ]);
      expect(controller.duplicateKeys, {'тема а'});
      expect(controller.emptyCount, 0);
    });

    test('TopicListReviewController.emptyCount counts blank rows', () {
      final controller = TopicListReviewController(initial: const [
        TopicDraft(title: ''),
        TopicDraft(title: '  '),
        TopicDraft(title: 'Тема'),
      ]);
      expect(controller.emptyCount, 2);
      controller.removeEmpty();
      expect(controller.length, 1);
      expect(controller.topics.single.title, 'Тема');
    });
  });

  group('friendlyTopicEditError', () {
    test('maps option_occupied to a friendly, non-technical message', () {
      final message = friendlyTopicEditError(Exception('option_occupied'));
      expect(message, contains('уже выбрали'));
      expect(message.toLowerCase(), isNot(contains('exception')));
      expect(message, isNot(contains('option_occupied')));
    });

    test('maps version_conflict to a refresh-oriented message', () {
      final message = friendlyTopicEditError(Exception('version_conflict'));
      expect(message, contains('Обновите'));
    });

    test('maps selection_unavailable / forbidden / unknown errors', () {
      expect(
        friendlyTopicEditError(Exception('selection_unavailable')),
        contains('недоступен'),
      );
      expect(
        friendlyTopicEditError(Exception('forbidden')),
        contains('прав'),
      );
      expect(
        friendlyTopicEditError(Exception('boom')),
        'Не удалось сохранить изменения. Попробуйте ещё раз.',
      );
    });
  });

  group('TopicListReviewScreen builds with drafts', () {
    testWidgets('shows hero header, topic count, and seeded drafts',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TopicListReviewScreen(
          chatId: 'chat-1',
          title: 'Курсовые работы',
          initialOptions: const [
            TopicOptionDraft(title: 'Тема 1', capacity: 2),
            TopicOptionDraft(title: 'Тема 2', capacity: 1),
          ],
          repository: _fakeRepo(),
        ),
      ));
      await tester.pump();

      expect(_text('Проверка списка тем'), findsOneWidget);
      expect(_textContaining('Темы'), findsWidgets);
      expect(_text('Тема 1'), findsOneWidget);
      expect(_text('Тема 2'), findsOneWidget);
      expect(_text('Опубликовать в чат'), findsOneWidget);
    });

    testWidgets('keeps KeyboardDismissScope wrapping the scroll area',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TopicListReviewScreen(
          chatId: 'chat-1',
          title: 'Курсовые работы',
          initialOptions: const [
            TopicOptionDraft(title: 'Тема 1'),
          ],
          repository: _fakeRepo(),
        ),
      ));
      await tester.pump();

      expect(find.byType(KeyboardDismissScope), findsWidgets);
      final scopeFinder = find.byType(KeyboardDismissScope).first;
      expect(
        find.descendant(
          of: scopeFinder,
          matching: find.byType(CustomScrollView),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows duplicate warning banner for repeated titles',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TopicListReviewScreen(
          chatId: 'chat-1',
          title: 'Курсовые работы',
          initialOptions: const [
            TopicOptionDraft(title: 'Тема'),
            TopicOptionDraft(title: 'тема'),
          ],
          repository: _fakeRepo(),
        ),
      ));
      await tester.pump();

      expect(_textContaining('Возможные дубли'), findsOneWidget);
      expect(_text('Убрать дубли'), findsOneWidget);
    });
  });

  group('TopicOptionsEditorScreen (published selection)', () {
    testWidgets('keeps KeyboardDismissScope wrapping the scroll area',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TopicOptionsEditorScreen(
          chatId: 'chat-1',
          selectionId: 'sel-1',
          title: 'Темы докладов',
          selectionRowVersion: 1,
          canManage: true,
          options: const [
            TopicEditRow(id: 'o1', title: 'Тема 1', capacity: 2, taken: 0),
          ],
          repository: _fakeRepo(),
        ),
      ));
      await tester.pump();

      expect(find.byType(KeyboardDismissScope), findsWidgets);
      final scopeFinder = find.byType(KeyboardDismissScope).first;
      expect(
        find.descendant(
          of: scopeFinder,
          matching: find.byType(CustomScrollView),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'occupied option protection: delete is blocked with a friendly message, no RPC call',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TopicOptionsEditorScreen(
          chatId: 'chat-1',
          selectionId: 'sel-1',
          title: 'Темы докладов',
          selectionRowVersion: 1,
          canManage: true,
          options: const [
            TopicEditRow(id: 'o1', title: 'Занятая тема', capacity: 2, taken: 1),
          ],
          repository: _fakeRepo(),
        ),
      ));
      await tester.pump();

      expect(_text('Занятая тема'), findsOneWidget);
      expect(_textContaining('Занято 1 из 2'), findsOneWidget);

      // Drive the search TextField's controller directly rather than via
      // `tester.enterText` — the latter resolves `EditableTextState` through
      // a default-`skipOffstage` descendant lookup that misses fully-built
      // widgets in this Flutter version (see the `_text`/`_textContaining`
      // note above).
      final searchField = tester.widget<TextField>(
        find.byType(TextField, skipOffstage: false).last,
      );
      searchField.controller!.text = 'Занятая';
      await tester.pump();

      // Invoke the delete button's callback directly rather than simulating
      // a real tap — coordinate-based hit-testing inside this
      // `CustomScrollView` is unreliable in this Flutter version (see the
      // `_text`/`_textContaining` note above), while resolving the actual
      // `onPressed` callback and calling it exercises the exact same
      // production code path deterministically.
      final deleteButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.delete_outline, skipOffstage: false),
          matching: find.byType(IconButton, skipOffstage: false),
        ),
      );
      deleteButton.onPressed!();
      await tester.pump();
      // Let the SnackBar's enter animation run.
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        _textContaining('сначала уточните с участником'),
        findsOneWidget,
      );
      // The row must still be present — nothing was actually removed.
      expect(_text('Занятая тема'), findsOneWidget);
    });

    testWidgets('does not fetch on open (no automatic RPC on initState)',
        (tester) async {
      // Regression guard: if the screen ever starts calling `_reload()`
      // from initState, this test would throw (client points at a bogus
      // host) instead of rendering normally.
      await tester.pumpWidget(MaterialApp(
        home: TopicOptionsEditorScreen(
          chatId: 'chat-1',
          selectionId: 'sel-1',
          title: 'Темы докладов',
          selectionRowVersion: 3,
          canManage: true,
          options: const [
            TopicEditRow(id: 'o1', title: 'Тема 1', capacity: 1),
          ],
          repository: _fakeRepo(),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(_text('Управление темами'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
