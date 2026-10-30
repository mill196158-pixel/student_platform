import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/auth_session.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.restoreSession});
  final Future<bool> Function()? restoreSession;

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
      final prefs = await SharedPreferences.getInstance();

      final sessionOk = await (widget.restoreSession?.call() ??
          AuthSession.tryRestoreSession(Supabase.instance.client));
      // GoRouter awaits the live password policy before building /home.
      // Do not repeat that network request or populate unused legacy state here.
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
