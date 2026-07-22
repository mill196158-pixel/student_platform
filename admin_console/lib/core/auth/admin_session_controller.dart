import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:student_ui/student_ui.dart';
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
    this._initializeSupabase,
    this._loadCapabilities,
    this._signIn,
    this._signOut,
    this._resetPasswordForEmail,
    this._updatePassword,
  });

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

  /// Sticky latch: once recovery is seen, bootstrap/capabilities must not
  /// overwrite it with login/shell phases.
  bool _passwordRecoveryLatched = false;
  bool _authStarted = false;

  bool get isLocalPrototype => phase == AdminSessionPhase.localPrototype;
  bool get isConnectedBackend =>
      !isLocalPrototype && AdminBackendConfig.isConfigured;
  bool get isAuthenticated =>
      phase == AdminSessionPhase.ready || phase == AdminSessionPhase.noAccess;
  bool get hasAdminAccess => phase == AdminSessionPhase.ready;
  bool get isPasswordRecovery =>
      _passwordRecoveryLatched || phase == AdminSessionPhase.passwordRecovery;

  /// Initialize Supabase and attach [onAuthStateChange] as early as possible,
  /// before router/capability checks.
  Future<void> startAuthEarly() async {
    if (_authStarted) return;
    _authStarted = true;

    errorMessage = null;
    // Keep infoMessage if returning from password update.
    if (!_passwordRecoveryLatched) {
      phase = AdminSessionPhase.bootstrapping;
    }
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

      // Critical: subscribe before any capability / router decisions.
      _attachAuthListener();

      // Allow the auth client to process the recovery fragment from the URL.
      await Future<void>.delayed(Duration.zero);

      if (_passwordRecoveryLatched || _detectPasswordRecoveryFromUri()) {
        _enterPasswordRecovery();
      }
    } catch (_) {
      if (_passwordRecoveryLatched) {
        _enterPasswordRecovery();
        return;
      }
      phase = AdminSessionPhase.error;
      capabilities = AdminCapabilities.empty;
      errorMessage =
          'Не удалось подключить безопасный вход. Проверьте конфигурацию и сеть.';
      notifyListeners();
    }
  }

  /// Finish startup after auth is ready. Never overwrites recovery.
  Future<void> completeBootstrap() async {
    if (_passwordRecoveryLatched ||
        phase == AdminSessionPhase.passwordRecovery) {
      _enterPasswordRecovery();
      return;
    }

    if (phase == AdminSessionPhase.localPrototype ||
        phase == AdminSessionPhase.error) {
      return;
    }

    if (!_supabaseReady && !AdminBackendConfig.isDemoMode) {
      // startAuthEarly failed or was skipped.
      return;
    }

    try {
      if (_initializeSupabase != null) {
        // Injected test client — no live session unless latched.
        if (_passwordRecoveryLatched) {
          _enterPasswordRecovery();
          return;
        }
        phase = AdminSessionPhase.signedOut;
        capabilities = AdminCapabilities.empty;
        notifyListeners();
        return;
      }

      final session = Supabase.instance.client.auth.currentSession;
      if (_passwordRecoveryLatched || _detectPasswordRecoveryFromUri()) {
        _enterPasswordRecovery();
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
      if (_passwordRecoveryLatched) {
        _enterPasswordRecovery();
        return;
      }
      phase = AdminSessionPhase.error;
      capabilities = AdminCapabilities.empty;
      errorMessage =
          'Не удалось подключить безопасный вход. Проверьте конфигурацию и сеть.';
      notifyListeners();
    }
  }

  /// Full bootstrap (tests / fallback when [startAuthEarly] was not used).
  Future<void> bootstrap() async {
    await startAuthEarly();
    await completeBootstrap();
  }

  void _enterPasswordRecovery() {
    _passwordRecoveryLatched = true;
    phase = AdminSessionPhase.passwordRecovery;
    capabilities = AdminCapabilities.empty;
    errorMessage = null;
    notifyListeners();
  }

  void _attachAuthListener() {
    _authSub?.cancel();
    if (_initializeSupabase != null) {
      // Test / injected path — no live Supabase client required.
      return;
    }
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        if (data.event == AuthChangeEvent.passwordRecovery) {
          _enterPasswordRecovery();
        }
      });
    } catch (_) {
      // Listener is best-effort; URI type=recovery still covers email links.
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
      final type = Uri.base.queryParameters['type'];
      if (type == 'recovery') {
        return true;
      }
    } catch (_) {
      // Ignore malformed URIs.
    }
    return false;
  }

  @visibleForTesting
  void debugEnterPasswordRecovery() {
    _enterPasswordRecovery();
  }

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    if (_passwordRecoveryLatched) {
      _enterPasswordRecovery();
      return;
    }

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
      if (_passwordRecoveryLatched) {
        _enterPasswordRecovery();
        return;
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
      _passwordRecoveryLatched = false;
      await signOut();
      infoMessage = 'Пароль изменён';
      notifyListeners();
    } on AuthException catch (error) {
      _enterPasswordRecovery();
      errorMessage = _friendlyResetError(error);
      notifyListeners();
    } catch (_) {
      _enterPasswordRecovery();
      errorMessage = 'Не удалось сохранить пароль. Попробуйте ещё раз.';
      notifyListeners();
    }
  }

  Future<void> refreshCapabilities() async {
    if (_passwordRecoveryLatched) {
      _enterPasswordRecovery();
      return;
    }

    phase = AdminSessionPhase.loadingCapabilities;
    errorMessage = null;
    notifyListeners();

    try {
      final loader = _loadCapabilities;
      final loaded = loader != null
          ? await loader()
          : await _fetchCapabilities();

      if (_passwordRecoveryLatched) {
        _enterPasswordRecovery();
        return;
      }

      capabilities = loaded;
      phase = loaded.hasAnyAdminAccess
          ? AdminSessionPhase.ready
          : AdminSessionPhase.noAccess;
      notifyListeners();
    } catch (_) {
      if (_passwordRecoveryLatched) {
        _enterPasswordRecovery();
        return;
      }
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

    // Drop private Admin news image bytes so the next session cannot reuse them.
    NewsImageBytesCache.instance.clear();

    _passwordRecoveryLatched = false;
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
    if (message.contains('otp_expired') || message.contains('expired')) {
      return 'Ссылка для сброса устарела. Запросите новую.';
    }
    return 'Не удалось выполнить операцию. Попробуйте ещё раз.';
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
