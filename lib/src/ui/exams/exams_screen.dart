import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';

class ExamsScreen extends StatefulWidget {
  const ExamsScreen({super.key});

  @override
  State<ExamsScreen> createState() => _ExamsScreenState();
}

class _ExamsScreenState extends State<ExamsScreen> {
  late Future<_StudyPlanState> _future;

  @override
  void initState() {
    super.initState();
    _future = _StudyPlanRepository().load();
  }

  Future<void> _reload() async {
    final next = _StudyPlanRepository().load();
    setState(() => _future = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_StudyPlanState>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: AppBar(title: Text('Зачёты и экзамены')),
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: Center(child: ProductLoadingIndicator.page()),
          );
        }

        final state = snapshot.data ?? _StudyPlanState.demo();
        return Scaffold(
          appBar: AppBar(
            title: Text('Зачёты и экзамены'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _AppBarMoreButton(
                  onExportPdf: () => _showExportSheet(context, state),
                ),
              ),
            ],
          ),
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: RefreshIndicator(
            onRefresh: () async {
              final next = _StudyPlanRepository().load();
              setState(() => _future = next);
              await next;
            },
            child: Center(
                child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 900),
                    child: _StudyPlanView(state: state, onChanged: _reload))),
          ),
        );
      },
    );
  }
}

class _StudyPlanView extends StatelessWidget {
  final _StudyPlanState state;
  final Future<void> Function() onChanged;

  const _StudyPlanView({required this.state, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final currentItems = state.itemsForSemester(state.currentSemester);
    final controlFormsCount =
        currentItems.map((item) => item.controlType).toSet().length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        _HeroCard(
          semester: state.currentSemester,
          count: currentItems.length,
          controlFormsCount: controlFormsCount,
          isDemo: state.isDemo,
        ),
        SizedBox(height: 14),
        _CurrentSemesterCard(
          semester: state.currentSemester,
          items: currentItems,
          onChanged: onChanged,
        ),
        SizedBox(height: 18),
        _FullPlanCard(state: state, onChanged: onChanged),
      ],
    );
  }
}

class _CurrentSemesterCard extends StatelessWidget {
  final int semester;
  final List<_StudySubject> items;
  final Future<void> Function() onChanged;

  const _CurrentSemesterCard({
    required this.semester,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(vertical: 4),
      childrenPadding: const EdgeInsets.only(bottom: 16),
      collapsedShape: const Border(),
      shape: const Border(),
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
      collapsedIconColor: Theme.of(context).colorScheme.onSurfaceVariant,
      textColor: Theme.of(context).colorScheme.onSurface,
      collapsedTextColor: Theme.of(context).colorScheme.onSurface,
      leading: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: .1),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.view_agenda_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      title: Text(
        'Текущий семестр',
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        '$semester семестр · ${items.length} ${_disciplineWord(items.length)}',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      children: [
        SizedBox(height: 4),
        if (items.isEmpty)
          const _EmptyPlanCard()
        else
          _ControlGroupedList(
            items: items,
            currentSemester: semester,
            onChanged: onChanged,
          ),
      ],
    );
  }
}

class _FullPlanCard extends StatefulWidget {
  final _StudyPlanState state;
  final Future<void> Function() onChanged;

  const _FullPlanCard({required this.state, required this.onChanged});

  @override
  State<_FullPlanCard> createState() => _FullPlanCardState();
}

class _FullPlanCardState extends State<_FullPlanCard> {
  late int _expandedSemester;

  @override
  void initState() {
    super.initState();
    _expandedSemester = widget.state.currentSemester;
  }

  @override
  void didUpdateWidget(covariant _FullPlanCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.state.semesters.contains(_expandedSemester)) {
      _expandedSemester = widget.state.currentSemester;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedItems = widget.state.itemsForSemester(_expandedSemester);

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(vertical: 4),
      childrenPadding: const EdgeInsets.only(bottom: 16),
      collapsedShape: const Border(),
      shape: const Border(),
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
      collapsedIconColor: Theme.of(context).colorScheme.onSurfaceVariant,
      textColor: Theme.of(context).colorScheme.onSurface,
      collapsedTextColor: Theme.of(context).colorScheme.onSurface,
      leading: Icon(Icons.menu_book_outlined,
          color: Theme.of(context).colorScheme.onSurface),
      title: Text(
        'Весь учебный план',
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        '${widget.state.semesters.length} ${_pluralRu(widget.state.semesters.length, 'семестр', 'семестра', 'семестров')}, '
        '${widget.state.items.length} ${_disciplineWord(widget.state.items.length)}',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      children: [
        SizedBox(height: 8),
        LayoutBuilder(builder: (context, bounds) {
          final semesters = widget.state.semesters;
          final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
          final columns = (bounds.maxWidth / (110 * scale))
              .floor()
              .clamp(1, semesters.length.clamp(1, 6));
          final width = (bounds.maxWidth - 8 * (columns - 1)) / columns;
          return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final semester in semesters)
                  SizedBox(
                      width: width,
                      child: _SemesterTabButton(
                          semester: semester,
                          count: widget.state.itemsForSemester(semester).length,
                          selected: _expandedSemester == semester,
                          isCurrent: semester == widget.state.currentSemester,
                          onTap: () =>
                              setState(() => _expandedSemester = semester))),
              ]));
        }),
        _SemesterSubjectList(
          semester: _expandedSemester,
          items: selectedItems,
          currentSemester: widget.state.currentSemester,
          onChanged: widget.onChanged,
        ),
      ],
    );
  }
}

class _SemesterTabButton extends StatelessWidget {
  final int semester;
  final int count;
  final bool selected;
  final bool isCurrent;
  final VoidCallback onTap;
  const _SemesterTabButton(
      {required this.semester,
      required this.count,
      required this.selected,
      required this.isCurrent,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Semantics(
        selected: selected,
        label: 'Семестр $semester${isCurrent ? ', текущий' : ''}',
        child: OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 64),
                padding: const EdgeInsets.all(12),
                backgroundColor: selected ? cs.primaryContainer : cs.surface,
                foregroundColor:
                    selected ? cs.onPrimaryContainer : cs.onSurface,
                side: BorderSide(
                    color: selected ? cs.primary : cs.outlineVariant),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Семестр $semester',
                      style: theme.textTheme.labelLarge?.copyWith(
                          color:
                              selected ? cs.onPrimaryContainer : cs.onSurface)),
                  const SizedBox(height: 4),
                  Text(
                      '$count ${_disciplineWord(count)}${isCurrent ? ' · текущий' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: selected
                              ? cs.onPrimaryContainer
                              : cs.onSurfaceVariant)),
                ])));
  }
}

class _SemesterSubjectList extends StatelessWidget {
  final int semester;
  final List<_StudySubject> items;
  final int currentSemester;
  final Future<void> Function() onChanged;

  const _SemesterSubjectList({
    required this.semester,
    required this.items,
    required this.currentSemester,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final orderedItems = [...items]..sort((a, b) {
        final controlCompare =
            _controlTypeOrder.indexOf(a.controlType).compareTo(
                  _controlTypeOrder.indexOf(b.controlType),
                );
        if (controlCompare != 0) return controlCompare;
        return a.name.compareTo(b.name);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$semester семестр',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 2),
        Text(
          items.isEmpty
              ? 'Нет дисциплин'
              : '${items.length} ${_disciplineWord(items.length)}',
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12),
        ),
        SizedBox(height: 10),
        if (items.isEmpty)
          Text(
            'В этом семестре пока нет дисциплин',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          )
        else
          for (final item in orderedItems)
            _SubjectListTile(
              item: item,
              isCurrentSemester: item.semesterNumber == currentSemester,
              onChanged: onChanged,
            ),
      ],
    );
  }
}

class _HeroCard extends StatelessWidget {
  final int semester;
  final int count;
  final int controlFormsCount;
  final bool isDemo;
  const _HeroCard(
      {required this.semester,
      required this.count,
      required this.controlFormsCount,
      required this.isDemo});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.school_outlined,
              color: theme.colorScheme.primary, size: 28),
          SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('$semester-й семестр', style: theme.textTheme.titleMedium),
                SizedBox(height: 4),
                Text(
                    '$count ${_disciplineWord(count)} · форм контроля: $controlFormsCount',
                    style: theme.textTheme.bodyMedium),
              ])),
          if (isDemo) Chip(label: Text('Пример')),
        ]));
  }
}

class _AppBarMoreButton extends StatelessWidget {
  final VoidCallback onExportPdf;

  const _AppBarMoreButton({required this.onExportPdf});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return PopupMenuButton<_ExamsAppBarAction>(
      tooltip: 'Ещё',
      offset: Offset(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      onSelected: (action) {
        if (action == _ExamsAppBarAction.exportPdf) {
          onExportPdf();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _ExamsAppBarAction.exportPdf,
          child: Row(
            children: [
              Icon(Icons.picture_as_pdf_outlined, color: primary, size: 20),
              SizedBox(width: 12),
              Flexible(
                  child: Text(
                'Скачать PDF',
                style: TextStyle(fontWeight: FontWeight.w700),
              )),
            ],
          ),
        ),
      ],
      child: Material(
        color: primary.withValues(alpha: .10),
        shape: CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(Icons.more_horiz_rounded, size: 22),
        ),
      ),
    );
  }
}

enum _ExamsAppBarAction { exportPdf }

class _ExportPillButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ExportPillButton({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) =>
      OutlinedButton(onPressed: onTap, child: Text(label));
}

class _ExportPrimaryButton extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ExportPrimaryButton({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: primary.withValues(alpha: .16)),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: .12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.menu_book_outlined, color: primary),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _ControlGroupedList extends StatelessWidget {
  final List<_StudySubject> items;
  final int currentSemester;
  final Future<void> Function() onChanged;

  const _ControlGroupedList({
    required this.items,
    required this.currentSemester,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<_StudySubject>>{};
    for (final item in items) {
      groups.putIfAbsent(item.controlType, () => []).add(item);
    }

    final orderedTypes =
        _controlTypeOrder.where((type) => groups.containsKey(type)).followedBy(
              groups.keys.where((type) => !_controlTypeOrder.contains(type)),
            );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final type in orderedTypes) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
            child: Text(
              _controlGroupTitle(type),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _controlColor(type, context),
                  ),
            ),
          ),
          for (final item in groups[type]!)
            _SubjectListTile(
              item: item,
              isCurrentSemester: item.semesterNumber == currentSemester,
              onChanged: onChanged,
            ),
        ],
      ],
    );
  }
}

class _SubjectListTile extends StatelessWidget {
  final _StudySubject item;
  final bool isCurrentSemester;
  final Future<void> Function() onChanged;
  const _SubjectListTile(
      {required this.item,
      required this.isCurrentSemester,
      required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _controlColor(item.controlType, context);
    return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: theme.colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: theme.colorScheme.outlineVariant)),
          child: InkWell(
            onTap: () => _showSubjectDetailsSheet(context, item),
            child: Padding(
                padding: const EdgeInsets.all(14),
                child: LayoutBuilder(builder: (context, bounds) {
                  final actions = Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (item.userVote == null)
                          _SmallIconAction(
                              tooltip: 'Оценить',
                              icon: Icons.star_rate_rounded,
                              color: color,
                              enabled: item.canVote,
                              onTap: () =>
                                  _showVoteSheet(context, item, onChanged))
                        else
                          _TinyStatus(label: 'Оценено'),
                        _SmallIconAction(
                            tooltip: 'Открыть чат',
                            icon: Icons.chat_bubble_outline_rounded,
                            color: theme.colorScheme.primary,
                            enabled: item.canOpenChat,
                            onTap: () => _openSubjectChat(context, item)),
                      ]);
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ControlBadge(type: item.controlType),
                              SizedBox(width: 12),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(item.name,
                                        style: theme.textTheme.titleSmall),
                                    SizedBox(height: 4),
                                    Text(
                                        item.department.isEmpty
                                            ? 'Кафедра не указана'
                                            : item.department,
                                        style: theme.textTheme.bodySmall),
                                    SizedBox(height: 6),
                                    _DifficultyLine(item: item),
                                  ])),
                              if (bounds.maxWidth >= 520) ...[
                                SizedBox(width: 12),
                                actions
                              ],
                            ]),
                        if (bounds.maxWidth < 520) ...[
                          SizedBox(height: 8),
                          Align(
                              alignment: Alignment.centerRight, child: actions)
                        ],
                      ]);
                })),
          ),
        ));
  }
}

class _SmallIconAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;
  const _SmallIconAction(
      {required this.tooltip,
      required this.icon,
      required this.color,
      required this.enabled,
      required this.onTap});
  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
      style: IconButton.styleFrom(
          minimumSize: Size(48, 48),
          foregroundColor: color,
          backgroundColor: color.withValues(alpha: .1)),
      icon: Icon(icon, size: 20));
}

class _TinyStatus extends StatelessWidget {
  final String label;

  const _TinyStatus({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).brightness == Brightness.dark
        ? Colors.green.shade200
        : Colors.green.shade900;
    return Container(
      key: const ValueKey('exam-voted-status'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

void _openSubjectChat(BuildContext context, _StudySubject item) {
  if (!item.canOpenChat || item.teamId.isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => TeamDetailsScreen(
        initialTabIndex: 1,
        team: Team(
          id: item.teamId,
          name: item.name,
          teacher: '',
          groupCode: '',
          icon: _controlBadge(item.controlType),
        ),
      ),
    ),
  );
}

Future<void> _showSubjectDetailsSheet(
    BuildContext context, _StudySubject item) {
  return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxWidth: 600),
      builder: (context) => SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .82),
            child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _ControlBadge(type: item.controlType),
                            SizedBox(width: 12),
                            Expanded(
                                child: Text(item.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium)),
                            IconButton(
                                tooltip: 'Закрыть',
                                onPressed: () => Navigator.pop(context),
                                icon: Icon(Icons.close_rounded)),
                          ]),
                      SizedBox(height: 16),
                      _DetailsGrid(item: item),
                    ])),
          )));
}

class _ControlBadge extends StatelessWidget {
  final String type;

  const _ControlBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final color = _controlColor(type, context);

    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .13),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: .38)),
      ),
      child: Text(
        _controlBadge(type),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: .2,
        ),
      ),
    );
  }
}

class _DetailsGrid extends StatelessWidget {
  final _StudySubject item;

  const _DetailsGrid({required this.item});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DetailsSection(
          title: 'О предмете',
          lines: [
            item.shortDescription,
            item.localDescription,
          ],
        ),
        _DetailsSection(
          title: 'Как сдавать',
          lines: [
            item.howToPass,
            item.assessmentNote,
          ],
        ),
        _DetailsSection(
          title: 'Советы студентов',
          lines: [
            item.semesterTips,
            item.commonPitfalls,
          ],
        ),
        _StatsSection(item: item),
        _ServiceInfoSection(item: item),
      ],
    );
  }
}

class _DetailsSection extends StatelessWidget {
  final String title;
  final List<String> lines;
  final List<(String, String)> rows;

  const _DetailsSection({
    required this.title,
    this.lines = const [],
    this.rows = const [],
  });

  @override
  Widget build(BuildContext context) {
    final visibleLines = lines.where((line) => line.trim().isNotEmpty).toList();
    if (visibleLines.isEmpty && rows.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            SizedBox(height: 6),
          ],
          for (final line in visibleLines)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                line,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                      height: 1.3,
                    ),
              ),
            ),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: RichText(
                text: TextSpan(
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface),
                  children: [
                    TextSpan(
                      text: '${row.$1}: ',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(text: row.$2),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsSection extends StatelessWidget {
  final _StudySubject item;

  const _StatsSection({required this.item});

  @override
  Widget build(BuildContext context) {
    return _DetailsSection(
      title: 'Статистика',
      rows: [
        ('Сложность', item.difficultyLabel),
      ],
    );
  }
}

class _ServiceInfoSection extends StatelessWidget {
  final _StudySubject item;

  const _ServiceInfoSection({required this.item});

  @override
  Widget build(BuildContext context) {
    final rows = [
      if (item.controlForm.isNotEmpty) ('Форма контроля', item.controlForm),
      if (item.credits > 0) ('З.е.', _formatNumber(item.credits)),
      if (item.hoursTotal > 0) ('Часы', '${item.hoursTotal}'),
      if (item.subjectIndex.isNotEmpty) ('Индекс', item.subjectIndex),
      if (item.blockName.isNotEmpty) ('Блок', item.blockName),
      if (item.department.isNotEmpty) ('Кафедра', item.department),
    ];

    if (rows.isEmpty) return const SizedBox.shrink();

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text(
        'Служебная информация',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        'скрыта, если понадобится',
        style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      children: [
        _DetailsSection(
          title: '',
          rows: rows,
        ),
      ],
    );
  }
}

class _DifficultyLine extends StatelessWidget {
  final _StudySubject item;

  const _DifficultyLine({required this.item});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.local_fire_department_rounded,
            size: 17, color: Colors.deepOrange),
        SizedBox(width: 5),
        Flexible(
          child: Text(
            'Сложность: ${item.difficultyLabel}',
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ),
      ],
    );
  }
}

Future<void> _showVoteSheet(
  BuildContext context,
  _StudySubject item,
  Future<void> Function() onChanged,
) async {
  var difficulty = item.userVote?.difficultyRating ?? 3;
  var isSaving = false;
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> submit() async {
            if (isSaving) return;
            setSheetState(() => isSaving = true);
            try {
              await _StudyPlanRepository().vote(
                item: item,
                difficultyRating: difficulty,
              );
              navigator.pop();
              await onChanged();
              messenger.showSnackBar(
                SnackBar(content: Text('Оценка сохранена')),
              );
            } on Object catch (error) {
              debugPrint('[voteSubjectDifficulty] $error');
              messenger.showSnackBar(
                SnackBar(content: Text(_voteErrorText(error))),
              );
            } finally {
              if (context.mounted) {
                setSheetState(() => isSaving = false);
              }
            }
          }

          return ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .82),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  18,
                  18,
                  MediaQuery.of(context).viewInsets.bottom + 18,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Оценить сложность',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        item.name,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      SizedBox(height: 16),
                      _RatingCircles(
                        value: difficulty,
                        onChanged: (value) =>
                            setSheetState(() => difficulty = value),
                      ),
                      SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: isSaving ? null : submit,
                          icon: isSaving
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      ProductLoadingIndicator(),
                                )
                              : Icon(Icons.check_rounded),
                          label: Text(
                              isSaving ? 'Сохраняю...' : 'Сохранить оценку'),
                        ),
                      ),
                    ],
                  ),
                ),
              ));
        },
      );
    },
  );
}

class _RatingCircles extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _RatingCircles({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(
                'Сложность',
                style: TextStyle(fontWeight: FontWeight.w800),
              )),
              Text(
                '$value / 5',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var rating = 1; rating <= 5; rating++)
                _RatingCircle(
                  rating: rating,
                  selected: rating == value,
                  color: color,
                  onTap: () => onChanged(rating),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RatingCircle extends StatelessWidget {
  final int rating;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _RatingCircle(
      {required this.rating,
      required this.selected,
      required this.color,
      required this.onTap});
  @override
  Widget build(BuildContext context) => Semantics(
      button: true,
      selected: selected,
      label: 'Оценка $rating из 5',
      child: Material(
          color: selected ? color : color.withValues(alpha: .08),
          shape: CircleBorder(
              side: BorderSide(
                  color: selected ? color : color.withValues(alpha: .24),
                  width: selected ? 2 : 1)),
          child: InkWell(
              onTap: onTap,
              customBorder: CircleBorder(),
              child: SizedBox.square(
                  dimension: 48,
                  child: Center(
                      child: ExcludeSemantics(
                          child: Text('$rating',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: selected
                                          ? Theme.of(context)
                                              .colorScheme
                                              .onPrimary
                                          : color))))))));
}

String _voteErrorText(Object error) {
  final message = error.toString();
  if (message.contains('not_authenticated')) {
    return 'Нужно заново войти в аккаунт';
  }
  if (message.contains('subject_offering_is_future')) {
    return 'Предмет ещё не начался';
  }
  if (message.contains('student_not_enrolled_for_offering_group')) {
    return 'Вы не учились в этой группе';
  }
  if (message.contains('subject_offering_not_found')) {
    return 'Предмет не найден';
  }
  if (message.contains('rating_out_of_range')) {
    return 'Оценка должна быть от 1 до 5';
  }
  if (message.contains('subject_already_voted')) {
    return 'Вы уже оценили этот предмет';
  }
  return 'Не удалось сохранить оценку';
}

class _EmptyPlanCard extends StatelessWidget {
  const _EmptyPlanCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Text(
        'Данные учебного плана пока не загружены для текущего семестра.',
        textAlign: TextAlign.center,
      ),
    );
  }
}

enum _PlanExportScope {
  semester,
  studyPlan,
}

Future<void> _showExportSheet(BuildContext context, _StudyPlanState state) {
  return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxWidth: 600),
      builder: (sheetContext) => SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * .82),
            child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                                child: Text('Экспортировать информацию',
                                    style: Theme.of(sheetContext)
                                        .textTheme
                                        .titleLarge)),
                            IconButton(
                                tooltip: 'Закрыть',
                                onPressed: () => Navigator.pop(sheetContext),
                                icon: Icon(Icons.close_rounded)),
                          ]),
                      SizedBox(height: 8),
                      Text(
                          'Можно скачать весь учебный план или отдельный семестр.',
                          style: Theme.of(sheetContext).textTheme.bodyMedium),
                      SizedBox(height: 20),
                      _ExportPrimaryButton(
                          title: 'Учебный план',
                          subtitle:
                              'Все семестры, дисциплины, формы контроля и часы',
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _exportStudyPlanPdf(
                                context, state, _PlanExportScope.studyPlan);
                          }),
                      SizedBox(height: 24),
                      Text('Отдельный семестр',
                          style: Theme.of(sheetContext).textTheme.titleMedium),
                      SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final semester in state.semesters)
                          _ExportPillButton(
                              label: '$semester семестр',
                              onTap: () {
                                Navigator.pop(sheetContext);
                                _exportStudyPlanPdf(
                                    context, state, _PlanExportScope.semester,
                                    semester: semester);
                              }),
                      ]),
                    ])),
          )));
}

Future<void> _exportStudyPlanPdf(
    BuildContext context, _StudyPlanState state, _PlanExportScope scope,
    {int? semester}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(content: Text('Собираю PDF-файл...')),
  );

  try {
    final bytes = await _buildStudyPlanPdf(state, scope, semester: semester);
    final exportDir = await _createExportDirectory();

    final now = DateTime.now();
    final filename =
        '${_exportFilePrefix(scope, semester: semester)}_${DateFormat('yyyyMMdd_HHmm').format(now)}.pdf';
    final file = File('${exportDir.path}${Platform.pathSeparator}$filename');
    await file.writeAsBytes(bytes, flush: true);

    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('PDF сохранён: $filename')),
    );
    await OpenFilex.open(file.path);
  } on Object catch (error) {
    debugPrint('[exportStudyPlanPdf] $error');
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Не удалось экспортировать PDF')),
    );
  }
}

Future<List<int>> _buildStudyPlanPdf(
    _StudyPlanState state, _PlanExportScope scope,
    {int? semester}) async {
  final font = await _loadPdfFont();
  final now = DateTime.now();
  final primary = PdfColor.fromInt(0xFF7057C7);
  final softPrimary = PdfColor.fromInt(0xFFF1ECFF);
  final text = PdfColor.fromInt(0xFF1F1F2D);
  final muted = PdfColor.fromInt(0xFF6C6C7A);
  final pdf = pw.Document(
    theme: pw.ThemeData.withFont(base: font, bold: font),
  );

  pdf.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(
        margin: const pw.EdgeInsets.all(28),
        theme: pw.ThemeData.withFont(base: font, bold: font),
      ),
      build: (context) {
        final children = <pw.Widget>[
          _pdfHeroHeader(
            title: _exportTitle(scope, semester: semester),
            subtitle:
                'Сформировано ${_formatPdfDateTime(now)} · ${state.currentSemester} семестр',
            primary: primary,
          ),
          pw.SizedBox(height: 16),
          pw.Row(
            children: [
              pw.Expanded(
                child: _pdfSummaryCard(
                  label: 'Текущий семестр',
                  value: '${state.currentSemester}',
                  primary: primary,
                  softPrimary: softPrimary,
                  text: text,
                ),
              ),
              pw.SizedBox(width: 10),
              pw.Expanded(
                child: _pdfSummaryCard(
                  label: 'Дисциплин',
                  value: '${state.items.length}',
                  primary: primary,
                  softPrimary: softPrimary,
                  text: text,
                ),
              ),
              pw.SizedBox(width: 10),
              pw.Expanded(
                child: _pdfSummaryCard(
                  label: 'Семестров',
                  value: '${state.semesters.length}',
                  primary: primary,
                  softPrimary: softPrimary,
                  text: text,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 18),
        ];

        if (scope == _PlanExportScope.semester) {
          final selectedSemester = semester ?? state.currentSemester;
          children.addAll([
            _pdfSectionTitle('$selectedSemester семестр', text),
            ..._pdfSemesterBlocks(
              {
                selectedSemester: state.itemsForSemester(selectedSemester),
              },
              primary: primary,
              muted: muted,
              text: text,
              includeDetails: false,
            ),
            pw.SizedBox(height: 12),
          ]);
        }

        if (scope == _PlanExportScope.studyPlan) {
          children.addAll([
            _pdfSectionTitle('Учебный план', text),
            ..._pdfSemesterBlocks(
              _itemsBySemester(state.items),
              primary: primary,
              muted: muted,
              text: text,
              includeDetails: false,
            ),
          ]);
        }

        return children;
      },
    ),
  );

  return pdf.save();
}

Future<Directory> _createExportDirectory() async {
  final candidates = <Directory?>[
    await getDownloadsDirectory(),
    await getApplicationSupportDirectory(),
    await getTemporaryDirectory(),
  ];

  for (final base in candidates.whereType<Directory>()) {
    try {
      if (!await base.exists()) continue;
      final exportDir = Directory(
        '${base.path}${Platform.pathSeparator}student_platform_exports',
      );
      await exportDir.create(recursive: true);
      return exportDir;
    } on Object catch (error) {
      debugPrint('[createExportDirectory] $error');
    }
  }

  final fallback = await getTemporaryDirectory();
  final exportDir = Directory(
    '${fallback.path}${Platform.pathSeparator}student_platform_exports',
  );
  await exportDir.create(recursive: true);
  return exportDir;
}

Future<pw.Font> _loadPdfFont() async {
  final candidates = [
    if (Platform.isWindows) r'C:\Windows\Fonts\arial.ttf',
    if (Platform.isWindows) r'C:\Windows\Fonts\segoeui.ttf',
  ];

  for (final path in candidates) {
    final file = File(path);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      return pw.Font.ttf(ByteData.sublistView(Uint8List.fromList(bytes)));
    }
  }

  final fallbackBytes =
      await File('assets/fonts/Lato-Regular.ttf').readAsBytes();
  return pw.Font.ttf(ByteData.sublistView(Uint8List.fromList(fallbackBytes)));
}

pw.Widget _pdfHeroHeader({
  required String title,
  required String subtitle,
  required PdfColor primary,
}) {
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.all(18),
    decoration: pw.BoxDecoration(
      color: primary,
      borderRadius: pw.BorderRadius.circular(18),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Student Platform',
          style: pw.TextStyle(
            color: PdfColors.white,
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 8),
        pw.Text(
          title,
          style: pw.TextStyle(
            color: PdfColors.white,
            fontSize: 24,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          subtitle,
          style: const pw.TextStyle(color: PdfColors.white, fontSize: 11),
        ),
      ],
    ),
  );
}

pw.Widget _pdfSummaryCard({
  required String label,
  required String value,
  required PdfColor primary,
  required PdfColor softPrimary,
  required PdfColor text,
}) {
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: softPrimary,
      borderRadius: pw.BorderRadius.circular(14),
      border: pw.Border.all(color: primary, width: .5),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label, style: const pw.TextStyle(fontSize: 10)),
        pw.SizedBox(height: 3),
        pw.Text(
          value,
          style: pw.TextStyle(
            color: text,
            fontSize: 20,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      ],
    ),
  );
}

pw.Widget _pdfSectionTitle(String title, PdfColor text) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Text(
      title,
      style: pw.TextStyle(
        color: text,
        fontSize: 18,
        fontWeight: pw.FontWeight.bold,
      ),
    ),
  );
}

List<pw.Widget> _pdfSemesterBlocks(
  Map<int, List<_StudySubject>> groupedItems, {
  required PdfColor primary,
  required PdfColor muted,
  required PdfColor text,
  required bool includeDetails,
}) {
  return [
    for (final entry in groupedItems.entries) ...[
      pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(bottom: 8),
        padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColor.fromInt(0xFFE4E0F1)),
          borderRadius: pw.BorderRadius.circular(14),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              children: [
                pw.Container(
                  width: 26,
                  height: 26,
                  alignment: pw.Alignment.center,
                  decoration: pw.BoxDecoration(
                    color: primary,
                    borderRadius: pw.BorderRadius.circular(9),
                  ),
                  child: pw.Text(
                    '${entry.key}',
                    style: pw.TextStyle(
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.SizedBox(width: 8),
                pw.Text(
                  '${entry.key} семестр',
                  style: pw.TextStyle(
                    color: text,
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Spacer(),
                pw.Text(
                  '${entry.value.length} ${_disciplineWord(entry.value.length)}',
                  style: pw.TextStyle(color: muted, fontSize: 10),
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            if (entry.value.isEmpty)
              pw.Text(
                'Дисциплины пока не загружены.',
                style: pw.TextStyle(color: muted, fontSize: 10),
              )
            else
              for (final item in entry.value)
                _pdfSubjectRow(
                  item,
                  muted: muted,
                  text: text,
                  includeDetails: includeDetails,
                ),
          ],
        ),
      ),
    ],
  ];
}

pw.Widget _pdfSubjectRow(
  _StudySubject item, {
  required PdfColor muted,
  required PdfColor text,
  required bool includeDetails,
}) {
  final meta = [
    if (item.controlForm.isNotEmpty) item.controlForm,
    if (item.credits > 0) '${_formatNumber(item.credits)} з.е.',
    if (item.hoursTotal > 0) '${item.hoursTotal} ч.',
    if (item.department.isNotEmpty) item.department,
  ].join(' · ');
  final details = [
    item.shortDescription,
    item.howToPass,
    item.semesterTips,
    item.assessmentNote,
  ].where((line) => line.trim().isNotEmpty).take(3).toList();

  return pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 6),
    padding: const pw.EdgeInsets.only(left: 8),
    decoration: pw.BoxDecoration(
      border: pw.Border(left: pw.BorderSide(color: muted, width: .8)),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          item.name,
          style: pw.TextStyle(
            color: text,
            fontSize: 11,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        if (meta.isNotEmpty) ...[
          pw.SizedBox(height: 2),
          pw.Text(meta, style: pw.TextStyle(color: muted, fontSize: 9)),
        ],
        if (includeDetails && details.isNotEmpty) ...[
          pw.SizedBox(height: 3),
          for (final detail in details)
            pw.Text(
              detail,
              style: pw.TextStyle(color: text, fontSize: 9, lineSpacing: 2),
            ),
        ],
      ],
    ),
  );
}

Map<int, List<_StudySubject>> _itemsBySemester(List<_StudySubject> items) {
  final grouped = <int, List<_StudySubject>>{};
  for (final item in items) {
    grouped.putIfAbsent(item.semesterNumber, () => []).add(item);
  }
  return Map<int, List<_StudySubject>>.fromEntries(
    grouped.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

class _StudyPlanRepository {
  final SupabaseClient _sb = Supabase.instance.client;

  Future<_StudyPlanState> load() async {
    try {
      final userId = _sb.auth.currentUser?.id;
      if (userId == null) return _StudyPlanState.demo();

      final enrollment = await _sb
          .from('student_enrollments')
          .select('group_id')
          .eq('user_id', userId)
          .eq('status', 'active')
          .filter('ended_at', 'is', null)
          .maybeSingle();
      final groupId = (enrollment?['group_id'] ?? '').toString();
      if (groupId.isEmpty) return _StudyPlanState.demo();

      final currentSemester = await _loadCurrentSemester(groupId);
      final nominalSemesters = await _loadNominalSemesters(groupId);
      final items = await _loadSubjects(groupId);
      if (items.isEmpty) return _StudyPlanState.demo();

      return _StudyPlanState(
        currentSemester: currentSemester,
        nominalSemesters: nominalSemesters,
        items: items,
      );
    } catch (_) {
      return _StudyPlanState.demo();
    }
  }

  Future<int> _loadCurrentSemester(String groupId) async {
    final rows = await _sb
        .from('group_term_semesters')
        .select('semester_number')
        .eq('group_id', groupId)
        .order('semester_number', ascending: false)
        .limit(1);
    if (rows.isNotEmpty) {
      return _asInt(rows.first['semester_number'], fallback: 4);
    }
    return 4;
  }

  Future<int> _loadNominalSemesters(String groupId) async {
    final row = await _sb
        .from('group_academic_profiles')
        .select('nominal_semesters')
        .eq('group_id', groupId)
        .maybeSingle();
    return _asInt(row?['nominal_semesters'], fallback: 4);
  }

  Future<List<_StudySubject>> _loadSubjects(String groupId) async {
    try {
      final res = await _sb.rpc('rpc_get_my_subjects_v2');
      final rows = (res as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      if (rows.isNotEmpty) {
        return rows.map(_StudySubject.fromRpcMap).toList();
      }
    } catch (_) {
      // The v2 RPC appears only after the Supabase migration is applied.
    }

    return _loadSubjectsFallback(groupId);
  }

  Future<List<_StudySubject>> _loadSubjectsFallback(String groupId) async {
    final rows = await _sb
        .from('subject_offerings')
        .select('''
          id,
          subject_id,
          group_id,
          display_name,
          semester_number,
          curriculum_subjects(
            display_name,
            raw_subject_name,
            control_form,
            department,
            hours_total,
            credits,
            subject_index,
            block_name
          ),
          subject_catalog(canonical_name)
        ''')
        .eq('group_id', groupId)
        .order('semester_number', ascending: true)
        .order('display_name', ascending: true);

    return rows
        .map((row) =>
            _StudySubject.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  Future<void> vote({
    required _StudySubject item,
    required int difficultyRating,
  }) async {
    await _sb.rpc(
      'rpc_vote_subject_difficulty_v2',
      params: {
        'p_subject_offering_id': item.id,
        'p_difficulty_rating': difficultyRating,
        'p_workload_rating': null,
        'p_usefulness_rating': null,
        'p_exam_stress_rating': null,
        'p_comment': null,
        'p_is_anonymous': true,
      },
    );
  }
}

class _StudyPlanState {
  final int currentSemester;
  final int nominalSemesters;
  final List<_StudySubject> items;
  final bool isDemo;

  const _StudyPlanState({
    required this.currentSemester,
    required this.nominalSemesters,
    required this.items,
    this.isDemo = false,
  });

  factory _StudyPlanState.demo() {
    return const _StudyPlanState(
      currentSemester: 4,
      nominalSemesters: 4,
      isDemo: true,
      items: [
        _StudySubject(
          id: 'demo-1',
          name: 'Подготовка к защите и защита ВКР',
          semesterNumber: 4,
          controlForm: 'ГИА',
          department: 'Водопользования и экологии',
          credits: 6,
          hoursTotal: 216,
          subjectIndex: 'Б3.01',
          blockName: 'Государственная итоговая аттестация',
        ),
        _StudySubject(
          id: 'demo-2',
          name: 'Проектная практика. Часть 2',
          semesterNumber: 4,
          controlForm: 'зачет с оц.',
          department: 'Водопользования и экологии',
          credits: 3,
          hoursTotal: 108,
          subjectIndex: 'Б2.02',
          blockName: 'Практика',
        ),
        _StudySubject(
          id: 'demo-3',
          name: 'Строительные материалы',
          semesterNumber: 3,
          controlForm: 'зачет',
          department: 'Кафедра строительных материалов',
          credits: 3,
          hoursTotal: 108,
        ),
        _StudySubject(
          id: 'demo-4',
          name: 'Гидравлика',
          semesterNumber: 3,
          controlForm: 'экзамен',
          department: 'Кафедра гидравлики',
          credits: 4,
          hoursTotal: 144,
        ),
      ],
    );
  }

  List<int> get semesters {
    final fromItems =
        items.map((e) => e.semesterNumber).where((e) => e > 0).toSet();
    final all = {
      for (var i = 1; i <= nominalSemesters; i++) i,
      ...fromItems,
      currentSemester,
    }.toList()
      ..sort();
    return all;
  }

  List<_StudySubject> itemsForSemester(int semester) {
    return items.where((item) => item.semesterNumber == semester).toList();
  }
}

class _StudySubject {
  final String id;
  final String subjectId;
  final String groupId;
  final String name;
  final int semesterNumber;
  final String visibilityStatus;
  final String controlForm;
  final String department;
  final String shortDescription;
  final String localDescription;
  final double avgDifficultyGlobal;
  final double avgDifficultyLocal;
  final _SubjectVote? userVote;
  final String teamId;
  final bool canVote;
  final bool canOpenChat;
  final String cannotVoteReason;
  final double credits;
  final int hoursTotal;
  final String subjectIndex;
  final String blockName;
  final String howToPass;
  final String commonPitfalls;
  final String semesterTips;
  final String assessmentNote;

  const _StudySubject({
    required this.id,
    this.subjectId = '',
    this.groupId = '',
    required this.name,
    required this.semesterNumber,
    this.visibilityStatus = 'current',
    required this.controlForm,
    required this.department,
    this.shortDescription = '',
    this.localDescription = '',
    this.avgDifficultyGlobal = 0,
    this.avgDifficultyLocal = 0,
    this.userVote,
    this.teamId = '',
    this.canVote = true,
    this.canOpenChat = false,
    this.cannotVoteReason = '',
    required this.credits,
    required this.hoursTotal,
    this.subjectIndex = '',
    this.blockName = '',
    this.howToPass = '',
    this.commonPitfalls = '',
    this.semesterTips = '',
    this.assessmentNote = '',
  });

  String get controlType => normalizeControlType(controlForm);

  String get visibilityLabel => switch (visibilityStatus) {
        'archived' => 'прошлый семестр',
        'future' => 'будущий семестр',
        _ => 'текущий',
      };

  String get difficultyLabel {
    final value =
        avgDifficultyGlobal > 0 ? avgDifficultyGlobal : avgDifficultyLocal;
    return _difficultyLabel(value);
  }

  factory _StudySubject.fromMap(Map<String, dynamic> row) {
    final curriculum = _asMap(row['curriculum_subjects']);
    final catalog = _asMap(row['subject_catalog']);
    final controlForm = (curriculum['control_form'] ?? '').toString().trim();
    final displayName = _resolveSubjectTitle(
      candidates: [
        curriculum['display_name'],
        curriculum['raw_subject_name'],
        row['display_name'],
        catalog['canonical_name'],
      ],
      controlForm: controlForm,
    );

    return _StudySubject(
      id: (row['id'] ?? '').toString(),
      subjectId: (row['subject_id'] ?? '').toString(),
      groupId: (row['group_id'] ?? '').toString(),
      name: displayName,
      semesterNumber: _asInt(row['semester_number']),
      controlForm: controlForm,
      department: (curriculum['department'] ?? '').toString().trim(),
      credits: _asDouble(curriculum['credits']),
      hoursTotal: _asInt(curriculum['hours_total']),
      subjectIndex: (curriculum['subject_index'] ?? '').toString().trim(),
      blockName: (curriculum['block_name'] ?? '').toString().trim(),
    );
  }

  factory _StudySubject.fromRpcMap(Map<String, dynamic> row) {
    return _StudySubject(
      id: (row['subject_offering_id'] ?? '').toString(),
      subjectId: (row['subject_id'] ?? '').toString(),
      groupId: (row['group_id'] ?? '').toString(),
      name: (row['subject_title'] ?? 'Без названия').toString().trim(),
      semesterNumber: _asInt(row['semester_number']),
      visibilityStatus: (row['visibility_status'] ?? 'current').toString(),
      controlForm: (row['control_form'] ?? '').toString().trim(),
      department: (row['department'] ?? '').toString().trim(),
      shortDescription: (row['short_description'] ?? '').toString().trim(),
      localDescription: (row['local_description'] ?? '').toString().trim(),
      avgDifficultyGlobal: _asDouble(row['avg_difficulty_global']),
      avgDifficultyLocal: _asDouble(row['avg_difficulty_local']),
      userVote: _SubjectVote.fromValue(row['user_vote']),
      teamId: (row['team_id'] ?? '').toString(),
      canVote: row['can_vote'] == true,
      canOpenChat: row['can_open_chat'] == true,
      cannotVoteReason: (row['cannot_vote_reason'] ?? '').toString(),
      credits: _asDouble(row['credits']),
      hoursTotal: _asInt(row['hours_total']),
      subjectIndex: (row['subject_index'] ?? '').toString().trim(),
      blockName: (row['block_name'] ?? '').toString().trim(),
      howToPass: (row['how_to_pass'] ?? '').toString().trim(),
      commonPitfalls: (row['common_pitfalls'] ?? '').toString().trim(),
      semesterTips: (row['semester_tips'] ?? '').toString().trim(),
      assessmentNote: (row['assessment_note'] ?? '').toString().trim(),
    );
  }
}

class _SubjectVote {
  final int difficultyRating;

  const _SubjectVote({
    required this.difficultyRating,
  });

  static _SubjectVote? fromValue(dynamic value) {
    final map = _asMap(value);
    if (map.isEmpty) return null;
    return _SubjectVote(
      difficultyRating: _asInt(map['difficulty_rating']),
    );
  }
}

const List<String> _controlTypeOrder = [
  'gia',
  'exam',
  'graded_credit',
  'credit',
  'course_work',
  'course_project',
  'practice_report',
  'other',
];

String normalizeControlType(String value) {
  final v = value.toLowerCase().trim();

  if (v.contains('гиа') || v.contains('вкр') || v.contains('защита')) {
    return 'gia';
  }

  if (v.contains('экз')) {
    return 'exam';
  }

  if (v.contains('диф') || v.contains('с оц')) {
    return 'graded_credit';
  }

  if (v.contains('кр')) {
    return 'course_work';
  }

  if (v.contains('кп')) {
    return 'course_project';
  }

  if (v.contains('отчет') || v.contains('отчёт') || v.contains('практик')) {
    return 'practice_report';
  }

  if (v.contains('зач') || v.contains('контр')) {
    return 'credit';
  }

  return 'other';
}

String _controlBadge(String type) {
  return switch (type) {
    'exam' => 'ЭКЗ',
    'credit' => 'ЗАЧ',
    'graded_credit' => 'ЗО',
    'course_work' => 'КР',
    'course_project' => 'КП',
    'practice_report' => 'ПР',
    'gia' => 'ГИА',
    _ => 'КОНТР',
  };
}

String _controlGroupTitle(String type) {
  return switch (type) {
    'exam' => 'Экзамены',
    'credit' => 'Зачёты',
    'graded_credit' => 'Зачёты с оценкой',
    'course_work' => 'Курсовые работы',
    'course_project' => 'Курсовые проекты',
    'practice_report' => 'Практика',
    'gia' => 'ГИА',
    _ => 'Другие формы контроля',
  };
}

Color _controlColor(String type, BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (type) {
    'exam' => dark ? Colors.deepOrange.shade200 : Colors.deepOrange.shade800,
    'credit' => dark ? Colors.indigo.shade200 : Colors.indigo.shade700,
    'graded_credit' => dark ? Colors.purple.shade200 : Colors.purple.shade700,
    'course_work' => dark ? Colors.teal.shade200 : Colors.teal.shade800,
    'course_project' =>
      dark ? Colors.blueGrey.shade200 : Colors.blueGrey.shade700,
    'practice_report' => dark ? Colors.green.shade200 : Colors.green.shade800,
    'gia' => dark ? Colors.red.shade300 : Colors.red.shade700,
    _ => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

String _resolveSubjectTitle({
  required List<dynamic> candidates,
  required String controlForm,
}) {
  for (final candidate in candidates) {
    final title = (candidate ?? '').toString().trim();
    if (title.isEmpty) continue;
    if (_looksLikeControlTitle(title, controlForm)) continue;
    return title;
  }

  return 'Без названия';
}

bool _looksLikeControlTitle(String title, String controlForm) {
  final normalizedTitle = _normalizeText(title);
  final normalizedControl = _normalizeText(controlForm);
  if (normalizedTitle.isEmpty) return true;
  if (normalizedControl.isNotEmpty && normalizedTitle == normalizedControl) {
    return true;
  }

  const controlOnlyValues = {
    'зачет',
    'зачёт',
    'зачет с оц',
    'зачёт с оц',
    'дифференцированный зачет',
    'дифференцированный зачёт',
    'экзамен',
    'экз',
    'кр',
    'кп',
    'курсовая работа',
    'курсовой проект',
    'контрольная работа',
    'форма контроля',
  };

  return controlOnlyValues.contains(normalizedTitle);
}

String _normalizeText(String value) {
  return value
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[.,;:]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty && value.first is Map) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  return const {};
}

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double _asDouble(dynamic value) {
  if (value is int) return value.toDouble();
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.replaceAll(',', '.')) ?? 0;
  return 0;
}

String _formatNumber(num value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(1);
}

String _formatHeroTime(DateTime value) {
  final hours = value.hour.toString().padLeft(2, '0');
  final minutes = value.minute.toString().padLeft(2, '0');
  return '$hours:$minutes';
}

String _formatHeroDate(DateTime value) {
  const weekdays = [
    'понедельник',
    'вторник',
    'среда',
    'четверг',
    'пятница',
    'суббота',
    'воскресенье',
  ];
  const months = [
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

  return '${weekdays[value.weekday - 1]}, ${value.day} '
      '${months[value.month - 1]}';
}

String _formatPdfDateTime(DateTime value) {
  return '${_formatHeroDate(value)} ${_formatHeroTime(value)}';
}

String _exportTitle(_PlanExportScope scope, {int? semester}) {
  return switch (scope) {
    _PlanExportScope.semester => '${semester ?? ''} семестр'.trim(),
    _PlanExportScope.studyPlan => 'Учебный план',
  };
}

String _exportFilePrefix(_PlanExportScope scope, {int? semester}) {
  return switch (scope) {
    _PlanExportScope.semester => 'semester_${semester ?? 'current'}',
    _PlanExportScope.studyPlan => 'study_plan',
  };
}

String _difficultyLabel(double value) {
  if (value <= 0) return 'нет оценок';
  return '${value.toStringAsFixed(1)} / 5';
}

String _disciplineWord(int count) {
  return _pluralRu(count, 'дисциплина', 'дисциплины', 'дисциплин');
}

String _pluralRu(int count, String one, String few, String many) {
  final mod100 = count.abs() % 100;
  final mod10 = count.abs() % 10;
  if (mod100 >= 11 && mod100 <= 14) return many;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}
