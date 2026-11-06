import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> setUser(String uid) async {
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final token = '${part({'alg':'none'})}.${part({'sub':uid,'iat':now,'exp':now+3600})}.sig';
  await Supabase.instance.client.auth.setInitialSession(jsonEncode({
    'access_token':token,'refresh_token':'test','token_type':'bearer','expires_at':now+3600,
    'user':{'id':uid,'aud':'authenticated','app_metadata':{},'user_metadata':{},'created_at':'2022-01-01T00:00:00Z'}
  }));
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('A clear boundary cannot prune B pending message in the same chat', () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url:'https://example.invalid',publishableKey:'test',
      authOptions:const FlutterAuthClientOptions(autoRefreshToken:false),
      httpClient:MockClient((request) async => http.Response('null',200,headers:{'content-type':'application/json'},request:request)));
    addTearDown(() async { await DmApi.clearSessionState(); await ChatMessageCacheStore.clearOnLogout(); await Supabase.instance.dispose(); });
    await setUser('a');
    DmApi.debugPrimeClearedAt('chat',DateTime.utc(2026, 6));
    await setUser('b');
    final local=Message(id:'local_b',chatId:'chat',authorId:'b',authorLogin:'',authorName:'',text:'pending',at:DateTime.utc(2026, 1),deliveryStatus:MessageDeliveryStatus.sending);
    await ChatMessageCacheStore.replace(chatId:'chat',userId:'b',messages:[local]);
    DmApi.debugSyncPageLoader=({required chatId, required limit, clearedAt}) async => (messages:<Message>[], hasMore:false);
    final result=await DmApi.syncLatest(chatId:'chat',invalidateClearBoundary:false);
    expect(result.ok,isTrue);
    expect(ChatMessageCacheStore.messagesSync('chat',userId:'b').map((m)=>m.id),contains('local_b'));
    expect(DmApi.debugCachedClearedAt('chat'),isNull);
  });
}
