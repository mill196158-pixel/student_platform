import 'package:flutter/foundation.dart';
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Demo vs Real repository selection for content editors.
///
/// Real Admin never falls back to Local/demo repositories when Supabase is
/// unavailable — callers must surface a visible error instead.
class AdminContentBackend {
  const AdminContentBackend._();

  static const String realUnavailableMessage =
      'Real Admin: Supabase недоступен. Локальные demo-данные не подмешиваются.';

  /// Returns a live client in Real mode, or throws [StateError].
  /// In Demo mode returns null (callers use Local repositories).
  static SupabaseClient? requireClientOrDemo({
    required SupabaseClient? Function() tryClient,
  }) {
    if (AdminBackendConfig.isDemoMode) return null;
    final client = tryClient();
    if (client == null) {
      throw StateError(realUnavailableMessage);
    }
    return client;
  }

  /// Testable selection without touching [Supabase.instance].
  @visibleForTesting
  static T resolveRepository<T>({
    required bool isDemoMode,
    required SupabaseClient? client,
    required T Function() localFactory,
    required T Function(SupabaseClient client) supabaseFactory,
  }) {
    if (isDemoMode) return localFactory();
    if (client == null) {
      throw StateError(realUnavailableMessage);
    }
    return supabaseFactory(client);
  }
}
