import 'package:flutter/foundation.dart';

/// Public client config for Admin Web.
///
/// Values come from `--dart-define` only. Empty values mean local prototype mode.
/// Never place service_role or other server secrets here.
class AdminAuthConfig {
  const AdminAuthConfig._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: String.fromEnvironment('SUPABASE_ANON_KEY'),
  );

  /// Test-only override. Never set in production builds.
  @visibleForTesting
  static bool? debugIsConfiguredOverride;

  static bool get isConfigured =>
      debugIsConfiguredOverride ??
      (supabaseUrl.trim().isNotEmpty &&
          supabasePublishableKey.trim().isNotEmpty);
}
