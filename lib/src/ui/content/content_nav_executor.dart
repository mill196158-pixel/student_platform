import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../learning/models/team.dart';
import '../learning/team_details_screen.dart';
import '../navigation/main_tab_scope.dart';
import 'content_deep_link_bus.dart';

/// Executes [ContentNavIntent] inside the Mobile host app.
class ContentNavExecutor {
  const ContentNavExecutor({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _sb => _client ?? Supabase.instance.client;

  Future<void> execute(
    BuildContext context,
    ContentNavIntent intent, {
    VoidCallback? onUnavailable,
    void Function(String message)? onUnavailableMessage,
    VoidCallback? onDisabled,
  }) async {
    void notifyUnavailable(String message) {
      if (onUnavailableMessage != null) {
        onUnavailableMessage(message);
      } else {
        onUnavailable?.call();
      }
    }

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
          notifyUnavailable('Не удалось открыть ссылку');
        }
      case ContentNavChat(:final targetMode, :final targetId):
        await _openChat(
          context,
          targetMode: targetMode,
          targetId: targetId,
          onUnavailable: () => notifyUnavailable('Этот чат вам недоступен'),
        );
      case ContentNavReferenceArticle():
      case ContentNavSubject():
      case ContentNavVacancy():
        MainTabScope.switchToTab(context, MainTab.info);
        ContentDeepLinkBus.instance.publish(intent);
    }
  }

  Future<void> _openChat(
    BuildContext context, {
    required String targetMode,
    required String? targetId,
    required VoidCallback onUnavailable,
  }) async {
    try {
      final resolved = await _sb.rpc(
        'content_resolve_chat_cta',
        params: {
          'p_target_mode': targetMode,
          if (targetId != null) 'p_target_id': targetId,
        },
      );
      final chatId = resolved?.toString().trim();
      if (chatId == null || chatId.isEmpty) {
        if (context.mounted) onUnavailable();
        return;
      }

      final teamRow = await _sb
          .from('chats')
          .select('team_id')
          .eq('id', chatId)
          .maybeSingle();
      final teamId = (teamRow?['team_id'] ?? '').toString().trim();
      if (teamId.isEmpty) {
        if (context.mounted) onUnavailable();
        return;
      }

      final row = await _sb
          .from('teams')
          .select(
            'id,name,teacher,icon,group_name,subject_offering_id,group_id,'
            'subject_id,academic_year_id,academic_term_id,semester_number,kind',
          )
          .eq('id', teamId)
          .maybeSingle();
      if (row == null) {
        if (context.mounted) onUnavailable();
        return;
      }

      final team = Team(
        id: (row['id'] ?? teamId).toString(),
        name: (row['name'] ?? 'Чат').toString(),
        teacher: (row['teacher'] ?? '').toString(),
        groupCode: (row['group_name'] ?? '').toString(),
        icon: (row['icon'] ?? '').toString().isNotEmpty
            ? (row['icon'] ?? '').toString()
            : '📚',
        subjectOfferingId: _nullableId(row['subject_offering_id']),
        groupId: _nullableId(row['group_id']),
        subjectId: _nullableId(row['subject_id']),
        academicYearId: _nullableId(row['academic_year_id']),
        academicTermId: _nullableId(row['academic_term_id']),
        semesterNumber: _nullableInt(row['semester_number']),
        kind: (row['kind'] ?? 'subject').toString(),
      );

      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TeamDetailsScreen(
            team: team,
            initialTabIndex: 1,
          ),
        ),
      );
    } catch (_) {
      if (context.mounted) onUnavailable();
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

  static String? _nullableId(Object? value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  static int? _nullableInt(Object? value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }
}
