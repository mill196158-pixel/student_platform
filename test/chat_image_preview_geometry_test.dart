import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/chat_image_aspect_cache.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'home_progressive_loading_test.dart' show signIn;

void main() {
  testWidgets('remembered dimensions apply immediately while access is checked',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const appLinks = MethodChannel('com.llfbandit.app_links/events');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appLinks, (_) async => null);
    final pending = Completer<http.Response>();
    var requests = 0;
    final client = MockClient((request) {
      if (request.url.path.endsWith('/chat-file-access')) {
        requests++;
        return pending.future;
      }
      return Future.value(http.Response('{}', 404, request: request));
    });
    await tester.runAsync(() async {
      await Supabase.initialize(
          url: 'https://example.test',
          publishableKey: 'test',
          httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      await signIn(Supabase.instance.client, 'geometry-user');
    });
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/geometry.png';
    ChatImageAspectCache.instance.remember(
        user: 'geometry-user',
        epoch: ChatFileAccess.generation,
        url: url,
        ratio: 1);
    Widget screen() => const MaterialApp(
        home: Scaffold(
            body: Center(
                child: AppNetworkImagePreview(
                    imageUrl: url, fileName: 'geometry.png', maxWidth: 300))));
    await tester.pumpWidget(screen());
    await tester.pump();
    expect(tester.getSize(find.byType(AppNetworkImagePreview)),
        const Size(245, 245));
    expect(find.text('Загрузка...'), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(requests, 1, reason: 'visible image must still verify access');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    await tester.pump();
    expect(tester.getSize(find.byType(AppNetworkImagePreview)),
        const Size(245, 245));
    pending.complete(http.Response(jsonEncode({'error': 'denied'}), 403,
        headers: {'content-type': 'application/json'}));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Supabase.instance.dispose();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appLinks, null);
  });
}
