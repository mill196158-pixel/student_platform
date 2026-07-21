import 'package:go_router/go_router.dart';

import '../core/auth/login_screen.dart';
import '../core/navigation/admin_shell.dart';
import '../features/academic/subjects/subjects_screen.dart';
import '../features/academic/teachers/teachers_screen.dart';
import '../features/content/news/news_editor_screen.dart';
import '../features/dashboard/dashboard_screen.dart';

final adminRouter = GoRouter(
  initialLocation: '/dashboard',
  routes: [
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    ShellRoute(
      builder: (context, state, child) =>
          AdminShell(currentPath: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (context, state) => const DashboardScreen(),
        ),
        GoRoute(
          path: '/content/news',
          builder: (context, state) => const NewsEditorScreen(),
        ),
        GoRoute(
          path: '/academic/subjects',
          builder: (context, state) => const SubjectsScreen(),
        ),
        GoRoute(
          path: '/academic/teachers',
          builder: (context, state) => const TeachersScreen(),
        ),
      ],
    ),
  ],
);
