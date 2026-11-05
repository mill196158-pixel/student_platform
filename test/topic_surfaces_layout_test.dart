import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_review_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_options_editor_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_option_edit_sheet.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_ocr_ui_helpers.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('new topic keyboard and PDF limit dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(
            brightness: dark ? Brightness.dark : Brightness.light),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(1.5),
                viewInsets: const EdgeInsets.only(bottom: 240)),
            child: child!),
        home: Scaffold(
            body: Builder(
                builder: (context) => Column(children: [
                      TextButton(
                          onPressed: () => showTopicOptionEditSheet(context),
                          child: const Text('Открыть форму')),
                      TextButton(
                          onPressed: () => showTopicPdfPagePicker(
                              context: context, pageCount: 24),
                          child: const Text('Открыть PDF')),
                    ]))),
      ));
      await tester.tap(find.text('Открыть форму'));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.widgetWithText(FilledButton, 'Добавить тему'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Добавить тему'));
      await tester.pumpAndSettle();
      expect(find.text('Введите название темы'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Открыть PDF'));
      await tester.pumpAndSettle();
      expect(find.text('Выбрано 10 из 10 страниц для распознавания.'),
          findsOneWidget);
      final page11 = find.widgetWithText(CheckboxListTile, 'Страница 11');
      final page1 = find.widgetWithText(CheckboxListTile, 'Страница 1');
      final pagesScroll = find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(page11, 120, scrollable: pagesScroll);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(page11).onChanged, isNull);
      await tester.scrollUntilVisible(page1, -120, scrollable: pagesScroll);
      await tester.ensureVisible(page1); await tester.pumpAndSettle();
      await tester.tap(page1); await tester.pumpAndSettle();
      await tester.scrollUntilVisible(page11, 120, scrollable: pagesScroll);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(page11).onChanged, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
    });
  }
  for (final size in [
    const Size(320, 568),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets('topic review/editor/edit sheet $size dark=$dark',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final client = SupabaseClient('https://layout.invalid', 'local',
            authOptions: const AuthClientOptions(autoRefreshToken: false));

        final repo = ChatGroupActionsRepository(client: client);
        Widget app(Widget child, {double inset = 0}) => MaterialApp(
            theme: ProductTheme.build(
                brightness: dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(1.5),
                    viewInsets: EdgeInsets.only(bottom: inset)),
                child: child!),
            home: child);
        await tester.pumpWidget(app(TopicListReviewScreen(
            chatId: 'local',
            title: 'Темы',
            repository: repo,
            initialOptions: const [
              TopicOptionDraft(
                  title:
                      'Расчёт сети водоснабжения жилого района и подбор оборудования',
                  sortOrder: 0),
              TopicOptionDraft(
                  title: 'Водоотведение и очистка поверхностного стока',
                  sortOrder: 1),
            ])));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
            find.byKey(const ValueKey('topic-edit-0')), 160,
            scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(find.byKey(const ValueKey('topic-edit-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('topic-edit-0')));
        await tester.pumpAndSettle();
        expect(find.text('Изменить тему'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Закрыть'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(app(TopicOptionsEditorScreen(
            chatId: 'local',
            selectionId: 'local',
            title: 'Темы курсовой работы',
            selectionRowVersion: 1,
            canManage: true,
            repository: repo,
            options: const [
              TopicEditRow(
                  id: 'a',
                  title: 'Расчёт сети водоснабжения жилого района',
                  capacity: 2,
                  taken: 1)
            ])));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
            find.byKey(const ValueKey('topic-edit-0')), 160,
            scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(find.byKey(const ValueKey('topic-edit-0')));
        await tester.pumpAndSettle();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('topic-edit-0')));
        await tester.pumpAndSettle();
        expect(find.text('Изменить тему'), findsOneWidget);
        expect(
            MediaQuery.textScalerOf(tester.element(find.text('Изменить тему')))
                .scale(10),
            15);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Закрыть'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
