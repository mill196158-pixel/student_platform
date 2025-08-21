import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
// import 'package:get_storage/get_storage.dart'; // Временно отключено
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Темы
import 'src/themes/themes.dart';
import 'src/themes/theme_service.dart';

// Экраны
import 'src/ui/splash/splash_screen.dart';
import 'src/ui/authentication/authenticate_screen.dart';
import 'src/ui/navigation/navigation_screen.dart';
import 'src/ui/profile/profile_screen.dart';
import 'src/ui/profile/edit_profile_screen.dart';
import 'src/ui/exams/exams_screen.dart';

/// ===== GoRouter =====
final GoRouter appRouter = GoRouter(
  initialLocation: '/splash',
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
      builder: (_, __) => const NavigationScreen(),
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
  ],
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Временно отключаем GetStorage для избежания ошибок
  // await GetStorage.init('student_platform');

  // === ТВОИ реальные значения из Supabase Settings → API ===
  const supabaseUrl = 'https://gwdanmwluhrcfxbnplwd.supabase.co';
  const supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd3ZGFubXdsdWhyY2Z4Ym5wbHdkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUyNjM1MTgsImV4cCI6MjA3MDgzOTUxOH0.tBZ7b_FyOxPWiqkFQf1OIh9c6hJ7Fm2eHyjsDjoBoSA';

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const StudentPlatformApp());
}

class StudentPlatformApp extends StatelessWidget {
  const StudentPlatformApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Student Platform',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light().data,
      darkTheme: AppTheme.dark().data,
      themeMode: themeService.getThemeMode(),
      routerConfig: appRouter,

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
    );
  }
}
