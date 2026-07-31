import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:student_ui/student_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../navigation/main_tab_scope.dart';
import 'content_deep_link_bus.dart';

/// Executes [ContentNavIntent] inside the Mobile host app.
class ContentNavExecutor {
  const ContentNavExecutor();

  Future<void> execute(
    BuildContext context,
    ContentNavIntent intent, {
    VoidCallback? onUnavailable,
    VoidCallback? onDisabled,
  }) async {
    switch (intent) {
      case ContentNavDisabled():
        onDisabled?.call();
        return;
      case ContentNavNone():
        return;
      case ContentNavAppTab(:final tab):
        final mainTab = _toMainTab(tab);
        if (mainTab == null) {
          onDisabled?.call();
          return;
        }
        MainTabScope.switchToTab(context, mainTab);
      case ContentNavDiary():
        if (!context.mounted) return;
        context.push('/my-diary');
      case ContentNavExternalHttps(:final uri):
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok && context.mounted) {
          onUnavailable?.call();
        }
      case ContentNavReferenceArticle():
      case ContentNavSubject():
      case ContentNavVacancy():
        MainTabScope.switchToTab(context, MainTab.info);
        ContentDeepLinkBus.instance.publish(intent);
    }
  }

  MainTab? _toMainTab(ContentAppTab tab) {
    return switch (tab) {
      ContentAppTab.home => MainTab.home,
      ContentAppTab.info => MainTab.info,
      ContentAppTab.learning => MainTab.learning,
      ContentAppTab.schedule => MainTab.schedule,
      ContentAppTab.profile => MainTab.profile,
    };
  }
}
