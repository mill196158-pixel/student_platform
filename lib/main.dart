import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kReleaseMode, kIsWeb, defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
// import 'package:get_storage/get_storage.dart'; // Временно отключено
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
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
import 'src/ui/info/info_screen.dart';
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
import 'src/core/pinned_media_host.dart';
import 'src/core/pinned_media_switch.dart';
import 'src/core/pinned_media_status_host.dart';
import 'src/core/offline_policy_grant.dart';
import 'src/core/sqlite_policy_grant_store.dart';
import 'src/core/coordinated_refresh_client.dart';
import 'src/core/refresh_security_fence.dart';
import 'src/core/offline_startup_admission.dart';
import 'src/core/local_snapshot_startup.dart';
import 'src/core/auth_session.dart';
import 'src/core/refresh_policy_grant_observer.dart';
import 'src/core/settled_policy_transport.dart';
import 'src/core/auth_transition_host.dart';
import 'src/core/serial_auth_local_storage.dart';
import 'src/core/session_capabilities_host.dart';
import 'src/core/session_capabilities.dart';
import 'src/ui/home/cached_home_schedule_reader.dart';
import 'src/ui/home/home_snapshot_cache.dart';
import 'src/ui/navigation/cached_team_chat_directory.dart';
import 'src/ui/home/home_content_coordinator.dart';
import 'src/ui/info/home_content_snapshot_store.dart';
import 'src/ui/schedule/schedule_month_cache.dart';
import 'src/core/offline_policy_grant_host.dart';
import 'src/core/guarded_policy_redirect.dart';
import 'src/core/qa_capability_view.dart';
import 'src/core/qa_rotation_navigation_guard.dart';
import 'src/core/qa_rotation_receipt.dart';
import 'src/core/qa_online_side_effect_coordinator.dart';
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
const _qaRotationNavigation = bool.fromEnvironment('QA_ROTATION_NAVIGATION_EXPERIMENT');
final _qaRotationReceipt = QaRotationReceipt();
AuthSessionScope? _policyQaScope;
PinnedMediaHost? _pinnedMediaHost;
@visibleForTesting
Future<void> debugDisposePinnedMediaHost() async {
  final host = _pinnedMediaHost;
  _pinnedMediaHost = null;
  await host?.dispose();
}
SqlitePolicyGrantStore? _policyQaStore;
OfflineStartupAdmission? _policyQaAdmission;
RefreshPolicyGrantObserver? _qaRefreshGrantObserver;
RefreshAdmissionClient? _qaRefreshGate;
RefreshAdmissionClient? _ordinaryRefreshGate;
HomeContentCoordinator? _qaHomeContent;
LocalSnapshotStartup? _ordinarySnapshotStartup;
VoidCallback? _ordinaryRejectHeldGate;
http.Client? _debugOrdinaryHttp;
RealtimeClientOptions? _debugOrdinaryRealtime;
String? _debugOrdinaryDatabasePath;
sqlite.DatabaseFactory? _debugOrdinaryDatabaseFactory;
void Function(sqlite.Database)? _debugChatDatabaseOpened;
final _ordinaryStartupPending = ValueNotifier<bool>(false);
final _ordinaryRouteRefresh = ValueNotifier<int>(0);
bool _ordinaryCacheUnavailable = false;
bool _ordinaryCleanColdStart = true;
bool get _ordinaryOffline => !_ordinaryCacheUnavailable && !_sqlitePolicyQa && !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
@visibleForTesting
bool get debugOrdinaryOfflineEnabled => _ordinaryOffline;

void _watchOrdinaryScope(AuthSessionScope scope) {
  var previous = scope.capture();
  var hadSession = Supabase.instance.client.auth.currentSession != null;
  scope.addListener(() {
    final current = scope.capture();
    final hasSession = Supabase.instance.client.auth.currentSession != null;
    final signedOut = hadSession && !hasSession;
    hadSession = hasSession;
    if (signedOut) {
      _ordinaryRejectHeldGate?.call();
      scheduleMicrotask(() {
        if (Supabase.instance.client.auth.currentSession == null) appRouter.go('/guest');
      });
    }
    if (current == previous) return;
    previous = current;
    _ordinaryRouteRefresh.value++;
  });
}

@visibleForTesting
void debugConfigureOrdinaryOffline({
  required AuthSessionScope scope,
  required LocalSnapshotStartup startup,
  required ProjectChatServerCache chatCache,
}) {
  assert(!kReleaseMode);
  _policyQaScope = scope;
  _watchOrdinaryScope(scope);
  _ordinarySnapshotStartup = startup;
  ProjectChatServerCache.qaInstance = chatCache;
  _ordinaryStartupPending.value = scope.capture() != null;
}

@visibleForTesting
Future<void> debugInitializeOrdinaryApp({required http.Client client,
    required String databasePath, required sqlite.DatabaseFactory databaseFactory,
    RealtimeClientOptions? realtimeOptions,
    void Function(sqlite.Database)? onChatDatabaseOpened}) async {
  assert(!kReleaseMode);
  _debugOrdinaryHttp = client;
  _debugOrdinaryRealtime = realtimeOptions;
  _debugOrdinaryDatabasePath = databasePath;
  _debugOrdinaryDatabaseFactory = databaseFactory;
  _debugChatDatabaseOpened = onChatDatabaseOpened;
  await _initializeApp((_) {}, initializeTheme: false);
}

/// ===== GoRouter =====
final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/splash',
  refreshListenable: _ordinaryRouteRefresh,
  observers: [routeObserver],
  redirect: (context, state) {
    final caps = SessionCapabilitiesHost.maybeRead(context);
    if (((_sqlitePolicyQa && _offlineUiQa) || _ordinaryOffline) &&
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
      mayAllow: !_ordinaryOffline ? null : () {
        final gate = _ordinaryRefreshGate;
        return gate != null && !gate.timedOutDrainBlocksAdmission;
      },
      onAllowed: !_ordinaryOffline ? null : (owner) {
        final caps = SessionCapabilitiesHost.maybeRead(context);
        if (caps == null || caps.capture(SessionCapability.networkRead) != null) return;
        final attempt = caps.beginAuthorization(owner);
        if (attempt != null) caps.grant(SessionCapabilityMode.online, attempt);
      },
    );
  },
  routes: [
    GoRoute(
      path: '/splash',
      builder: (context, state) {
        final manualRetry = state.uri.queryParameters['retry'] == '1' &&
            !(_ordinaryOffline && state.uri.queryParameters['offline'] == '1' &&
                _ordinarySnapshotStartup != null);
        final networkUnavailable = state.uri.queryParameters['offline'] == '1';
        final admission = _offlineUiQa ? _policyQaAdmission : null;
        final localAdmission = _ordinaryOffline ? _ordinarySnapshotStartup : null;
        final caps = SessionCapabilitiesHost.maybeRead(context);
        return SplashScreen(
            key: ValueKey('$manualRetry:$networkUnavailable'),
            manualRetry: manualRetry,
            initialNetworkUnavailable: networkUnavailable,
            qaAdmission: caps == null ? null : admission != null
                ? () => admission.resolve(caps)
                : localAdmission == null ? null : () async {
                    try {
                      final result = await localAdmission.resolve(caps);
                      if (result == OfflineStartupResult.denied ||
                          result == OfflineStartupResult.passwordChangeRequired) {
                        _ordinaryRejectHeldGate?.call();
                      }
                      return result;
                    }
                    finally { _ordinaryStartupPending.value = false; }
                  });
      },
    ),
    GoRoute(
      path: '/login',
      builder: (_, state) {
        if (_ordinaryOffline) _ordinaryCleanColdStart = false;
        return AuthenticateScreen(
          key: ValueKey(state.uri.queryParameters['mode']),
          initialRegister: state.uri.queryParameters['mode'] == 'register',
        );
      },
    ),
    GoRoute(
      path: '/guest',
      builder: (_, __) {
        if (_ordinaryOffline) _ordinaryCleanColdStart = false;
        return const NavigationScreen(key: ValueKey('guest-shell'), guest: true);
      },
    ),
    GoRoute(
      path: '/home',
      builder: (context, __) {
        final caps = SessionCapabilitiesHost.maybeRead(context);
        final scope = AuthSessionScopeHost.maybeRead(context);
        if (_ordinaryOffline && caps != null && scope != null) {
          Widget cached(BuildContext context) {
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
                homeContent: _qaHomeContent,
                homeContentCapabilities: caps,
                cachedInfo: chats == null ? null : (_) => InfoScreen(
                    cachedStore: chats, cachedCapabilities: caps),
                cachedLearning: chats == null ? null : (_) => CachedTeamChatDirectory(
                    store: chats, capabilities: caps, subjectsOnly: false),
                cachedProfile: chats == null ? null : (_) => ProfileScreen(
                    cachedReader: reader, cachedChats: chats, cachedCapabilities: caps));
            } catch (_) {
              return const Scaffold(body: Center(child: Text('Сохранённые данные недоступны.')));
            }
          }
          return QaCapabilityView(capabilities: caps,
              blockedBuilder: (_) => const Scaffold(body: Center(
                  child: Text('Сохранённые данные недоступны.'))),
              onlineBuilder: (_, barrier) {
                _ordinaryCleanColdStart = false;
                return PushSessionHost(barrier: barrier,
                    child: NavigationScreen(onlineBarrier: barrier, homeContent: _qaHomeContent));
              },
              cachedBuilder: cached);
        }
        if (_sqlitePolicyQa && _offlineUiQa) {
          if (caps == null || scope == null)
            return const Scaffold(
                body: Center(child: Text('Сохранённые данные недоступны.')));
          Widget blocked(BuildContext _) => const Scaffold(
              body: Center(child: Text('Сохранённые данные недоступны.')));
          return QaCapabilityView(
              capabilities: caps,
              retainOnlineForRotation: _qaRotationNavigation,
              blockedBuilder: blocked,
              onlineBuilder: (_, barrier) => SessionKeeper(
                  barrier: barrier,
                  child: PushSessionHost(
                      barrier: barrier,
                      child: InAppToastHost(
                          barrier: barrier,
                          child: NavigationScreen(
                              onlineBarrier: barrier,
                              homeContent: _qaHomeContent)))),
              cachedBuilder: (_) {
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
                      homeContent: _qaHomeContent,
                      homeContentCapabilities: caps,
                      cachedInfo: chats == null ? null : (_) => InfoScreen(
                        cachedStore: chats, cachedCapabilities: caps),
                      cachedLearning: chats == null ? null : (_) => CachedTeamChatDirectory(
                        store: chats, capabilities: caps, subjectsOnly: false),
                      cachedProfile: chats == null
                          ? null
                          : (_) => ProfileScreen(
                              cachedReader: reader,
                              cachedChats: chats,
                              cachedCapabilities: caps));
                } catch (_) {
                  return blocked(context);
                }
              });
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
      if (_sqlitePolicyQa || _ordinaryOffline ||
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
  final useOrdinaryOffline = _ordinaryOffline;
  final inner = (usePolicyQa || useOrdinaryOffline)
      ? (useOrdinaryOffline ? _debugOrdinaryHttp : null) ?? http.Client() : null;
  final refreshFence = RefreshSecurityFence();
  final gate = inner == null
      ? null
      : RefreshAdmissionClient(inner, securityFence: refreshFence,
          trackQaRefresh: _qaRotationNavigation);
  if (_qaRotationNavigation) _qaRefreshGate = gate;
  if (useOrdinaryOffline) _ordinaryRefreshGate = gate;
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
      realtimeClientOptions: _debugOrdinaryRealtime ?? const RealtimeClientOptions(),
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
      if (_offlineUiQa) {
        final contentDb = await openHomeContentSnapshotDatabase(
            '$directory/offline_home_content_qa_v1.db');
        _qaHomeContent = HomeContentCoordinator(
            store: HomeContentSnapshotStore(
                db: contentDb,
                scope: scope,
                currentBinding: binding,
                project: SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '')),
            scope: scope,
            httpClient: inner);
      }
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
      if (_offlineUiQa) {
        _qaRefreshGrantObserver = RefreshPolicyGrantObserver(client: client,
          scope: scope, store: store, gate: gate, fence: refreshFence,
          policy: SettledPolicyTransport(inner), backend: Uri.parse(SupabaseConfig.url),
          publicKey: SupabaseConfig.anonKey,
          onVerifiedRotation: _qaRotationNavigation ? _qaRotationReceipt.record : null,
          closePreviousOnline: () => QaOnlineSideEffectCoordinator.instance
              .closeAndWait(timeout: const Duration(seconds: 10)));
      }
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
            publicKey: SupabaseConfig.anonKey,
            onInitialRefreshAdmitted: _qaRotationNavigation
                ? (owner, caps) => _qaRotationReceipt.record(owner, owner, caps)
                : null,
            onOnlineAdmitted: (owner, binding, caps) =>
                _qaRefreshGrantObserver?.arm(owner, binding, caps));
      }
      gate.bind(CoordinatedRefreshClient(inner, store,
          currentRefreshToken: () => client.auth.currentSession?.refreshToken,
          securityFence: refreshFence,
          monitor: monitor));
    } else if (useOrdinaryOffline && gate != null && inner != null) {
      final client = Supabase.instance.client;
      final scope = AuthSessionScope(
          currentSession: () => client.auth.currentSession,
          authEvents: client.auth.onAuthStateChange);
      await scope.ready;
      _policyQaScope = scope;
      _watchOrdinaryScope(scope);
      final project = SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '');
      final issuer = '$project/auth/v1';
      OfflineSessionBinding? binding() {
        final session = client.auth.currentSession;
        return session == null ? null : OfflineSessionBinding.fromSession(session, issuer);
      }
      if (pinnedMediaRuntimeEnabled() || sourceDocumentFenceEnabled()) {
        _pinnedMediaHost = PinnedMediaHost(scope: scope, project: project,
            currentSession: () => client.auth.currentSession, currentBinding: binding,
            supportDirectory: getApplicationSupportDirectory,
            cacheDirectory: getApplicationCacheDirectory,
            databaseFactory: _debugOrdinaryDatabaseFactory)..start();
      }
      sqlite.Database? chatDb;
      try {
        final directory = _debugOrdinaryDatabasePath ?? await sqlite.getDatabasesPath();
        chatDb = await openProjectChatServerDatabase(
            '$directory/offline_chat_ordinary_v1.db', factory: _debugOrdinaryDatabaseFactory);
        _debugChatDatabaseOpened?.call(chatDb);
        final contentDb = await openHomeContentSnapshotDatabase(
            '$directory/offline_home_content_ordinary_v1.db', factory: _debugOrdinaryDatabaseFactory);
        ProjectChatServerCache.qaInstance = ProjectChatServerCache(
            db: chatDb, scope: scope, currentBinding: binding, project: project);
        _qaHomeContent = HomeContentCoordinator(
            store: HomeContentSnapshotStore(
                db: contentDb, scope: scope, currentBinding: binding, project: project),
            scope: scope, httpClient: inner);
      } catch (error) {
        // A damaged or full offline cache must not prevent ordinary online
        // use. Preserve the database files and the SDK session for recovery.
        try { if (chatDb != null) await closeProjectChatServerDatabase(chatDb); } catch (_) {}
        ProjectChatServerCache.qaInstance = null;
        _qaHomeContent = null;
        _ordinarySnapshotStartup = null;
        _ordinaryCacheUnavailable = true;
        _ordinaryStartupPending.value = false;
        gate.bind(inner);
        gate.resume();
        debugPrint('[offline] Cache unavailable: ${error.runtimeType}');
      }
      if (!_ordinaryCacheUnavailable) {
      final transport = SettledPolicyTransport(inner);
      var gateBound = false;
      Timer? reconnectTimer;
      var reconnectInFlight = false;
      var enteringCache = false;
      scope.addListener(() {
        if (scope.capture() == null) {
          reconnectTimer?.cancel();
          reconnectTimer = null;
        }
      });
      void openGate() {
        if (!gateBound) {
          gateBound = true;
          gate.bind(inner);
        }
        gate.resume();
      }
      void rejectHeldGate() { rejectHeldRefreshesSafely(gate, openGate); }
      _ordinaryRejectHeldGate = rejectHeldGate;
      {
        bool sameSession(OfflineSessionBinding expected) {
          return isSameLocalSnapshotSession(scope, expected, client.auth.currentSession);
        }
        Future<bool> probeConnection() async {
          final abort = Completer<void>();
          final timer = Timer(const Duration(seconds: 2), () {
            if (!abort.isCompleted) abort.complete();
          });
          try {
            final request = http.AbortableRequest('GET', Uri.parse('$project/auth/v1/health'),
                abortTrigger: abort.future)
              ..followRedirects = false
              ..headers['apikey'] = SupabaseConfig.anonKey;
            final response = await inner.send(request).timeout(const Duration(seconds: 3));
            await response.stream.drain<void>().timeout(const Duration(seconds: 3));
            return response.statusCode == 200;
          } catch (_) {
            return false;
          } finally {
            timer.cancel();
            if (!abort.isCompleted) abort.complete();
          }
        }
        void watchForReconnect(OfflineSessionBinding expected) {
          reconnectTimer?.cancel();
          reconnectTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
            if (!sameSession(expected)) {
              timer.cancel();
              return;
            }
            if (reconnectInFlight) return;
            reconnectInFlight = true;
            probeConnection().then((available) {
              if (!timer.isActive || !available || enteringCache || !sameSession(expected)) return;
              timer.cancel();
              openGate();
              appRouter.go('/splash');
            }, onError: (Object _, StackTrace __) {}).whenComplete(() {
              reconnectInFlight = false;
            });
          });
        }
        _ordinaryStartupPending.value = scope.capture() != null && binding() != null;
        _ordinarySnapshotStartup = LocalSnapshotStartup(
            scope: scope,
            issuer: issuer,
            restore: () {
              if (client.auth.currentSession?.isExpired == true && !gateBound) {
                final expected = binding();
                unawaited(probeConnection().then((available) {
                  if (expected != null && available && !enteringCache && sameSession(expected)) openGate();
                }));
              }
              return AuthSession.restoreSessionStatus(client);
            },
            checkPolicy: () {
              final owner = scope.capture();
              final session = client.auth.currentSession;
              if (owner == null || session == null || !scope.matchesSession(owner, session)) {
                return Future.value(SettledPolicyStatus.indeterminate);
              }
              return transport.check(backend: Uri.parse(project), userId: owner.userId,
                  accessToken: session.accessToken, publicKey: SupabaseConfig.anonKey,
                  timeout: const Duration(seconds: 12));
            },
            onCacheOnly: () async {
              enteringCache = true;
              try {
                if (!_ordinaryCleanColdStart) {
                  throw StateError('Local-only mode requires a clean cold start');
                }
                await gate.suspendAndDrain(timeout: const Duration(seconds: 8));
                final closed = await QaOnlineSideEffectCoordinator.instance
                    .closeAndWait(timeout: const Duration(seconds: 10));
                if (!closed) throw StateError('Online work did not drain');
                final expected = binding();
                if (expected == null || !sameSession(expected)) throw StateError('Session changed');
                watchForReconnect(expected);
              }
              finally { enteringCache = false; }
            },
            onOnline: () async {
              gate.requireAuthDrained();
              reconnectTimer?.cancel();
              openGate();
            },
            onLateDenial: (passwordChangeRequired) {
              reconnectTimer?.cancel();
              rejectHeldGate();
              appRouter.go(passwordChangeRequired ? '/change-password' : '/login');
            });
      }
      if (scope.capture() == null || binding() == null) {
        openGate();
      }
      }
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
                      durableMode: ForwardOutboxHost.mobileProductionMode,
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
                                builder: (context, child) {
                                  final routes = child ?? const SizedBox.shrink();
                                  if (_sqlitePolicyQa && _offlineUiQa && _qaRotationNavigation) {
                                    final caps = SessionCapabilitiesHost.maybeRead(context);
                                    final scope = AuthSessionScopeHost.maybeRead(context);
                                    if (caps == null || scope == null) return const SizedBox.shrink();
                                    return QaRotationNavigationGuard(scope: scope,
                                        capabilities: caps, receipt: _qaRotationReceipt,
                                        refreshStarts: _qaRefreshGate?.refreshStarts,
                                        hasPendingRefresh: () => _qaRefreshGate?.qaRefreshPending ?? true,
                                        child: routes);
                                  }
                                  final shell = _sqlitePolicyQa ? routes : InAppToastHost(child: routes);
                                  return pinnedMediaRuntimeEnabled() ? PinnedMediaStatusHost(child: shell) : shell;
                                },

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
  Widget build(BuildContext context) {
    if (_sqlitePolicyQa && !kIsWeb) return child;
    if (!_ordinaryOffline) return SessionKeeper(child: child);
    final caps = SessionCapabilitiesHost.maybeOf(context);
    return ValueListenableBuilder<bool>(
      valueListenable: _ordinaryStartupPending,
      builder: (context, pending, _) => SessionKeeper(
        enabled: !pending && caps?.mode != SessionCapabilityMode.cacheOnly,
        child: child,
      ),
    );
  }
}
