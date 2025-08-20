import 'package:go_router/go_router.dart';
import '../features/auth/presentation/login_page.dart';

final class AppRoutes {
  static const login = '/login';
  static const home = '/home';
}

final class AppRouter {
  static final router = GoRouter(
    initialLocation: AppRoutes.login,
    routes: [
      GoRoute(path: AppRoutes.login, builder: (_, __) => const LoginPage()),
      // Домашний экран объявлен в login_page.dart (чтобы уложиться в 5 файлов)
    ],
  );
}
