import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_backend_config.dart';
import 'admin_capabilities.dart';

enum AdminSessionPhase {
  bootstrapping,
  localPrototype,
  signedOut,
  loadingCapabilities,
  ready,
  noAccess,
  passwordRecovery,
  error,
}

/// Owns Supabase Auth session + server-backed capabilities for Admin Web.
class AdminSessionController extends ChangeNotifier {
  AdminSessionController({
    Future<void> Function()? initializeSupabase,
    Future<AdminCapabilities> Function()? loadCapabilities,
    Future<AuthResponse> Function(String email, String password)? signIn,
    Future<void> Function()? signOut,
    Future<void> Function(String email)? resetPasswordForEmail,
    Future<void> Function(String password)? updatePassword,
  }) : _initializeSupabase = initializeSupabase,
       _loadCapabilities = loadCapabilities,
       _signIn = signIn,
       _signOut = signOut,
       _resetPasswordForEmail = resetPasswordForEmail,
       _updatePassword = updatePassword;

  final Future<void> Function()? _initializeSupabase;
  final Future<AdminCapabilities> Function()? _loadCapabilities;
  final Future<AuthResponse> Function(String email, String password)? _signIn;
  final Future<void> Function()? _signOut;
  final Future<void> Function(String email)? _resetPasswordForEmail;
  final Future<void> Function(String password)? _updatePassword;

  StreamSubscription<AuthState>? _authSub;

  AdminSessionPhase phase = AdminSessionPhase.bootstrapping;
  AdminCapabilities capabilities = AdminCapabilities.empty;
  String? errorMessage;
  String? infoMessage;
  bool _supabaseReady = false;

  bool get isLocalPrototype => phase == AdminSessionPhase.localPrototype;
  bool get isConnectedBackend =>
      !isLocalPrototype && AdminBackendConfig.isConfigured;
  bool get isAuthenticated =>
      phase == AdminSessionPhase.ready || phase == AdminSessionPhase.noAccess;
  bool get hasAdminAccess => phase == AdminSessionPhase.ready;
  bool get isPasswordRecovery => phase == AdminSessionPhase.passwordRecovery;

  Future<void> bootstrap() async {
    phase = AdminSessionPhase.bootstrapping;
    errorMessage = null;
    infoMessage = null;
    notifyListeners();

    if (AdminBackendConfig.isDemoMode) {
      phase = AdminSessionPhase.localPrototype;
      capabilities = AdminCapabilities.empty;
      notifyListeners();
      return;
    }

    final configError = AdminBackendConfig.configurationError;
    if (configError != null) {
      phase = AdminSessionPhase.error;
      capabilities = AdminCapabilities.empty;
      errorMessage = configError;
      notifyListeners();
      return;
    }

    try {
      final initialize = _initializeSupabase;
      if (initialize != null) {
        await initialize();
      } else {
        await Supabase.initialize(
          url: AdminBackendConfig.supabaseUrl,
          publishableKey: AdminBackendConfig.supabasePublishableKey,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: true),
        );
      }
      _supabaseReady = true;
      // Attach ASAP so late PASSWORD_RECOVERY emissions are still handled.
      _attachAuthListener();

      final session = Supabase.instance.client.auth.currentSession;
      // Recovery may already have been applied during initialize (listener
      // could miss the first event). Detect via URI / route without reading
      // token values, or via phase set by the listener.
      if (phase == AdminSessionPhase.passwordRecovery ||
          _detectPasswordRecoveryFromUri() ||
          (session != null && _isResetPasswordRoute())) {
        phase = AdminSessionPhase.passwordRecovery;
        capabilities = AdminCapabilities.empty;
        notifyListeners();
        return;
      }

      if (session == null) {
        phase = AdminSessionPhase.signedOut;
        capabilities = AdminCapabilities.empty;
        notifyListeners();
        return;
      }

      await refreshCapabilities();
    } catch (_) {
      phase = AdminSessionPhase.error;
      capabilities = AdminCapabilities.empty;
      errorMessage =
          'Не удалось подключить безопасный вход. Проверьте конфигурацию и сеть.';
      notifyListeners();
    }
  }

  void _attachAuthListener() {
    _authSub?.cancel();
    if (_initializeSupabase != null) {
      // Test / injected path — no live Supabase client required.
      return;
    }
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((
        data,
      ) {
        if (data.event == AuthChangeEvent.passwordRecovery) {
          phase = AdminSessionPhase.passwordRecovery;
          capabilities = AdminCapabilities.empty;
          errorMessage = null;
          notifyListeners();
        }
      });
    } catch (_) {
      // Listener is best-effort; URI detection still covers email links.
    }
  }

  /// Detects recovery redirect without reading/logging token values.
  bool _detectPasswordRecoveryFromUri() {
    try {
      final fragment = Uri.base.fragment;
      // Only look for the recovery marker key — never log fragment/query.
      if (fragment.contains('type=recovery')) {
        return true;
      }
      if (Uri.base.queryParameters['type'] == 'recovery') {
        return true;
      }
    } catch (_) {
      // Ignore malformed URIs.
    }
    return false;
  }

  bool _isResetPasswordRoute() {
    try {
      final fragment = Uri.base.fragment;
      final path = fragment.split('?').first;
      final normalized = path.startsWith('/') ? path : '/$path';
      return normalized == '/auth/reset-password';
    } catch (_) {
      return false;
    }
  }

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    if (AdminBackendConfig.isDemoMode) {
      phase = AdminSessionPhase.localPrototype;
      notifyListeners();
      return;
    }

    final configError = AdminBackendConfig.configurationError;
    if (configError != null) {
      phase = AdminSessionPhase.error;
      errorMessage = configError;
      notifyListeners();
      return;
    }

    phase = AdminSessionPhase.loadingCapabilities;
    errorMessage = null;
    infoMessage = null;
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

  Future<void> requestPasswordReset({required String email}) async {
    errorMessage = null;
    infoMessage = null;
    notifyListeners();

    final trimmed = email.trim();
    if (trimmed.isEmpty) {
      errorMessage = 'Укажите email.';
      notifyListeners();
      return;
    }

    try {
      final reset = _resetPasswordForEmail;
      if (reset != null) {
        await reset(trimmed);
      } else {
        await Supabase.instance.client.auth.resetPasswordForEmail(
          trimmed,
          redirectTo: AdminBackendConfig.passwordResetRedirectTo,
        );
      }
      infoMessage =
          'Если аккаунт существует, мы отправили письмо со ссылкой для сброса пароля.';
      notifyListeners();
    } on AuthException catch (error) {
      errorMessage = _friendlyResetError(error);
      notifyListeners();
    } catch (_) {
      errorMessage = 'Не удалось отправить письмо. Попробуйте позже.';
      notifyListeners();
    }
  }

  Future<void> updatePassword({required String password}) async {
    errorMessage = null;
    infoMessage = null;
    notifyListeners();

    if (password.length < 8) {
      errorMessage = 'Пароль должен быть не короче 8 символов.';
      notifyListeners();
      return;
    }

    try {
      final update = _updatePassword;
      if (update != null) {
        await update(password);
      } else {
        await Supabase.instance.client.auth.updateUser(
          UserAttributes(password: password),
        );
      }
      await signOut();
      infoMessage = 'Пароль обновлён. Войдите с новым паролем.';
      notifyListeners();
    } on AuthException catch (error) {
      phase = AdminSessionPhase.passwordRecovery;
      errorMessage = _friendlyResetError(error);
      notifyListeners();
    } catch (_) {
      phase = AdminSessionPhase.passwordRecovery;
      errorMessage = 'Не удалось сохранить пароль. Попробуйте ещё раз.';
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
      } else if (_supabaseReady || AdminBackendConfig.isConfigured) {
        await Supabase.instance.client.auth.signOut();
      }
    } catch (_) {
      // Still clear local admin state.
    }

    capabilities = AdminCapabilities.empty;
    errorMessage = null;
    if (AdminBackendConfig.isDemoMode) {
      phase = AdminSessionPhase.localPrototype;
    } else if (AdminBackendConfig.configurationError != null) {
      phase = AdminSessionPhase.error;
      errorMessage = AdminBackendConfig.configurationError;
    } else {
      phase = AdminSessionPhase.signedOut;
    }
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

  String _friendlyResetError(AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('rate limit') || message.contains('too many')) {
      return 'Слишком много попыток. Подождите и попробуйте снова.';
    }
    if (message.contains('same as') || message.contains('different')) {
      return 'Новый пароль должен отличаться от текущего.';
    }
    return 'Не удалось выполнить операцию. Попробуйте ещё раз.';
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
