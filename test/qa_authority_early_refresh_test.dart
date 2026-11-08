import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'experimental_guarded_supabase_initialize_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('QA host wait times out without dispatch, and late bind cannot revive it', () async {
    var sends=0;
    final inner=MockClient((_) async { sends++; return http.Response('',200); });
    final gate=RefreshAdmissionClient(inner,backend:Uri.parse('https://example.invalid'),
      qaAuthorityRequired:true,qaAuthorityTimeout:const Duration(milliseconds:30));
    gate.bind(inner);
    final request=http.Request('POST',Uri.parse('https://example.invalid/auth/v1/token?grant_type=refresh_token'));
    await expectLater(gate.send(request),throwsA(isA<RefreshTransportSuppressed>()));
    expect(gate.qaAuthorityWaiters,0);
    gate.bindQaAuthority((guarded,value)=>guarded.send(value));
    await Future<void>.delayed(Duration.zero);
    expect(sends,0);
    gate.close();
  });
  test('QA authority waiters are bounded', () async {
    var sends=0;
    final inner=MockClient((_) async { sends++; return http.Response('',200); });
    final gate=RefreshAdmissionClient(inner,backend:Uri.parse('https://example.invalid'),qaAuthorityRequired:true);
    http.Request request()=>http.Request('POST',Uri.parse('https://example.invalid/auth/v1/token?grant_type=refresh_token'));
    final first=gate.send(request());
    final firstRejected=expectLater(first,throwsA(isA<RefreshTransportSuppressed>()));
    await Future<void>.delayed(Duration.zero);
    expect(gate.qaAuthorityWaiters,1);
    await expectLater(gate.send(request()),throwsA(isA<RefreshTransportSuppressed>()));
    gate.rejectQaAuthority();
    await firstRejected;
    expect((sends,gate.qaAuthorityWaiters),(0,0));
    gate.close();
  });
  for (final operation in ['block','close']) {
    test('QA $operation releases a request waiting for authority', () async {
      var sends=0;
      final inner=MockClient((_) async { sends++; return http.Response('',200); });
      final gate=RefreshAdmissionClient(inner,backend:Uri.parse('https://example.invalid'),qaAuthorityRequired:true);
      final request=http.Request('POST',Uri.parse('https://example.invalid/auth/v1/token?grant_type=refresh_token'));
      final held=gate.send(request);
      final rejected=expectLater(held,throwsA(isA<RefreshTransportSuppressed>()));
      if (operation=='block') { gate.block(); } else { gate.close(); }
      await rejected;
      expect((sends,gate.qaAuthorityWaiters),(0,0));
      if (operation=='block') gate.close();
    });
  }
  test('QA suspend and resume invalidates a request awaiting authority', () async {
    var sends = 0;
    final inner = MockClient((_) async { sends++; return http.Response('',200); });
    final gate = RefreshAdmissionClient(inner,backend:Uri.parse('https://example.invalid'),qaAuthorityRequired:true);
    gate.bind(inner);
    final request = http.Request('POST',Uri.parse('https://example.invalid/auth/v1/token?grant_type=refresh_token'));
    final held = gate.send(request);
    final rejected = expectLater(held,throwsA(isA<RefreshTransportSuppressed>()));
    await gate.suspendAndDrain();
    gate.resume();
    gate.bindQaAuthority((guarded,value)=>guarded.send(value));
    await rejected;
    expect(sends,0);
    gate.close();
  });
  test('refresh held before logout cannot resume after authority binds', () async {
    var sends = 0;
    final inner = MockClient((_) async { sends++; return http.Response('',200); });
    final gate = RefreshAdmissionClient(inner,backend:Uri.parse('https://example.invalid'),qaAuthorityRequired:true);
    gate.bind(inner);
    final request = http.Request('POST',Uri.parse('https://example.invalid/auth/v1/token?grant_type=refresh_token'));
    final held = gate.send(request);
    final rejected = expectLater(held,throwsA(isA<RefreshTransportSuppressed>()));
    gate.discardHeldRefreshes();
    gate.bindQaAuthority((guarded,value)=>guarded.send(value));
    await rejected;
    expect(sends,0);
    gate.close();
  });
  for (final hostFails in [false,true]) {
    test(hostFails ? 'QA authority unavailable rejects refresh without network' : 'initial SDK refresh waits for QA authority', () async {
      var sends=0, authorityCalls=0;
      final inner=MockClient((_) async { sends++; return http.Response(fixture.session('new'),200,headers:{'content-type':'application/json'}); });
      final gate=RefreshAdmissionClient(inner,backend:Uri.parse('https://example.invalid'),qaAuthorityRequired:true);
      if (!hostFails) gate.bind(inner);
      final client=SupabaseClient('https://example.invalid','synthetic',httpClient:gate,
          authOptions:const AuthClientOptions(autoRefreshToken:false));
      addTearDown(client.dispose);
      await client.auth.setInitialSession(fixture.session('old'));
      final pending=client.auth.refreshSession();
      await Future<void>.delayed(const Duration(milliseconds:40));
      expect(sends,0);
      if (hostFails) {
        gate.rejectQaAuthority();
        await expectLater(pending,throwsA(isA<AuthException>()));
        expect(sends,0);
        expect(client.auth.currentSession?.refreshToken,'old');
      } else {
        gate.bindQaAuthority((guarded,request) async { authorityCalls++; return guarded.send(request); });
        expect((await pending).session?.refreshToken,'new');
        expect((sends,authorityCalls),(1,1));
      }
    });
  }
}
