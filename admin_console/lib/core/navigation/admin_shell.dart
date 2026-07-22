import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/admin_capabilities.dart';
import '../auth/admin_session_controller.dart';

class AdminShell extends StatelessWidget {
  const AdminShell({
    required this.currentPath,
    required this.session,
    required this.child,
    super.key,
  });

  final String currentPath;
  final AdminSessionController session;
  final Widget child;

  List<_AdminDestination> _visibleDestinations(AdminCapabilities caps) {
    final local = session.isLocalPrototype;
    return [
      _AdminDestination(
        label: 'Главная',
        icon: Icons.dashboard_outlined,
        path: '/dashboard',
        isVisible: local || caps.canViewDashboard || caps.hasAnyAdminAccess,
      ),
      _AdminDestination(
        label: 'Новости',
        icon: Icons.newspaper_outlined,
        path: '/content/news',
        section: 'Контент',
        isVisible: local || caps.canReadContent,
      ),
      _AdminDestination(
        label: 'Предметы',
        icon: Icons.menu_book_outlined,
        path: '/academic/subjects',
        section: 'Учебная часть',
        isVisible: local || caps.canReadAcademic,
      ),
      _AdminDestination(
        label: 'Преподаватели',
        icon: Icons.school_outlined,
        path: '/academic/teachers',
        isVisible: local || caps.canReadAcademic,
      ),
      const _AdminDestination(
        label: 'Студенты',
        icon: Icons.groups_outlined,
        isEnabled: false,
        isVisible: false,
      ),
      const _AdminDestination(
        label: 'Модерация',
        icon: Icons.shield_outlined,
        isEnabled: false,
        isVisible: false,
      ),
      const _AdminDestination(
        label: 'Система',
        icon: Icons.settings_outlined,
        isEnabled: false,
        isVisible: false,
      ),
    ].where((item) => item.isVisible).toList(growable: false);
  }

  String _title(List<_AdminDestination> destinations) {
    for (final destination in destinations) {
      if (destination.path == currentPath) return destination.label;
    }
    return 'Student Platform Admin';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final destinations = _visibleDestinations(session.capabilities);
        return LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 900;
            final navigation = _NavigationPanel(
              currentPath: currentPath,
              destinations: destinations,
              onSelected: (path) {
                if (isCompact) Navigator.of(context).pop();
                context.go(path);
              },
            );

            return Scaffold(
              drawer: isCompact ? Drawer(child: navigation) : null,
              appBar: AppBar(
                backgroundColor: Colors.white,
                leading: isCompact
                    ? Builder(
                        builder: (context) => IconButton(
                          tooltip: 'Открыть меню',
                          onPressed: () => Scaffold.of(context).openDrawer(),
                          icon: const Icon(Icons.menu_rounded),
                        ),
                      )
                    : null,
                title: Text(
                  _title(destinations),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                actions: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Chip(
                      avatar: Icon(
                        session.isLocalPrototype
                            ? Icons.science_outlined
                            : Icons.cloud_done_outlined,
                        size: 18,
                      ),
                      label: Text(
                        session.isLocalPrototype
                            ? 'Локальный прототип'
                            : 'Подключено',
                      ),
                    ),
                  ),
                  if (!session.isLocalPrototype)
                    IconButton(
                      tooltip: 'Выйти',
                      onPressed: () async {
                        await session.signOut();
                        if (context.mounted) context.go('/login');
                      },
                      icon: const Icon(Icons.logout_rounded),
                    ),
                  const SizedBox(width: 8),
                ],
              ),
              body: Row(
                children: [
                  if (!isCompact)
                    SizedBox(width: 260, child: Material(child: navigation)),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: child,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _NavigationPanel extends StatelessWidget {
  const _NavigationPanel({
    required this.currentPath,
    required this.destinations,
    required this.onSelected,
  });

  final String currentPath;
  final List<_AdminDestination> destinations;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    String? previousSection;
    return ColoredBox(
      color: const Color(0xFF18172B),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 22, 22, 26),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Color(0xFF7C6EF2),
                    child: Icon(
                      Icons.admin_panel_settings,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Student Platform\nAdmin',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final destination in destinations) ...[
                    if (destination.section != null &&
                        destination.section != previousSection)
                      _SectionLabel(label: destination.section!),
                    _NavigationTile(
                      destination: destination,
                      isSelected: destination.path == currentPath,
                      onTap: destination.isEnabled && destination.path != null
                          ? () => onSelected(destination.path!)
                          : null,
                    ),
                    if (destination.section != null)
                      Builder(
                        builder: (_) {
                          previousSection = destination.section;
                          return const SizedBox.shrink();
                        },
                      ),
                  ],
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'Права проверяются на сервере',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _NavigationTile extends StatelessWidget {
  const _NavigationTile({
    required this.destination,
    required this.isSelected,
    required this.onTap,
  });

  final _AdminDestination destination;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: destination.isEnabled,
      selected: isSelected,
      selectedTileColor: const Color(0xFF353253),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(destination.icon, color: Colors.white70),
      title: Text(
        destination.label,
        style: const TextStyle(color: Colors.white),
      ),
      trailing: destination.isEnabled
          ? null
          : const Text(
              'Скоро',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
      onTap: onTap,
    );
  }
}

class _AdminDestination {
  const _AdminDestination({
    required this.label,
    required this.icon,
    this.path,
    this.section,
    this.isEnabled = true,
    this.isVisible = true,
  });

  final String label;
  final IconData icon;
  final String? path;
  final String? section;
  final bool isEnabled;
  final bool isVisible;
}
