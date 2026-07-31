import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/chats/data/chat_archive_api.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  int _tab = 0; // 0 academic, 1 personal
  bool _loading = true;
  List<_ArchivedChat> _academic = const [];
  List<_ArchivedChat> _personal = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await ChatArchiveApi.getMyArchivedChatSummaries();
      final academic = <_ArchivedChat>[];
      final personal = <_ArchivedChat>[];
      for (final row in rows) {
        final item = _ArchivedChat.fromRpc(row);
        if (item.archiveType == 'academic') {
          academic.add(item);
        } else if (item.archiveType == 'personal') {
          personal.add(item);
        }
      }
      if (!mounted) return;
      setState(() {
        _academic = academic;
        _personal = personal;
        _loading = false;
      });
    } catch (e) {
      safeDebugLog('[ArchiveScreen] load failed: ${e.runtimeType}');
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось загрузить архив')),
      );
    }
  }

  List<_ArchivedChat> get _visible => _tab == 0 ? _academic : _personal;

  Future<void> _openChat(_ArchivedChat c) async {
    if (c.archiveType == 'personal' && (c.peerId?.isNotEmpty ?? false)) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BlocProvider.value(
            value: context.read<TeamCubit>(),
            child: DirectChatScreen(
              peerId: c.peerId!,
              peerName: c.title,
              peerAvatarUrl: c.avatarUrl,
            ),
          ),
        ),
      );
      return;
    }

    if (c.teamId == null || c.teamId!.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeamDetailsScreen(
          team: Team(
            id: c.teamId!,
            name: c.title,
            icon: c.teamIcon ?? '',
            teacher: c.teamTeacher ?? '',
            groupCode: c.teamGroupName ?? '',
          ),
          initialTabIndex: 1,
          readOnly: true,
        ),
      ),
    );
  }

  Future<void> _unarchivePersonal(_ArchivedChat c) async {
    final chatId = c.chatId;
    if (chatId == null || chatId.isEmpty) return;
    try {
      await ChatArchiveApi.setPersonalChatArchived(
        chatId: chatId,
        archived: false,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось вернуть из архива')),
      );
    }
  }

  Future<void> _hidePersonal(_ArchivedChat c) async {
    final chatId = c.chatId;
    if (chatId == null || chatId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить переписку у себя?'),
        content: const Text(
          'Переписка исчезнет только у вас. Если собеседник напишет снова, диалог появится в сообщениях.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ChatArchiveApi.hidePersonalChatForMe(chatId: chatId);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить переписку')),
      );
    }
  }

  void _showPersonalMenu(_ArchivedChat c, Offset globalPosition) {
    HapticFeedback.mediumImpact();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: 'unarchive',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.unarchive_outlined),
            title: Text('Вернуть из архива'),
          ),
        ),
        PopupMenuItem(
          value: 'hide',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: Colors.redAccent),
            title: Text(
              'Удалить у себя',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ),
      ],
    ).then((value) {
      if (value == 'unarchive') unawaited(_unarchivePersonal(c));
      if (value == 'hide') unawaited(_hidePersonal(c));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dividerOpacity = theme.brightness == Brightness.dark ? .24 : .35;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Архив'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: _ArchiveSegmented(
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _visible.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.of(context).size.height * 0.35,
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 32),
                                child: Text(
                                  _tab == 0
                                      ? 'Архив учебных чатов пока пуст'
                                      : 'Здесь появятся личные диалоги, которые вы отправите в архив',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: cs.onSurface.withValues(alpha: 0.62),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.only(
                              left: 6,
                              right: 6,
                              top: 4,
                              bottom:
                                  MediaQuery.of(context).padding.bottom + 12,
                            ),
                            itemCount: _visible.length,
                            separatorBuilder: (_, __) => Padding(
                              padding:
                                  const EdgeInsets.only(left: 72, right: 14),
                              child: Divider(
                                height: 0,
                                thickness: 0.6,
                                color: theme.dividerColor
                                    .withValues(alpha: dividerOpacity),
                              ),
                            ),
                            itemBuilder: (ctx, i) {
                              final c = _visible[i];
                              return _ArchiveRow(
                                data: c,
                                onTap: () => unawaited(_openChat(c)),
                                onLongPressStart: c.archiveType == 'personal'
                                    ? (details) => _showPersonalMenu(
                                          c,
                                          details.globalPosition,
                                        )
                                    : null,
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ArchiveSegmented extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;

  const _ArchiveSegmented({
    required this.index,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        children: [
          Expanded(
            child: _SegChip(
              label: 'Учебные',
              selected: index == 0,
              onTap: () => onChanged(0),
            ),
          ),
          Expanded(
            child: _SegChip(
              label: 'Личные',
              selected: index == 1,
              onTap: () => onChanged(1),
            ),
          ),
        ],
      ),
    );
  }
}

class _SegChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: selected ? cs.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected
                  ? cs.onPrimary
                  : cs.onSurface.withValues(alpha: 0.72),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _ArchiveRow extends StatelessWidget {
  final _ArchivedChat data;
  final VoidCallback onTap;
  final GestureLongPressStartCallback? onLongPressStart;

  const _ArchiveRow({
    required this.data,
    required this.onTap,
    this.onLongPressStart,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final onSurface = theme.colorScheme.onSurface;
    final onSurfaceVar = onSurface.withValues(alpha: 0.68);
    final isAcademic = data.archiveType == 'academic';
    final time = data.lastTime != null ? _formatTime(data.lastTime!) : '';
    final subtitle = isAcademic
        ? (data.semesterLabel?.isNotEmpty == true
            ? data.semesterLabel!
            : 'Учебный чат')
        : (data.lastMsgPreview ?? '');
    final footer = isAcademic && data.availableUntil != null
        ? 'Доступен до ${_formatLongDate(data.availableUntil!)}'
        : null;

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onLongPressStart: onLongPressStart,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                _ArchiveAvatar(
                  label: data.title,
                  avatarUrl: data.avatarUrl,
                  isAcademic: isAcademic,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleMedium?.copyWith(
                          color: onSurface,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(
                          color: onSurfaceVar,
                          fontWeight: FontWeight.w600,
                          height: 1.05,
                        ),
                      ),
                      if (footer != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          footer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.labelSmall?.copyWith(
                            color: onSurfaceVar,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ] else if (!isAcademic &&
                          (data.lastAuthor?.isNotEmpty ?? false)) ...[
                        const SizedBox(height: 2),
                        Text(
                          data.lastAuthor!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.labelSmall?.copyWith(color: onSurfaceVar),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (time.isNotEmpty)
                  Text(
                    time,
                    style: t.labelSmall?.copyWith(
                      color: onSurfaceVar,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$dd.$mo';
  }

  String _formatLongDate(DateTime dt) {
    const months = <String>[
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    final local = dt.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}

class _ArchiveAvatar extends StatelessWidget {
  final String label;
  final String? avatarUrl;
  final bool isAcademic;

  const _ArchiveAvatar({
    required this.label,
    this.avatarUrl,
    required this.isAcademic,
  });

  @override
  Widget build(BuildContext context) {
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 26,
        backgroundImage: NetworkImage(avatarUrl!),
        backgroundColor: Colors.transparent,
      );
    }

    final ch = (label.trim().isNotEmpty ? label.trim().characters.first : '•')
        .toUpperCase();
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 52,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: isAcademic ? cs.primaryContainer : cs.secondaryContainer,
      ),
      child: Text(
        ch,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 18,
          color: isAcademic ? cs.onPrimaryContainer : cs.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _ArchivedChat {
  final String? chatId;
  final String archiveType;
  final String chatType;
  final String title;
  final String? avatarUrl;
  final String? peerId;
  final String? teamId;
  final String? teamIcon;
  final String? teamTeacher;
  final String? teamGroupName;
  final String? semesterLabel;
  final String? lastAuthor;
  final String? lastMsgPreview;
  final DateTime? lastTime;
  final DateTime? availableUntil;
  final bool readOnly;

  const _ArchivedChat({
    required this.chatId,
    required this.archiveType,
    required this.chatType,
    required this.title,
    this.avatarUrl,
    this.peerId,
    this.teamId,
    this.teamIcon,
    this.teamTeacher,
    this.teamGroupName,
    this.semesterLabel,
    this.lastAuthor,
    this.lastMsgPreview,
    this.lastTime,
    this.availableUntil,
    this.readOnly = false,
  });

  factory _ArchivedChat.fromRpc(Map<String, dynamic> row) {
    final body = (row['body'] ?? '').toString().trim();
    final content = (row['content'] ?? '').toString().trim();
    final msgType = (row['msg_type'] ?? '').toString();
    String preview;
    if (body.isNotEmpty) {
      preview = body;
    } else if (content.isNotEmpty) {
      preview = content;
    } else if (msgType == 'file' || msgType == 'image') {
      preview = 'Вложение';
    } else {
      preview = 'Сообщений пока нет';
    }

    return _ArchivedChat(
      chatId: (row['chat_id'] ?? '').toString().isEmpty
          ? null
          : (row['chat_id'] ?? '').toString(),
      archiveType: (row['archive_type'] ?? '').toString(),
      chatType: (row['chat_type'] ?? '').toString(),
      title: (() {
        final t = (row['title'] ?? '').toString().trim();
        if (t.isNotEmpty) return t;
        final tn = (row['team_name'] ?? '').toString().trim();
        return tn.isNotEmpty ? tn : 'Чат';
      })(),
      avatarUrl: (() {
        final a = (row['avatar_url'] ?? '').toString().trim();
        return a.isEmpty ? null : a;
      })(),
      peerId: (() {
        final p = (row['peer_id'] ?? '').toString().trim();
        return p.isEmpty ? null : p;
      })(),
      teamId: (() {
        final t = (row['team_id'] ?? '').toString().trim();
        return t.isEmpty ? null : t;
      })(),
      teamIcon: (row['team_icon'] ?? '').toString(),
      teamTeacher: (row['team_teacher'] ?? '').toString(),
      teamGroupName: (row['team_group_name'] ?? '').toString(),
      semesterLabel: (() {
        final s = (row['semester_label'] ?? '').toString().trim();
        return s.isEmpty ? null : s;
      })(),
      lastAuthor: (() {
        final a = (row['last_author_name'] ?? '').toString().trim();
        return a.isEmpty ? null : a;
      })(),
      lastMsgPreview: preview,
      lastTime: DateTime.tryParse((row['last_message_at'] ?? '').toString()),
      availableUntil:
          DateTime.tryParse((row['available_until'] ?? '').toString()),
      readOnly: row['read_only'] == true,
    );
  }
}
