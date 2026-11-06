import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/core/qa_capability_view.dart';
import 'package:student_platform/src/core/qa_online_side_effect_coordinator.dart';
import 'package:student_platform/src/core/qa_rotation_navigation_guard.dart';
import 'package:student_platform/src/core/qa_rotation_receipt.dart';
import 'package:student_platform/src/core/refresh_security_fence.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  for (final scenario in ['allow', 'deny', 'timeout', 'logout', 'overlap', 'callback_block', 'grant_aba', 'begin_aba', 'owner_switch', 'block_regrant']) {
    testWidgets('SDK initial refresh and $scenario policy guard route', (tester) async {
      final h = await tester.runAsync(() async {
        if (Platform.isWindows) {
          open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
        }
        sqfliteFfiInit();
        final dir = await Directory.systemTemp.createTemp('qa_initial_refresh_');
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        String part(Object v) => base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
        Map<String, Object> session(int version, {String user = 'a'}) => {
          'access_token': '${part({'alg':'HS256'})}.${part({
            'iss':'https://a.invalid/auth/v1', 'sub':user,
            'session_id':user == 'a' ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' : 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            'role':'authenticated', 'aud':'authenticated', 'iat':now - 10,
            'exp':now + 3600 + version})}.sig$version',
          'refresh_token':'refresh-$version', 'token_type':'bearer',
          'expires_in':3600, 'expires_at':now + 3600 + version,
          'user':{'id':user,'aud':'authenticated','app_metadata':{},
            'user_metadata':{},'created_at':'2026-01-01T00:00:00Z'},
        };
        final entered = Completer<void>(), release = Completer<void>();
        var calls = 0;
        final inner = MockClient((request) async {
          if (request.url.path == '/auth/v1/token') {
            calls++;
            if (!entered.isCompleted) entered.complete();
            await release.future;
            return http.Response(jsonEncode(session(2)), 200,
              headers: {'content-type':'application/json'}, request: request);
          }
          return scenario == 'deny'
              ? http.Response('{}', 403, request: request)
              : http.Response('[{"id":"a","must_change_password":false}]', 200,
                  headers: {'content-type':'application/json'}, request: request);
        });
        final fence = RefreshSecurityFence();
        final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://a.invalid'),
          securityFence: fence, trackQaRefresh: true);
        final client = SupabaseClient('https://a.invalid', 'synthetic',
          authOptions: const AuthClientOptions(autoRefreshToken: false), httpClient: gate);
        await client.auth.setInitialSession(jsonEncode(session(1)));
        final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
          authEvents: client.auth.onAuthStateChange);
        await scope.ready;
        OfflineSessionBinding? binding() => client.auth.currentSession == null ? null
            : OfflineSessionBinding.fromSession(client.auth.currentSession!, 'https://a.invalid/auth/v1');
        final db = await openPolicyGrantDatabase('${dir.path}/policy.db', factory: databaseFactoryFfi);
        final store = SqlitePolicyGrantStore(scope: scope, currentBinding: binding,
          coordinator: SqlitePolicyGrantCoordinator(db));
        gate.bind(CoordinatedRefreshClient.forTesting(inner, store, Uri.parse('https://a.invalid'),
          currentRefreshToken: () => client.auth.currentSession?.refreshToken, securityFence: fence));
        final caps = SessionCapabilities(scope), receipt = QaRotationReceipt();
        var abaTriggered = false;
        var tryOnBlock = false, attacking = false, failedAttempts = 0;
        caps.addListener(() {
          if (scenario == 'block_regrant' && tryOnBlock && !attacking &&
              caps.mode == SessionCapabilityMode.blocked) {
            attacking = true;
            final current = scope.capture();
            final attempt = current == null ? null : caps.beginAuthorization(current);
            if (attempt == null) { failedAttempts++; }
            else { caps.grant(SessionCapabilityMode.online, attempt); }
            attacking = false;
            return;
          }
          if (scenario == 'owner_switch' && !abaTriggered &&
              caps.mode == SessionCapabilityMode.online) {
            abaTriggered = true;
            unawaited(client.auth.setInitialSession(jsonEncode(session(3, user: 'b'))));
            return;
          }
          if (!abaTriggered && ((scenario == 'grant_aba' &&
              caps.mode == SessionCapabilityMode.online) ||
              (scenario == 'begin_aba' && caps.revision > 0 &&
               caps.mode == SessionCapabilityMode.blocked))) {
            abaTriggered = true;
            caps.block();
            final current = scope.capture();
            if (current != null) {
              final attempt = caps.beginAuthorization(current);
              if (attempt != null) caps.grant(SessionCapabilityMode.online, attempt);
            }
          }
        });
        final admission = OfflineStartupAdmission(client: client, scope: scope, store: store,
          gate: gate, monitor: RefreshTransportMonitor(), fence: fence,
          owner: scope.capture()!, binding: binding()!, prior: null,
          fenceRevision: fence.revision, backend: Uri.parse('https://a.invalid'),
          publicKey: 'synthetic', policy: SettledPolicyTransport.forTesting(inner, Uri.parse('https://a.invalid')),
          policyTimeout: Duration(milliseconds: scenario == 'timeout' ? 50 : 2000),
          onOnlineAdmitted: (_, __, caps) {
            if (scenario == 'callback_block') caps.block();
            if (scenario == 'block_regrant') {
              tryOnBlock = true;
              caps.block();
            }
          },
          onInitialRefreshAdmitted: (owner, caps) => receipt.record(owner, owner, caps));
        final refresh = client.auth.refreshSession();
        await entered.future;
        return (dir:dir, db:db, store:store, gate:gate, client:client, scope:scope,
          caps:caps, receipt:receipt, admission:admission, refresh:refresh, release:release,
          calls:() => calls, failedAttempts:() => failedAttempts);
      });
      expect(h, isNotNull);
      final setup = h!;
      final coordinator = QaOnlineSideEffectCoordinator();
      await tester.pumpWidget(MaterialApp(
        builder: (_, child) => QaRotationNavigationGuard(scope: setup.scope,
          capabilities: setup.caps, receipt: setup.receipt,
          refreshStarts: setup.gate.refreshStarts,
          hasPendingRefresh: () => setup.gate.qaRefreshPending, child: child!),
        home: QaCapabilityView(capabilities: setup.caps, coordinator: coordinator,
          retainOnlineForRotation: true, blockedBuilder: (_) => const Text('blocked'),
          cachedBuilder: (_) => const Text('cached'),
          onlineBuilder: (_, __) => const Scaffold(body: Text('private chat'))),
      ));
      final result = await tester.runAsync(() async {
        final pending = setup.admission.resolve(setup.caps);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        Future<http.StreamedResponse>? second;
        if (scenario == 'overlap') {
          final request = http.Request('POST', Uri.parse(
              'https://a.invalid/auth/v1/token?grant_type=refresh_token'))
            ..body = jsonEncode({'refresh_token':'refresh-1'});
          second = setup.gate.send(request);
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (scenario == 'logout') setup.scope.invalidateForSignOut();
        if (scenario != 'timeout') setup.release.complete();
        final result = await pending;
        if (!setup.release.isCompleted) setup.release.complete();
        try { await setup.refresh; } catch (_) {}
        if (second != null) { try { await second; } catch (_) {} }
        if (scenario == 'owner_switch') {
          await Future<void>.delayed(Duration.zero);
          final newOwner = setup.scope.capture();
          expect(newOwner?.userId, 'b');
          expect(setup.caps.grant(SessionCapabilityMode.online,
              setup.caps.beginAuthorization(newOwner!)!), isTrue);
          expect(await setup.gate.runTrackedPolicy(() async => 42), 42);
        }
        return result;
      });
      await tester.pumpAndSettle();
      expect(setup.calls(), scenario == 'overlap' ? 2 : 1);
      expect(result, scenario == 'allow' ? OfflineStartupResult.online
          : scenario == 'deny' ? OfflineStartupResult.denied : OfflineStartupResult.unavailable);
      if (scenario == 'block_regrant') {
        expect(setup.failedAttempts(), greaterThan(0));
        expect(setup.caps.mode, SessionCapabilityMode.blocked);
      }
      if (scenario != 'owner_switch') {
        expect(find.text('private chat'), scenario == 'allow' ? findsOneWidget : findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        coordinator.dispose(); setup.receipt.dispose(); setup.caps.dispose();
        setup.store.dispose(); setup.scope.dispose(); await setup.client.dispose();
        await setup.db.close(); await setup.dir.delete(recursive: true);
      });
    });
  }
}
