import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/services/file_service.dart';
import 'package:student_platform/src/ui/learning/global_cache.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/attachments/chat_attachments_controller.dart';
import 'package:student_platform/src/ui/chats/forward/forward_send_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'forget confirmed sent retains new items and never discards server files',
      () async {
    var requests = 0, notifications = 0;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }));
    final client = Supabase.instance.client;
    String part(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const uid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final token = '${part({'alg': 'none'})}.${part({
          'sub': uid,
          'session_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          'iat': now,
          'exp': now + 3600
        })}.sig';
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'test',
      'token_type': 'bearer',
      'expires_at': now + 3600,
      'user': {
        'id': uid,
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final files = FileService(supabase: client);
    final controller = ChatAttachmentsController(files, GlobalCache(), client);
    controller.addListener(() => notifications++);
    LocalAttach file(String localId, String? uploadedId) => LocalAttach(
        localId: localId,
        path: '/$localId',
        name: localId,
        mimeType: 'application/pdf',
        size: 4,
        isImage: false,
        uploadedFileId: uploadedId,
        uploadStatus: LocalAttachUploadStatus.uploaded);
    final sent = file('sent', 'sent-id'), later = file('later', 'later-id');
    controller.pending.add(sent);
    final snapshot = ForwardAttachmentSnapshot(controller.pending);
    controller.pending.add(later);
    controller.forgetConfirmedSent(snapshot.containsUnchanged);
    await Future<void>.delayed(Duration.zero);
    expect(controller.pending.map((item) => item.localId), ['later']);
    expect(notifications, 1);
    expect(requests, 0);
    controller.dispose();
    client.dispose();
  });
}
