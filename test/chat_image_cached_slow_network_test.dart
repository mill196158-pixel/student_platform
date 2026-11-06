import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:student_platform/src/ui/learning/widgets/qa_local_image_prewarm.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  testWidgets('cached image renders before stalled network and hides on denial', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('cached-image-qa-')))!;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    messenger.setMockMethodCallHandler(links, (_) async => null);
    var response = Completer<http.Response>();
    var calls = 0;
    var allowReplacement = false;
    await tester.runAsync(() => Supabase.initialize(url: 'https://example.invalid', publishableKey: 'test',
      httpClient: MockClient((request) async {
        calls++;
        if (allowReplacement) return http.Response(jsonEncode({
          'url': 'https://studentsplatform.storage.yandexcloud.net/chats/test/picture.png',
          'cacheable': true, 'accessPolicyVersion': 1, 'expiresIn': 60
        }), 200, headers: {'content-type': 'application/json'});
        return response.future;
      }),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
    const uid = 'cache-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/picture.png';
    late File cachedFile;
    await tester.runAsync(() async {
      await signInWithFileSession(Supabase.instance.client, uid, sid);
      final digest = sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
      final file = cachedFile = File('${dir.path}/authorized_chat_files/$uid/$digest');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(await File('assets/icons/launcher_icon.png').readAsBytes());
      await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    });
    var provider = AuthorizedFileImageProvider(url);
    expect(await tester.runAsync(() => qaPrewarmLocalImage(url, current: () => false)), isFalse);
    expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);
    await tester.runAsync(() => File('${cachedFile.path}.grant').rename('${cachedFile.path}.pending'));
    expect(await tester.runAsync(() => qaPrewarmLocalImage(url, current: () => true)), isFalse);
    expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);
    await tester.runAsync(() => File('${cachedFile.path}.pending').rename('${cachedFile.path}.grant'));
    final decoding = Completer<void>(), release = Completer<void>();
    var current = true;
    qaDebugBeforePrewarmInsert = () async { decoding.complete(); await release.future; };
    late Future<bool> delayed;
    var prewarmFinished = false;
    await tester.runAsync(() async {
      delayed = qaPrewarmLocalImage(url, current: () => current);
      unawaited(delayed.then((_) => prewarmFinished = true));
    });
    for (var i = 0; i < 100 && !decoding.isCompleted && !prewarmFinished; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(decoding.isCompleted, isTrue, reason: 'local prewarm must reach decoded image');
    current = false;
    release.complete();
    expect(await tester.runAsync(() => delayed), isFalse);
    expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);
    qaDebugBeforePrewarmInsert = null;
    if (const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM')) {
      final decodingAgain = Completer<void>(), releaseAgain = Completer<void>();
      qaDebugBeforePrewarmInsert = () async { decodingAgain.complete(); await releaseAgain.future; };
      late Future<bool> stale;
      await tester.runAsync(() async { stale = qaPrewarmLocalImage(url, current: () => true); });
      for (var i = 0; i < 100 && !decodingAgain.isCompleted; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(decodingAgain.isCompleted, isTrue);
      final oldBytes = await tester.runAsync(() => cachedFile.readAsBytes());
      await tester.runAsync(() => ChatFileAccess.discardUnreadableImage(url,
          user: uid, epoch: ChatFileAccess.generation, sessionBinding: sid,
          expectedBytes: oldBytes!));
      releaseAgain.complete();
      expect(await tester.runAsync(() => stale), isFalse);
      expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);
      await tester.runAsync(() async {
        await cachedFile.writeAsBytes(oldBytes!);
        await File('${cachedFile.path}.grant').writeAsString('chat-file-grant-v2:$sid');
      });
      provider = AuthorizedFileImageProvider(url);
      qaDebugBeforePrewarmInsert = null;

      // Hold a decoded old copy while the real download path installs bytes.
      final startedReplace = Completer<void>(), finishReplace = Completer<void>();
      qaDebugBeforePrewarmInsert = () async { startedReplace.complete(); await finishReplace.future; };
      late Future<bool> oldDecode;
      await tester.runAsync(() async { oldDecode = qaPrewarmLocalImage(url, current: () => true); });
      for (var i = 0; i < 100 && !startedReplace.isCompleted; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(startedReplace.isCompleted, isTrue);
      final delayedViewers = Completer<void>();
      var viewerStarts = 0;
      if (const bool.fromEnvironment('CHAT_REENTRY_GATE_QA')) {
        AuthorizedFileImageProvider.debugAuthorize = (_) {
          viewerStarts++;
          return delayedViewers.future;
        };
        Widget viewers(bool second) => MaterialApp(home: Scaffold(body: Column(children: [
          const AuthorizedFileImage(key: ValueKey('one'), imageUrl: url, width: 40, height: 40),
          if (second) const AuthorizedFileImage(key: ValueKey('two'), imageUrl: url, width: 40, height: 40),
        ])));
        await tester.pumpWidget(viewers(true));
        await tester.pump();
        expect(viewerStarts, greaterThanOrEqualTo(2));
        await tester.pumpWidget(viewers(false));
        await tester.pump();
      }
      final beforeReplace = ChatFileAccess.qaContentEpoch(url, uid);
      await tester.runAsync(() => cachedFile.rename('${cachedFile.path}.test-old'));
      final modified = [...oldBytes!, 0];
      ChatFileAccess.debugHttpClientFactory = () => MockClient((_) async => http.Response.bytes(modified, 200));
      allowReplacement = true;
      expect(await tester.runAsync(() => ChatFileAccess.readBytes(url)), modified);
      expect(ChatFileAccess.qaContentEpoch(url, uid), greaterThan(beforeReplace));
      finishReplace.complete();
      expect(await tester.runAsync(() => oldDecode), isFalse);
      expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);
      if (const bool.fromEnvironment('CHAT_REENTRY_GATE_QA')) {
        delayedViewers.complete();
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        AuthorizedFileImageProvider.debugAuthorize = null;
      }
      qaDebugBeforePrewarmInsert = null;
      ChatFileAccess.debugHttpClientFactory = null;
      ChatFileAccess.debugResetProcessMemory();
      // Establish a fresh completed grant before the independent decode race.
      await tester.runAsync(() => ChatFileAccess.resolve(url));
      provider = AuthorizedFileImageProvider(url);
      allowReplacement = false;
      calls = 0;
      if (const bool.fromEnvironment('CHAT_REENTRY_GATE_QA')) {
        // Change only the captured credential getter during codec await: no
        // auth event or generation update may be required to hide old pixels.
        var observedToken = Supabase.instance.client.auth.currentSession!.accessToken;
        AuthorizedFileImageProvider.debugQaToken = () => observedToken;
        AuthorizedFileImageProvider.debugAuthorize = (_) async {};
        provider = AuthorizedFileImageProvider(url);
        final decodeKey = await provider.obtainKey(ImageConfiguration.empty);
        expect(identical(decodeKey, provider), isTrue, reason: 'valid receipt must obtain its own key');
        final decoded = Completer<void>(), finishDecode = Completer<void>();
        AuthorizedFileImageProvider.debugQaAfterDecode = () async { decoded.complete(); await finishDecode.future; };
        final realCodec = (await tester.runAsync(() => ui.instantiateImageCodec(oldBytes)))!;
        AuthorizedFileImageProvider.debugQaCodec = () async => realCodec;
        late ImageStreamCompleter delayedStream;
        final delayedFrame = Completer<ImageInfo>();
        final delayedListener = ImageStreamListener((info, _) { if (!delayedFrame.isCompleted) delayedFrame.complete(info); });
        await tester.runAsync(() async {
          delayedStream = provider.loadImage(decodeKey, (buffer, {getTargetSize}) =>
              ui.instantiateImageCodecFromBuffer(buffer));
          delayedStream.addListener(delayedListener);
        });
        for (var i = 0; i < 100 && !decoded.isCompleted; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(decoded.isCompleted, isTrue);
        observedToken = 'rotated-synthetic-token';
        finishDecode.complete();
        for (var i = 0; i < 100 && !delayedFrame.isCompleted; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(delayedFrame.isCompleted, isTrue);
        final delayedInfo = await delayedFrame.future;
        final deniedPixels = await tester.runAsync(() => delayedInfo.image.toByteData(format: ui.ImageByteFormat.rawRgba));
        expect(deniedPixels!.getUint8(3), 0);
        delayedStream.removeListener(delayedListener);
        delayedInfo.dispose();
        AuthorizedFileImageProvider.debugQaAfterDecode = null;
        AuthorizedFileImageProvider.debugQaCodec = null;
        AuthorizedFileImageProvider.debugQaToken = null;
        AuthorizedFileImageProvider.debugAuthorize = null;
        provider = AuthorizedFileImageProvider(url);
        // Key belongs to A; a later load must not dispatch under a new owner.
        AuthorizedFileImageProvider.debugAuthorize = (_) async {};
        final oldKey = await provider.obtainKey(ImageConfiguration.empty);
        await tester.runAsync(() async {
          await signInWithFileSession(Supabase.instance.client, 'other-user', sid);
          await signInWithFileSession(Supabase.instance.client, uid, sid);
        });
        final callsBeforeStaleLoad = calls;
        final stream = provider.loadImage(oldKey, PaintingBinding.instance.instantiateImageCodecWithSize);
        final frame = Completer<ImageInfo>();
        late final ImageStreamListener listener;
        listener = ImageStreamListener((info, _) { if (!frame.isCompleted) frame.complete(info); });
        stream.addListener(listener);
        for (var i = 0; i < 100 && !frame.isCompleted; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(frame.isCompleted, isTrue);
        final info = await frame.future;
        final transparent = await tester.runAsync(() => info.image.toByteData(format: ui.ImageByteFormat.rawRgba));
        expect(transparent!.getUint8(3), 0);
        expect(calls, callsBeforeStaleLoad);
        stream.removeListener(listener);
        info.dispose();
        AuthorizedFileImageProvider.debugAuthorize = null;
        provider = AuthorizedFileImageProvider(url);

      }
    }
    expect(await tester.runAsync(() => qaPrewarmLocalImage(url, current: () => true)), isTrue);
    expect(PaintingBinding.instance.imageCache.containsKey(provider), isTrue);
    expect(calls, 0);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: RepaintBoundary(
      key: ValueKey('image-boundary'), child: SizedBox(width: 40, height: 40,
        child: AuthorizedFileImage(imageUrl: url, width: 40, height: 40))))));
    for (var i = 0; i < 100 && find.byWidgetPredicate((w) => w is RawImage && w.image != null).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(response.isCompleted, isFalse);
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null), findsWidgets);
    Future<Uint8List> pixels() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('image-boundary')));
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return Uint8List.fromList(data!.buffer.asUint8List());
      } finally { image.dispose(); }
    }
    final beforeDenyPixels = (await tester.runAsync(pixels))!;
    for (var i = 0; i < 100 && calls == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(calls, greaterThan(0));
    if (const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM')) {
      // A legacy server response cannot keep a pre-existing decoded key alive.
      final previousPixels = tester.widget<RawImage>(find.byWidgetPredicate(
          (w) => w is RawImage && w.image != null).first).image!.clone();
      final beforeUnsupported = ChatFileAccess.qaAccessEpoch(url, uid);
      final legacyResponse = response;
      response = Completer<http.Response>();
      const generic403 = bool.fromEnvironment('QA_TEST_GENERIC_403');
      const late403 = bool.fromEnvironment('QA_TEST_LATE_GENERIC_403');
      if (late403) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15100)));
        await tester.pump();
      }
      legacyResponse.complete(generic403 || late403
          ? http.Response('{"error":"untyped"}', 403, headers: {'content-type': 'application/json'})
          : http.Response(jsonEncode({'url': url, 'cacheable': true}), 200,
              headers: {'content-type': 'application/json'}));
      for (var i = 0; i < 100 && ChatFileAccess.qaAccessEpoch(url, uid) == beforeUnsupported; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(ChatFileAccess.qaAccessEpoch(url, uid), greaterThan(beforeUnsupported));
      // The I/O isolate can deliver the event after the previous pump ended.
      // This is the first frame guaranteed to follow that notification.
      await tester.pump();
      expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null &&
          w.image!.isCloneOf(previousPixels)), findsNothing);
      previousPixels.dispose();
      if (generic403 || late403) {
        if (!response.isCompleted) response.complete(http.Response('{}', 503));
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await Supabase.instance.dispose();
          final root = await Directory.systemTemp.resolveSymbolicLinks();
          final target = await dir.resolveSymbolicLinks();
          if (!p.isWithin(root, target) || !p.basename(target).startsWith('cached-image-qa-')) {
            throw StateError('Unsafe test directory');
          }
          for (var i = 0; i < 100 && await dir.exists(); i++) {
            try { await dir.delete(recursive: true); }
            on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 20)); }
          }
          expect(await dir.exists(), isFalse);
        });
        messenger.setMockMethodCallHandler(paths, null);
        messenger.setMockMethodCallHandler(links, null);
        return;
      }
      // The new legacy online check is pending; it must not use old pixels.
      for (var i = 0; i < 100 && calls < 2; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }
    response.complete(http.Response('{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
      headers: {'content-type': 'application/json'}));
    for (var i = 0; i < 100 && !ChatFileAccess.isAccessRevoked(url); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(ChatFileAccess.isAccessRevoked(url), isTrue);
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is RawImage && w.image != null), findsNothing);
    final afterDenyPixels = (await tester.runAsync(pixels))!;
    expect(afterDenyPixels, isNot(orderedEquals(beforeDenyPixels)));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(await tester.runAsync(() => qaPrewarmLocalImage(url, current: () => true)), isFalse);
    expect(await tester.runAsync(() => cachedFile.exists()), isTrue);
    if (const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM') &&
        const bool.fromEnvironment('CHAT_REENTRY_GATE_QA')) {
      for (final error in <Object>[
        const FunctionException(status: 403, details: {'error': 'other'}),
        const FunctionException(status: 503),
        const SocketException('synthetic offline'),
        const FormatException('synthetic decode'),
      ]) {
        AuthorizedFileImageProvider.debugAuthorize = (_) => Future<void>.error(error);
        await expectLater(AuthorizedFileImageProvider(url).obtainKey(ImageConfiguration.empty),
            throwsA(same(error)));
      }
      final staleResponse = Completer<void>();
      AuthorizedFileImageProvider.debugAuthorize = (_) => staleResponse.future;
      final staleProvider = AuthorizedFileImageProvider(url);
      final staleResult = staleProvider.obtainKey(ImageConfiguration.empty);
      await tester.runAsync(() async {
        await signInWithFileSession(Supabase.instance.client, 'other-user', sid);
        await signInWithFileSession(Supabase.instance.client, uid, sid);
      });
      staleResponse.completeError(const FunctionException(status: 403,
          details: {'error': 'file_unavailable', 'reason': 'access_denied_v1'}));
      await tester.pump();
      final cancelled = await staleResult;
      expect(cancelled, isNot(staleProvider));
      AuthorizedFileImageProvider.debugAuthorize = null;
    }
    await tester.pumpWidget(const SizedBox.shrink());
    var denialSaved = false;
    for (var i = 0; i < 100 && !denialSaved; i++) {
      denialSaved = (await tester.runAsync(() => File('${cachedFile.path}.denied').exists()))!;
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(denialSaved, isTrue);
    await tester.runAsync(() async {
      await Supabase.instance.dispose();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, target) || !p.basename(target).startsWith('cached-image-qa-')) {
        throw StateError('Unsafe test directory');
      }
      for (var i = 0; i < 100 && await dir.exists(); i++) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(await dir.exists(), isFalse);
    });
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(links, null);
  });
}
