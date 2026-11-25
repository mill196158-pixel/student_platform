import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_attachment.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _CachePaths extends PathProviderWindows {
  _CachePaths(this.root);
  final String root;
  @override
  Future<String> getApplicationCachePath() async => root;
}

/// A previously downloaded drawing for the signed-in test student.
/// The real CAD program and a drawing with a known annotation are optional
/// inputs for the Windows device journey.
class CachedDrawingJourney {
  CachedDrawingJourney(this.root, this.cad, this.hash, this.file);
  final Directory root;
  final String cad;
  final Digest hash;
  final ChatFile file;

  static Future<CachedDrawingJourney?> prepare(
      Directory root, String chat) async {
    final sourcePath = Platform.environment['STUDENT_QA_DRAWING'];
    final cadPath = Platform.environment['STUDENT_QA_AUTOCAD'];
    if (sourcePath == null || cadPath == null) return null;
    final source = File(sourcePath);
    final bytes = await source.readAsBytes();
    expect(ascii.decode(bytes.sublist(0, 6)), 'AC1032');
    final uid = Supabase.instance.client.auth.currentUser!.id;
    final key = 'chats/$chat/qa-plan.dwg';
    final file = ChatFile(
        id: 'cached-drawing',
        chatId: chat,
        messageId: 'original',
        fileName: 'План корпуса.dwg',
        fileKey: key,
        fileUrl: Uri.https(ChatFileAccess.storageHost, '/$key').toString(),
        fileType: 'application/acad',
        fileSize: bytes.length,
        uploadedBy: uid,
        uploadedAt: DateTime.now(),
        deletionVerified: true);
    final stored = File(
        '${root.path}/authorized_chat_files/$uid/${sha256.convert(utf8.encode('$uid:$key'))}');
    await stored.parent.create(recursive: true);
    await stored.writeAsBytes(bytes);
    final sid = ChatFileAccess.currentSessionBinding!;
    await File('${stored.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    return CachedDrawingJourney(root, cadPath, sha256.convert(bytes), file);
  }

  Future<void> openAfterClear(WidgetTester tester) async {
    final original = PathProviderPlatform.instance;
    final session = Supabase.instance.client.auth;
    final scope = AuthSessionScope(
        currentSession: () => session.currentSession,
        authEvents: session.onAuthStateChange);
    await scope.ready;
    final caps = SessionCapabilities(scope);
    final owner = scope.capture()!;
    expect(
        caps.grant(
            SessionCapabilityMode.cacheOnly, caps.beginAuthorization(owner)!),
        isTrue);
    final service = DmChatService.cachedOnly(
        peerId: 'local-student',
        initialChatId: file.chatId,
        capabilities: caps,
        cacheReader: (_, __) async => throw StateError('No online fallback'));
    final result = Completer<bool>();
    try {
      PathProviderPlatform.instance = _CachePaths(root.path);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CachedChatAttachment(
                  file: file,
                  service: service,
                  debugOpen: (path) async {
                    try {
                      final handedOff = await File(path).readAsBytes();
                      expect(sha256.convert(handedOff), hash);
                      // AutoCAD Core Console takes a named drawing on Windows.
                      final named = await File('${root.path}/opened.dwg')
                          .writeAsBytes(handedOff);
                      final script = File('${root.path}/read.scr');
                      await script.writeAsString(
                          '(princ (strcat "CAD-VERIFIED:" (cdr (assoc 1 (entget (ssname (ssget "_X" (list (cons 0 "TEXT"))) 0))))))\n_.QUIT\n');
                      final cadRun = await Process.run(cad,
                          ['/i', named.path, '/s', script.path, '/l', 'en-US'],
                          workingDirectory: root.path,
                          stdoutEncoding: null,
                          stderrEncoding: null);
                      final output = String.fromCharCodes(
                          (cadRun.stdout as List<int>).where((b) => b != 0));
                      result.complete(cadRun.exitCode == 0 &&
                          output.contains(
                              'CAD-VERIFIED:QA SHEET 1 - ACADEMIC FLOOR'));
                    } catch (error, stack) {
                      result.completeError(error, stack);
                    }
                    return result.future;
                  }))));
      // Wait for the actual cache reader before tapping the document card.
      final available = await ChatFileAccess.readCachedOnly(file.fileUrl,
          permit: () => service.canReadCached);
      expect(available, isNotNull);
      await tester.pump(const Duration(milliseconds: 300));
      final target = find.text(file.fileName);
      expect(target, findsOneWidget);
      await tester.tap(target);
      expect(await result.future.timeout(const Duration(seconds: 50)), isTrue);
      debugPrint(
          'PASS E2E-092 real cached chat attachment opened offline in AutoCAD after news clear; SHA-256 $hash and model-space annotation verified');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      PathProviderPlatform.instance = original;
      await service.dispose();
      caps.dispose();
      scope.dispose();
    }
  }
}
