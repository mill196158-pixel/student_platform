import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'state/team_cubit.dart';
import 'models/assignment.dart';

class AssignmentDetailsScreen extends StatelessWidget {
  final String assignmentId;
  const AssignmentDetailsScreen({super.key, required this.assignmentId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // светлый контрастный фон «как у Keep»
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        title: const Text('Задание'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showMore(context),
            tooltip: 'Ещё',
          ),
        ],
      ),

      body: BlocBuilder<TeamCubit, TeamState>(
        builder: (context, state) {
          final st = state;
          final a = _pickAssignment(st, assignmentId);

          final isDraft = !a.published;
          final isDone = context.read<TeamCubit>().isAssignmentDone(a.id);

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AssignmentHeaderCard(
                  assignment: a,
                  isDraft: isDraft,
                  isDone: isDone,
                ),
                const SizedBox(height: 16),
                _SectionCard(
                  title: 'Описание',
                  child: Text(
                    (a.description.trim().isEmpty)
                        ? 'Описания нет.'
                        : a.description,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.42,
                      color: Color(0xFF111827), // почти-чёрный
                    ),
                  ),
                ),
                if ((a.attachments).isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _SectionCard(
                    title: 'Вложения',
                    child: Column(
                      children: a.attachments
                          .map((f) => _AttachmentTile(
                                name: f['name'] ?? '',
                                path: f['path'] ?? '',
                              ))
                          .toList(),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),

      // ОДНА большая кнопка снизу
      bottomNavigationBar: BlocBuilder<TeamCubit, TeamState>(
        builder: (context, state) {
          final st = state;
          final a = _pickAssignment(st, assignmentId);

          final isDraft = st.pending?.id == a.id;
          final isDone = context.read<TeamCubit>().isAssignmentDone(a.id);

          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                children: [
                  if (isDraft && st.isStarosta)
                    Expanded(
                      child: _BigButton.icon(
                        icon: Icons.publish_outlined,
                        label: 'Опубликовать',
                        onPressed: () {
                          context.read<TeamCubit>().publishPendingManually();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Задание опубликовано')),
                          );
                        },
                      ),
                    ),
                  if (isDraft && !st.isStarosta)
                    Expanded(
                      child: _BigButton.tonalIcon(
                        icon: Icons.how_to_vote_outlined,
                        label: 'Голосовать «за»',
                        onPressed: () => context.read<TeamCubit>().voteForPending(),
                      ),
                    ),
                  if (!isDraft)
                    Expanded(
                      child: _BigButton.icon(
                        icon: isDone ? Icons.check_circle : Icons.task_alt,
                        label: isDone ? 'Выполнено' : 'Отметить как выполнено',
                        bgColor: isDone ? const Color(0xFF16A34A) : null, // зелёный если уже выполнено
                        onPressed: () => context
                            .read<TeamCubit>()
                            .markAssignmentDone(assignmentId: a.id, done: !isDone),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  TeamAssignment _pickAssignment(TeamState st, String id) {
    return (st.assignments).firstWhere(
      (x) => x.id == id,
      orElse: () => st.published.isNotEmpty ? st.published.last : st.assignments.first,
    );
  }

  void _showMore(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Поделиться'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// ——— Карточка «шапки»: статусные чипы, заголовок, срок
class _AssignmentHeaderCard extends StatelessWidget {
  final TeamAssignment assignment;
  final bool isDraft;
  final bool isDone;

  const _AssignmentHeaderCard({
    required this.assignment,
    required this.isDraft,
    required this.isDone,
  });

  @override
  Widget build(BuildContext context) {
    final stripe = isDraft
        ? const Color(0xFFF59E0B) // amber-500
        : (isDone ? const Color(0xFF16A34A) : Theme.of(context).colorScheme.primary);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white, // Явно белая карточка
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)), // gray-200
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.06),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // цветная полоска сверху
          Container(height: 6, color: stripe),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (isDraft)
                      _StatusChip(
                        icon: Icons.edit_note,
                        label: 'Черновик',
                        bg: const Color(0xFFFFF3CD),
                        border: const Color(0xFFF59E0B),
                        fgIcon: const Color(0xFFB45309),
                      ),
                    if (!isDraft)
                      _StatusChip(
                        icon: Icons.rocket_launch_outlined,
                        label: 'Опубликовано',
                        bg: const Color(0xFFEFFAF1),
                        border: const Color(0xFF16A34A),
                        fgIcon: const Color(0xFF166534),
                      ),
                    if (isDone)
                      _StatusChip(
                        icon: Icons.check_circle,
                        label: 'Выполнено',
                        bg: const Color(0xFFEFFAF1),
                        border: const Color(0xFF16A34A),
                        fgIcon: const Color(0xFF166534),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  assignment.title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.1,
                    color: Color(0xFF111827), // почти-чёрный
                    height: 1.15,
                  ),
                ),
                if (assignment.due != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.event_outlined, size: 18, color: Color(0xFF6B7280)),
                      const SizedBox(width: 6),
                      Text(
                        'Срок: ${_formatDue(assignment.due)}',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF374151),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDue(dynamic due) {
    if (due is DateTime) {
      String two(int v) => v < 10 ? '0$v' : '$v';
      return '${two(due.day)}.${two(due.month)}.${due.year} ${two(due.hour)}:${two(due.minute)}';
    }
    return '$due';
    // если у тебя строка типа "15.09" — она отобразится как есть
  }
}

class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bg;
  final Color border;
  final Color fgIcon;

  const _StatusChip({
    required this.icon,
    required this.label,
    required this.bg,
    required this.border,
    required this.fgIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fgIcon),
          const SizedBox(width: 6),
          const Text(
            // тёмный текст
            // (жёстко, чтобы не побелел в тёмной теме)
            '',
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF111827),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white, // белая секция
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  final String name;
  final String path;
  const _AttachmentTile({required this.name, required this.path});

  @override
  Widget build(BuildContext context) {
    final ext = name.split('.').last.toLowerCase();
    IconData icon = Icons.insert_drive_file_outlined;
    if (['pdf'].contains(ext)) icon = Icons.picture_as_pdf_outlined;
    if (['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(ext)) icon = Icons.image_outlined;
    if (['xls', 'xlsx', 'csv'].contains(ext)) icon = Icons.table_chart_outlined;
    if (['doc', 'docx'].contains(ext)) icon = Icons.description_outlined;
    if (['zip', 'rar', '7z'].contains(ext)) icon = Icons.archive_outlined;

    return ListTile(
      dense: false,
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 6,
      leading: Icon(icon, color: const Color(0xFF6B7280)),
      title: Text(
        name,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Color(0xFF111827),
        ),
      ),
      subtitle: Text(
        path,
        style: const TextStyle(
          fontSize: 12.5,
          color: Color(0xFF6B7280),
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.more_horiz),
        onPressed: () {},
        tooltip: 'Действия',
      ),
      onTap: () {},
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

/// Красивая «большая кнопка» (Stadium/радиус 28, высота 52)
class _BigButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;
  final IconData? icon;
  final Color? bgColor;
  final bool tonal;

  const _BigButton._({
    required this.onPressed,
    required this.label,
    this.icon,
    this.bgColor,
    this.tonal = false,
  });

  factory _BigButton.icon({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? bgColor,
  }) =>
      _BigButton._(icon: icon, label: label, onPressed: onPressed, bgColor: bgColor);

  factory _BigButton.tonalIcon({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) =>
      _BigButton._(
        icon: icon,
        label: label,
        onPressed: onPressed,
        tonal: true,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = tonal ? scheme.secondaryContainer : (bgColor ?? scheme.primary);
    final fg = tonal ? scheme.onSecondaryContainer : Colors.white;

    return SizedBox(
      height: 52,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: ButtonStyle(
          backgroundColor: MaterialStatePropertyAll(bg),
          foregroundColor: MaterialStatePropertyAll(fg),
          shape: MaterialStatePropertyAll(
            const StadiumBorder(),
          ),
          textStyle: const MaterialStatePropertyAll(
            TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          elevation: const MaterialStatePropertyAll(0),
        ),
      ),
    );
  }
}
