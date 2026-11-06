import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:student_ui/student_ui.dart';

// Импорты по текущей структуре
import '../home/home_screen.dart';
import '../home/cached_home_schedule_reader.dart';
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
  const NavigationScreen(
      {super.key,
      this.guest = false,
      this.cachedReader,
      this.cachedInfo,
      this.cachedLearning,
      this.cachedProfile});
  final bool guest;

  /// Non-null only after a cache-only admission. Other tabs must supply their
  /// own local-only implementation before they can be opened in this mode.
  final CachedHomeScheduleReader? cachedReader;
  final WidgetBuilder? cachedInfo;
  final WidgetBuilder? cachedLearning;
  final WidgetBuilder? cachedProfile;

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  int _currentIndex = 0;
  final PageStorageBucket _bucket = PageStorageBucket();
  final ValueNotifier<bool> _profileActive = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _homeActive = ValueNotifier<bool>(true);

  bool get _cacheOnly => widget.cachedReader != null;
  bool _backgroundStarted = false;

  void _syncBackground() {
    final shouldRun = !widget.guest && !_cacheOnly;
    if (shouldRun == _backgroundStarted) return;
    _backgroundStarted = shouldRun;
    if (shouldRun) {
      ChatWarmCoordinator.instance.start();
      PresenceService.instance.start();
    } else {
      PresenceService.instance.stop();
      ChatWarmCoordinator.instance.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _profileActive.value = _currentIndex == 4;
    // Quietly refresh chat list + top thread histories in the background.
    _syncBackground();
  }

  @override
  void didUpdateWidget(covariant NavigationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBackground();
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
    final reader = widget.cachedReader;
    if (reader != null && !widget.guest) {
      return ListenableBuilder(
        listenable: reader.accessChanges,
        builder: (context, _) => reader.canRead
            ? _buildWorkspace(context)
            : const Scaffold(
                body: Center(child: Text('Сохранённые данные недоступны.')),
              ),
      );
    }
    return _buildWorkspace(context);
  }

  Widget _buildWorkspace(BuildContext context) {
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
                  key: ValueKey(_cacheOnly),
                  bucket: _bucket,
                  child: IndexedStack(
                    index: _currentIndex,
                    children: [
                      VisitedTab(
                          active: _currentIndex == 0,
                          builder: (_) => _KeepAlive(
                              storageKey: 'tab_home',
                              child: HomeScreen(
                                  activeListenable: _homeActive,
                                  cachedReader: widget.cachedReader))),
                      VisitedTab(
                          active: _currentIndex == 1,
                          builder: (context) => _KeepAlive(
                              storageKey: 'tab_info',
                              child: _cacheOnly
                                  ? _cachedTab(context, widget.cachedInfo)
                                  : const InfoScreen())),
                      VisitedTab(
                          active: _currentIndex == 2,
                          builder: (context) => _KeepAlive(
                              storageKey: 'tab_learning',
                              child: _cacheOnly
                                  ? _cachedTab(context, widget.cachedLearning)
                                  : const LearningScreen())),
                      VisitedTab(
                          active: _currentIndex == 3,
                          builder: (_) => _KeepAlive(
                              storageKey: 'tab_schedule',
                              child: ScheduleScreen(
                                  cachedReader: widget.cachedReader,
                                  subscribeRealtime: !_cacheOnly))),
                      VisitedTab(
                        active: _currentIndex == 4,
                        builder: (_) => _KeepAlive(
                          storageKey: 'tab_profile',
                          child: _cacheOnly
                              ? _cachedTab(context, widget.cachedProfile)
                              : ProfileScreen(activeListenable: _profileActive),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _cachedTab(BuildContext context, WidgetBuilder? builder) =>
      builder?.call(context) ??
      const Center(
        child: Text('Сохранённые данные этого раздела пока недоступны.'),
      );

  @override
  void dispose() {
    if (_backgroundStarted) {
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
