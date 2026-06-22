import 'package:flutter/material.dart';

// Импорты по текущей структуре
import '../home/home_screen.dart';
import '../info/info_screen.dart';
import '../learning/learning_screen.dart';
import '../schedule/schedule_screen.dart';
import '../profile/profile_screen.dart';
import 'modern_bottom_nav.dart';

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  int _currentIndex = 0;
  final PageStorageBucket _bucket = PageStorageBucket();
  final ValueNotifier<bool> _profileActive = ValueNotifier<bool>(false);

  late final List<Widget> _tabs = <Widget>[
    const _KeepAlive(storageKey: 'tab_home', child: HomeScreen()),
    const _KeepAlive(storageKey: 'tab_info', child: InfoScreen()),
    const _KeepAlive(storageKey: 'tab_learning', child: LearningScreen()),
    const _KeepAlive(storageKey: 'tab_schedule', child: ScheduleScreen()),
    const _KeepAlive(storageKey: 'tab_profile', child: ProfileScreen()),
  ];

  @override
  void initState() {
    super.initState();
    _profileActive.value = _currentIndex == 4;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: false,
      body: PageStorage(
        bucket: _bucket,
        child: IndexedStack(
          index: _currentIndex,
          children: [
            _tab(active: _currentIndex == 0, child: _tabs[0]),
            _tab(active: _currentIndex == 1, child: _tabs[1]),
            _tab(active: _currentIndex == 2, child: _tabs[2]),
            _tab(active: _currentIndex == 3, child: _tabs[3]),
            _tab(
              active: _currentIndex == 4,
              child: _KeepAlive(
                storageKey: 'tab_profile',
                child: ProfileScreen(activeListenable: _profileActive),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: ModernBottomNav(
        currentIndex: _currentIndex,
        items: const [
          ModernBottomNavItem(icon: Icons.home_rounded, label: 'Главная'),
          ModernBottomNavItem(
              icon: Icons.info_outline_rounded, label: 'Полезная'),
          ModernBottomNavItem(icon: Icons.menu_book_rounded, label: 'Обучение'),
          ModernBottomNavItem(
              icon: Icons.calendar_today_rounded, label: 'Расписание'),
          ModernBottomNavItem(icon: Icons.person_rounded, label: 'Профиль'),
        ],
        onTap: (index) {
          if (index != _currentIndex) {
            setState(() => _currentIndex = index);
            _profileActive.value = (index == 4);
          }
        },
      ),
    );
  }

  Widget _tab({required bool active, required Widget child}) {
    return Offstage(
      offstage: !active,
      child: TickerMode(
        enabled: active,
        child: child,
      ),
    );
  }

  @override
  void dispose() {
    _profileActive.dispose();
    super.dispose();
  }
}

/// Обёртка, которая:
/// 1) включает keep-alive (не dispose'ит виджет при смене вкладки),
/// 2) даёт стабильный PageStorageKey для сохранения скроллов и т.п.
class _KeepAlive extends StatefulWidget {
  final Widget child;
  final String storageKey;
  const _KeepAlive({required this.child, required this.storageKey});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin<_KeepAlive> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return KeyedSubtree(
      key: PageStorageKey(widget.storageKey),
      child: widget.child,
    );
  }
}
