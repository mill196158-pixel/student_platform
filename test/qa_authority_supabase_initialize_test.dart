import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/serial_auth_local_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'experimental_guarded_supabase_initialize_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real Supabase.initialize returns while expired recovery waits for QA host', () async {
    SharedPreferences.setMockInitialValues({});
    final seed=SharedPreferencesLocalStorage(persistSessionKey:'synthetic-early-host');
    await seed.initialize();
    final expired=jsonDecode(fixture.session('old')) as Map<String,dynamic>;
    final now=DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    expired['access_token']='${part({'alg':'HS256'})}.${part({'iss':'https://example.invalid/auth/v1','sub':'u','session_id':'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','role':'authenticated','aud':'authenticated','iat':now-3600,'exp':now-120})}.sig';
    await seed.persistSession(jsonEncode(expired));
    final storage=SerialAuthLocalStorage(SharedPreferencesLocalStorage(persistSessionKey:'synthetic-early-host'));
    var sends=0;
    final inner=MockClient((_) async { sends++; return http.Response(fixture.session('new'),200,headers:{'content-type':'application/json'}); });
    final gate=RefreshAdmissionClient(inner,backend:Uri.parse('https://example.invalid'),qaAuthorityRequired:true);
    gate.bind(inner);
    final sdk=await Supabase.initialize(url:'https://example.invalid',anonKey:'synthetic',httpClient:gate,
      authOptions:FlutterAuthClientOptions(localStorage:storage,autoRefreshToken:true,detectSessionInUri:false)).timeout(const Duration(seconds:5));
    addTearDown(() async { gate.close(); await sdk.dispose(); });
    for(var i=0;i<100 && gate.qaAuthorityWaiters==0;i++) { await Future<void>.delayed(const Duration(milliseconds:10)); }
    expect(gate.qaAuthorityWaiters,1);
    expect(sends,0);
    expect(sdk.client.auth.currentSession?.refreshToken,'old');
    gate.rejectQaAuthority();
    for(var i=0;i<100 && gate.qaAuthorityWaiters!=0;i++) { await Future<void>.delayed(const Duration(milliseconds:10)); }
    expect(gate.qaAuthorityWaiters,0);
    expect(sends,0);
    expect(sdk.client.auth.currentSession?.refreshToken,'old');
  });
}
