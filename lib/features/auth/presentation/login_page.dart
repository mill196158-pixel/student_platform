import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../routes/app_router.dart';
// Если будет lottie-файл, раскомментируй импорт и виджет ниже
// import 'package:lottie/lottie.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _noCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Вход')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            TextField(
              controller: _noCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Студенческий номер',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Пароль',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => context.go(AppRoutes.home),
              child: const Text('Войти'),
            ),
            const SizedBox(height: 24),

            // Пример Lottie — когда положишь файл, раскомментируй
            // Lottie.asset('assets/lottie/splash.json', height: 120),

            const Spacer(),
            Text(
              'Добро пожаловать!',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Домашний экран (минимальные карточки в стиле Cloudmate)
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Сегодня')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Главная', style: t.titleLarge),
          const SizedBox(height: 12),
          const _CardTile(
            icon: Icons.calendar_today_outlined,
            title: 'Пары',
            subtitle: 'Расписание на сегодня',
          ),
          const SizedBox(height: 12),
          const _CardTile(
            icon: Icons.assignment_outlined,
            title: 'Задания',
            subtitle: 'Ближайшие дедлайны',
          ),
        ],
      ),
    );
  }
}

class _CardTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _CardTile({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 16),
          ],
        ),
      ),
    );
  }
}
