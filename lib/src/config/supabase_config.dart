import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  /// Publishable key — safe in client builds; access is enforced by Supabase RLS.
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://gwdanmwluhrcfxbnplwd.supabase.co',
  );
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_5V4JL2xjAyMGDziyE2Fpyg_Uweg683y',
  );

  static void validate() {
    if (url.isEmpty || anonKey.isEmpty) {
      throw StateError('Supabase config is incomplete.');
    }
  }

  static SupabaseClient get client => Supabase.instance.client;
}
