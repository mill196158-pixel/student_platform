import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static void validate() {
    if (url.isEmpty || anonKey.isEmpty) {
      throw StateError(
        'Supabase config is missing. Run with '
        '--dart-define=SUPABASE_URL=... '
        '--dart-define=SUPABASE_ANON_KEY=...',
      );
    }
  }

  static SupabaseClient get client => Supabase.instance.client;
}
