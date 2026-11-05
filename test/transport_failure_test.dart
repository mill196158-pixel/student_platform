import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/core/transport_failure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('accepts known transport failures only', () {
    expect(isTemporaryTransportFailure(TimeoutException('timeout')), isTrue);
    expect(
        isTemporaryTransportFailure(const SocketException('offline')), isTrue);
    expect(
        isTemporaryTransportFailure(http.ClientException('offline')), isTrue);
    expect(isTemporaryTransportFailure(AuthRetryableFetchException()), isTrue);
    expect(
        isTemporaryTransportFailure(
            AuthRetryableFetchException(statusCode: '503')),
        isTrue);
  });

  test('does not turn explicit denial or malformed state into offline access',
      () {
    expect(
        isTemporaryTransportFailure(
            AuthRetryableFetchException(statusCode: '401')),
        isFalse);
    expect(
        isTemporaryTransportFailure(
            AuthRetryableFetchException(statusCode: '403')),
        isFalse);
    expect(
        isTemporaryTransportFailure(
            AuthRetryableFetchException(statusCode: '401 Unauthorized')),
        isFalse);
    expect(
        isTemporaryTransportFailure(
            const AuthApiException('denied', statusCode: '401')),
        isFalse);
    expect(
        isTemporaryTransportFailure(
            const PostgrestException(message: 'denied', code: '42501')),
        isFalse);
    expect(isTemporaryTransportFailure(StateError('invalid policy')), isFalse);
  });
}
