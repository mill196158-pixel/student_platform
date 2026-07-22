import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'admin_session_controller.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({required this.session, super.key});

  final AdminSessionController session;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _submitting = false;
  String? _localError;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    final confirm = _confirmController.text;
    if (password.length < 8) {
      setState(() => _localError = 'Пароль должен быть не короче 8 символов.');
      return;
    }
    if (password != confirm) {
      setState(() => _localError = 'Пароли не совпадают.');
      return;
    }

    setState(() {
      _localError = null;
      _submitting = true;
    });
    await widget.session.updatePassword(password: password);
    if (!mounted) return;
    setState(() => _submitting = false);

    if (widget.session.phase == AdminSessionPhase.signedOut) {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final canReset = session.isPasswordRecovery;
        final err = _localError ?? session.errorMessage;

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
                        Icons.password_rounded,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Новый пароль',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        canReset
                            ? 'Задайте новый пароль для входа в Admin Web.'
                            : 'Откройте ссылку из письма для сброса пароля, затем задайте новый пароль здесь.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF6E7180)),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        enabled: canReset && !_submitting,
                        decoration: const InputDecoration(
                          labelText: 'Новый пароль',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirmController,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        enabled: canReset && !_submitting,
                        onSubmitted: (_) {
                          if (!_submitting) _submit();
                        },
                        decoration: const InputDecoration(
                          labelText: 'Повторите пароль',
                        ),
                      ),
                      if (err != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          err,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: (!canReset || _submitting) ? null : _submit,
                        icon: _submitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_rounded),
                        label: Text(
                          _submitting ? 'Сохранение…' : 'Сохранить пароль',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () => context.go('/login'),
                        child: const Text('На страницу входа'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
