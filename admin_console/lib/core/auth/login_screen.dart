import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'admin_backend_config.dart';
import 'admin_session_controller.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.session, super.key});

  final AdminSessionController session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    await widget.session.signInWithPassword(
      email: _emailController.text,
      password: _passwordController.text,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (widget.session.hasAdminAccess) {
      context.go('/dashboard');
    } else if (widget.session.phase == AdminSessionPhase.noAccess) {
      context.go('/no-access');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final demo = AdminBackendConfig.isDemoMode;
    final hasError =
        session.phase == AdminSessionPhase.error ||
        (session.errorMessage != null &&
            session.phase != AdminSessionPhase.loadingCapabilities);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.admin_panel_settings,
                    size: 52,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Student Platform Admin',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    demo
                        ? 'Включён локальный прототип (ADMIN_DEMO_MODE). Публикация и серверные права недоступны.'
                        : 'Войдите через Supabase Auth в браузере. Права проверяются на сервере.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF6E7180)),
                  ),
                  if (!demo) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.center,
                      child: Chip(
                        avatar: const Icon(Icons.cloud_done_outlined, size: 18),
                        label: const Text('Подключено'),
                        backgroundColor: const Color(0xFFE8F5E9),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (demo) ...[
                    FilledButton.icon(
                      onPressed: () => context.go('/dashboard'),
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Открыть локальный прототип'),
                    ),
                  ] else if (AdminBackendConfig.configurationError != null) ...[
                    Text(
                      AdminBackendConfig.configurationError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      onPressed: () => session.bootstrap(),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Повторить подключение'),
                    ),
                  ] else ...[
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) {
                        if (!_submitting) _submit();
                      },
                      decoration: const InputDecoration(labelText: 'Пароль'),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _submitting
                            ? null
                            : () => context.go('/auth/forgot-password'),
                        child: const Text('Забыли пароль?'),
                      ),
                    ),
                    if (session.infoMessage != null) ...[
                      Text(
                        session.infoMessage!,
                        style: const TextStyle(
                          color: Color(0xFF2E7D32),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (hasError && session.errorMessage != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        session.errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _submitting ? null : _submit,
                      icon: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login_rounded),
                      label: Text(_submitting ? 'Вход…' : 'Войти'),
                    ),
                    if (session.phase == AdminSessionPhase.error) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => session.bootstrap(),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Повторить подключение'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
