import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/durable_active_session_registry.dart';
import 'package:student_platform/src/core/experimental_refresh_handoff_boundary.dart';
import 'package:student_platform/src/core/experimental_refresh_request_binding.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The native implementation must bind its opaque ticket to the calling
/// engine and keep document dispatch closed until [admit] commits. Test
/// doubles do not establish native engine security.
abstract interface class QaNativeDocumentAuthority {
  Future<Object?> captureClosed(String project, String uid, String sid, ActiveSessionSnapshot owner);
  Future<bool> admit(Object ticket, ActiveSessionSnapshot owner);
  Future<bool> abandon(Object ticket);
}

/// Process-local reference only; native ticket and SQLite remain authoritative.
class QaDocumentAuthorityLifecycle {
  static QaDocumentAuthorityHost? current;
  static Future<bool> revokeBeforeLogout() async {
    final host=current;
    return host != null && await host.revokeBeforeLogout();
  }
}

/// A cache-only permit may arrive before the QA native host. The host itself
/// revalidates the exact scope and permit when this deferred work runs.
class QaCachedAdmissionLatch {
  SessionCapabilities? _pending;
  QaDocumentAuthorityHost? _host;
  Future<bool>? lastAttempt;
  void onGranted(SessionCapabilities caps) { _pending=caps; _tryAdmit(); }
  void bind(QaDocumentAuthorityHost host) { _host=host; _tryAdmit(); }
  void clear() { _pending=null; }
  void _tryAdmit() {
    final host=_host, caps=_pending;
    if (host!=null && caps!=null) lastAttempt=host.admitCached(caps);
  }
}

/// Do not run a logout/denial transition until native close has committed.
Future<bool> qaRevokeThenRoute(Future<bool> Function() revoke, void Function() route) async {
  try {
    if (!await revoke()) return false;
    route();
    return true;
  } catch (_) { return false; }
}

/// Isolated QA orchestration. The SDK's storage and offline grant are not
/// modified. No production caller is wired to this host.
class QaDocumentAuthorityHost {
  QaDocumentAuthorityHost({required this.client,required this.scope,required this.gate,
    required this.registry,required this.owner,required this.native,required this.policy,
    required this.publicKey});
  final SupabaseClient client;
  final AuthSessionScope scope;
  final RefreshAdmissionClient gate;
  final DurableActiveSessionRegistry registry;
  final ProjectDatabaseOwnerCapability owner;
  final QaNativeDocumentAuthority native;
  final SettledPolicyTransport policy;
  final String publicKey;
  Object? _ticket;
  ExperimentalRefreshRequestBinding? _binding;
  ExperimentalRefreshHandoffBoundary? _pending;
  String? _uid,_sid;
  bool _disposed=false;
  bool _admitting=false;

  bool _current(AuthOperationScope captured) => !_disposed && scope.isCurrent(captured) &&
      scope.matchesSession(captured,client.auth.currentSession) && owner.isCurrentFor(registry.db);

  Future<bool> prepare() async {
    Object? capturedTicket;
    bool fail() { gate.rejectQaAuthority(); return false; }
    try {
      final captured=scope.capture();
      if (_ticket!=null || captured==null || !_current(captured)) return fail();
      final session=client.auth.currentSession!;
      final claims=OfflineSessionBinding.fromSession(session,'${registry.project}/auth/v1');
      if (claims==null) return fail();
      final binding=await ExperimentalRefreshRequestBinding.capture(registry,owner,
          uid:claims.userId,sid:claims.sessionId,currentRefreshToken:()=>client.auth.currentSession?.refreshToken);
      if (binding==null || !_current(captured)) return fail();
      final ticket=await native.captureClosed(registry.project,claims.userId,claims.sessionId,binding.snapshot);
      if (ticket==null) return fail();
      capturedTicket=ticket;
      if (!_current(captured)) { await native.abandon(ticket); return fail(); }
      _ticket=ticket; _uid=claims.userId; _sid=claims.sessionId; _binding=binding;
      gate.bindQaAuthority((transport,request) async {
        final admitted=_binding;
        if (_disposed || admitted==null) throw RefreshTransportSuppressed();
        final boundary=ExperimentalRefreshHandoffBoundary(transport,admitted,
            terminalDenial:_terminalDenial,sameSessionSuccess:_sameSessionSuccess);
        final response=await boundary.send(request);
        _pending=boundary;
        return response;
      });
      QaDocumentAuthorityLifecycle.current=this;
      return true;
    } catch (_) {
      if (capturedTicket!=null) { try { await native.abandon(capturedTicket); } catch (_) {} }
      return fail();
    }
  }

  bool _terminalDenial(int status, Uint8List bytes, Map<String,String> headers) {
    if (status!=401 && status!=403) return false;
    try {
      final json=jsonDecode(utf8.decode(bytes));
      if (json is! Map) return false;
      final code=json['code'] ?? json['error_code'];
      return const {'session_not_found','session_expired','user_banned'}.contains(code);
    } catch (_) { return false; }
  }

  bool _sameSessionSuccess(Uint8List bytes, ActiveSessionSnapshot owner) {
    try {
      final json=jsonDecode(utf8.decode(bytes));
      if (json is! Map<String,dynamic>) return false;
      final session=Session.fromJson(json);
      if (session==null) return false;
      final claims=OfflineSessionBinding.fromSession(session,'${registry.project}/auth/v1');
      return claims!=null && claims.userId==owner.uid && claims.sessionId==owner.sid;
    } catch (_) { return false; }
  }

  /// Performs the actual settled policy GET. No caller-provided policy bool.
  Future<bool> admitAfterPolicy() async {
    final ticket=_ticket, previous=_pending;
    if (_disposed || _admitting || ticket==null || previous==null) return false;
    _admitting=true;
    try {
      final captured=scope.capture();
      final session=client.auth.currentSession;
      if (captured==null || session==null || !_current(captured)) return false;
      final claims=OfflineSessionBinding.fromSession(session,'${registry.project}/auth/v1');
      if (claims==null || claims.userId!=_uid || claims.sessionId!=_sid) return false;
      final outcome=await policy.check(backend:Uri.parse(registry.project),userId:claims.userId,
          accessToken:session.accessToken,publicKey:publicKey,timeout:const Duration(seconds:3));
      if (outcome!=SettledPolicyStatus.allowed || !_current(captured)) {
        if (outcome==SettledPolicyStatus.denied || outcome==SettledPolicyStatus.passwordChangeRequired) {
          await revokeBeforeLogout();
        }
        return false;
      }
      if (!await previous.settleAfterAdmission(verified:()=>_current(captured))) return false;
      if (!_current(captured)) return false;
      final next=await registry.read();
      if (next==null || next.state!='active' || next.uid!=_uid || next.sid!=_sid || !_current(captured)) return false;
      final newBinding=await ExperimentalRefreshRequestBinding.capture(registry,owner,
          uid:_uid!,sid:_sid!,currentRefreshToken:()=>client.auth.currentSession?.refreshToken);
      if (newBinding==null || !_current(captured)) return false;
      if (!await native.admit(ticket,next) || !_current(captured)) { await native.abandon(ticket); return false; }
      _binding=newBinding; _pending=null;
      return true;
    } catch (_) { return false; }
    finally { _admitting=false; }
  }

  /// Reuses the application's already issued cache-only permit. This makes no
  /// request and does not authenticate a password or create a server grant.
  Future<bool> admitCached(SessionCapabilities caps) async {
    final ticket=_ticket;
    if (_disposed || _admitting || ticket==null || caps.mode!=SessionCapabilityMode.cacheOnly) return false;
    _admitting=true;
    try {
      final captured=scope.capture();
      final permit=caps.capture(SessionCapability.cachedRead);
      if (captured==null || permit==null || !_current(captured) ||
          !caps.owns(permit,captured)) return false;
      final session=client.auth.currentSession!;
      final claims=OfflineSessionBinding.fromSession(session,'${registry.project}/auth/v1');
      if (claims==null || claims.userId!=_uid || claims.sessionId!=_sid) return false;
      final snapshot=await registry.read();
      if (snapshot==null || snapshot.state!='active' || snapshot.uid!=_uid || snapshot.sid!=_sid ||
          !_current(captured) || !caps.owns(permit,captured)) return false;
      if (!await native.admit(ticket,snapshot) || !_current(captured) ||
          !caps.owns(permit,captured)) {
        await native.abandon(ticket);
        return false;
      }
      return true;
    } catch (_) { return false; }
    finally { _admitting=false; }
  }
  Future<void> dispose() async {
    _disposed=true; _binding=null; gate.rejectQaAuthority();
    if (identical(QaDocumentAuthorityLifecycle.current,this)) QaDocumentAuthorityLifecycle.current=null;
    final ticket=_ticket; _ticket=null;
    if (ticket!=null) { try { await native.abandon(ticket); } catch (_) {} }
  }

  Future<bool> revokeBeforeLogout() async {
    final ticket=_ticket;
    if (_disposed || ticket==null) return false;
    try {
      final revoked=await native.abandon(ticket);
      if (revoked) {
        _disposed=true; _binding=null; _ticket=null;
        if (identical(QaDocumentAuthorityLifecycle.current,this)) QaDocumentAuthorityLifecycle.current=null;
      }
      return revoked;
    } catch (_) { return false; }
  }
}
