import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'guest_surface.dart';

/// Shared explanation before any guest action requiring an account.
class GuestAccountScreen extends StatelessWidget {
  const GuestAccountScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const GuestAccountScreen()),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(
          title: const Text('Больше возможностей'),
          backgroundColor: Theme.of(context).colorScheme.surface,
          surfaceTintColor: Colors.transparent,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.school_outlined,
                      size: 52, color: guestPurple),
                  const SizedBox(height: 20),
                  const Text('Учись вместе со своей группой',
                      style:
                          TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 12),
                  const Text('Ты сейчас в гостевом режиме. Для личных учебных '
                      'разделов нужен аккаунт — так приложение узнает тебя и '
                      'проверит доступ к твоим командам.'),
                  const SizedBox(height: 24),
                  const GuestPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('С аккаунтом',
                            style: TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w800)),
                        SizedBox(height: 12),
                        Text('• Команды и чаты предметов\n'
                            '• Сообщения и вложения доступных тебе команд\n'
                            '• Задания и сроки твоей группы\n'
                            '• Личный дневник, заметки и файлы'),
                        SizedBox(height: 12),
                        Text(
                            'Доступ к конкретным командам зависит от участия в них.'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('Можно остаться гостем',
                      style:
                          TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  const Text('Открытые материалы доступны без аккаунта. '
                      'Регистрация нужна, когда захочешь пользоваться личными разделами.'),
                  const SizedBox(height: 24),
                  const Text(
                      'Сейчас аккаунт выдаёт администратор. Самостоятельная регистрация пока недоступна.'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => context.go('/login?mode=register'),
                    child: const Text('Зарегистрироваться'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => context.go('/login'),
                    child: const Text('Войти'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Продолжить без входа'),
                  ),
                ]),
          ),
        ),
      );
}
