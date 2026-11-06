import 'dart:convert';

import 'package:student_platform/src/config/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> signInForScopedDraft(SupabaseClient client) async {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token = '${part({'alg': 'none'})}.${part({
    'iss': '${SupabaseConfig.url}/auth/v1', 'sub': 'user',
    'session_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    'aud': 'authenticated', 'role': 'authenticated', 'iat': now, 'exp': now + 3600,
  })}.sig';
  await client.auth.setInitialSession(jsonEncode({
    'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer',
    'expires_at': now + 3600,
    'user': {'id': 'user', 'aud': 'authenticated', 'app_metadata': {},
      'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'},
  }));
}
