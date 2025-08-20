import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/config/auth_email_adapter.dart';
import 'package:student_platform/src/core/session.dart';

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

    if (context.mounted) context.go('/home');
  }

  static Future<void> signOut(BuildContext context) async {
    await _sb.auth.signOut();
    AppSession.clear();
    if (context.mounted) context.go('/login');
  }
}
