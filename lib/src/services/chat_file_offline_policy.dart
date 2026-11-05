import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A cached private file may only bridge a transport failure for its owner.
bool canUseOfflineChatFile({
  required Object error,
  required String? owner,
  required String? currentOwner,
  required String? sessionOwner,
  required int epoch,
  required int currentEpoch,
  required bool isPrivateKey,
  required bool cacheable,
  required int length,
  required DateTime modified,
  required DateTime? sessionExpiresAt,
  required DateTime now,
}) {
  final transportFailure = error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException;
  if (!transportFailure ||
      owner == null ||
      owner.isEmpty ||
      owner != currentOwner ||
      owner != sessionOwner ||
      epoch != currentEpoch ||
      !isPrivateKey ||
      !cacheable ||
      length <= 0 ||
      sessionExpiresAt == null ||
      !sessionExpiresAt.isAfter(now)) return false;
  final age = now.difference(modified);
  return !age.isNegative && age <= const Duration(hours: 24);
}
