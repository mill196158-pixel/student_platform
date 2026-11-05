import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/services/chat_file_offline_policy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final now = DateTime.utc(2026, 11, 6, 12);
  bool allowed({
    Object? error,
    String? owner = 'a',
    String? currentOwner = 'a',
    String? sessionOwner = 'a',
    int epoch = 3,
    int currentEpoch = 3,
    bool isPrivateKey = true,
    bool cacheable = true,
    int length = 42,
    DateTime? modified,
    DateTime? expires,
    bool noExpiry = false,
  }) =>
      canUseOfflineChatFile(
        error: error ?? TimeoutException('offline'),
        owner: owner,
        currentOwner: currentOwner,
        sessionOwner: sessionOwner,
        epoch: epoch,
        currentEpoch: currentEpoch,
        isPrivateKey: isPrivateKey,
        cacheable: cacheable,
        length: length,
        modified: modified ?? now.subtract(const Duration(hours: 1)),
        sessionExpiresAt:
            noExpiry ? null : expires ?? now.add(const Duration(hours: 1)),
        now: now,
      );

  test('timeout and network failure allow a valid same-owner cache', () {
    expect(allowed(), isTrue);
    expect(allowed(error: const SocketException('offline')), isTrue);
    expect(allowed(modified: now.subtract(const Duration(hours: 24))), isTrue);
  });

  test('refusal or malformed response never becomes offline access', () {
    expect(allowed(error: FunctionException(status: 403)), isFalse);
    expect(allowed(error: FunctionException(status: 401)), isFalse);
    expect(allowed(error: FunctionException(status: 404)), isFalse);
    expect(allowed(error: StateError('invalid response')), isFalse);
  });

  test('requires the original active user and session generation', () {
    expect(allowed(owner: null), isFalse);
    expect(allowed(currentOwner: 'b'), isFalse);
    expect(allowed(sessionOwner: 'b'), isFalse);
    expect(allowed(currentEpoch: 4), isFalse);
    expect(allowed(noExpiry: true), isFalse);
    expect(allowed(expires: now), isFalse);
  });

  test('refuses non-cacheable, invalid and expired cache files', () {
    expect(allowed(cacheable: false), isFalse);
    expect(allowed(isPrivateKey: false), isFalse);
    expect(allowed(length: 0), isFalse);
    expect(allowed(modified: now.add(const Duration(seconds: 1))), isFalse);
    expect(
        allowed(modified: now.subtract(const Duration(hours: 24, seconds: 1))),
        isFalse);
  });
}
