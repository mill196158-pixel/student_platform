import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen(
      {super.key,
      this.restoreSession,
      this.restoreStatus,
      this.qaAdmission,
      this.manualRetry = false});
  final Future<bool> Function()? restoreSession;
  final Future<SessionRestoreStatus> Function()? restoreStatus;
  final Future<OfflineStartupResult> Function()? qaAdmission;
  final bool manualRetry;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  int _staleRetries = 0;
  bool _needsRetry = false;
  @override
  void initState() {
    super.initState();
    if (widget.manualRetry) {
      _needsRetry = true;
    } else {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    try {
      if (widget.qaAdmission != null) {
        final result = await widget.qaAdmission!();
        if (!mounted) return;
        switch (result) {
          case OfflineStartupResult.online:
          case OfflineStartupResult.cacheOnly:
            context.go('/home');
            return;
          case OfflineStartupResult.passwordChangeRequired:
            context.go('/change-password');
            return;
          case OfflineStartupResult.denied:
            context.go('/guest');
            return;
          case OfflineStartupResult.unavailable:
            setState(() => _needsRetry = true);
            return;
        }
      }
      final SessionRestoreStatus status;
      if (widget.restoreStatus != null) {
        status = await widget.restoreStatus!();
      } else if (widget.restoreSession != null) {
        status = await widget.restoreSession!()
            ? SessionRestoreStatus.restored
            : SessionRestoreStatus.rejected;
      } else {
        status =
            await AuthSession.restoreSessionStatus(Supabase.instance.client);
      }
      // GoRouter awaits the live password policy before building /home.
      // Do not repeat that network request or populate unused legacy state here.
      if (!mounted) return;

      if (status == SessionRestoreStatus.restored) {
        context.go('/home');
        return;
      }

      if (status == SessionRestoreStatus.stale) {
        if (_staleRetries++ == 0) {
          await _bootstrap();
        } else {
          setState(() => _needsRetry = true);
        }
        return;
      }
      if (status == SessionRestoreStatus.transportFailure) {
        context.go('/login');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Нет соединения. Подключитесь к сети и повторите вход.'),
        ));
        return;
      }

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
  Widget build(BuildContext context) => SplashLoadingView(
        failed: _needsRetry,
        onRetry: () {
          setState(() {
            _needsRetry = widget.manualRetry;
            _staleRetries = 0;
          });
          _bootstrap();
        },
      );
}

class SplashLoadingView extends StatelessWidget {
  const SplashLoadingView({super.key, this.failed = false, this.onRetry});

  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: t.colorScheme.surface,
      body: Center(
        child: failed
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    onRetry == null
                        ? 'Не удалось открыть приложение. Закройте его и попробуйте снова.'
                        : 'Не удалось проверить текущий вход.',
                    textAlign: TextAlign.center,
                  ),
                  if (onRetry != null)
                    TextButton(
                        onPressed: onRetry, child: const Text('Повторить')),
                ]),
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
