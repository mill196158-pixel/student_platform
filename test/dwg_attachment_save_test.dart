import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/forward_group_bubble.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  test('DWG uses a CAD handler and stays a document for Android legacy metadata', () {
    for (final mime in ['image/vnd.dwg', 'application/octet-stream', '']) {
      final drawing = ChatFile(
        id: 'f', chatId: 'c', messageId: null, fileName: 'Корпус.DWG',
        fileKey: 'drawing', fileUrl: 'example', fileType: mime,
        fileSize: 100, uploadedBy: 'student', uploadedAt: DateTime.utc(2026),
      );
      expect(ChatFile.externalOpenMime(drawing.fileName, fallback: mime),
          mime == 'image/vnd.dwg' ? mime : 'application/acad');
      expect(drawing.type, ChatFileType.document);
      expect(drawing.isDocument, isTrue);
      expect(drawing.isImage, isFalse);
    }
    for (final mime in ['IMAGE/VND.DWG; version=1', 'application/x-acad']) {
      final drawing = ChatFile(
        id: 'f', chatId: 'c', messageId: null, fileName: 'Чертёж',
        fileKey: 'drawing', fileUrl: 'example', fileType: mime,
        fileSize: 100, uploadedBy: 'student', uploadedAt: DateTime.utc(2026),
      );
      expect(drawing.isDocument, isTrue);
      expect(drawing.isImage, isFalse);
      expect(ChatFile.externalFileName(drawing.fileName, mime), 'Чертёж.dwg');
      expect(ChatFile.drawingOpenMime(drawing.fileName, mime),
          mime.split(';').first.toLowerCase());
    }
    expect(ChatFile.externalFileName('   ', 'application/x-dwg'), 'Чертёж.dwg');
    expect(ChatFile.externalFileName('file', 'application/octet-stream'), 'file');
    expect(ChatFile.drawingOpenMime('file.pdf', 'application/octet-stream'), isNull);
    expect(ChatFile.externalOpenMime('plan.jpg'), isNull);
    expect(ChatFile.externalOpenMime('plan.jpg', fallback: 'image/jpeg'), 'image/jpeg');
  });

  testWidgets('Android DWG exports cached bytes, can cancel, and can retry',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('dwg-export-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var pathReads = 0;
    messenger.setMockMethodCallHandler(pathChannel, (_) async {
      pathReads++;
      return dir.path;
    });
    messenger.setMockMethodCallHandler(links, (_) async => null);
    final picker = _DrawingPicker();
    FilePicker.platform = picker;
    var blobDownloads = 0;
    ChatFileAccess.debugHttpClientFactory = () => MockClient((request) async {
      blobDownloads++;
      return http.Response('offline', 503, request: request);
    });
    await tester.runAsync(() => Supabase.initialize(
          url: 'https://example.test',
          publishableKey: 'test',
          httpClient: MockClient((request) async {
            return http.Response('offline', 503, request: request);
          }),
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        ));
    addTearDown(() async {
      ChatFileAccess.debugHttpClientFactory = null;
      await Supabase.instance.dispose();
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(links, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await tester.binding.setSurfaceSize(const Size(350, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const uid = 'drawing-owner';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/plan.dwg';
    final data = ascii.encode('AC1032: synthetic drawing');
    await tester.runAsync(() async {
      await signInWithFileSession(Supabase.instance.client, uid, sid);
      final digest =
          sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
      final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data);
      await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    });
    await tester.pumpWidget(const MaterialApp(
      home: FullscreenFileViewer(fileUrl: url, fileName: 'План.DWG', fileSize: 24),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(pathReads, 0);
    final save = find.text('Сохранить файл');
    Future<void> saveOnce() async {
      await tester.tap(save);
      await tester.pump();
      for (var i = 0; i < 80 && save.evaluate().isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await saveOnce();
    expect(picker.requests, hasLength(1));
    expect(find.text('Файл сохранён'), findsNothing);
    await saveOnce();
    expect(picker.requests, hasLength(2));
    expect(picker.requests.last.$1, 'План.DWG');
    expect(picker.requests.last.$2, data);
    expect(find.text('Файл сохранён'), findsOneWidget);
    final forward = Message(id: 'fw', chatId: 'chat', authorId: uid,
        authorName: 'Студент', authorLogin: '', at: DateTime.utc(2026),
        text: '__FG__:${jsonEncode({
          'fg': 1,
          'items': [
            {'a': 'Студент', 'f': [
              {'name': 'Чертёж', 'mime': 'image/vnd.dwg', 'url': url, 'size': 24}
            ]}
          ]
        })}');
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: ForwardGroupBubble(message: forward, time: '11:00',
            isMe: false, idToFile: const {}))));
    await tester.pump();
    await tester.tap(find.text('Чертёж'));
    await tester.pumpAndSettle();
    expect(find.byType(FullscreenFileViewer), findsOneWidget);
    await saveOnce();
    expect(picker.requests, hasLength(3));
    expect(picker.requests.last.$1, 'Чертёж.dwg');
    expect(picker.requests.last.$2, data);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(
      home: FullscreenFileViewer(fileUrl: url, fileName: '', fileSize: 24,
          mimeType: 'application/x-dwg'),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<FullscreenFileViewer>(find.byType(FullscreenFileViewer)).fileName, isEmpty);
    await saveOnce();
    expect(picker.requests, hasLength(4));
    expect(picker.requests.last.$1, 'Чертёж.dwg');
    expect(picker.requests.last.$2, data);
    expect(blobDownloads, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _DrawingPicker extends FilePicker {
  final requests = <(String?, Uint8List?)>[];

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    requests.add((fileName, bytes));
    return requests.length == 1 ? null : 'saved-by-system';
  }
}
