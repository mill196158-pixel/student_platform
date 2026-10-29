import 'package:flutter/material.dart';

/// Account provisioning requires a verified administrator workflow.
class RegisterScreen extends StatelessWidget {
  const RegisterScreen({super.key, required this.toggleView});
  final VoidCallback toggleView;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Получить доступ')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Самостоятельная регистрация временно недоступна. '
              'Для получения аккаунта обратитесь к администратору платформы.',
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton(onPressed: toggleView, child: const Text('Вернуться ко входу')),
        ],
      ),
    ),
  );
}
