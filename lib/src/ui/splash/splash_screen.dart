import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:flutter/material.dart';
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

      if (mounted) context.go('/guest');
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
  Widget build(BuildContext context) => const SplashLoadingView();
}

class SplashLoadingView extends StatelessWidget {
  const SplashLoadingView({super.key, this.failed = false});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: t.colorScheme.surface,
      body: Center(
        child: failed
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Не удалось открыть приложение. Закройте его и попробуйте снова.',
                  textAlign: TextAlign.center,
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: const ProductLoadingIndicator(
                      size: 260,
                      semanticsLabel: 'Открываем приложение',
                    ),
                  ),
                  const SizedBox(height: 12),
                  ExcludeSemantics(
                    child: Text('Открываем приложение…',
                        style: t.textTheme.titleMedium),
                  ),
                ],
              ),
      ),
    );
  }
}
