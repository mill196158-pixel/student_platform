import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/admin_session_controller.dart';
import '../core/auth/forgot_password_screen.dart';
import '../core/auth/login_screen.dart';
import '../core/auth/no_access_screen.dart';
import '../core/auth/reset_password_screen.dart';
import '../core/navigation/admin_shell.dart';
import '../features/academic/students/students_screen.dart';
import '../features/academic/subjects/subjects_screen.dart';
import '../features/academic/teachers/teachers_screen.dart';
import '../features/content/news/news_editor_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/moderation/moderation_screen.dart';

bool _isAuthPublicPath(String loc) {
  return loc == '/login' ||
      loc == '/auth/forgot-password' ||
      loc == '/auth/reset-password';
}

GoRouter createAdminRouter(AdminSessionController session) {
  return GoRouter(
    initialLocation: '/dashboard',
    refreshListenable: session,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final phase = session.phase;

      // Recovery wins over bootstrap/capabilities — do not bounce to login/shell.
      if (session.isPasswordRecovery) {
        return loc == '/auth/reset-password' ? null : '/auth/reset-password';
      }

      if (phase == AdminSessionPhase.bootstrapping ||
          phase == AdminSessionPhase.loadingCapabilities) {
        return loc == '/loading' ? null : '/loading';
      }

      if (phase == AdminSessionPhase.localPrototype) {
        if (loc == '/login' ||
            loc == '/loading' ||
            loc == '/no-access' ||
            loc.startsWith('/auth/')) {
          return '/dashboard';
        }
        return null;
      }

      if (phase == AdminSessionPhase.signedOut ||
          phase == AdminSessionPhase.error) {
        if (_isAuthPublicPath(loc)) return null;
        return '/login';
      }

      if (phase == AdminSessionPhase.noAccess) {
        return loc == '/no-access' ? null : '/no-access';
      }

      // ready
      if (loc == '/login' ||
          loc == '/loading' ||
          loc == '/no-access' ||
          loc.startsWith('/auth/')) {
        return '/dashboard';
      }

      final caps = session.capabilities;
      if (loc.startsWith('/content') && !caps.canReadContent) {
        return '/no-access';
      }
      if (loc.startsWith('/academic') && !caps.canReadAcademic) {
        return '/no-access';
      }
      if (loc == '/dashboard' &&
          !caps.canViewDashboard &&
          !caps.hasAnyAdminAccess) {
        return '/no-access';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => LoginScreen(session: session),
      ),
      GoRoute(
        path: '/auth/forgot-password',
        builder: (context, state) => ForgotPasswordScreen(session: session),
      ),
      GoRoute(
        path: '/auth/reset-password',
        builder: (context, state) => ResetPasswordScreen(session: session),
      ),
      GoRoute(
        path: '/no-access',
        builder: (context, state) => NoAccessScreen(session: session),
      ),
      GoRoute(
        path: '/loading',
        builder: (context, state) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      ShellRoute(
        builder: (context, state, child) => AdminShell(
          currentPath: state.uri.path,
          session: session,
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/content/news',
            builder: (context, state) => NewsEditorScreen(session: session),
          ),
          GoRoute(
            path: '/academic/subjects',
            builder: (context, state) => SubjectsScreen(session: session),
          ),
          GoRoute(
            path: '/academic/teachers',
            builder: (context, state) => TeachersScreen(session: session),
          ),
          GoRoute(
            path: '/academic/students',
            builder: (context, state) => StudentsScreen(session: session),
          ),
          GoRoute(
            path: '/moderation',
            builder: (context, state) => ModerationScreen(session: session),
          ),
        ],
      ),
    ],
  );
}
