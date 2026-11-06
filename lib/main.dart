import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kReleaseMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
// import 'package:get_storage/get_storage.dart'; // Временно отключено
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:supabase_flutter/supabase_flutter.dart';

// Глобальный кэш
import 'src/ui/learning/global_cache.dart';

// Темы
import 'src/themes/themes.dart';
import 'src/themes/theme_service.dart';

// Экраны
import 'src/ui/splash/splash_screen.dart';
import 'src/ui/authentication/authenticate_screen.dart';
import 'src/ui/authentication/screens/change_password_screen.dart';
import 'src/ui/navigation/navigation_screen.dart';
import 'src/ui/profile/profile_screen.dart';
import 'src/ui/profile/edit_profile_screen.dart';
import 'src/ui/profile/personal_diary_screen.dart';
import 'src/ui/profile/my_reviews_screen.dart';
import 'src/ui/exams/exams_screen.dart';
import 'src/ui/schedule/subject_diary/subject_diary.dart';
import 'src/ui/notifications/notification_settings_screen.dart';
import 'src/ui/notifications/push_session_host.dart';
import 'src/ui/notifications/in_app_toast_host.dart';
import 'src/config/supabase_config.dart';
import 'src/core/session_keeper.dart';
import 'src/core/auth_session_scope_host.dart';
import 'src/core/auth_session_scope.dart';
import 'src/core/offline_policy_grant.dart';
import 'src/core/sqlite_policy_grant_store.dart';
import 'src/core/coordinated_refresh_client.dart';
import 'src/core/refresh_security_fence.dart';
import 'src/core/offline_startup_admission.dart';
import 'src/core/settled_policy_transport.dart';
import 'src/core/auth_transition_host.dart';
import 'src/core/serial_auth_local_storage.dart';
import 'src/core/session_capabilities_host.dart';
import 'src/core/session_capabilities.dart';
import 'src/ui/home/cached_home_schedule_reader.dart';
import 'src/ui/home/home_snapshot_cache.dart';
import 'src/ui/schedule/schedule_month_cache.dart';
import 'src/core/offline_policy_grant_host.dart';
import 'src/core/guarded_policy_redirect.dart';
import 'src/ui/chats/forward/forward_outbox_host.dart';
import 'src/ui/learning/state/team_snapshot_host.dart';
import 'src/services/push/push_notification_service.dart';
import 'src/navigation/root_nav.dart';
import 'router_observer.dart';
import 'src/ui/learning/state/team_cubit.dart';
import 'src/ui/learning/models/team.dart';
import 'src/ui/chats/core/chat_message_cache_store.dart';
import 'src/ui/chats/core/project_chat_server_cache.dart';
import 'src/ui/chats/data/chat_summaries_cache.dart';
import 'src/ui/friends/data/friends_snapshot_cache.dart';

// The QA build must opt in explicitly; production stays on the existing path
// until the SQLite migration, logout and cold-start integration are reviewed.
const _sqlitePolicyQa = bool.fromEnvironment('SQLITE_POLICY_QA');
// Remains off until cache ownership and all offline side effects are reviewed.
const _offlineUiQa = bool.fromEnvironment('OFFLINE_UI_QA');
AuthSessionScope? _policyQaScope;
SqlitePolicyGrantStore? _policyQaStore;
OfflineStartupAdmission? _policyQaAdmission;

/// ===== GoRouter =====
final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/splash',
  observers: [routeObserver],
  redirect: (context, state) {
    final caps = SessionCapabilitiesHost.maybeRead(context);
    if (_sqlitePolicyQa &&
        _offlineUiQa &&
        caps?.mode == SessionCapabilityMode.cacheOnly) {
      return state.uri.path == '/home' || state.uri.path == '/splash'
          ? null
          : '/home';
    }
    final client = Supabase.instance.client;
    return guardedPolicyRedirect(
      path: state.uri.path,
      hasSession: () => client.auth.currentSession != null,
      currentAccess: () =>
          context.mounted ? OfflinePolicyGrantHost.maybeRead(context) : null,
    );
  },
  routes: [
    GoRoute(
      path: '/splash',
      builder: (context, state) {
        final manualRetry = state.uri.queryParameters['retry'] == '1';
        final admission = _offlineUiQa ? _policyQaAdmission : null;
        final caps = SessionCapabilitiesHost.maybeRead(context);
        return SplashScreen(
            key: ValueKey(manualRetry),
            manualRetry: manualRetry,
            qaAdmission: admission == null || caps == null
                ? null
                : () => admission.resolve(caps));
      },
    ),
    GoRoute(
      path: '/login',
      builder: (_, state) => AuthenticateScreen(
        key: ValueKey(state.uri.queryParameters['mode']),
        initialRegister: state.uri.queryParameters['mode'] == 'register',
      ),
    ),
    GoRoute(
      path: '/guest',
      builder: (_, __) =>
          const NavigationScreen(key: ValueKey('guest-shell'), guest: true),
    ),
    GoRoute(
      path: '/home',
      builder: (context, __) {
        final caps = SessionCapabilitiesHost.maybeRead(context);
        final scope = AuthSessionScopeHost.maybeRead(context);
        if (_sqlitePolicyQa &&
            _offlineUiQa &&
            caps?.mode == SessionCapabilityMode.cacheOnly) {
          if (caps == null || scope == null)
            return const Scaffold(
                body: Center(child: Text('Сохранённые данные недоступны.')));
          try {
            final reader = CachedHomeScheduleReader(
                capabilities: caps,
                home: HomeSnapshotCache(
                    project: SupabaseConfig.url,
                    authScope: scope,
                    currentUserId: () => scope.capture()?.userId,
                    sessionGeneration: () => scope.generation,
                    sessionIdentity: scope.capture),
                schedule: ScheduleMonthCache(scope, SupabaseConfig.url));
            final chats = ProjectChatServerCache.qaInstance;
            return NavigationScreen(
                cachedReader: reader,
                cachedProfile: chats == null
                    ? null
                    : (_) => ProfileScreen(
                        cachedReader: reader,
                        cachedChats: chats,
                        cachedCapabilities: caps));
          } catch (_) {
            return const Scaffold(
                body: Center(child: Text('Сохранённые данные недоступны.')));
          }
        }
        return const PushSessionHost(child: NavigationScreen());
      },
    ),
    GoRoute(
      path: '/change-password',
      builder: (_, __) => const ChangePasswordScreen(),
    ),
    GoRoute(
      path: '/profile',
      builder: (_, __) => const ProfileScreen(),
    ),
    GoRoute(
      path: '/edit-profile',
      builder: (_, __) => const EditProfileScreen(),
    ),
    GoRoute(
      path: '/exams',
      builder: (_, __) => const ExamsScreen(),
    ),
    GoRoute(
      path: '/my-diary',
      builder: (_, __) => const PersonalDiaryScreen(),
    ),
    GoRoute(
      path: '/my-reviews',
      builder: (_, __) => const MyReviewsScreen(),
    ),
    GoRoute(
      path: '/notification-settings',
      builder: (_, __) => const NotificationSettingsScreen(),
    ),
  ],
);

Future<void> main() async {
  final startup = Stopwatch()..start();
  void stage(String name) {
    if (!kReleaseMode || const bool.fromEnvironment('STARTUP_TRACE'))
      debugPrint('[startup-perf] $name ${startup.elapsedMilliseconds}ms');
  }

  WidgetsFlutterBinding.ensureInitialized();
  stage('binding-ready');

  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  if (android) {
    // Draw the branded loader while the session and disk caches initialize.
    await Future.wait([
      ProductLoadingIndicator.preload(),
      themeService.initialize(),
    ]);
    runApp(const _StartupApp());
    await WidgetsBinding.instance.endOfFrame;
    stage('loader-frame');
  } else {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }
  stage('orientation-ready');

  try {
    await _initializeApp(stage, initializeTheme: !android);
  } catch (error) {
    if (!android) rethrow;
    debugPrint('[startup] Initialization failed: ${error.runtimeType}');
    runApp(const _StartupApp(failed: true));
    return;
  }

  runApp(const StudentPlatformApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    stage('first-frame');
    unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      stage('first-raster');
      if (_sqlitePolicyQa ||
          Supabase.instance.client.auth.currentSession == null) return;
      unawaited(PushNotificationService.instance.bootstrapFirebase().then((_) {
        stage(PushNotificationService.instance.isFirebaseReady
            ? 'push-ready'
            : 'push-unavailable');
      }));
    }));
  });
}

Future<void> _initializeApp(
  void Function(String) stage, {
  required bool initializeTheme,
}) async {
  SupabaseConfig.validate();
  final usePolicyQa = _sqlitePolicyQa && !kIsWeb;
  final inner = usePolicyQa ? http.Client() : null;
  final refreshFence = RefreshSecurityFence();
  final gate = inner == null
      ? null
      : RefreshAdmissionClient(inner, securityFence: refreshFence);
  sqlite.Database? policyDb;
  try {
    if (usePolicyQa) {
      final directory = await sqlite.getDatabasesPath();
      policyDb =
          await openPolicyGrantDatabase('$directory/offline_policy_qa_v2.db');
    }
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
      httpClient: gate,
      authOptions: FlutterAuthClientOptions(
        // Disabling auto refresh causes the SDK's recoverSession to sign out
        // an expired saved session. The admission gate holds transport instead.
        autoRefreshToken: true,
        localStorage: createSerialSdkAuthStorage(SupabaseConfig.url),
      ),
    );
    if (gate != null && policyDb != null && inner != null) {
      final client = Supabase.instance.client;
      final scope = AuthSessionScope(
          currentSession: () => client.auth.currentSession,
          authEvents: client.auth.onAuthStateChange);
      await scope.ready;
      final issuer =
          '${SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '')}/auth/v1';
      OfflineSessionBinding? binding() {
        final session = client.auth.currentSession;
        return session == null
            ? null
            : OfflineSessionBinding.fromSession(session, issuer);
      }

      final store = SqlitePolicyGrantStore(
          scope: scope,
          currentBinding: binding,
          coordinator: SqlitePolicyGrantCoordinator(policyDb));
      final directory = await sqlite.getDatabasesPath();
      final chatDb = await openProjectChatServerDatabase(
          '$directory/offline_chat_qa_v1.db');
      ProjectChatServerCache.qaInstance = ProjectChatServerCache(
          db: chatDb,
          scope: scope,
          currentBinding: binding,
          project: SupabaseConfig.url.replaceFirst(RegExp(r'/$'), ''));
      final owner = scope.capture();
      final sessionBinding = binding();
      final prior = owner == null || sessionBinding == null
          ? null
          : await store.capturePriorGrant(owner, sessionBinding);
      final monitor = RefreshTransportMonitor();
      final fenceRevision = refreshFence.revision;
      _policyQaScope = scope;
      _policyQaStore = store;
      if (owner != null && sessionBinding != null) {
        _policyQaAdmission = OfflineStartupAdmission(
            client: client,
            scope: scope,
            store: store,
            gate: gate,
            monitor: monitor,
            fence: refreshFence,
            owner: owner,
            binding: sessionBinding,
            prior: prior,
            fenceRevision: fenceRevision,
            policy: SettledPolicyTransport(inner),
            backend: Uri.parse(SupabaseConfig.url),
            publicKey: SupabaseConfig.anonKey);
      }
      gate.bind(CoordinatedRefreshClient(inner, store,
          currentRefreshToken: () => client.auth.currentSession?.refreshToken,
          securityFence: refreshFence,
          monitor: monitor));
    }
  } catch (_) {
    gate?.block();
    rethrow;
  }

  stage('supabase-ready');
  // Firebase/local notification setup must not hold back the first frame.
  // Authenticated push startup still awaits the same single-flight initializer.
  PushNotificationService.instance.bindNavigatorKey(rootNavigatorKey);

  // Поднимаем локальные данные до входа в приложение: после старта чаты
  // и друзья сразу рисуются из дискового кэша, сеть обновляет их в фоне.
  await Future.wait([
    if (initializeTheme) themeService.initialize(),
    GlobalCache().initialize(),
    ChatMessageCacheStore.initializeCurrentUser(),
    ChatSummariesCache.initializeCurrentUser(),
    FriendsSnapshotCache.initializeCurrentUser(),
  ]);

  // Подключаем серверную реализацию дневника предмета
  SubjectDiaryRepository.instance = SubjectDiaryRepositorySupabase();

  stage('local-cache-ready');
}

class _StartupApp extends StatelessWidget {
  const _StartupApp({this.failed = false});

  final bool failed;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light().data,
        darkTheme: AppTheme.dark().data,
        themeMode: themeService.value,
        builder: (_, __) => SplashLoadingView(failed: failed),
      );
}

class StudentPlatformApp extends StatelessWidget {
  const StudentPlatformApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: <BlocProvider<dynamic>>[
        // Глобальный провайдер TeamCubit, доступен во всём приложении
        BlocProvider<TeamCubit>(
          create: (_) => TeamCubit(
            const Team(
              id: '',
              name: 'App',
              teacher: '',
              groupCode: '',
              icon: 'A',
            ),
          ),
        ),
      ],
      child: AuthSessionScopeHost(
          createScope: _policyQaScope == null ? null : () => _policyQaScope!,
          child: AuthTransitionHost(
              child: TeamSnapshotHost(
                  child: ForwardOutboxHost(
                      durableMode: ForwardOutboxHost.androidQaMode,
                      child: OfflinePolicyGrantHost(
                          sqliteStore: _policyQaStore,
                          child: SessionCapabilitiesHost(
                              child: _QaAwareSessionKeeper(
                            child: ValueListenableBuilder<ThemeMode>(
                              valueListenable: themeService,
                              builder: (context, mode, _) => MaterialApp.router(
                                scaffoldMessengerKey: rootScaffoldMessengerKey,
                                title: 'Student Platform',
                                debugShowCheckedModeBanner: false,
                                theme: AppTheme.light().data,
                                darkTheme: AppTheme.dark().data,
                                themeMode: mode,
                                routerConfig: appRouter,
                                builder: (context, child) => _sqlitePolicyQa
                                    ? (child ?? const SizedBox.shrink())
                                    : InAppToastHost(
                                        child:
                                            child ?? const SizedBox.shrink()),

                                // Локализация
                                locale: const Locale('ru', 'RU'),
                                supportedLocales: const [
                                  Locale('ru', 'RU'),
                                  Locale('en', 'US'),
                                ],
                                localizationsDelegates: const [
                                  GlobalMaterialLocalizations.delegate,
                                  GlobalCupertinoLocalizations.delegate,
                                  GlobalWidgetsLocalizations.delegate,
                                ],
                              ),
                            ),
                          ))))))),
    );
  }
}

/// QA admission owns refresh coordination; the normal app retains SessionKeeper.
class _QaAwareSessionKeeper extends StatelessWidget {
  const _QaAwareSessionKeeper({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      _sqlitePolicyQa && !kIsWeb ? child : SessionKeeper(child: child);
}
