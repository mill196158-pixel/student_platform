import 'package:flutter/material.dart';
import 'package:flutter_chat_reactions/flutter_chat_reactions.dart' as fcr;
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/messages/chat_message_list.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const menuItems = <fcr.MenuItem>[
    fcr.MenuItem(label: 'Ответить', icon: Icons.reply),
    fcr.MenuItem(label: 'Скопировать', icon: Icons.copy),
  ];

  Future<void> pumpActionsDialog(
    WidgetTester tester, {
    required List<String> actions,
    required ValueNotifier<int> routeDepth,
    required ValueNotifier<Offset?> dragPosition,
    required ValueNotifier<int> dragRelease,
    VoidCallback? onBackdropTap,
  }) async {
    var actionCommitted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open-chat'),
                  onPressed: () {
                    routeDepth.value += 1;
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (chatContext) {
                          return Scaffold(
                            appBar: AppBar(title: const Text('Chat')),
                            body: Center(
                              child: TextButton(
                                key: const Key('open-menu'),
                                onPressed: () {
                                  showGeneralDialog<void>(
                                    context: chatContext,
                                    barrierDismissible: true,
                                    barrierLabel: 'message_reactions',
                                    barrierColor:
                                        Colors.black.withValues(alpha: 0.24),
                                    pageBuilder:
                                        (dialogContext, animation, secondary) {
                                      void dismissDialogOnly() {
                                        if (!dialogContext.mounted) return;
                                        Navigator.of(dialogContext).pop();
                                      }

                                      void commitMenuAction(String label) {
                                        if (actionCommitted) return;
                                        actionCommitted = true;
                                        dismissDialogOnly();
                                        actions.add(label);
                                      }

                                      return debugPackageActionsDialogShell(
                                        onBackdropTap: () {
                                          if (actionCommitted) return;
                                          onBackdropTap?.call();
                                          dismissDialogOnly();
                                        },
                                        child: Center(
                                          child: debugPackageActionsMenu(
                                            menuItems: menuItems,
                                            dragPosition: dragPosition,
                                            dragRelease: dragRelease,
                                            onTap: (item) =>
                                                commitMenuAction(item.label),
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                                child: const Text('Open menu'),
                              ),
                            ),
                          );
                        },
                      ),
                    ).whenComplete(() => routeDepth.value -= 1);
                  },
                  child: const Text('Open chat'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-chat')));
    await tester.pumpAndSettle();
    expect(find.text('Chat'), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Скопировать'), findsOneWidget);
  }

  testWidgets(
    'tap Copy without movement commits once and keeps chat open',
    (tester) async {
      final actions = <String>[];
      final routeDepth = ValueNotifier<int>(0);
      final dragPosition = ValueNotifier<Offset?>(null);
      final dragRelease = ValueNotifier<int>(0);
      addTearDown(() {
        routeDepth.dispose();
        dragPosition.dispose();
        dragRelease.dispose();
      });

      await pumpActionsDialog(
        tester,
        actions: actions,
        routeDepth: routeDepth,
        dragPosition: dragPosition,
        dragRelease: dragRelease,
      );

      await tester.tap(find.text('Скопировать'));
      await tester.pumpAndSettle();

      expect(actions, ['Скопировать']);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Скопировать'), findsNothing);
      expect(routeDepth.value, 1);
    },
  );

  testWidgets('Reply runs exactly once', (tester) async {
    final actions = <String>[];
    final routeDepth = ValueNotifier<int>(0);
    final dragPosition = ValueNotifier<Offset?>(null);
    final dragRelease = ValueNotifier<int>(0);
    addTearDown(() {
      routeDepth.dispose();
      dragPosition.dispose();
      dragRelease.dispose();
    });

    await pumpActionsDialog(
      tester,
      actions: actions,
      routeDepth: routeDepth,
      dragPosition: dragPosition,
      dragRelease: dragRelease,
    );

    await tester.tap(find.text('Ответить'));
    await tester.pumpAndSettle();

    expect(actions, ['Ответить']);
    expect(find.text('Chat'), findsOneWidget);
    expect(routeDepth.value, 1);
  });

  testWidgets('backdrop tap closes only the menu', (tester) async {
    final actions = <String>[];
    final routeDepth = ValueNotifier<int>(0);
    final dragPosition = ValueNotifier<Offset?>(null);
    final dragRelease = ValueNotifier<int>(0);
    var backdropTaps = 0;
    addTearDown(() {
      routeDepth.dispose();
      dragPosition.dispose();
      dragRelease.dispose();
    });

    await pumpActionsDialog(
      tester,
      actions: actions,
      routeDepth: routeDepth,
      dragPosition: dragPosition,
      dragRelease: dragRelease,
      onBackdropTap: () => backdropTaps += 1,
    );

    await tester.tapAt(const Offset(12, 12));
    await tester.pumpAndSettle();

    expect(actions, isEmpty);
    expect(backdropTaps, 1);
    expect(find.text('Скопировать'), findsNothing);
    expect(find.text('Chat'), findsOneWidget);
    expect(routeDepth.value, 1);
  });

  testWidgets('drag-release selection still commits the hovered action',
      (tester) async {
    final actions = <String>[];
    final routeDepth = ValueNotifier<int>(0);
    final dragPosition = ValueNotifier<Offset?>(null);
    final dragRelease = ValueNotifier<int>(0);
    addTearDown(() {
      routeDepth.dispose();
      dragPosition.dispose();
      dragRelease.dispose();
    });

    await pumpActionsDialog(
      tester,
      actions: actions,
      routeDepth: routeDepth,
      dragPosition: dragPosition,
      dragRelease: dragRelease,
    );

    final copyCenter = tester.getCenter(find.text('Скопировать'));
    dragPosition.value = copyCenter;
    await tester.pump();
    dragRelease.value = 1;
    await tester.pumpAndSettle();

    expect(actions, ['Скопировать']);
    expect(find.text('Chat'), findsOneWidget);
    expect(routeDepth.value, 1);
  });

  testWidgets('rapid repeated activation commits only once', (tester) async {
    final actions = <String>[];
    final dragPosition = ValueNotifier<Offset?>(null);
    final dragRelease = ValueNotifier<int>(0);
    addTearDown(() {
      dragPosition.dispose();
      dragRelease.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: debugPackageActionsMenu(
              menuItems: menuItems,
              dragPosition: dragPosition,
              dragRelease: dragRelease,
              onTap: (item) => actions.add(item.label),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final replyCenter = tester.getCenter(find.text('Ответить'));

    // Pointer path.
    await tester.tapAt(replyCenter);
    // Same opening: drag-release path after the tap should be ignored.
    dragPosition.value = replyCenter;
    dragRelease.value = 1;
    await tester.pump();
    // Second synthetic release tick must also be ignored.
    dragRelease.value = 2;
    await tester.pump();

    expect(actions, ['Ответить']);
  });
}
