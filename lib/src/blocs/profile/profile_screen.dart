import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cloudmate/src/blocs/profile/profile_cubit.dart';
import 'package:cloudmate/src/models/demo_user.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  void _logout(BuildContext context) {
    // GoRouter
    try {
      // если используется go_router
      // context.go('/login');
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (r) => false);
    } catch (_) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (r) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: profileCubit,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Профиль'),
          centerTitle: true,
          leading: IconButton(
            tooltip: 'Редактировать',
            icon: const Icon(Icons.tune),
            onPressed: () {
              Navigator.of(context).pushNamed('/edit-profile');
            },
          ),
          actions: [
            IconButton(
              tooltip: 'Выйти',
              icon: const Icon(Icons.logout),
              onPressed: () => _logout(context),
            ),
          ],
        ),
        body: BlocBuilder<ProfileCubit, DemoUser>(
          builder: (context, user) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: GestureDetector(
                      onTap: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Демо-режим: смена аватара пока недоступна')),
                        );
                      },
                      child: CircleAvatar(
                        radius: 52,
                        backgroundColor: Colors.deepPurple.shade100,
                        backgroundImage:
                        user.avatarUrl != null ? NetworkImage(user.avatarUrl!) : null,
                        child: user.avatarUrl == null
                            ? const Icon(Icons.person, size: 48)
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(user.fullName,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(user.email,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: Colors.black54)),
                  const SizedBox(height: 12),
                  Text(
                    user.status.isEmpty ? 'Статус не указан' : user.status,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),

                  // Статистика
                  Row(
                    children: [
                      _StatCard(title: 'Сообщения', value: user.messagesCount.toString(), icon: Icons.chat_bubble_outline),
                      const SizedBox(width: 12),
                      _StatCard(title: 'Друзья', value: user.friendsCount.toString(), icon: Icons.group_outlined),
                    ],
                  ),

                  const SizedBox(height: 24),
                  // Переход к "Зачёты и Экзамены"
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.of(context).pushNamed('/exams'),
                      icon: const Icon(Icons.school_outlined),
                      label: const Text('Зачёты и экзамены'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        bottomNavigationBar: _DemoBottomNav(currentIndex: 4),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  const _StatCard({required this.title, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Column(
            children: [
              Icon(icon),
              const SizedBox(height: 8),
              Text(value, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(title, style: const TextStyle(color: Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }
}

// Заглушка нижней навигации (чтобы выглядело как у тебя на скрине)
class _DemoBottomNav extends StatelessWidget {
  final int currentIndex;
  const _DemoBottomNav({required this.currentIndex});
  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: currentIndex,
      type: BottomNavigationBarType.fixed,
      onTap: (_) {},
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'Главная'),
        BottomNavigationBarItem(icon: Icon(Icons.info_outline), label: 'Полезная'),
        BottomNavigationBarItem(icon: Icon(Icons.menu_book_outlined), label: 'Обучение'),
        BottomNavigationBarItem(icon: Icon(Icons.event_note_outlined), label: 'Расписание'),
        BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'Профиль'),
      ],
    );
  }
}
