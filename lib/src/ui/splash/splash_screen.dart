import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/session.dart';
import 'package:student_platform/src/core/password_policy.dart';

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
    try {
      final client = Supabase.instance.client;
      final prefs = await SharedPreferences.getInstance();

      final sessionOk = await AuthSession.tryRestoreSession(client);

      if (sessionOk) {
        final mustChangePassword = await loadPasswordChangeRequired(client);
        if (!mounted) return;
        if (mustChangePassword) {
          context.go('/change-password');
          return;
        }
        await AppSession.loadFromServer();
      }

      if (!mounted) return;

      if (sessionOk) {
        context.go('/home');
        return;
      }

      await prefs.remove('loggedIn');
      await prefs.remove('user');

      if (mounted) context.go('/login');
    } catch (_) {
      if (!mounted) return;
      context.go('/login');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Не удалось проверить вход. Проверьте соединение и повторите попытку.'),
      ));
    }
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
