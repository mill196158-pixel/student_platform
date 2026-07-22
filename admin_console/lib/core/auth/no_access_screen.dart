import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'admin_session_controller.dart';

class NoAccessScreen extends StatelessWidget {
  const NoAccessScreen({required this.session, super.key});

  final AdminSessionController session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Нет доступа',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Ваш аккаунт вошёл успешно, но административные права не назначены. Обратитесь к super_admin.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await session.signOut();
                      if (context.mounted) context.go('/login');
                    },
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Выйти'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
