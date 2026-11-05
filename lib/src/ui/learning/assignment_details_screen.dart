import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../common/friendly_empty_state.dart';
import 'state/team_cubit.dart';
import 'models/assignment.dart';

class AssignmentDetailsScreen extends StatefulWidget {
  final String assignmentId;
  const AssignmentDetailsScreen({super.key, required this.assignmentId});

  @override
  State<AssignmentDetailsScreen> createState() =>
      _AssignmentDetailsScreenState();
}

class _AssignmentDetailsScreenState extends State<AssignmentDetailsScreen> {
  bool _saving = false;
  String get assignmentId => widget.assignmentId;
  Future<void> _save(Future<void> Function() action,
      {String? success, bool close = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await action();
      if (!mounted) return;
      if (success != null)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(success)));
      if (close) Navigator.of(context).pop();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось сохранить. Повторите.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Задание'),
        centerTitle: true,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: IconButton(
                tooltip: 'Ещё',
                icon: Icon(Icons.more_vert,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                onPressed: () => _showMore(context)),
          ),
        ],
      ),
      body: BlocBuilder<TeamCubit, TeamState>(
        builder: (context, state) {
          final st = state;
          final a = _pickAssignment(st, assignmentId);
          if (a == null) {
            return const FriendlyEmptyState(
              title: 'Задание недоступно',
              fallbackIcon: Icons.assignment_outlined,
              animationHeight: 56,
            );
          }
          final isDraft = st.pending?.id == a.id;
          final isDone = context.read<TeamCubit>().isAssignmentDone(a.id);
          final link = _findLink(a);
          final files = _extractAttachments(a);

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                ((MediaQuery.sizeOf(context).width - 800) / 2)
                    .clamp(20.0, double.infinity),
                16,
                ((MediaQuery.sizeOf(context).width - 800) / 2)
                    .clamp(20.0, double.infinity),
                32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ModernAssignmentHeaderCard(
                    assignment: a, isDraft: isDraft, isDone: isDone),
                if (isDraft) ...[
                  const SizedBox(height: 14),
                  _VoteHintBanner(votes: a.votesCount),
                ],
                const SizedBox(height: 20),
                if (link != null) ...[
                  _ModernSectionCard(
                    title: 'Ссылка',
                    icon: Icons.link_rounded,
                    child: _ModernLinkTile(link: link),
                  ),
                  const SizedBox(height: 14),
                ],
                _ModernSectionCard(
                  title: 'Описание',
                  icon: Icons.notes_rounded,
                  child: _ModernDescriptionTile(
                      description: a.description.trim().isEmpty
                          ? 'Описания нет.'
                          : a.description),
                ),
                if (files.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _ModernSectionCard(
                    title: 'Вложения',
                    icon: Icons.attach_file_rounded,
                    child: Column(
                        children: files
                            .map((f) => _ModernAttachmentTile(
                                name: f['name'] ?? '', path: f['path'] ?? ''))
                            .toList()),
                  ),
                ],
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: BlocBuilder<TeamCubit, TeamState>(
        builder: (context, state) {
          final st = state;
          final a = _pickAssignment(st, assignmentId);
          if (a == null) return const SizedBox.shrink();
          final isDraft = st.pending?.id == a.id;
          final isDone = context.read<TeamCubit>().isAssignmentDone(a.id);

          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Center(
                    heightFactor: 1,
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: Row(
                          children: [
                            if (isDraft && st.isStarosta)
                              Expanded(
                                child: _ModernBigButton(
                                  icon: Icons.rocket_launch,
                                  label: 'Опубликовать',
                                  onPressed: _saving
                                      ? null
                                      : () => _save(
                                          () => context
                                              .read<TeamCubit>()
                                              .publishAssignment(a.id),
                                          success: 'Задание опубликовано',
                                          close: true),
                                ),
                              ),
                            if (isDraft && !st.isStarosta)
                              Expanded(
                                child: _ModernBigButton(
                                  icon: Icons.how_to_vote,
                                  label: 'Голосовать «за»',
                                  onPressed: _saving
                                      ? null
                                      : () => _save(() => context
                                          .read<TeamCubit>()
                                          .voteFor(a.id, propagateError: true)),
                                ),
                              ),
                            if (!isDraft)
                              Expanded(
                                child: _ModernBigButton(
                                  icon: isDone
                                      ? Icons.check_circle
                                      : Icons.check_circle_outline,
                                  label: isDone
                                      ? 'Выполнено'
                                      : 'Отметить как выполнено',
                                  onPressed: _saving
                                      ? null
                                      : () => _save(
                                          () => context
                                              .read<TeamCubit>()
                                              .toggleCompleted(a.id),
                                          close: true),
                                ),
                              ),
                          ],
                        ))),
              ),
            ),
          );
        },
      ),
    );
  }

  Assignment? _pickAssignment(TeamState st, String id) {
    for (final assignment in st.assignments) {
      if (assignment.id == id) return assignment;
    }
    return null;
  }

  String? _findLink(Assignment a) {
    try {
      final dyn = a as dynamic;
      final fromModel = dyn.link ?? dyn.url ?? dyn.href;
      if (fromModel is String && fromModel.trim().isNotEmpty)
        return fromModel.trim();
    } catch (_) {}
    for (final f in _extractAttachments(a)) {
      final p = f['path'] ?? '';
      if (p.startsWith('http://') || p.startsWith('https://')) return p;
    }
    final rx = RegExp(r'(https?:\/\/[^\s]+)');
    final m = rx.firstMatch(a.description);
    if (m != null) return m.group(0);
    return null;
  }

  List<Map<String, String>> _extractAttachments(Assignment a) {
    final List<Map<String, String>> out = [];
    void addItem(dynamic item) {
      if (item == null) return;
      if (item is Map) {
        final name = (item['name'] ??
                item['filename'] ??
                item['title'] ??
                item['file'] ??
                '')
            .toString();
        final path =
            (item['path'] ?? item['url'] ?? item['link'] ?? item['href'] ?? '')
                .toString();
        if (name.isNotEmpty || path.isNotEmpty)
          out.add({'name': name, 'path': path});
      } else if (item is String) {
        final base = item.split('/').last.split('\\').last;
        out.add({'name': base, 'path': item});
      }
    }

    try {
      final dyn = a as dynamic;
      final attachments = dyn.attachments;
      if (attachments is Iterable) {
        for (final it in attachments) addItem(it);
      } else if (attachments != null) {
        addItem(attachments);
      }
      final files = dyn.files ?? dyn.fileList;
      if (files is Iterable) {
        for (final it in files) addItem(it);
      } else if (files != null) {
        addItem(files);
      }
    } catch (_) {}
    return out;
  }

  void _showMore(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      builder: (sheetContext) => Material(
        color: Theme.of(sheetContext).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              _ModernActionTile(
                icon: Icons.share,
                title: 'Поделиться',
                subtitle: 'Отправить ссылку на задание',
                onTap: () => Navigator.pop(context),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ModernAssignmentHeaderCard extends StatelessWidget {
  final Assignment assignment;
  final bool isDraft;
  final bool isDone;

  const _ModernAssignmentHeaderCard(
      {required this.assignment, required this.isDraft, required this.isDone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final color = isDraft
        ? (dark ? Colors.amber.shade200 : Colors.orange.shade900)
        : isDone
            ? (dark ? Colors.green.shade200 : Colors.green.shade900)
            : theme.colorScheme.primary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _ModernStatusChip(
          icon: isDraft
              ? Icons.edit_note
              : isDone
                  ? Icons.check_circle
                  : Icons.assignment_outlined,
          label: isDraft
              ? 'Черновик'
              : isDone
                  ? 'Выполнено'
                  : 'Опубликовано',
          background: color.withValues(alpha: .12),
          foreground: color),
      const SizedBox(height: 20),
      Text(assignment.title, style: theme.textTheme.titleLarge),
      if (assignment.due != null && '${assignment.due}'.trim().isNotEmpty) ...[
        const SizedBox(height: 20),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.event_outlined,
              color: theme.colorScheme.onSurfaceVariant, size: 20),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Срок выполнения', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(_formatDue(assignment.due),
                    style: theme.textTheme.bodyMedium),
              ])),
        ]),
      ],
    ]);
  }

  static String _formatDue(dynamic due) {
    if (due is DateTime) {
      String two(int v) => v < 10 ? '0$v' : '$v';
      return '${two(due.day)}.${two(due.month)}.${due.year} ${two(due.hour)}:${two(due.minute)}';
    }
    return '$due';
  }
}

class _ModernStatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;

  const _ModernStatusChip({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: foreground.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 8),
          Flexible(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: foreground))),
        ],
      ),
    );
  }
}

class _VoteHintBanner extends StatelessWidget {
  final int votes;

  const _VoteHintBanner({required this.votes});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: const Color(0xFF624B9C).withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.how_to_vote_rounded,
                color: Color(0xFF624B9C), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Нужны 2 голоса одногруппников',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Сейчас $votes/2 — потом задание увидят все.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModernSectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final IconData? icon;
  const _ModernSectionCard(
      {required this.title, required this.child, this.icon});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8)
          ],
          Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
        ]),
        const SizedBox(height: 12),
        child,
      ]),
    );
  }
}

class _ModernLinkTile extends StatelessWidget {
  final String link;

  const _ModernLinkTile({required this.link});

  @override
  Widget build(BuildContext context) {
    return Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.link,
                  color: Theme.of(context).colorScheme.primary, size: 20),
            ),
            title: Text(link,
                style: TextStyle(
                    decoration: TextDecoration.underline,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600)),
            subtitle: Text('Нажми, чтобы скопировать',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            trailing: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.copy,
                  color: Theme.of(context).colorScheme.onPrimary, size: 16),
            ),
            onTap: () async {
              await services.Clipboard.setData(
                  services.ClipboardData(text: link));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ссылка скопирована')));
            },
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ));
  }
}

class _ModernDescriptionTile extends StatelessWidget {
  final String description;
  const _ModernDescriptionTile({required this.description});
  @override
  Widget build(BuildContext context) => Text(description,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5));
}

class _ModernAttachmentTile extends StatelessWidget {
  final String name;
  final String path;

  const _ModernAttachmentTile({required this.name, required this.path});

  @override
  Widget build(BuildContext context) {
    final ext = name.split('.').last.toLowerCase();
    IconData icon = Icons.insert_drive_file;
    Color iconColor = const Color(0xFF64748B);

    if (['pdf'].contains(ext)) {
      icon = Icons.picture_as_pdf;
      iconColor = const Color(0xFFEF4444);
    } else if (['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(ext)) {
      icon = Icons.image;
      iconColor = const Color(0xFF2F9D84);
    } else if (['xls', 'xlsx', 'csv'].contains(ext)) {
      icon = Icons.table_chart;
      iconColor = const Color(0xFF2F9D84);
    } else if (['doc', 'docx'].contains(ext)) {
      icon = Icons.description;
      iconColor = const Color(0xFF7C63D8);
    } else if (['zip', 'rar', '7z'].contains(ext)) {
      icon = Icons.archive;
      iconColor = const Color(0xFFB58B3B);
    }

    final showName = name.isNotEmpty
        ? name
        : (path.isNotEmpty ? path.split('/').last.split('\\').last : 'Файл');

    return Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            title: Text(showName,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface)),
            subtitle: path.isNotEmpty
                ? Text(path,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant))
                : null,
            trailing: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: const Color(0xFF64748B).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.more_horiz,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 16),
            ),
            onTap: () {},
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ));
  }
}

class _ModernBigButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData icon;
  const _ModernBigButton(
      {required this.onPressed, required this.label, required this.icon});
  @override
  Widget build(BuildContext context) => FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label, textAlign: TextAlign.center),
        style: FilledButton.styleFrom(
            minimumSize: const Size(0, 56),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
      );
}

class _ModernActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ModernActionTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap});
  @override
  Widget build(BuildContext context) => ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap);
}
