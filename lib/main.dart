import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
// import 'package:get_storage/get_storage.dart'; // Временно отключено
import 'package:go_router/go_router.dart';
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
import 'src/services/push/push_notification_service.dart';
import 'src/navigation/root_nav.dart';
import 'router_observer.dart';
import 'src/ui/learning/state/team_cubit.dart';
import 'src/ui/learning/models/team.dart';
import 'src/ui/chats/core/chat_message_cache_store.dart';
import 'src/ui/chats/data/chat_summaries_cache.dart';
import 'src/ui/friends/data/friends_snapshot_cache.dart';

/// ===== GoRouter =====
final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/splash',
  observers: [routeObserver],
  routes: [
    GoRoute(
      path: '/splash',
      builder: (_, __) => const SplashScreen(),
    ),
    GoRoute(
      path: '/login',
      builder: (_, __) => AuthenticateScreen(),
    ),
    GoRoute(
      path: '/home',
      builder: (_, __) => const PushSessionHost(child: NavigationScreen()),
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
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Временно отключаем GetStorage для избежания ошибок
  // await GetStorage.init('student_platform');

  SupabaseConfig.validate();
  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
    authOptions: const FlutterAuthClientOptions(
      autoRefreshToken: true,
    ),
  );

  // Mobile-only Firebase bootstrap (no-op on Windows/desktop / missing config).
  PushNotificationService.instance.bindNavigatorKey(rootNavigatorKey);
  await PushNotificationService.instance.bootstrapFirebase();

  // Поднимаем локальные данные до первого кадра: после холодного старта чаты
  // и друзья сразу рисуются из дискового кэша, сеть обновляет их в фоне.
  await Future.wait([
    GlobalCache().initialize(),
    ChatMessageCacheStore.initializeCurrentUser(),
    ChatSummariesCache.initializeCurrentUser(),
    FriendsSnapshotCache.initializeCurrentUser(),
  ]);

  // Подключаем серверную реализацию дневника предмета
  SubjectDiaryRepository.instance = SubjectDiaryRepositorySupabase();

  runApp(const StudentPlatformApp());
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
      child: SessionKeeper(
        child: MaterialApp.router(
          title: 'Student Platform',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light().data,
          darkTheme: AppTheme.dark().data,
          themeMode: themeService.getThemeMode(),
          routerConfig: appRouter,
          builder: (context, child) => InAppToastHost(
            child: child ?? const SizedBox.shrink(),
          ),

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
    );
  }
}
