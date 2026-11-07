import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/src/core/session_keeper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'pending to online keeps router identity and its in-flight redirect',
      (tester) async {
    final pending = ValueNotifier(true);
    final decision = Completer<String?>();
    var refreshes = 0;
    final router = GoRouter(
        initialLocation: '/splash',
        redirect: (_, state) {
          if (state.uri.path == '/home') return decision.future;
          return null;
        },
        routes: [
          GoRoute(
              path: '/splash',
              builder: (_, __) => const Scaffold(body: Text('splash'))),
          GoRoute(
              path: '/home',
              builder: (_, __) => const Scaffold(body: Text('home'))),
        ]);
    addTearDown(() {
      router.dispose();
      pending.dispose();
    });
    await tester.pumpWidget(ValueListenableBuilder<bool>(
        valueListenable: pending,
        builder: (_, value, __) => SessionKeeper(
            enabled: !value,
            refreshOverride: () async {
              refreshes++;
            },
            child: MaterialApp.router(routerConfig: router))));
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    final oldRouterElement =
        find.byWidgetPredicate((widget) => widget is Router).evaluate().single;
    router.go('/home');
    await tester.pump();
    expect(find.text('splash'), findsOneWidget);
    pending.value = false;
    await tester.pump();
    expect(
        identical(
            oldRouterElement,
            find
                .byWidgetPredicate((widget) => widget is Router)
                .evaluate()
                .single),
        isTrue);
    expect(refreshes, 1);
    decision.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    pending.value = true;
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(refreshes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('replacing the wrapper reproduces router disposal',
      (tester) async {
    final pending = ValueNotifier(true);
    final router = GoRouter(initialLocation: '/splash', routes: [
      GoRoute(
          path: '/splash',
          builder: (_, __) => const Scaffold(body: Text('splash'))),
    ]);
    addTearDown(() {
      router.dispose();
      pending.dispose();
    });
    await tester.pumpWidget(ValueListenableBuilder<bool>(
        valueListenable: pending,
        builder: (_, value, __) {
          final child = MaterialApp.router(routerConfig: router);
          return value
              ? child
              : SessionKeeper(refreshOverride: () async {}, child: child);
        }));
    await tester.pumpAndSettle();
    final oldRouter =
        find.byWidgetPredicate((widget) => widget is Router).evaluate().single;
    pending.value = false;
    await tester.pump();
    final newRouter =
        find.byWidgetPredicate((widget) => widget is Router).evaluate().single;
    expect(identical(oldRouter, newRouter), isFalse);
    expect(oldRouter.mounted, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'disabled keeper performs no timer or lifecycle refresh and resumes when enabled',
      (tester) async {
    final enabled = ValueNotifier(false);
    var refreshes = 0;
    addTearDown(enabled.dispose);
    await tester.pumpWidget(ValueListenableBuilder<bool>(
        valueListenable: enabled,
        builder: (_, value, __) => SessionKeeper(
            enabled: value,
            refreshOverride: () async {
              refreshes++;
            },
            child: const SizedBox.shrink())));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(minutes: 26));
    expect(refreshes, 0);
    enabled.value = true;
    await tester.pump();
    expect(refreshes, 1);
    await tester.pump(const Duration(minutes: 25));
    expect(refreshes, 2);
    enabled.value = false;
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(minutes: 26));
    expect(refreshes, 2);
    enabled.value = true;
    await tester.pump();
    expect(refreshes, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
