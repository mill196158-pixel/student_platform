import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:student_ui/student_ui.dart';

// Импорты по текущей структуре
import '../home/home_screen.dart';
import '../info/info_screen.dart';
import '../learning/learning_screen.dart';
import '../schedule/schedule_screen.dart';
import '../profile/profile_screen.dart';
import '../chats/data/chat_warm_coordinator.dart';
import '../../services/presence/user_presence.dart';
import '../../themes/theme_service.dart';
import 'main_tab_scope.dart';
import 'visited_tab.dart';
import '../guest/guest_workspace.dart';

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key, this.guest = false});
  final bool guest;

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  int _currentIndex = 0;
  final PageStorageBucket _bucket = PageStorageBucket();
  final ValueNotifier<bool> _profileActive = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _homeActive = ValueNotifier<bool>(true);

  late final List<Widget> _tabs = <Widget>[
    _KeepAlive(
        storageKey: 'tab_home',
        child: HomeScreen(activeListenable: _homeActive)),
    const _KeepAlive(storageKey: 'tab_info', child: InfoScreen()),
    const _KeepAlive(storageKey: 'tab_learning', child: LearningScreen()),
    const _KeepAlive(storageKey: 'tab_schedule', child: ScheduleScreen()),
  ];

  @override
  void initState() {
    super.initState();
    _profileActive.value = _currentIndex == 4;
    // Quietly refresh chat list + top thread histories in the background.
    if (!widget.guest) {
      ChatWarmCoordinator.instance.start();
      PresenceService.instance.start();
    }
  }

  void _switchToTab(MainTab tab) {
    final index = tab.index;
    if (index != _currentIndex) {
      setState(() => _currentIndex = index);
      _profileActive.value = tab == MainTab.profile;
      _homeActive.value = tab == MainTab.home;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlay = ThemeService.overlayFor(darkMode: isDark);
    // Re-assert on every tab rebuild so a transparent AppBar (profile) cannot
    // leave white status icons on light screens.
    SystemChrome.setSystemUIOverlayStyle(overlay);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: MainTabScope(
        switchTo: _switchToTab,
        child: StudentWorkspaceFrame(
          index: _currentIndex,
          onSelected: (index) => _switchToTab(MainTab.values[index]),
          child: widget.guest
              ? GuestWorkspace(tab: _currentIndex)
              : PageStorage(
                  bucket: _bucket,
                  child: IndexedStack(
                    index: _currentIndex,
                    children: [
                      VisitedTab(
                          active: _currentIndex == 0, builder: (_) => _tabs[0]),
                      VisitedTab(
                          active: _currentIndex == 1, builder: (_) => _tabs[1]),
                      VisitedTab(
                          active: _currentIndex == 2, builder: (_) => _tabs[2]),
                      VisitedTab(
                          active: _currentIndex == 3, builder: (_) => _tabs[3]),
                      VisitedTab(
                        active: _currentIndex == 4,
                        builder: (_) => _KeepAlive(
                          storageKey: 'tab_profile',
                          child:
                              ProfileScreen(activeListenable: _profileActive),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (!widget.guest) {
      PresenceService.instance.stop();
      ChatWarmCoordinator.instance.stop();
    }
    _profileActive.dispose();
    _homeActive.dispose();
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
