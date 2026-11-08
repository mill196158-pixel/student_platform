import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/core/durable_active_session_registry.dart';
import 'package:student_platform/src/core/experimental_refresh_request_binding.dart';

/// QA-only document authority boundary. Does not implement SDK authentication,
/// change offline grants, or cancel a request when its caller times out.
class ExperimentalRefreshHandoffBoundary extends http.BaseClient {
  ExperimentalRefreshHandoffBoundary(this.inner, this.binding,
      {required this.terminalDenial, required this.sameSessionSuccess,
      this.maxBytes = 1024 * 1024, this.deadline = const Duration(seconds:15)});
  final http.Client inner;
  final ExperimentalRefreshRequestBinding binding;
  final bool Function(int status, Uint8List body, Map<String,String> headers) terminalDenial;
  final bool Function(Uint8List body, ActiveSessionSnapshot captured) sameSessionSuccess;
  final int maxBytes;
  final Duration deadline;
  ActiveSessionTransition? _admissionPending;
  // Process-local only: separate Dart isolates/engines do not share this set.
  static final Set<String> _observers = {};
  String get _observerKey => '${binding.registry.project}|${binding.snapshot.instance}|${binding.snapshot.revision}';

  /// Only the caller that verifies the SDK session AND a fresh online policy
  /// may complete this. Process death leaves pending closed.
  Future<bool> settleAfterAdmission({required bool Function() verified}) async {
    final pending = _admissionPending;
    if (pending == null || !verified()) return false;
    final ok = await binding.registry.finish(pending, current:verified, handoffOwner:binding.owner);
    if (ok) _admissionPending = null;
    return ok;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request || maxBytes <= 0 || deadline <= Duration.zero) {
      throw StateError('Refresh authority unavailable');
    }
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = Uint8List.fromList(request.bodyBytes)
      ..persistentConnection = request.persistentConnection
      ..followRedirects = false;
    final observerKey = _observerKey;
    if (!_observers.add(observerKey)) throw StateError('Refresh observer already active');
    final started = Stopwatch()..start();
    bool allowed;
    try { allowed = await binding.permits(copy); } catch (_) { _observers.remove(observerKey); rethrow; }
    if (!allowed) { _observers.remove(observerKey); throw StateError('Stale refresh request'); }
    final completion = _receive(copy, started).whenComplete(() => _observers.remove(observerKey));
    completion.ignore();
    // Keep observing late responses after a caller timeout; no authority is
    // changed by timeout itself. The memory bound applies to the full body.
    return completion.timeout(deadline);
  }

  Future<http.StreamedResponse> _receive(http.BaseRequest request, Stopwatch started) async {
    final response = await inner.send(request);
    final bytes = BytesBuilder(copy:false);
    final successful = response.statusCode >= 200 && response.statusCode < 300;
    Future<void>? closePending;
    Future<void> closeAmbiguous() async {
      final captured = binding.snapshot;
      await binding.registry.begin(captured, nextUid:captured.uid, nextSid:captured.sid,
          current:() => binding.owner.isCurrentFor(binding.registry.db));
    }
    final remaining = deadline - started.elapsed;
    final timer = successful ? Timer(remaining.isNegative ? Duration.zero : remaining,
        () { closePending ??= closeAmbiguous(); }) : null;
    try {
      if (response.contentLength != null && response.contentLength! > maxBytes) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('Refresh response too large');
      }
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxBytes) throw StateError('Refresh response too large');
        bytes.add(chunk);
      }
    } catch (_) {
      timer?.cancel();
      if (successful) {
        closePending ??= closeAmbiguous();
        await closePending;
      }
      rethrow;
    }
    timer?.cancel();
    if (closePending != null) {
      await closePending;
      throw StateError('Refresh response arrived after authority was closed');
    }
    final body = bytes.takeBytes();
    final registry = binding.registry;
    final captured = binding.snapshot;
    bool current() => binding.owner.isCurrentFor(registry.db);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final ticket = await registry.begin(captured, nextUid:captured.uid, nextSid:captured.sid, current:current);
      if (ticket == null) throw StateError('Refresh owner changed');
      if (!sameSessionSuccess(body, captured)) throw StateError('Unconfirmed refresh');
      _admissionPending = ticket;
    } else if (terminalDenial(response.statusCode, body, response.headers)) {
      if (!await registry.revoke(captured, current:current)) throw StateError('Denial not recorded');
    } else if (response.statusCode < 500) {
      throw StateError('Unclassified refresh outcome');
    }
    return http.StreamedResponse(Stream.value(body), response.statusCode,
        contentLength:body.length, request:response.request, headers:response.headers,
        isRedirect:response.isRedirect, persistentConnection:response.persistentConnection,
        reasonPhrase:response.reasonPhrase);
  }
}
