import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'admin_auth_config.dart';
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
    final local = !AdminAuthConfig.isConfigured;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
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
                    local
                        ? 'Backend не настроен. Доступен локальный прототип без публикации.'
                        : 'Войдите через безопасный Supabase Auth. Права проверяются на сервере.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF6E7180)),
                  ),
                  const SizedBox(height: 24),
                  if (local) ...[
                    FilledButton.icon(
                      onPressed: () => context.go('/dashboard'),
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Открыть локальный прототип'),
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
                    if (session.errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        session.errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
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
