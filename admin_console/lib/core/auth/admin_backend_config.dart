import 'package:flutter/foundation.dart';

/// Public client config for Admin Web.
///
/// Defaults match the mobile app publishable client for project
/// `gwdanmwluhrcfxbnplwd`. `--dart-define` remains an optional override.
///
/// Demo / local prototype is **opt-in** via `ADMIN_DEMO_MODE=true`.
/// Never place `service_role` or other server secrets here.
class AdminBackendConfig {
  const AdminBackendConfig._();

  static const String defaultSupabaseUrl =
      'https://gwdanmwluhrcfxbnplwd.supabase.co';

  /// Same publishable client key as the mobile app (public, RLS-enforced).
  static const String defaultPublishableKey =
      'sb_publishable_5V4JL2xjAyMGDziyE2Fpyg_Uweg683y';

  static const bool _demoModeFlag = bool.fromEnvironment(
    'ADMIN_DEMO_MODE',
    defaultValue: false,
  );

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: defaultSupabaseUrl,
  );

  static const String supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: String.fromEnvironment(
      'SUPABASE_ANON_KEY',
      defaultValue: defaultPublishableKey,
    ),
  );

  /// Test-only override. Never set in production builds.
  @visibleForTesting
  static bool? debugDemoModeOverride;

  static bool get isDemoMode => debugDemoModeOverride ?? _demoModeFlag;

  static bool get hasClientCredentials =>
      supabaseUrl.trim().isNotEmpty && supabasePublishableKey.trim().isNotEmpty;

  /// Real backend mode: not demo, and public client credentials are present.
  static bool get isConfigured => !isDemoMode && hasClientCredentials;

  /// Human-readable config problem for real mode. Null when OK or demo.
  static String? get configurationError {
    if (isDemoMode) return null;
    if (!hasClientCredentials) {
      return 'Не заданы SUPABASE_URL или publishable/anon key. '
          'Реальный вход недоступен.';
    }
    return null;
  }

  /// Must match real-launch `--web-port=3000` and Supabase Redirect URLs.
  static const String passwordResetRedirectTo =
      'http://localhost:3000/#/auth/reset-password';
}

/// Backward-compatible alias used by older call sites / tests.
typedef AdminAuthConfig = AdminBackendConfig;
