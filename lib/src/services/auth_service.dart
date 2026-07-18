import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/config/auth_email_adapter.dart';
import 'package:student_platform/src/core/session.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/ui/authentication/screens/change_password_screen.dart';

class AuthService {
  static final _sb = Supabase.instance.client;

  /// Вход по логину (или email) + пароль.
  /// НИКАКИХ запросов к таблицам здесь не делаем.
  static Future<void> signInWithLoginOrEmail(
    BuildContext context, {
    required String loginOrEmail,
    required String password,
  }) async {
    final email = toAuthEmail(loginOrEmail);
    await _sb.auth.signInWithPassword(email: email, password: password);

    // Сессия уже есть -> подхватываем профиль отдельным вызовом RPC
    await AppSession.loadFromServer(); // не падает, если профиля нет

    final uid = _sb.auth.currentUser?.id;
    var mustChangePassword = false;
    if (uid != null) {
      final row = await _sb
          .from('users')
          .select('must_change_password')
          .eq('id', uid)
          .maybeSingle();
      mustChangePassword = row?['must_change_password'] == true;
    }

    if (context.mounted) {
      if (mustChangePassword) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
        );
      } else {
        context.go('/home');
      }
    }
  }

  static Future<void> signOut(BuildContext context) async {
    await PushNotificationService.instance.onLogout();
    await _sb.auth.signOut();
    AppSession.clear();
    if (context.mounted) context.go('/login');
  }
}
