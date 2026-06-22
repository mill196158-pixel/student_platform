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
      backgroundColor: const Color(0xFFFAF8FC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Задание',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
        centerTitle: true,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 4))
              ],
            ),
            child: IconButton(
                icon: const Icon(Icons.more_vert, color: Color(0xFF64748B)),
                onPressed: () => _showMore(context)),
          ),
        ],
      ),
      body: BlocBuilder<TeamCubit, TeamState>(
        builder: (context, state) {
          final st = state;
          final a = _pickAssignment(st, assignmentId);
          final isDraft = st.pending?.id == a.id;
          final isDone = context.read<TeamCubit>().isAssignmentDone(a.id);
          final link = _findLink(a);
          final files = _extractAttachments(a);

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 140),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ModernAssignmentHeaderCard(
                    assignment: a, isDraft: isDraft, isDone: isDone),
                const SizedBox(height: 24),
                if (link != null) ...[
                  _ModernSectionCard(
                    title: '🔗 Ссылка',
                    gradient: const LinearGradient(
                        colors: [Color(0xFFEDE7F6), Color(0xFFF7FBFA)]),
                    child: _ModernLinkTile(link: link),
                  ),
                  const SizedBox(height: 16),
                ],
                _ModernSectionCard(
                  title: '📝 Описание',
                  gradient: const LinearGradient(
                      colors: [Color(0xFFFFFBFF), Color(0xFFF3EEF9)]),
                  child: _ModernDescriptionTile(
                      description: a.description.trim().isEmpty
                          ? 'Описания нет.'
                          : a.description),
                ),
                if (files.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _ModernSectionCard(
                    title: '📎 Вложения',
                    gradient: const LinearGradient(
                        colors: [Color(0xFFD6F5EE), Color(0xFFF7FBFA)]),
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
          final isDraft = st.pending?.id == a.id;
          final isDone = context.read<TeamCubit>().isAssignmentDone(a.id);

          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, -4))
              ],
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Row(
                  children: [
                    if (isDraft && st.isStarosta)
                      Expanded(
                        child: _ModernBigButton(
                          icon: Icons.rocket_launch,
                          label: 'Опубликовать',
                          gradient: const LinearGradient(
                              colors: [Color(0xFF2F9D84), Color(0xFF5DBEAD)]),
                          onPressed: () {
                            context.read<TeamCubit>().publishPendingManually();
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Задание опубликовано')));
                            Navigator.of(context).pop();
                          },
                        ),
                      ),
                    if (isDraft && !st.isStarosta)
                      Expanded(
                        child: _ModernBigButton(
                          icon: Icons.how_to_vote,
                          label: 'Голосовать «за»',
                          gradient: const LinearGradient(
                              colors: [Color(0xFFB58B3B), Color(0xFFD6BD7A)]),
                          onPressed: () =>
                              context.read<TeamCubit>().voteFor(a.id),
                        ),
                      ),
                    if (!isDraft)
                      Expanded(
                        child: _ModernBigButton(
                          icon: isDone
                              ? Icons.check_circle
                              : Icons.check_circle_outline,
                          label:
                              isDone ? 'Выполнено' : 'Отметить как выполнено',
                          gradient: isDone
                              ? const LinearGradient(colors: [
                                  Color(0xFF2F9D84),
                                  Color(0xFF5DBEAD)
                                ])
                              : const LinearGradient(colors: [
                                  Color(0xFF7C63D8),
                                  Color(0xFF8A72D8)
                                ]),
                          onPressed: () {
                            context.read<TeamCubit>().toggleCompleted(a.id);
                            Navigator.of(context).pop();
                          },
                        ),
                      ),
                  ],
                ),
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
      orElse: () =>
          st.published.isNotEmpty ? st.published.last : st.assignments.first,
    );
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
      showDragHandle: true,
      builder: (_) => Container(
        decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
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
                gradient: const LinearGradient(
                    colors: [Color(0xFFEDE7F6), Color(0xFFF7FBFA)]),
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
    final statusGradient = isDraft
        ? const LinearGradient(colors: [Color(0xFFFFF1D6), Color(0xFFEDE7F6)])
        : (isDone
            ? const LinearGradient(
                colors: [Color(0xFFD6F5EE), Color(0xFFC2ECE4)])
            : const LinearGradient(
                colors: [Color(0xFFEDE7F6), Color(0xFFD6F5EE)]));

    return Container(
      decoration: BoxDecoration(
        gradient: statusGradient,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 20,
              offset: const Offset(0, 8)),
          BoxShadow(
              color: Colors.white.withValues(alpha: 0.8),
              blurRadius: 1,
              offset: const Offset(0, 1)),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(24),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _ModernStatusChip(
                  icon: isDraft
                      ? Icons.edit_note
                      : (isDone ? Icons.check_circle : Icons.rocket_launch),
                  label: isDraft
                      ? 'Черновик'
                      : (isDone ? 'Выполнено' : 'Опубликовано'),
                  background: isDraft
                      ? const Color(0xFFFFF1D6)
                      : (isDone
                          ? const Color(0xFFD6F5EE)
                          : const Color(0xFFEDE7F6)),
                  foreground: isDraft
                      ? const Color(0xFFB58B3B)
                      : (isDone
                          ? const Color(0xFF2F9D84)
                          : const Color(0xFF7C63D8)),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.3)),
                  ),
                  child: const Icon(Icons.assignment,
                      color: Color(0xFF64748B), size: 20),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              assignment.title,
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: Color(0xFF1E293B),
                  height: 1.2),
            ),
            if (assignment.due != null &&
                '${assignment.due}'.trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: const Color(0xFFFFF1D6),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.event,
                          size: 18, color: Color(0xFFB58B3B)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Срок выполнения',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF64748B))),
                          Text(_formatDue(assignment.due),
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1E293B))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
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
        boxShadow: [
          BoxShadow(
              color: foreground.withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: foreground)),
        ],
      ),
    );
  }
}

class _ModernSectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Gradient gradient;

  const _ModernSectionCard(
      {required this.title, required this.child, required this.gradient});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 4))
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1E293B))),
                const Spacer(),
                Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: const Color(0xFF64748B),
                        borderRadius: BorderRadius.circular(4))),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _ModernLinkTile extends StatelessWidget {
  final String link;

  const _ModernLinkTile({required this.link});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: const Color(0xFFEDE7F6),
              borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.link, color: Color(0xFF7C63D8), size: 20),
        ),
        title: Text(link,
            style: const TextStyle(
                decoration: TextDecoration.underline,
                color: Color(0xFF7C63D8),
                fontWeight: FontWeight.w600)),
        subtitle: const Text('Нажми, чтобы скопировать',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
        trailing: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: const Color(0xFF7C63D8),
              borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.copy, color: Colors.white, size: 16),
        ),
        onTap: () async {
          await services.Clipboard.setData(services.ClipboardData(text: link));
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ссылка скопирована')));
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}

class _ModernDescriptionTile extends StatelessWidget {
  final String description;

  const _ModernDescriptionTile({required this.description});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Text(description,
          style: const TextStyle(
              fontSize: 16, height: 1.5, color: Color(0xFF374151))),
    );
  }
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

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        title: Text(showName,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1E293B))),
        subtitle: path.isNotEmpty
            ? Text(path,
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)))
            : null,
        trailing: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: const Color(0xFF64748B).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10)),
          child:
              const Icon(Icons.more_horiz, color: Color(0xFF64748B), size: 16),
        ),
        onTap: () {},
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}

class _ModernBigButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;
  final IconData icon;
  final Gradient gradient;

  const _ModernBigButton(
      {required this.onPressed,
      required this.label,
      required this.icon,
      required this.gradient});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 12,
              offset: const Offset(0, 4))
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 12),
                Text(label,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModernActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Gradient gradient;
  final VoidCallback onTap;

  const _ModernActionTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.gradient,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.share,
                      color: Color(0xFF64748B), size: 20),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1E293B))),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF64748B))),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios,
                    color: Color(0xFF64748B), size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
