import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/i_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/chats/core/dm_composer_bar.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart';

class _Service implements IChatService {
  final messages = <Message>[];
  final markStarted = Completer<void>(), markRelease = Completer<void>();
  var markCalls = 0;
  @override
  ChatMode get mode => ChatMode.dm;
  @override
  bool get supportsAssignments => false;
  @override
  bool get supportsNotes => false;
  @override
  String get currentUserId => 'user';
  @override
  String? get chatId => 'chat';
  @override
  Future<String> ensureChatId() async => 'chat';
  @override
  List<Message> get currentMessages => messages;
  @override
  ChatMessagesViewState get messagesViewState => const ChatMessagesViewState(
      phase: ChatMessagesLoadPhase.ready,
      messages: <Message>[],
      hasSnapshot: true);
  @override
  Stream<ChatMessagesViewState> watchMessagesState() =>
      Stream.value(messagesViewState);
  @override
  Stream<List<Message>> watchMessages() => Stream.value(messages);
  @override
  Future<Map<String, dynamic>> getUnreadMeta() async => {};
  @override
  Future<void> markRead(String id) async {
    markCalls++;
    if (!markStarted.isCompleted) markStarted.complete();
    await markRelease.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('stale DM retry callback cannot dispatch after compose is blocked', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    var presigns = 0;
    late Map<String, dynamic> session;
    await tester.runAsync(() async {
      await Supabase.initialize(url: SupabaseConfig.url, publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/generate-upload-url')) presigns++;
          return http.Response('[]', 200, headers: {'content-type':'application/json'}, request: request);
        }));
      String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final token = '${part({'alg':'none'})}.${part({'iss':'${SupabaseConfig.url}/auth/v1','aud':'authenticated','role':'authenticated','sub':'user','session_id':'cccccccc-cccc-4ccc-8ccc-cccccccccccc','iat':now,'exp':now+3600})}.sig';
      session = {
        'access_token': token, 'refresh_token':'synthetic', 'token_type':'bearer',
        'expires_at':now+3600, 'user': {'id':'user', 'aud':'authenticated',
          'app_metadata':{}, 'user_metadata':{}, 'created_at':'20220202'} };
      await Supabase.instance.client.auth.setInitialSession(jsonEncode(session));
    });
    var allowed = true;
    var guardChecks = 0;
    final service = _Service();
    await tester.pumpWidget(AuthSessionScopeHost(child: MaterialApp(home: UnifiedChatScreen(service: service,
        debugCanComposeDm: () { guardChecks++; return allowed; }))));
    for (var i = 0; i < 30 && find.byType(DmComposerBar).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(find.byType(DmComposerBar), findsOneWidget);
    var bar = tester.widget<DmComposerBar>(find.byType(DmComposerBar));
    bar.onAddFile(AttachedFile(localId:'file', path:'C:/synthetic.pdf', name:'synthetic.pdf', isImage:false, size:1));
    await tester.pump();
    bar = tester.widget<DmComposerBar>(find.byType(DmComposerBar));
    expect(bar.attachedFiles, hasLength(1));
    final callback = bar.onRetryFile!;
    final chosen = bar.attachedFiles.single;
    session['access_token'] = '${session['access_token']}2';
    session['refresh_token'] = 'synthetic-rotated';
    await tester.runAsync(() => Supabase.instance.client.auth.setInitialSession(jsonEncode(session)));
    allowed = false;
    final beforeChecks = guardChecks;
    callback(chosen);
    expect(guardChecks, greaterThan(beforeChecks), reason: 'Interrupted-session retry still checks DM compose');
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(presigns, 0);
    expect(tester.takeException(), isNull);
    expect(tester.widget<DmComposerBar>(find.byType(DmComposerBar)).attachedFiles, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Supabase.instance.dispose());
    messenger.setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), null);
  });
}
