import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';

void main() {
  test('refresh waiting for admission is counted without blocking the drain', () async {
    final inner = MockClient((request) async => http.Response('ok', 200, request: request));
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    final request = http.Request('POST', Uri.parse('https://example.invalid/auth/v1/token?grant_type=refresh_token'));
    final pending = gate.send(request);
    expect(gate.refreshEntrants, 1);
    expect(gate.refreshEntryRevision, 1);
    expect(gate.activeAuthOperations, 0);
    await gate.suspendAndDrain();
    gate.resume(); gate.bind(inner);
    final response = await pending;
    await response.stream.drain<void>();
    expect(gate.refreshEntrants, 0);
    expect(gate.refreshEntryRevision, 1);
  });

  test('failed admission releases entrant and retains revision', () async {
    final inner = MockClient((_) async => http.Response('unexpected', 500));
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    final pending = gate.send(http.Request('POST',
      Uri.parse('https://example.invalid/auth/v1/token?grant_type=refresh_token')));
    expect(gate.refreshEntrants, 1);
    gate.block();
    await expectLater(pending, throwsA(isA<Exception>()));
    expect(gate.refreshEntrants, 0);
    expect(gate.refreshEntryRevision, 1);
  });
}
