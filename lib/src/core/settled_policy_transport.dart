import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/config/supabase_config.dart';

enum SettledPolicyStatus {
  allowed,
  passwordChangeRequired,
  denied,
  unavailable,
  indeterminate,
}

/// One GET-only policy request. This component does not authenticate or grant
/// offline access; its caller must fence its owner and persist any decision.
/// It does not bind the supplied user ID and token to the current session;
/// wiring it into admission without an independent session fence is unsafe.
/// It waits for the underlying request to settle even after requesting abort.
class SettledPolicyTransport {
  SettledPolicyTransport(this.client)
      : _trustedBackend = Uri.parse(SupabaseConfig.url);

  @visibleForTesting
  SettledPolicyTransport.forTesting(this.client, this._trustedBackend);

  final http.Client client;
  final Uri _trustedBackend;

  bool _trustedOrigin(Uri backend) =>
      _trustedBackend.scheme == 'https' &&
      _trustedBackend.userInfo.isEmpty &&
      backend.scheme == 'https' &&
      backend.userInfo.isEmpty &&
      backend.host.isNotEmpty &&
      backend.host == _trustedBackend.host &&
      backend.port == _trustedBackend.port &&
      (backend.path.isEmpty || backend.path == '/') &&
      !backend.hasQuery &&
      !backend.hasFragment;

  Future<SettledPolicyStatus> check({
    required Uri backend,
    required String userId,
    required String accessToken,
    required String publicKey,
    required Duration timeout,
  }) async {
    if (!_trustedOrigin(backend) ||
        userId.isEmpty ||
        accessToken.isEmpty ||
        publicKey.isEmpty ||
        timeout.isNegative) {
      return SettledPolicyStatus.indeterminate;
    }
    final uri = backend.resolve('/rest/v1/users').replace(queryParameters: {
      'id': 'eq.$userId',
      'select': 'id,must_change_password',
      'limit': '2',
    });
    final abort = Completer<void>();
    var timeoutRequested = false;
    final timer = Timer(timeout, () {
      timeoutRequested = true;
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['apikey'] = publicKey
            ..headers['Authorization'] = 'Bearer $accessToken';
      final streamed = await client.send(request);
      // A denial remains authoritative even if the UI deadline has elapsed.
      if (streamed.statusCode == 401 || streamed.statusCode == 403) {
        try {
          await streamed.stream.listen((_) {}).cancel();
        } catch (_) {
          // The status is already received; a broken body is still denial.
        }
        return SettledPolicyStatus.denied;
      }
      if (timeoutRequested) {
        await streamed.stream.drain<void>();
        return SettledPolicyStatus.indeterminate;
      }
      if (streamed.statusCode != 200) {
        await streamed.stream.drain<void>();
        return SettledPolicyStatus.indeterminate;
      }
      final bytes = <int>[];
      await for (final chunk in streamed.stream) {
        if (bytes.length + chunk.length > 64 * 1024) {
          return SettledPolicyStatus.indeterminate;
        }
        bytes.addAll(chunk);
      }
      if (timeoutRequested) return SettledPolicyStatus.indeterminate;
      final rows = jsonDecode(utf8.decode(bytes));
      if (rows is! List || rows.length != 1 || rows.single is! Map) {
        return SettledPolicyStatus.indeterminate;
      }
      final row = rows.single as Map;
      if (row['id'] != userId || row['must_change_password'] is! bool) {
        return SettledPolicyStatus.indeterminate;
      }
      return row['must_change_password'] == true
          ? SettledPolicyStatus.passwordChangeRequired
          : SettledPolicyStatus.allowed;
    } on http.RequestAbortedException {
      return SettledPolicyStatus.indeterminate;
    } on http.ClientException {
      // The SDK/client may wrap unrelated or post-header errors; they do not
      // establish that the authority was unreachable.
      return SettledPolicyStatus.indeterminate;
    } catch (_) {
      return SettledPolicyStatus.indeterminate;
    } finally {
      timer.cancel();
    }
  }
}
