import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/common/keyboard_dismiss_scope.dart';

/// Stage 13.11.1 — keyboard must stay open after field tap.
///
/// Root cause under test: programmatic ScrollUpdateNotification (keyboard
/// inset re-layout) must NOT unfocus; only user dragDetails may dismiss.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 13.11.1 KeyboardDismissScope focus retention', () {
    testWidgets('tap field keeps focus after pumpAndSettle and delay',
        (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_harness(focus: focus));
      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isRegistered, isTrue);
    });

    testWidgets('typing does not lose focus', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_harness(focus: focus));
      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('field_a')), 'темы');
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(find.text('темы'), findsOneWidget);
    });

    testWidgets('rebuild / setState does not lose focus', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var tick = 0;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            return _harness(
              focus: focus,
              onRebuildChrome: () => setState(() => tick++),
              rebuildToken: tick,
            );
          },
        ),
      );
      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('rebuild')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(focus.hasFocus, isTrue);
      expect(tick, 1);
    });

    testWidgets('viewInsets / keyboard re-layout does not lose focus',
        (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final view = tester.view;
      addTearDown(view.reset);

      await tester.pumpWidget(_harness(focus: focus, scrollable: true));
      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      // Simulate keyboard opening — inset change that previously caused
      // ScrollUpdateNotification(scrollDelta>2) → unfocus.
      view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
    });

    testWidgets(
        'programmatic ScrollUpdateNotification without drag keeps focus',
        (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        _harness(
          focus: focus,
          scrollable: true,
          scrollController: scrollController,
        ),
      );
      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      // Jump without dragDetails — models keyboard auto-scroll.
      scrollController.jumpTo(40);
      await tester.pump();
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('user drag scroll dismisses keyboard', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);

      await tester.pumpWidget(_harness(focus: focus, scrollable: true));
      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('tap outside editable closes keyboard', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_harness(focus: focus));
      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('outside')));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('Next moves focus to next field without closing both',
        (tester) async {
      final focusA = FocusNode();
      final focusB = FocusNode();
      addTearDown(focusA.dispose);
      addTearDown(focusB.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardDismissScope(
              child: Column(
                children: [
                  TextField(
                    key: const Key('field_a'),
                    focusNode: focusA,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => focusB.requestFocus(),
                  ),
                  TextField(
                    key: const Key('field_b'),
                    focusNode: focusB,
                    textInputAction: TextInputAction.done,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focusA.hasFocus, isTrue);

      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      // Explicit next handler / focus traversal to B.
      focusB.requestFocus();
      await tester.pump();
      expect(focusB.hasFocus, isTrue);
      expect(focusA.hasFocus, isFalse);
    });

    testWidgets('validation error rebuild does not make field unusable',
        (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final formKey = GlobalKey<FormState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardDismissScope(
              child: Form(
                key: formKey,
                child: Column(
                  children: [
                    TextFormField(
                      key: const Key('field_a'),
                      focusNode: focus,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'required' : null,
                    ),
                    TextButton(
                      key: const Key('validate'),
                      onPressed: () => formKey.currentState?.validate(),
                      child: const Text('validate'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('validate')));
      await tester.pumpAndSettle();
      expect(find.text('required'), findsOneWidget);

      // Field remains usable — can focus and type after validation.
      await tester.tap(find.byKey(const Key('field_a')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.enterText(find.byKey(const Key('field_a')), 'ok');
      await tester.pump();
      expect(focus.hasFocus, isTrue);
    });
  });

  group('Stage 13.11.1 topic/collection form shells', () {
    testWidgets('topic-like shell keeps focus through inset + rebuild',
        (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final view = tester.view;
      addTearDown(view.reset);
      var capsTick = 0;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            return MaterialApp(
              home: Scaffold(
                body: KeyboardDismissScope(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Column(
                      children: [
                        Text('caps-$capsTick'),
                        TextField(
                          key: const Key('topic_title'),
                          focusNode: focus,
                          autofocus: true,
                        ),
                        TextField(key: const Key('topic_desc')),
                        TextButton(
                          key: const Key('caps_update'),
                          onPressed: () => setState(() => capsTick++),
                          child: const Text('caps'),
                        ),
                        const SizedBox(height: 800),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pump();
      // Autofocus may apply asynchronously.
      if (!focus.hasFocus) {
        await tester.tap(find.byKey(const Key('topic_title')));
        await tester.pump();
      }
      expect(focus.hasFocus, isTrue);

      view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('caps_update')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.enterText(find.byKey(const Key('topic_title')), 'Экология');
      await tester.pump(const Duration(seconds: 1));
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('collection-like shell keeps focus through inset + rebuild',
        (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final view = tester.view;
      addTearDown(view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardDismissScope(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  children: [
                    TextField(
                      key: const Key('collection_title'),
                      focusNode: focus,
                    ),
                    TextField(key: const Key('collection_amount')),
                    const SizedBox(height: 800),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('collection_title')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);

      await tester.enterText(
        find.byKey(const Key('collection_title')),
        'Подарок',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('assignment-like shell (New Assignment) not broken',
        (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardDismissScope(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  children: [
                    TextField(
                      key: const Key('assignment_title'),
                      focusNode: focus,
                    ),
                    TextField(key: const Key('assignment_desc')),
                    const SizedBox(height: 400, child: Text('chrome')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('assignment_title')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.enterText(
        find.byKey(const Key('assignment_title')),
        'ДЗ',
      );
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tap(find.text('chrome'));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
    });
  });

  test('KeyboardDismissScope source has no pointer-down unfocus / timers', () {
    final source = File('lib/src/ui/common/keyboard_dismiss_scope.dart')
        .readAsStringSync();
    // Strip comments so docstrings mentioning the ban do not false-positive.
    final code = source
        .replaceAll(RegExp(r'//.*', multiLine: true), '')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    expect(code.contains('onPointerDown'), isFalse);
    expect(code.contains('onTapDown'), isFalse);
    expect(code.contains('Future.delayed'), isFalse);
    expect(code.contains('Timer('), isFalse);
    expect(code.contains('requestFocus'), isFalse);
    expect(code.contains('dragDetails != null'), isTrue);
    // scrollDelta must not drive dismiss (keyboard inset false positive).
    expect(
      RegExp(r'scrollDelta\?\.abs\(\)|scrollDelta\s*[><]').hasMatch(code),
      isFalse,
    );
  });
}

Widget _harness({
  required FocusNode focus,
  bool scrollable = false,
  ScrollController? scrollController,
  VoidCallback? onRebuildChrome,
  int rebuildToken = 0,
}) {
  final field = TextField(
    key: const Key('field_a'),
    focusNode: focus,
  );
  final column = Column(
    children: [
      Text('token-$rebuildToken'),
      field,
      const SizedBox(height: 24),
      const SizedBox(
        key: Key('outside'),
        height: 80,
        width: double.infinity,
        child: Text('outside'),
      ),
      if (onRebuildChrome != null)
        TextButton(
          key: const Key('rebuild'),
          onPressed: onRebuildChrome,
          child: const Text('rebuild'),
        ),
      if (scrollable) const SizedBox(height: 1200),
    ],
  );

  return MaterialApp(
    home: Scaffold(
      body: KeyboardDismissScope(
        child: scrollable
            ? SingleChildScrollView(
                controller: scrollController,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: column,
              )
            : column,
      ),
    ),
  );
}
