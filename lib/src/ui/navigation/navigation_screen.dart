import 'package:flutter/material.dart';

// Импорты по текущей структуре
import '../home/home_screen.dart';
import '../info/info_screen.dart';
import '../learning/learning_screen.dart';
import '../schedule/schedule_screen.dart';
import '../profile/profile_screen.dart';

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  int _currentIndex = 0;
  final PageStorageBucket _bucket = PageStorageBucket();

  late final List<Widget> _tabs = <Widget>[
    const _KeepAlive(storageKey: 'tab_home', child: HomeScreen()),
    const _KeepAlive(storageKey: 'tab_info', child: InfoScreen()),
    const _KeepAlive(storageKey: 'tab_learning', child: LearningScreen()),
    const _KeepAlive(storageKey: 'tab_schedule', child: ScheduleScreen()),
    const _KeepAlive(storageKey: 'tab_profile', child: ProfileScreen()),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageStorage(
        bucket: _bucket,
        child: IndexedStack(
          index: _currentIndex,
          children: _tabs,
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Главная'),
          BottomNavigationBarItem(icon: Icon(Icons.info_outline), label: 'Полезная'),
          BottomNavigationBarItem(icon: Icon(Icons.menu_book), label: 'Обучение'),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_today), label: 'Расписание'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Профиль'),
        ],
      ),
    );
  }
}

/// Обёртка, которая:
/// 1) включает keep-alive (не dispose'ит виджет при смене вкладки),
/// 2) даёт стабильный PageStorageKey для сохранения скроллов и т.п.
class _KeepAlive extends StatefulWidget {
  final Widget child;
  final String storageKey;
  const _KeepAlive({super.key, required this.child, required this.storageKey});

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
