import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/core/settled_policy_transport.dart';

class _Client extends http.BaseClient {
  _Client(this.sendRequest);
  final Future<http.StreamedResponse> Function(http.BaseRequest) sendRequest;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      sendRequest(request);
}

http.StreamedResponse _response(int status, Object body) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status);

void main() {
  Future<SettledPolicyStatus> check(http.Client client,
          {Duration timeout = const Duration(seconds: 1)}) =>
      SettledPolicyTransport.forTesting(
              client, Uri.parse('https://backend.invalid'))
          .check(
              backend: Uri.parse('https://backend.invalid'),
              userId: 'user-a',
              accessToken: 'test-token',
              publicKey: 'test-key',
              timeout: timeout);

  test('only an exact policy row can allow, with redirects disabled', () async {
    for (final test in [
      (
        200,
        [
          {'id': 'user-a', 'must_change_password': false}
        ],
        SettledPolicyStatus.allowed
      ),
      (
        200,
        [
          {'id': 'user-a', 'must_change_password': true}
        ],
        SettledPolicyStatus.passwordChangeRequired
      ),
      (
        200,
        [
          {'id': 'user-b', 'must_change_password': false}
        ],
        SettledPolicyStatus.indeterminate
      ),
      (
        200,
        [
          {'id': 'user-a', 'must_change_password': 'false'}
        ],
        SettledPolicyStatus.indeterminate
      ),
      (200, [], SettledPolicyStatus.indeterminate),
      (401, {}, SettledPolicyStatus.denied),
      (403, {}, SettledPolicyStatus.denied),
      (503, {}, SettledPolicyStatus.indeterminate),
      (302, {}, SettledPolicyStatus.indeterminate),
    ]) {
      final client = _Client((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/rest/v1/users');
        expect(request.url.queryParameters['id'], 'eq.user-a');
        expect(request.followRedirects, isFalse);
        return _response(test.$1, test.$2);
      });
      expect(await check(client), test.$3);
      client.close();
    }
  });

  test('unclassified client failure remains indeterminate', () async {
    final client = _Client((_) async {
      throw http.ClientException('unreachable');
    });
    expect(await check(client), SettledPolicyStatus.indeterminate);
    client.close();
  });

  test('failed or oversized successful response body is indeterminate',
      () async {
    final broken = _Client((_) async => http.StreamedResponse(
        Stream<List<int>>.error(http.ClientException('stream failed')), 200));
    expect(await check(broken), SettledPolicyStatus.indeterminate);
    broken.close();
    final oversized = _Client((_) async => http.StreamedResponse(
        Stream.value(List<int>.filled(64 * 1024 + 1, 65)), 200));
    expect(await check(oversized), SettledPolicyStatus.indeterminate);
    oversized.close();
  });

  test('spoofed origins cannot receive bearer credentials', () async {
    var calls = 0;
    final client = _Client((request) async {
      calls++;
      return _response(200, []);
    });
    final transport = SettledPolicyTransport.forTesting(
        client, Uri.parse('https://backend.invalid'));
    for (final candidate in [
      'https://backend.invalid.evil.test',
      'https://backend.invalid:444',
      'https://evil@backend.invalid',
      'http://backend.invalid',
      'https://backend.invalid/other',
      'https://backend.invalid?x=y',
      'https://backend.invalid#fragment',
    ]) {
      expect(
          await transport.check(
              backend: Uri.parse(candidate),
              userId: 'user-a',
              accessToken: 'test-token',
              publicKey: 'test-key',
              timeout: const Duration(seconds: 1)),
          SettledPolicyStatus.indeterminate);
    }
    expect(calls, 0);
    client.close();
  });

  test('timeout requests abort but waits for a late denial', () async {
    final response = Completer<http.StreamedResponse>();
    final aborted = Completer<void>();
    final client = _Client((request) {
      final abortable = request as http.AbortableRequest;
      abortable.abortTrigger!.then((_) => aborted.complete());
      return response.future;
    });
    var completed = false;
    final result = check(client, timeout: Duration.zero).whenComplete(() {
      completed = true;
    });
    await aborted.future;
    expect(completed, isFalse);
    response.complete(_response(401, {}));
    expect(await result, SettledPolicyStatus.denied);
    client.close();
  });

  test('abort or late success cannot authorize offline access', () async {
    for (final abortError in [true, false]) {
      final response = Completer<http.StreamedResponse>();
      final aborted = Completer<void>();
      final client = _Client((request) {
        (request as http.AbortableRequest)
            .abortTrigger!
            .then((_) => aborted.complete());
        return response.future;
      });
      final result = check(client, timeout: Duration.zero);
      await aborted.future;
      if (abortError) {
        response.completeError(http.RequestAbortedException());
      } else {
        response.complete(_response(200, [
          {'id': 'user-a', 'must_change_password': false}
        ]));
      }
      expect(await result, SettledPolicyStatus.indeterminate);
      client.close();
    }
  });
}
