import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'refresh_security_fence.dart';
import 'transport_failure_platform_stub.dart'
    if (dart.library.io) 'transport_failure_platform_io.dart' as platform;

/// A narrow set of failures that indicate the request could not reach its
/// authority. Server rejections and unexpected payloads are not transport
/// failures and must not grant offline admission.
bool isTemporaryTransportFailure(Object error) {
  if (error is RefreshSecurityFenceException) return false;
  if (error is TimeoutException || error is http.ClientException) return true;
  if (platform.isSocketFailure(error)) return true;
  if (error is AuthRetryableFetchException) {
    final rawStatus = error.statusCode;
    if (rawStatus == null) return true;
    final status = int.tryParse(rawStatus);
    return status != null && (status == 408 || status >= 500 && status <= 599);
  }
  return false;
}
