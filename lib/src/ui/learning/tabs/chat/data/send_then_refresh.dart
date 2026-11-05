import 'dart:async';

class SendScopeInvalidated implements Exception {
  const SendScopeInvalidated();
}

/// The send acknowledgement remains authoritative if a subsequent refresh fails.
Future<String> sendThenRefresh({
  required Future<String> Function() send,
  required bool Function() isCurrent,
  required Future<void> Function(String) refresh,
  Duration refreshTimeout = const Duration(seconds: 5),
}) async {
  if (!isCurrent()) throw const SendScopeInvalidated();
  final id = await send();
  try {
    if (!isCurrent()) return id;
    await refresh(id).timeout(refreshTimeout);
  } catch (_) {
    // A refresh failure cannot turn a confirmed send into a failed send.
  }
  return id;
}
