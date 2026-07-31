import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../friends/friend_profile_screen.dart';
import 'team_roster_pdf_service.dart';

/// Shared board note for a team chat (any active member may edit).
class TeamChatNotice {
  const TeamChatNotice({
    required this.teamId,
    required this.body,
    required this.rowVersion,
    required this.canEdit,
    this.updatedBy,
    this.updatedAt,
    this.history = const [],
  });

  final String teamId;
  final String body;
  final int rowVersion;
  final bool canEdit;
  final String? updatedBy;
  final DateTime? updatedAt;
  final List<TeamChatNoticeEvent> history;

  bool get hasBody => body.trim().isNotEmpty;

  factory TeamChatNotice.fromJson(Map<String, dynamic> json) {
    final historyRaw = json['history'];
    final history = <TeamChatNoticeEvent>[];
    if (historyRaw is List) {
      for (final item in historyRaw.whereType<Map>()) {
        history.add(
          TeamChatNoticeEvent.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }
    return TeamChatNotice(
      teamId: (json['team_id'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      rowVersion: _asInt(json['row_version']),
      canEdit: json['can_edit'] != false,
      updatedBy: _nullable(json['updated_by']),
      updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()),
      history: history,
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String? _nullable(dynamic v) {
    final t = v?.toString().trim() ?? '';
    return t.isEmpty ? null : t;
  }
}

class TeamChatNoticeEvent {
  const TeamChatNoticeEvent({
    required this.id,
    required this.actorId,
    required this.actorDisplayName,
    required this.body,
    required this.rowVersion,
    required this.createdAt,
    required this.cleared,
  });

  final String id;
  final String actorId;
  final String actorDisplayName;
  final String body;
  final int rowVersion;
  final DateTime createdAt;
  final bool cleared;

  factory TeamChatNoticeEvent.fromJson(Map<String, dynamic> json) {
    return TeamChatNoticeEvent(
      id: (json['id'] ?? '').toString(),
      actorId: (json['actor_id'] ?? '').toString(),
      actorDisplayName: ((json['actor_display_name'] ?? '').toString().trim())
              .isEmpty
          ? 'Участник'
          : (json['actor_display_name'] ?? '').toString().trim(),
      body: (json['body'] ?? '').toString(),
      rowVersion: TeamChatNotice._asInt(json['row_version']),
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now(),
      cleared: json['cleared'] == true ||
          (json['body'] ?? '').toString().trim().isEmpty,
    );
  }
}

class TeamMemberDirectoryEntry {
  const TeamMemberDirectoryEntry({
    required this.userId,
    required this.displayName,
    required this.role,
    this.avatarUrl,
  });

  final String userId;
  final String displayName;
  final String role;
  final String? avatarUrl;

  factory TeamMemberDirectoryEntry.fromJson(Map<String, dynamic> json) {
    final surnameName = (json['display_name'] ?? '').toString().trim();
    return TeamMemberDirectoryEntry(
      userId: (json['user_id'] ?? '').toString(),
      displayName: surnameName.isEmpty ? 'Участник' : surnameName,
      role: (json['role'] ?? 'member').toString(),
      avatarUrl: TeamChatNotice._nullable(json['avatar_url']),
    );
  }

  String get roleLabel {
    switch (role.toLowerCase()) {
      case 'owner':
        return 'Владелец';
      case 'starosta':
        return 'Староста';
      default:
        return '';
    }
  }
}

class TeamChatNoticeRepository {
  TeamChatNoticeRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<TeamChatNotice> getNotice(String teamId) async {
    final res = await _client.rpc(
      'get_team_chat_notice',
      params: {'p_team_id': teamId, 'p_history_limit': 20},
    );
    if (res is Map) {
      return TeamChatNotice.fromJson(Map<String, dynamic>.from(res));
    }
    return TeamChatNotice(
      teamId: teamId,
      body: '',
      rowVersion: 0,
      canEdit: true,
    );
  }

  Future<TeamChatNotice> upsertNotice({
    required String teamId,
    required String body,
    required int expectedVersion,
  }) async {
    final res = await _client.rpc(
      'upsert_team_chat_notice',
      params: {
        'p_team_id': teamId,
        'p_body': body,
        'p_expected_version': expectedVersion,
      },
    );
    return TeamChatNotice.fromJson(Map<String, dynamic>.from(res as Map));
  }

  Future<TeamMembersDirectory> getMembersDirectory(String teamId) async {
    try {
      final res = await _client.rpc(
        'get_team_members_directory',
        params: {'p_team_id': teamId},
      );
      if (res is Map) {
        return TeamMembersDirectory.fromJson(
          Map<String, dynamic>.from(res),
          fromAuthoritativeRpc: true,
        );
      }
      throw StateError('get_team_members_directory returned unexpected payload');
    } on PostgrestException catch (e) {
      if (!_isMissingRpc(e)) rethrow;
      // Older backend without get_team_members_directory.
      final legacy = await _client.rpc(
        'list_team_members_directory',
        params: {'p_team_id': teamId},
      );
      final members = legacy is List
          ? legacy
              .whereType<Map>()
              .map((e) => TeamMemberDirectoryEntry.fromJson(
                    Map<String, dynamic>.from(e),
                  ))
              .toList()
          : const <TeamMemberDirectoryEntry>[];
      return TeamMembersDirectory(
        members: members,
        canExportRoster: false,
        fromAuthoritativeRpc: false,
      );
    }
  }

  bool _isMissingRpc(PostgrestException e) {
    final code = (e.code ?? '').toUpperCase();
    final msg = e.message.toLowerCase();
    return code == 'PGRST202' ||
        code == '42883' ||
        msg.contains('could not find the function') ||
        msg.contains('function public.get_team_members_directory') ||
        (msg.contains('get_team_members_directory') &&
            msg.contains('does not exist'));
  }
}

class TeamMembersDirectory {
  const TeamMembersDirectory({
    required this.members,
    required this.canExportRoster,
    this.fromAuthoritativeRpc = false,
  });

  final List<TeamMemberDirectoryEntry> members;
  final bool canExportRoster;

  /// True when `canExportRoster` came from `get_team_members_directory`.
  final bool fromAuthoritativeRpc;

  factory TeamMembersDirectory.fromJson(
    Map<String, dynamic> json, {
    required bool fromAuthoritativeRpc,
  }) {
    final raw = json['members'];
    final members = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => TeamMemberDirectoryEntry.fromJson(
                  Map<String, dynamic>.from(e),
                ))
            .toList()
        : const <TeamMemberDirectoryEntry>[];
    return TeamMembersDirectory(
      members: members,
      canExportRoster: json['can_export_roster'] == true,
      fromAuthoritativeRpc: fromAuthoritativeRpc,
    );
  }
}

String _formatNoticeTime(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  final sameDay =
      local.year == now.year && local.month == now.month && local.day == now.day;
  if (sameDay) return DateFormat('HH:mm', 'ru').format(local);
  if (local.year == now.year) {
    return DateFormat('d MMM, HH:mm', 'ru').format(local);
  }
  return DateFormat('d MMM yyyy, HH:mm', 'ru').format(local);
}

Future<void> showTeamMembersSheet({
  required BuildContext context,
  required String teamId,
  String teamTitle = '',
  String? groupLabel,
  bool canExportRoster = false,
}) async {
  final repo = TeamChatNoticeRepository();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Instagram-style: sheet starts under status bar, no extra SafeArea void.
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final topInset = MediaQuery.paddingOf(ctx).top + 8;
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: DraggableScrollableSheet(
          expand: true,
          initialChildSize: 0.90,
          minChildSize: 0.42,
          maxChildSize: 1.0,
          builder: (context, scrollController) {
            return _InstagramSheetShell(
              child: _TeamMembersSheet(
                teamId: teamId,
                teamTitle: teamTitle,
                groupLabel: groupLabel,
                canExportRoster: canExportRoster,
                repo: repo,
                scrollController: scrollController,
              ),
            );
          },
        ),
      );
    },
  );
}

class _TeamMembersSheet extends StatefulWidget {
  const _TeamMembersSheet({
    required this.teamId,
    required this.teamTitle,
    required this.groupLabel,
    required this.canExportRoster,
    required this.repo,
    required this.scrollController,
  });

  final String teamId;
  final String teamTitle;
  final String? groupLabel;
  final bool canExportRoster;
  final TeamChatNoticeRepository repo;
  final ScrollController scrollController;

  @override
  State<_TeamMembersSheet> createState() => _TeamMembersSheetState();
}

class _TeamMembersSheetState extends State<_TeamMembersSheet> {
  late final Future<TeamMembersDirectory> _future =
      widget.repo.getMembersDirectory(widget.teamId);
  bool _exporting = false;

  Future<void> _openProfile(TeamMemberDirectoryEntry member) async {
    final id = member.userId.trim();
    if (id.isEmpty) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => FriendProfileScreen(userId: id),
      ),
    );
  }

  Future<void> _exportPdf(List<TeamMemberDirectoryEntry> members) async {
    if (_exporting || members.isEmpty) return;
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Собираю PDF для преподавателя…')),
    );
    try {
      final rows = [
        for (var i = 0; i < members.length; i++)
          TeamRosterPdfRow(
            index: i + 1,
            displayName: members[i].displayName,
          ),
      ];
      await const TeamRosterPdfService().exportAndShare(
        teamTitle: widget.teamTitle,
        groupLabel: widget.groupLabel,
        rows: rows,
      );
    } catch (e) {
      debugPrint('[members] pdf export failed: $e');
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Не удалось создать PDF')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TeamMembersDirectory>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Не удалось загрузить участников'),
          );
        }
        final directory = snap.data ??
            const TeamMembersDirectory(
              members: [],
              canExportRoster: false,
              fromAuthoritativeRpc: false,
            );
        final members = directory.members;
        // Server SoT when RPC available; client isStarosta only as legacy fallback.
        final canExport = directory.fromAuthoritativeRpc
            ? directory.canExportRoster
            : widget.canExportRoster;
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        return CustomScrollView(
          controller: widget.scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
                child: Text(
                  'Участники',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  members.isEmpty
                      ? 'Пока никого нет'
                      : '${members.length} · по алфавиту · № по списку · нажмите строку → профиль',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (canExport && members.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: FilledButton.icon(
                    onPressed: _exporting ? null : () => _exportPdf(members),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: _exporting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.picture_as_pdf_rounded),
                    label: Text(
                      _exporting ? 'Собираю PDF…' : 'PDF для преподавателя',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            if (members.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: SizedBox.shrink(),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  0,
                  12,
                  16 + MediaQuery.paddingOf(context).bottom,
                ),
                sliver: SliverList.separated(
                  itemCount: members.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final m = members[i];
                    final n = i + 1;
                    final role = m.roleLabel;
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _openProfile(m),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          decoration: BoxDecoration(
                            color: cs.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: cs.outlineVariant.withValues(alpha: 0.55),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: cs.primary.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '$n',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: cs.primary,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              CircleAvatar(
                                radius: 18,
                                backgroundImage: (m.avatarUrl ?? '').isNotEmpty
                                    ? NetworkImage(m.avatarUrl!)
                                    : null,
                                child: (m.avatarUrl ?? '').isEmpty
                                    ? Text(
                                        m.displayName.isNotEmpty
                                            ? m.displayName[0].toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      m.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        height: 1.1,
                                      ),
                                    ),
                                    if (role.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        role,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                          color: cs.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right_rounded,
                                color: cs.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

Future<void> showTeamChatNoticeSheet({
  required BuildContext context,
  required String teamId,
}) async {
  final repo = TeamChatNoticeRepository();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final topInset = MediaQuery.paddingOf(ctx).top + 8;
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: DraggableScrollableSheet(
          expand: true,
          initialChildSize: 0.72,
          minChildSize: 0.42,
          maxChildSize: 1.0,
          builder: (context, scrollController) {
            return _InstagramSheetShell(
              child: _TeamChatNoticeSheet(
                teamId: teamId,
                repo: repo,
                scrollController: scrollController,
              ),
            );
          },
        ),
      );
    },
  );
}

class _TeamChatNoticeSheet extends StatefulWidget {
  const _TeamChatNoticeSheet({
    required this.teamId,
    required this.repo,
    required this.scrollController,
  });

  final String teamId;
  final TeamChatNoticeRepository repo;
  final ScrollController scrollController;

  @override
  State<_TeamChatNoticeSheet> createState() => _TeamChatNoticeSheetState();
}

class _TeamChatNoticeSheetState extends State<_TeamChatNoticeSheet> {
  final _controller = TextEditingController();
  TeamChatNotice? _notice;
  Object? _error;
  bool _loading = true;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _saveError = null;
    });
    try {
      final notice = await widget.repo.getNotice(widget.teamId);
      if (!mounted) return;
      _controller.text = notice.body;
      setState(() {
        _notice = notice;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final notice = _notice;
    if (notice == null || _saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved = await widget.repo.upsertNotice(
        teamId: widget.teamId,
        body: _controller.text,
        expectedVersion: notice.rowVersion,
      );
      if (!mounted) return;
      _controller.text = saved.body;
      setState(() {
        _notice = saved;
        _saving = false;
      });
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Информация сохранена')),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      String friendly;
      if (msg.contains('version_conflict') || msg.contains('40001')) {
        friendly = 'Информация уже изменена — обновите и повторите';
        await _reload();
      } else if (msg.contains('rate_limited') || msg.contains('P0001')) {
        friendly = 'Слишком часто. Подождите несколько секунд';
      } else {
        friendly = 'Не удалось сохранить';
      }
      setState(() {
        _saving = false;
        _saveError = friendly;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Не удалось открыть информацию'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _reload,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }

    final history = _notice?.history ?? const <TeamChatNoticeEvent>[];
    final lastEdit = history.isNotEmpty ? history.first : null;
    final lastEditLabel = _lastEditLabel(
      lastEdit: lastEdit,
      updatedAt: _notice?.updatedAt,
      hasBody: (_notice?.body ?? '').trim().isNotEmpty ||
          _controller.text.trim().isNotEmpty,
    );

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(bottom: bottom),
      child: ListView(
        controller: widget.scrollController,
        padding: EdgeInsets.fromLTRB(
          20,
          2,
          20,
          20 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Text(
            'Информация для группы',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Одна общая заметка для всей группы. Любой участник может её обновить.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  cs.primary.withValues(alpha: 0.08),
                  cs.surfaceContainerHighest.withValues(alpha: 0.55),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: cs.primary.withValues(alpha: 0.14),
              ),
            ),
            child: TextField(
              controller: _controller,
              enabled: !_saving,
              maxLines: 7,
              minLines: 4,
              maxLength: 2000,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
              decoration: InputDecoration(
                hintText:
                    'Например: сдача лаб + курсач — это зачёт. Дедлайн 15 мая.',
                border: InputBorder.none,
                counterStyle: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (lastEditLabel != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.person_outline_rounded,
                  size: 16,
                  color: cs.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    lastEditLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_saveError != null) ...[
            const SizedBox(height: 8),
            Text(
              _saveError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton(
                onPressed: _saving ? null : _reload,
                child: const Text('Обновить'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(_saving ? 'Сохранение…' : 'Сохранить'),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Icon(Icons.history_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                'Кто менял',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (history.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'Пока никто не писал — станьте первым.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            ...history.map((e) => _EditorHistoryTile(event: e)),
        ],
      ),
    );
  }

  String? _lastEditLabel({
    required TeamChatNoticeEvent? lastEdit,
    required DateTime? updatedAt,
    required bool hasBody,
  }) {
    if (lastEdit != null) {
      return 'Последнее изменение: ${lastEdit.actorDisplayName} · '
          '${_formatNoticeTime(lastEdit.createdAt)}';
    }
    if (updatedAt != null && hasBody) {
      return 'Последнее изменение · ${_formatNoticeTime(updatedAt)}';
    }
    return null;
  }
}

class _EditorHistoryTile extends StatelessWidget {
  const _EditorHistoryTile({required this.event});

  final TeamChatNoticeEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = event.actorDisplayName;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final action = event.cleared ? 'Очищено' : 'Изменено';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: cs.primary.withValues(alpha: 0.12),
            child: Text(
              initial,
              style: TextStyle(
                color: cs.primary,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            action,
            style: theme.textTheme.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatNoticeTime(event.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact sheet chrome: grabber tight to content (Instagram-like).
class _InstagramSheetShell extends StatelessWidget {
  const _InstagramSheetShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 28,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          const SizedBox(height: 6),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(child: child),
        ],
      ),
    );
  }
}
