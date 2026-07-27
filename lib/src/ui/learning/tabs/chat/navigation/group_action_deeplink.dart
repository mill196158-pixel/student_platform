import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../models/team.dart';
import '../../../team_details_screen.dart';

/// Deep-link target for topic/collection card messages in team chat.
class GroupActionDeeplinkArgs {
  const GroupActionDeeplinkArgs({
    this.chatId,
    this.cardMessageId,
    required this.entityType,
    required this.entityId,
    this.teamId,
  });

  final String? chatId;
  final String? cardMessageId;
  final String entityType;
  final String entityId;
  final String? teamId;

  factory GroupActionDeeplinkArgs.fromDeadline({
    required String eventType,
    required String entityId,
    String? chatId,
    String? cardMessageId,
    String? teamId,
  }) {
    return GroupActionDeeplinkArgs(
      chatId: chatId,
      cardMessageId: cardMessageId,
      entityType: eventType,
      entityId: entityId,
      teamId: teamId,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GroupActionDeeplinkArgs &&
        other.chatId == chatId &&
        other.cardMessageId == cardMessageId &&
        other.entityType == entityType &&
        other.entityId == entityId &&
        other.teamId == teamId;
  }

  @override
  int get hashCode => Object.hash(
        chatId,
        cardMessageId,
        entityType,
        entityId,
        teamId,
      );
}

/// Opens [TeamDetailsScreen] chat tab and scrolls to [GroupActionDeeplinkArgs.cardMessageId].
Future<void> openGroupActionDeeplink(
  BuildContext context,
  GroupActionDeeplinkArgs args, {
  SupabaseClient? client,
}) async {
  final sb = client ?? Supabase.instance.client;
  if (sb.auth.currentUser == null) {
    _showFallback(context, 'Войдите в аккаунт, чтобы открыть чат.');
    return;
  }

  var teamId = (args.teamId ?? '').trim();
  if (teamId.isEmpty && (args.chatId ?? '').trim().isNotEmpty) {
    teamId = await _resolveTeamIdFromChat(sb, args.chatId!.trim()) ?? '';
  }
  if (teamId.isEmpty) {
    _showFallback(context, 'Чат недоступен или удалён.');
    return;
  }

  final team = await _loadTeam(sb, teamId);
  if (team == null) {
    _showFallback(context, 'Нет доступа к этой команде.');
    return;
  }

  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => TeamDetailsScreen(
        team: team,
        initialTabIndex: 1,
        highlightMessageId: args.cardMessageId,
      ),
    ),
  );
}

Future<String?> _resolveTeamIdFromChat(SupabaseClient sb, String chatId) async {
  try {
    final row =
        await sb.from('chats').select('team_id').eq('id', chatId).maybeSingle();
    final teamId = (row?['team_id'] ?? '').toString().trim();
    return teamId.isEmpty ? null : teamId;
  } catch (_) {
    return null;
  }
}

Future<Team?> _loadTeam(SupabaseClient sb, String teamId) async {
  try {
    final row = await sb
        .from('teams')
        .select(
          'id,name,teacher,icon,group_name,subject_offering_id,group_id,subject_id,academic_year_id,academic_term_id,semester_number,kind',
        )
        .eq('id', teamId)
        .maybeSingle();
    if (row == null) return null;
    return Team(
      id: (row['id'] ?? teamId).toString(),
      name: (row['name'] ?? 'Команда').toString(),
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
      kind: (row['kind'] ?? '').toString(),
    );
  } catch (_) {
    return null;
  }
}

void _showFallback(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

String? _nullableId(dynamic value) {
  final text = (value ?? '').toString().trim();
  return text.isEmpty ? null : text;
}

int? _nullableInt(dynamic value) {
  if (value is int) return value;
  return int.tryParse((value ?? '').toString());
}
