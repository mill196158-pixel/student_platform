import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:student_platform/src/ui/learning/widgets/reentry_image_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

class _Pending extends StatefulWidget {
  const _Pending({required this.release});
  final Future<void> release;
  @override
  State<_Pending> createState() => _PendingState();
}

class _PendingState extends State<_Pending> {
  ReentryImageObserver? observer;
  Object? ticket;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ReentryImageScope.maybeOf(context);
    if (identical(observer, next)) return;
    observer?.finish(ticket);
    observer = next;
    ticket = next?.begin();
    widget.release.then((_) {
      observer?.finish(ticket);
      ticket = null;
    });
  }

  @override
  void dispose() {
    observer?.finish(ticket);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('chat content');
}

void main() {
  testWidgets('initial chat waits for snapshot and never re-hides on updates',
      (tester) async {
    final ready = Completer<void>();
    Widget screen(bool snapshot) => MaterialApp(
        home: Scaffold(
            body: ReentryImageGate(
                key: const ValueKey('same-team-session'),
                readyForReveal: snapshot,
                timeout: const Duration(seconds: 5),
                child: _Pending(release: ready.future))));
    await tester.pumpWidget(screen(false));
    ready.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0);
    await tester.pumpWidget(screen(true));
    await tester.pump();
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
    await tester.pumpWidget(screen(false));
    await tester.pump();
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late snapshot never hides an already visible chat',
      (tester) async {
    final wait = Completer<void>();
    Widget screen(bool snapshot) => MaterialApp(
        home: Scaffold(
            body: ReentryImageGate(
                key: const ValueKey('same-team-and-session'),
                initiallyArmed: snapshot,
                child: _Pending(release: wait.future))));
    await tester.pumpWidget(screen(false));
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
    await tester.pumpWidget(screen(true));
    await tester.pump();
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
    wait.complete();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late image or list rebuild does not rehide revealed chat',
      (tester) async {
    final first = Completer<void>();
    final second = Completer<void>();
    Widget screen(Future<void> future, Key childKey) => MaterialApp(
        home: Scaffold(
            body: ReentryImageGate(
                key: const ValueKey('same-team-and-session'),
                child: KeyedSubtree(
                    key: childKey, child: _Pending(release: future)))));
    await tester.pumpWidget(screen(first.future, const ValueKey('first')));
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0);
    first.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
    await tester.pumpWidget(screen(second.future, const ValueKey('new-image')));
    await tester.pump();
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
    second.complete();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bounded timeout never hides the chat indefinitely',
      (tester) async {
    final wait = Completer<void>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReentryImageGate(
                timeout: const Duration(milliseconds: 300),
                child: _Pending(release: wait.future)))));
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0);
    await tester.pump(const Duration(milliseconds: 301));
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
    await tester.pumpWidget(const SizedBox());
    wait.complete();
    await tester.pump();
  });

  testWidgets('ordinary gate reveals a previously authorized decoded image',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reentry-gate-normal-')))!;
    messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/normal.png';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const uid = 'normal-gate-user';
    final client = MockClient((request) async => http.Response(
      jsonEncode({'url': url, 'cacheable': true, 'accessPolicyVersion': 1, 'expiresIn': 60}),
      200, request: request, headers: {'content-type': 'application/json'}));
    await tester.runAsync(() async {
      await Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
        httpClient: client, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      await signInWithFileSession(Supabase.instance.client, uid, sid);
      final digest = sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
      final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(await File('assets/icons/launcher_icon.png').readAsBytes());
      await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(links, null);
      messenger.setMockMethodCallHandler(paths, null);
      await Supabase.instance.dispose();
      final tmp = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir.resolveSymbolicLinks();
      if (!p.isWithin(tmp, target) || !p.basename(target).startsWith('reentry-gate-normal-')) {
        throw StateError('Unsafe test directory');
      }
      await dir.delete(recursive: true);
      ChatFileAccess.debugResetProcessMemory();
    });
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ReentryImageGate(
      timeout: Duration(seconds: 5), child: Center(child: AppNetworkImagePreview(
        imageUrl: url, fileName: 'normal.png', maxWidth: 300))))));
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0);
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
      if (tester.widget<Opacity>(find.byType(Opacity).first).opacity == 1) break;
    }
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null), findsWidgets);
    expect(find.text('Загрузка...'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    // Drain the already-started revalidation before the synthetic SDK is disposed.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  });
  testWidgets('reopen reveals the same mounted authorized decoded image',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    final dir = await tester
        .runAsync(() => Directory.systemTemp.createTemp('reentry-gate-'));
    messenger.setMockMethodCallHandler(paths, (_) async => dir!.path);
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/qr.png';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    var denied = false;
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return denied
          ? http.Response(
              '{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
              request: request, headers: {'content-type': 'application/json'})
          : http.Response(
              jsonEncode({
                'url': url,
                'cacheable': true,
                'accessPolicyVersion': 1,
                'expiresIn': 60
              }),
              200,
              request: request,
              headers: {'content-type': 'application/json'});
    });
    await tester.runAsync(() async {
      await Supabase.initialize(
          url: 'https://example.test',
          publishableKey: 'test',
          httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      await signInWithFileSession(Supabase.instance.client, 'gate-user', sid);
      final digest = sha256
          .convert(utf8.encode('gate-user:${ChatFileAccess.keyFor(url)}'));
      final file = File('${dir!.path}/authorized_chat_files/gate-user/$digest');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
          await File('assets/icons/launcher_icon.png').readAsBytes());
      await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    });
    Widget screen() => const MaterialApp(
        home: Scaffold(
            body: ReentryImageGate(
                timeout: Duration(seconds: 5),
                child: Center(
                    child: AppNetworkImagePreview(
                        imageUrl: url, fileName: 'qr.png', maxWidth: 300)))));
    Future<void> ready() async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
        if (opacity.opacity == 1) return;
      }
      fail('gate did not reveal a decoded image');
    }

    await tester.pumpWidget(screen());
    await ready();
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    final before = tester.state(find.byType(AppNetworkImagePreview));
    await ready();
    expect(identical(before, tester.state(find.byType(AppNetworkImagePreview))),
        isTrue);
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsWidgets);
    expect(tester.getSize(find.byType(AppNetworkImagePreview)),
        const Size(245, 245));
    final staleProvider = AuthorizedFileImageProvider(url);
    ChatFileAccess.fenceForLogout();
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsNothing);
    final countBefore = calls;
    final cancelled1 = await staleProvider.obtainKey(ImageConfiguration.empty);
    final cancelled2 = await staleProvider.obtainKey(ImageConfiguration.empty);
    expect(cancelled1 == staleProvider, isFalse);
    expect(cancelled1 == cancelled2, isFalse);
    expect(calls, countBefore);
    await tester.pumpWidget(const SizedBox());
    ChatFileAccess.debugResetProcessMemory();
    await tester.pumpWidget(screen());
    await ready();
    denied = true;
    ChatFileAccess.debugResetProcessMemory();
    var finishedDeny = false;
    unawaited(ChatFileAccess.resolve(url).then<void>((_) {
      finishedDeny = true;
    }, onError: (Object _, StackTrace __) {
      finishedDeny = true;
    }));
    for (var i = 0; i < 100 && !finishedDeny; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(finishedDeny, isTrue);
    expect(ChatFileAccess.isAccessRevoked(url), isTrue);
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsNothing);
    await tester.pumpWidget(const SizedBox());
    ChatFileAccess.debugResetProcessMemory();
    denied = false;
    var refreshed = false;
    unawaited(ChatFileAccess.resolve(url).then<void>((_) {
      refreshed = true;
    }, onError: (Object _, StackTrace __) {
      refreshed = true;
    }));
    for (var i = 0; i < 100 && !refreshed; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(refreshed, isTrue);
    final hold = Completer<void>();
    Widget hidden(String source) => MaterialApp(
        home: Scaffold(
            body: ReentryImageGate(
                timeout: const Duration(seconds: 5),
                child: Stack(children: [
                  Center(
                      child: AppNetworkImagePreview(
                          imageUrl: source, fileName: 'qr.png', maxWidth: 300)),
                  _Pending(release: hold.future),
                ]))));
    await tester.pumpWidget(hidden(url));
    for (var i = 0;
        i < 100 &&
            find
                .byWidgetPredicate((w) => w is RawImage && w.image != null)
                .evaluate()
                .isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0);
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsWidgets);
    final oldImage = tester
        .widget<RawImage>(find
            .byWidgetPredicate((w) => w is RawImage && w.image != null)
            .first)
        .image;
    await tester.pumpWidget(hidden(
        'https://studentsplatform.storage.yandexcloud.net/chats/test/other.png'));
    await tester.pump();
    expect(
        find.byWidgetPredicate(
            (w) => w is RawImage && identical(w.image, oldImage)),
        findsNothing);
    await tester.pumpWidget(hidden(url));
    for (var i = 0;
        i < 100 &&
            find
                .byWidgetPredicate((w) => w is RawImage && w.image != null)
                .evaluate()
                .isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsWidgets);
    denied = true;
    ChatFileAccess.debugResetProcessMemory();
    finishedDeny = false;
    unawaited(ChatFileAccess.resolve(url).then<void>((_) {
      finishedDeny = true;
    }, onError: (Object _, StackTrace __) {
      finishedDeny = true;
    }));
    for (var i = 0; i < 100 && !finishedDeny; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(finishedDeny, isTrue);
    expect(ChatFileAccess.isAccessRevoked(url), isTrue);
    await tester.pump();
    hold.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsNothing);
    await tester.pumpWidget(const SizedBox());
    ChatFileAccess.debugResetProcessMemory();
    // Two detached viewers resolving beyond the old 30 second listener window
    // must not render a prior session or accumulate cancelled image cache keys.
    final delayed = Completer<void>();
    var started = 0;
    AuthorizedFileImageProvider.debugAuthorize = (_) {
      started++;
      return delayed.future;
    };
    final cacheBefore = PaintingBinding.instance.imageCache.currentSize;
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Column(children: [
      AuthorizedFileImage(imageUrl: url, width: 30, height: 30),
      AuthorizedFileImage(imageUrl: url, width: 30, height: 30),
    ]))));
    expect(started, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 31));
    ChatFileAccess.debugResetProcessMemory();
    delayed.completeError(ChatFileSessionChanged());
    await tester.pump();
    await tester.pump();
    AuthorizedFileImageProvider.debugAuthorize = null;
    expect(tester.takeException(), isNull);
    expect(PaintingBinding.instance.imageCache.currentSize,
        lessThanOrEqualTo(cacheBefore));
    final noNetworkBefore = calls;
    for (var attempt = 0; attempt < 4; attempt++) {
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: Image(image: staleProvider))));
      for (var i = 0;
          i < 20 &&
              find
                  .byWidgetPredicate((w) => w is RawImage && w.image != null)
                  .evaluate()
                  .isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null),
          findsWidgets);
      final canceled = tester
          .widget<RawImage>(find
              .byWidgetPredicate((w) => w is RawImage && w.image != null)
              .first)
          .image!;
      final rgba = await tester
          .runAsync(() => canceled.toByteData(format: ImageByteFormat.rawRgba));
      expect(rgba!.getUint8(3), 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
    expect(calls, noNetworkBefore);
    expect(PaintingBinding.instance.imageCache.currentSize,
        lessThanOrEqualTo(cacheBefore));
    // Let outstanding image providers settle before tearing down their SDK.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.runAsync(() async {
      await Supabase.instance.dispose();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir!.resolveSymbolicLinks();
      if (!p.isWithin(root, target) ||
          !p.basename(target).startsWith('reentry-gate-')) {
        throw StateError('Unsafe test directory');
      }
      await dir.delete(recursive: true);
    });
    messenger.setMockMethodCallHandler(links, null);
    messenger.setMockMethodCallHandler(paths, null);
  }, skip: !const bool.fromEnvironment('CHAT_REENTRY_GATE_QA'));
}
