import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final subtitle = AdminBackendConfig.isDemoMode
        ? 'Локальный прототип: изменения остаются только в текущей сессии.'
        : 'Изменения сохраняются в Supabase через RPC и RBAC (без service_role).';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Рабочее пространство',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(subtitle),
          const SizedBox(height: 24),
          Wrap(
            spacing: 18,
            runSpacing: 18,
            children: [
              _DashboardCard(
                title: 'Новости',
                subtitle: 'Визуальный редактор и телефонный предпросмотр',
                icon: Icons.newspaper_outlined,
                color: const Color(0xFF6656D9),
                onTap: () => context.go('/content/news'),
              ),
              _DashboardCard(
                title: 'Главная promo',
                subtitle: 'Управляемый блок «Застрял с заданием?»',
                icon: Icons.home_outlined,
                color: const Color(0xFF5B8A72),
                onTap: () => context.go('/content/home-promo'),
              ),
              _DashboardCard(
                title: 'Лента профиля',
                subtitle: 'Карточки placement profile_feed',
                icon: Icons.view_carousel_outlined,
                color: const Color(0xFF8B6BB8),
                onTap: () => context.go('/content/profile-feed'),
              ),
              _DashboardCard(
                title: 'Предметы',
                subtitle: 'Справочник и готовность материалов',
                icon: Icons.menu_book_outlined,
                color: const Color(0xFF2979A9),
                onTap: () => context.go('/academic/subjects'),
              ),
              _DashboardCard(
                title: 'Преподаватели',
                subtitle: 'Карточки и связи с предметами',
                icon: Icons.school_outlined,
                color: const Color(0xFFB85C76),
                onTap: () => context.go('/academic/teachers'),
              ),
              if (AdminBackendConfig.isDemoMode)
                const _DashboardCard(
                  title: 'Безопасное подключение',
                  subtitle: 'В demo-режиме backend не подключён',
                  icon: Icons.lock_outline,
                  color: Color(0xFF7A7E8B),
                )
              else
                _DashboardCard(
                  title: 'Модерация',
                  subtitle: 'Очереди отзывов, вакансий и жалоб',
                  icon: Icons.gavel_outlined,
                  color: const Color(0xFF7A7E8B),
                  onTap: () => context.go('/moderation'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 190,
      child: Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.12),
                  foregroundColor: color,
                  child: Icon(icon),
                ),
                const Spacer(),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
