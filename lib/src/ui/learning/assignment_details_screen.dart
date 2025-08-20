import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'state/team_cubit.dart';
import 'models/assignment.dart';

class AssignmentDetailsScreen extends StatelessWidget {
  final String assignmentId;
  const AssignmentDetailsScreen({super.key, required this.assignmentId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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

          final isDraft = st.pending?.id == a.id;
          final isDone = context.read<TeamCubit>().isAssignmentDone(a.id);

          final link = _findLink(a);                 // ссылка из модели/вложений/описания
          final files = _extractAttachments(a);      // универсальный парсер вложений

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

                if (link != null) ...[
                  _SectionCard(
                    title: 'Ссылка',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.link),
                      title: Text(
                        link,
                        style: const TextStyle(
                          decoration: TextDecoration.underline,
                          color: Color(0xFF1D4ED8),
                        ),
                      ),
                      subtitle: const Text('Нажми, чтобы скопировать'),
                      onTap: () async {
                        await services.Clipboard.setData(
                          services.ClipboardData(text: link),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Ссылка скопирована')),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                _SectionCard(
                  title: 'Описание',
                  child: Text(
                    (a.description.trim().isEmpty) ? 'Описания нет.' : a.description,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.42,
                      color: Color(0xFF111827),
                    ),
                  ),
                ),

                if (files.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _SectionCard(
                    title: 'Вложения',
                    child: Column(
                      children: files
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
                          Navigator.of(context).pop();
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
                        icon: isDone ? Icons.check_box : Icons.check_box_outline_blank,
                        label: isDone ? 'Выполнено' : 'Отметить как выполнено',
                        bgColor: isDone ? const Color(0xFF16A34A) : null,
                        onPressed: () {
                          // тот же метод, что и в списке — состояния синхронизируются мгновенно
                          context.read<TeamCubit>().toggleCompleted(a.id);
                          Navigator.of(context).pop(); // назад к списку
                        },
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

  Assignment _pickAssignment(TeamState st, String id) {
    return (st.assignments).firstWhere(
      (x) => x.id == id,
      orElse: () => st.published.isNotEmpty ? st.published.last : st.assignments.first,
    );
  }

  // --- Универсальный поиск ссылки ---
  String? _findLink(Assignment a) {
    // 1) Прямо из модели: link/url/href (через dynamic, чтобы не падать, если поля нет)
    try {
      final dyn = a as dynamic;
      final fromModel = dyn.link ?? dyn.url ?? dyn.href;
      if (fromModel is String && fromModel.trim().isNotEmpty) return fromModel.trim();
    } catch (_) {}

    // 2) Из вложений
    for (final f in _extractAttachments(a)) {
      final p = f['path'] ?? '';
      if (p.startsWith('http://') || p.startsWith('https://')) return p;
    }

    // 3) Первая http(s)-ссылка в описании
    final rx = RegExp(r'(https?:\/\/[^\s]+)');
    final m = rx.firstMatch(a.description);
    if (m != null) return m.group(0);

    return null;
  }

  // --- Универсальное извлечение вложений из разных структур модели ---
  List<Map<String, String>> _extractAttachments(Assignment a) {
    final List<Map<String, String>> out = [];

    void addItem(dynamic item) {
      if (item == null) return;
      if (item is Map) {
        final name = (item['name'] ?? item['filename'] ?? item['title'] ?? item['file'] ?? '').toString();
        final path = (item['path'] ?? item['url'] ?? item['link'] ?? item['href'] ?? '').toString();
        if (name.isNotEmpty || path.isNotEmpty) {
          out.add({'name': name, 'path': path});
        }
      } else if (item is String) {
        final base = item.split('/').last.split('\\').last;
        out.add({'name': base, 'path': item});
      }
    }

    try {
      final dyn = a as dynamic;

      // стандартное поле
      final attachments = dyn.attachments;
      if (attachments is Iterable) {
        for (final it in attachments) addItem(it);
      } else if (attachments != null) {
        addItem(attachments);
      }

      // возможные альтернативы
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
  final Assignment assignment;
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
        ? const Color(0xFFF59E0B)
        : (isDone ? const Color(0xFF16A34A) : Theme.of(context).colorScheme.primary);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)),
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
                    color: Color(0xFF111827),
                    height: 1.15,
                  ),
                ),
                if (assignment.due != null && '${assignment.due}'.trim().isNotEmpty) ...[
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
        color: Colors.white,
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

    final showName = name.isNotEmpty ? name : (path.isNotEmpty ? path.split('/').last.split('\\').last : 'Файл');

    return ListTile(
      dense: false,
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 6,
      leading: Icon(icon, color: const Color(0xFF6B7280)),
      title: Text(
        showName,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Color(0xFF111827),
        ),
      ),
      subtitle: path.isNotEmpty
          ? Text(
              path,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
            )
          : null,
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
        style: const ButtonStyle(
          shape: MaterialStatePropertyAll(StadiumBorder()),
          textStyle: MaterialStatePropertyAll(
            TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          elevation: MaterialStatePropertyAll(0),
        ).copyWith(
          backgroundColor: MaterialStatePropertyAll(bg),
          foregroundColor: MaterialStatePropertyAll(fg),
        ),
      ),
    );
  }
}
