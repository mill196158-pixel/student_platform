import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_auth_config.dart';
import 'admin_capabilities.dart';

enum AdminSessionPhase {
  bootstrapping,
  localPrototype,
  signedOut,
  loadingCapabilities,
  ready,
  noAccess,
  error,
}

/// Owns Supabase Auth session + server-backed capabilities for Admin Web.
class AdminSessionController extends ChangeNotifier {
  AdminSessionController({
    this._initializeSupabase,
    this._loadCapabilities,
    this._signIn,
    this._signOut,
  });

  final Future<void> Function()? _initializeSupabase;
  final Future<AdminCapabilities> Function()? _loadCapabilities;
  final Future<AuthResponse> Function(String email, String password)? _signIn;
  final Future<void> Function()? _signOut;

  AdminSessionPhase phase = AdminSessionPhase.bootstrapping;
  AdminCapabilities capabilities = AdminCapabilities.empty;
  String? errorMessage;
  bool _supabaseReady = false;

  bool get isLocalPrototype => phase == AdminSessionPhase.localPrototype;
  bool get isAuthenticated =>
      phase == AdminSessionPhase.ready || phase == AdminSessionPhase.noAccess;
  bool get hasAdminAccess => phase == AdminSessionPhase.ready;

  Future<void> bootstrap() async {
    phase = AdminSessionPhase.bootstrapping;
    errorMessage = null;
    notifyListeners();

    if (!AdminAuthConfig.isConfigured) {
      phase = AdminSessionPhase.localPrototype;
      capabilities = AdminCapabilities.empty;
      notifyListeners();
      return;
    }

    try {
      final initialize = _initializeSupabase;
      if (initialize != null) {
        await initialize();
      } else {
        await Supabase.initialize(
          url: AdminAuthConfig.supabaseUrl,
          publishableKey: AdminAuthConfig.supabasePublishableKey,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: true),
        );
      }
      _supabaseReady = true;

      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) {
        phase = AdminSessionPhase.signedOut;
        capabilities = AdminCapabilities.empty;
        notifyListeners();
        return;
      }

      await refreshCapabilities();
    } catch (_) {
      phase = AdminSessionPhase.error;
      errorMessage =
          'Не удалось подключить безопасный вход. Проверьте конфигурацию и сеть.';
      notifyListeners();
    }
  }

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    if (!AdminAuthConfig.isConfigured) {
      phase = AdminSessionPhase.localPrototype;
      notifyListeners();
      return;
    }

    phase = AdminSessionPhase.loadingCapabilities;
    errorMessage = null;
    notifyListeners();

    try {
      final signIn = _signIn;
      if (signIn != null) {
        await signIn(email, password);
      } else {
        await Supabase.instance.client.auth.signInWithPassword(
          email: email.trim(),
          password: password,
        );
      }
      await refreshCapabilities();
    } on AuthException catch (error) {
      phase = AdminSessionPhase.signedOut;
      errorMessage = _friendlyAuthError(error);
      notifyListeners();
    } catch (_) {
      phase = AdminSessionPhase.signedOut;
      errorMessage = 'Не удалось войти. Проверьте email и пароль.';
      notifyListeners();
    }
  }

  Future<void> refreshCapabilities() async {
    phase = AdminSessionPhase.loadingCapabilities;
    errorMessage = null;
    notifyListeners();

    try {
      final loader = _loadCapabilities;
      final loaded = loader != null
          ? await loader()
          : await _fetchCapabilities();
      capabilities = loaded;
      phase = loaded.hasAnyAdminAccess
          ? AdminSessionPhase.ready
          : AdminSessionPhase.noAccess;
      notifyListeners();
    } catch (_) {
      phase = AdminSessionPhase.error;
      capabilities = AdminCapabilities.empty;
      errorMessage =
          'Не удалось проверить права доступа. Попробуйте войти снова.';
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    try {
      final signOut = _signOut;
      if (signOut != null) {
        await signOut();
      } else if (_supabaseReady || AdminAuthConfig.isConfigured) {
        await Supabase.instance.client.auth.signOut();
      }
    } catch (_) {
      // Still clear local admin state.
    }

    capabilities = AdminCapabilities.empty;
    errorMessage = null;
    phase = AdminAuthConfig.isConfigured
        ? AdminSessionPhase.signedOut
        : AdminSessionPhase.localPrototype;
    notifyListeners();
  }

  Future<AdminCapabilities> _fetchCapabilities() async {
    final response = await Supabase.instance.client.rpc(
      'get_my_admin_capabilities',
    );
    if (response is Map<String, dynamic>) {
      return AdminCapabilities.fromJson(response);
    }
    if (response is Map) {
      return AdminCapabilities.fromJson(Map<String, dynamic>.from(response));
    }
    return AdminCapabilities.empty;
  }

  String _friendlyAuthError(AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('invalid login') || message.contains('invalid')) {
      return 'Неверный email или пароль.';
    }
    if (message.contains('email not confirmed')) {
      return 'Email ещё не подтверждён.';
    }
    return 'Не удалось войти. Попробуйте ещё раз.';
  }
}
