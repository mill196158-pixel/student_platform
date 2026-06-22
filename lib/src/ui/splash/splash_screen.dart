import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/session.dart';
import 'package:student_platform/src/ui/authentication/screens/change_password_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Future.delayed(const Duration(milliseconds: 600));

    final client = Supabase.instance.client;
    final prefs = await SharedPreferences.getInstance();
    final loggedIn = prefs.getBool('loggedIn') ?? false;
    final userJson = prefs.getString('user');
    final decodedUser = userJson == null ? null : jsonDecode(userJson);
    final hasUser = decodedUser is Map;
    final mustChangePassword =
        decodedUser is Map && decodedUser['must_change_password'] == true;

    final sessionOk = await AuthSession.tryRestoreSession(client);

    if (sessionOk) {
      await AppSession.loadFromServer();
    }

    if (!mounted) return;

    if (sessionOk) {
      if (mustChangePassword) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
        );
        return;
      }
      context.go('/home');
      return;
    }

    if (loggedIn && hasUser) {
      await prefs.remove('loggedIn');
      await prefs.remove('user');
    }

    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: t.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Lottie.asset('assets/lottie/cat_sleeping.json', height: 200),
            const SizedBox(height: 16),
            Text('Загружаем…', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      ),
    );
  }
}
