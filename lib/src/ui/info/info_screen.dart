import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth_session.dart';
import '../../data/academic_context_service.dart';
import '../../services/auth_service.dart';
import 'subject_info_screen.dart';

enum _UsefulFilter { all, exams, credits, practices, courseWorks }

enum _UsefulSection { subjects, help, jobs }

BoxConstraints _fullWidthSheetConstraints(BuildContext context) {
  return BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width);
}

class InfoScreen extends StatefulWidget {
  const InfoScreen({super.key});

  @override
  State<InfoScreen> createState() => _InfoScreenState();
}

class _InfoScreenState extends State<InfoScreen> {
  late Future<_UsefulPlanState> _future = _load();
  int? _selectedSemester;
  _UsefulFilter _filter = _UsefulFilter.all;
  _UsefulSection _section = _UsefulSection.subjects;
  bool _filtersExpanded = false;
  bool _controlGroupsTouched = false;
  final Set<String> _collapsedControlGroups = {};

  Future<_UsefulPlanState> _load() async {
    final contextData = await AcademicContextService().load();
    final groupId = contextData.groupId;

    if (groupId == null) {
      return _UsefulPlanState(
        contextData: contextData,
        subjects: const [],
        warning: contextData.loadWarning ?? 'Учебный контекст не найден',
      );
    }

    final subjects = await _UsefulSubjectsRepository().load(groupId: groupId);

    return _UsefulPlanState(
      contextData: contextData,
      subjects: subjects,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7FB),
      body: FutureBuilder<_UsefulPlanState>(
        future: _future,
        builder: (context, snapshot) {
          final state = snapshot.data;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 128,
                child: _UsefulHeader(
                  selectedSection: _section,
                  onSectionTap: () => _showSectionSheet(context),
                  onInfoTap: () => _showInfoSheet(context),
                ),
              ),
              Expanded(
                child: _buildBody(snapshot, state),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(
    AsyncSnapshot<_UsefulPlanState> snapshot,
    _UsefulPlanState? state,
  ) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_section == _UsefulSection.help) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: const [_HelpSection()],
      );
    }

    if (_section == _UsefulSection.jobs) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: const [_JobsSection()],
      );
    }

    if (state == null) {
      return const _EmptyState(text: 'Не удалось загрузить предметы');
    }

    if (state.warning != null) {
      final sessionExpired =
          state.warning == AuthSession.sessionExpiredMessage ||
              AuthSession.isAuthFailure(state.warning!);
      return _EmptyState(
        text:
            sessionExpired ? AuthSession.sessionExpiredMessage : state.warning!,
        actionLabel: sessionExpired ? 'Войти снова' : null,
        onAction: sessionExpired ? () => AuthService.signOut(context) : null,
      );
    }

    final semesters = state.semesters;
    final currentSemester = state.contextData.currentSemesterNumber;
    final selectedSemester = semesters.isEmpty
        ? null
        : _selectedSemester ??
            (semesters.contains(currentSemester)
                ? currentSemester
                : semesters.last);
    final semesterSubjects = state.subjects
        .where((item) => item.semesterNumber == selectedSemester)
        .toList();
    final visibleSubjects = semesterSubjects
        .where((item) => _matchesFilter(item, _filter))
        .toList();
    final controlGroupLabels =
        _groupSubjectsByControl(visibleSubjects).keys.toList();
    final effectiveCollapsedControlGroups = _controlGroupsTouched
        ? _collapsedControlGroups
        : controlGroupLabels.skip(1).toSet();

    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _future = _load());
        await _future;
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (state.subjects.isEmpty)
            const _EmptyState(
              text: 'Предметы учебного плана пока не найдены',
              compact: true,
            )
          else ...[
            _AcademicContextStrip(
              contextData: state.contextData,
              selectedSemester: selectedSemester,
              currentSemester: currentSemester,
            ),
            const SizedBox(height: 10),
            _SubjectControlsCard(
              semesters: semesters,
              currentSemester: currentSemester,
              selectedSemester: selectedSemester,
              selectedFilter: _filter,
              expanded: _filtersExpanded,
              onToggleExpanded: () {
                setState(() => _filtersExpanded = !_filtersExpanded);
              },
              onSemesterSelected: (value) {
                setState(() {
                  _selectedSemester = value;
                  _filter = _UsefulFilter.all;
                  _controlGroupsTouched = false;
                  _collapsedControlGroups.clear();
                });
              },
              onFilterSelected: (value) {
                setState(() {
                  _filter = value;
                  _controlGroupsTouched = false;
                  _collapsedControlGroups.clear();
                });
              },
            ),
            const SizedBox(height: 12),
            if (visibleSubjects.isEmpty)
              const _EmptyState(
                text: 'В этом фильтре предметы не найдены',
                compact: true,
              )
            else
              _SemesterSubjectsSection(
                semester: selectedSemester,
                currentSemester: currentSemester,
                subjects: visibleSubjects,
                collapsedGroups: effectiveCollapsedControlGroups,
                onGroupTap: (label) {
                  setState(() {
                    if (!_controlGroupsTouched) {
                      _controlGroupsTouched = true;
                      _collapsedControlGroups
                        ..clear()
                        ..addAll(effectiveCollapsedControlGroups);
                    }
                    if (!_collapsedControlGroups.add(label)) {
                      _collapsedControlGroups.remove(label);
                    }
                  });
                },
              ),
          ],
        ],
      ),
    );
  }

  bool _matchesFilter(_UsefulSubject item, _UsefulFilter filter) {
    final text = item.controlForm.toLowerCase();
    switch (filter) {
      case _UsefulFilter.all:
        return true;
      case _UsefulFilter.exams:
        return text.contains('экзам');
      case _UsefulFilter.credits:
        return text.contains('зач');
      case _UsefulFilter.practices:
        return text.contains('практ');
      case _UsefulFilter.courseWorks:
        return text.contains('курс') || text.contains('кр');
    }
  }

  Future<void> _showSectionSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<_UsefulSection>(
      context: context,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Раздел',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 10),
                _SectionChoiceTile(
                  icon: Icons.school_outlined,
                  title: 'Предметы',
                  subtitle: 'Учебный план',
                  selected: _section == _UsefulSection.subjects,
                  onTap: () {
                    Navigator.of(sheetContext).pop(_UsefulSection.subjects);
                  },
                ),
                _SectionChoiceTile(
                  icon: Icons.help_outline_rounded,
                  title: 'Справочный раздел',
                  subtitle: 'Инструкции, документы и ответы на учебные вопросы',
                  selected: _section == _UsefulSection.help,
                  onTap: () {
                    Navigator.of(sheetContext).pop(_UsefulSection.help);
                  },
                ),
                _SectionChoiceTile(
                  icon: Icons.work_outline_rounded,
                  title: 'Вакансии',
                  subtitle: 'Работа и стажировки',
                  selected: _section == _UsefulSection.jobs,
                  onTap: () {
                    Navigator.of(sheetContext).pop(_UsefulSection.jobs);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || selected == null || selected == _section) return;
    setState(() => _section = selected);
  }

  void _showInfoSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _InfoSheetHeader(),
                SizedBox(height: 14),
                _InfoSheetPoint(
                  icon: Icons.school_outlined,
                  title: 'Предметы',
                  text:
                      'Здесь собраны дисциплины по семестрам. Внутри предмета будут файлы, материалы и учебная информация.',
                ),
                _InfoSheetPoint(
                  icon: Icons.help_outline_rounded,
                  title: 'Справочный раздел',
                  text:
                      'Короткие инструкции по документам, доступам, аудиториям и частым учебным вопросам.',
                ),
                _InfoSheetPoint(
                  icon: Icons.work_outline_rounded,
                  title: 'Вакансии',
                  text:
                      'Место для стажировок, подработок и проектных задач, которые могут быть полезны студентам.',
                ),
                _InfoSheetPoint(
                  icon: Icons.swap_horiz_rounded,
                  title: 'Как переключаться',
                  text:
                      'Нажми круглую кнопку с иконкой раздела вверху экрана и выбери нужный блок.',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _filterLabel(_UsefulFilter filter) {
  switch (filter) {
    case _UsefulFilter.all:
      return 'Все';
    case _UsefulFilter.exams:
      return 'Экзамены';
    case _UsefulFilter.credits:
      return 'Зачёты';
    case _UsefulFilter.practices:
      return 'Практики';
    case _UsefulFilter.courseWorks:
      return 'Курсовые / КР';
  }
}

String _controlGroupLabel(String controlForm) {
  final text = controlForm.toLowerCase();
  if (text.contains('экзам')) return 'Экзамены';
  if (text.contains('зач') && text.contains('оцен')) return 'Зачёты с оценкой';
  if (text.contains('зач')) return 'Зачёты';
  if (text.contains('практ')) return 'Практики';
  if (text.contains('курс') || text.contains('кр')) return 'Курсовые / КР';
  return 'Другие формы контроля';
}

int _controlGroupOrder(String label) {
  const order = [
    'Экзамены',
    'Зачёты',
    'Зачёты с оценкой',
    'Практики',
    'Курсовые / КР',
    'Другие формы контроля',
  ];
  final index = order.indexOf(label);
  return index == -1 ? order.length : index;
}

Color _controlAccent(String label) {
  final text = label.toLowerCase();
  if (text.contains('экзам')) return const Color(0xFFE16B5C);
  if (text.contains('зач')) return const Color(0xFF2F80ED);
  if (text.contains('практ')) return const Color(0xFF2EAD6B);
  if (text.contains('курс') || text.contains('кр'))
    return const Color(0xFFF2994A);
  return const Color(0xFF5667B0);
}

Map<String, List<_UsefulSubject>> _groupSubjectsByControl(
  List<_UsefulSubject> subjects,
) {
  final grouped = <String, List<_UsefulSubject>>{};
  for (final subject in subjects) {
    final label = _controlGroupLabel(subject.controlForm);
    grouped.putIfAbsent(label, () => []).add(subject);
  }

  for (final value in grouped.values) {
    value.sort((a, b) => a.title.compareTo(b.title));
  }

  final entries = grouped.entries.toList()
    ..sort((a, b) =>
        _controlGroupOrder(a.key).compareTo(_controlGroupOrder(b.key)));
  return Map.fromEntries(entries);
}

String _pluralRu(int count, String one, String few, String many) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return few;
  }
  return many;
}

class _UsefulSubjectsRepository {
  _UsefulSubjectsRepository({SupabaseClient? client})
      : _sb = client ?? Supabase.instance.client;

  final SupabaseClient _sb;

  Future<List<_UsefulSubject>> load({required String groupId}) async {
    final rows = await _sb
        .from('subject_offerings')
        .select(
          'id,display_name,subject_id,group_id,curriculum_subject_id,semester_number,status',
        )
        .eq('group_id', groupId)
        .order('semester_number')
        .order('display_name');

    final result = <_UsefulSubject>[];

    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw as Map);
      final subjectId = _stringOrNull(row['subject_id']);
      final curriculumSubjectId = _stringOrNull(row['curriculum_subject_id']);
      final subjectOfferingId = _firstNonEmpty([row['id']]);

      Map<String, dynamic>? subject;
      if (subjectId != null) {
        subject = _asMap(await _sb
            .from('subject_catalog')
            .select('canonical_name,description')
            .eq('id', subjectId)
            .maybeSingle());
      }

      Map<String, dynamic>? curriculum;
      if (curriculumSubjectId != null) {
        curriculum = _asMap(await _sb
            .from('curriculum_subjects')
            .select('display_name,control_form')
            .eq('id', curriculumSubjectId)
            .maybeSingle());
      }

      final team = _asMap(await _sb
          .from('teams')
          .select('id,name,teacher,icon,group_name')
          .eq('subject_offering_id', subjectOfferingId)
          .limit(1)
          .maybeSingle());

      Map<String, dynamic>? chat;
      final teamId = _stringOrNull(team?['id']);
      if (teamId != null) {
        chat = _asMap(await _sb
            .from('chats')
            .select('id,type')
            .eq('team_id', teamId)
            .eq('type', 'team_main')
            .limit(1)
            .maybeSingle());
      }

      result.add(
        _UsefulSubject(
          id: subjectOfferingId,
          title: _firstNonEmpty([
            row['display_name'],
            subject?['canonical_name'],
            curriculum?['display_name'],
          ]),
          subjectId: subjectId,
          groupId: _stringOrNull(row['group_id']),
          semesterNumber: _asInt(row['semester_number']),
          controlForm: _firstNonEmpty([curriculum?['control_form']]),
          description: _firstNonEmpty([subject?['description']]),
          teacherName: _firstNonEmpty([team?['teacher']]),
          teamId: teamId,
          teamName: _firstNonEmpty([team?['name']]),
          teamIcon: _firstNonEmpty([team?['icon']]),
          teamGroupName: _firstNonEmpty([team?['group_name']]),
          chatId: _stringOrNull(chat?['id']),
        ),
      );
    }

    return result;
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  String? _stringOrNull(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  String _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = (value ?? '').toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }
}

class _UsefulPlanState {
  final AcademicContext contextData;
  final List<_UsefulSubject> subjects;
  final String? warning;

  const _UsefulPlanState({
    required this.contextData,
    required this.subjects,
    this.warning,
  });

  List<int> get semesters {
    final values = subjects
        .map((item) => item.semesterNumber)
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();
    return values;
  }
}

class _UsefulSubject {
  final String id;
  final String title;
  final String? subjectId;
  final String? groupId;
  final int? semesterNumber;
  final String controlForm;
  final String description;
  final String teacherName;
  final String? teamId;
  final String teamName;
  final String teamIcon;
  final String teamGroupName;
  final String? chatId;

  const _UsefulSubject({
    required this.id,
    required this.title,
    this.subjectId,
    this.groupId,
    this.semesterNumber,
    required this.controlForm,
    required this.description,
    required this.teacherName,
    this.teamId,
    required this.teamName,
    required this.teamIcon,
    required this.teamGroupName,
    this.chatId,
  });

  bool get hasChat => chatId != null && teamId != null;
}

String _sectionSubtitle(_UsefulSection section) {
  switch (section) {
    case _UsefulSection.subjects:
      return 'учебный план';
    case _UsefulSection.help:
      return 'справочный раздел';
    case _UsefulSection.jobs:
      return 'работа и стажировки';
  }
}

IconData _sectionIcon(_UsefulSection section) {
  switch (section) {
    case _UsefulSection.subjects:
      return Icons.school_outlined;
    case _UsefulSection.help:
      return Icons.help_outline_rounded;
    case _UsefulSection.jobs:
      return Icons.work_outline_rounded;
  }
}

class _UsefulHeader extends StatelessWidget {
  final _UsefulSection selectedSection;
  final VoidCallback onSectionTap;
  final VoidCallback onInfoTap;

  const _UsefulHeader({
    required this.selectedSection,
    required this.onSectionTap,
    required this.onInfoTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white,
                theme.colorScheme.primary.withValues(alpha: 0.06),
                theme.colorScheme.primary.withValues(alpha: 0.12),
              ],
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                left: -40,
                top: -20,
                child: _GlowCircle(
                  diameter: 140,
                  color: theme.colorScheme.primary.withValues(alpha: 0.10),
                ),
              ),
              Positioned(
                right: -30,
                bottom: -30,
                child: _GlowCircle(
                  diameter: 160,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          bottom: false,
          child: SizedBox.expand(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Align(
                alignment: const Alignment(-1, 0.26),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.85),
                            blurRadius: 8,
                            offset: const Offset(-2, -2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.lightbulb_outline_rounded,
                        color: theme.colorScheme.primary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Информация',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                              height: 1.05,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  offset: const Offset(0, 2),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _sectionSubtitle(selectedSection),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.black.withValues(alpha: 0.64),
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _HeaderActionButton(
                      icon: Icons.info_outline_rounded,
                      onTap: onInfoTap,
                    ),
                    const SizedBox(width: 8),
                    _HeaderActionButton(
                      icon: _sectionIcon(selectedSection),
                      onTap: onSectionTap,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoSheetHeader extends StatelessWidget {
  const _InfoSheetHeader();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Что внутри раздела',
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: Colors.black,
            fontWeight: FontWeight.w900,
          ),
    );
  }
}

class _InfoSheetPoint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _InfoSheetPoint({
    required this.icon,
    required this.title,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F4FF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: theme.colorScheme.primary, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.black.withValues(alpha: 0.64),
                    height: 1.3,
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

class _HeaderActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _HeaderActionButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.86),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(icon, color: theme.colorScheme.primary),
      ),
    );
  }
}

class _SectionChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _SectionChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.10)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.22)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.58),
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle_rounded,
                  color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

class _AcademicContextStrip extends StatelessWidget {
  final AcademicContext contextData;
  final int? selectedSemester;
  final int? currentSemester;

  const _AcademicContextStrip({
    required this.contextData,
    required this.selectedSemester,
    required this.currentSemester,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groupName = contextData.groupName ?? 'Группа не указана';
    final recordBookNumber = contextData.recordBookNumber;
    final semester = selectedSemester ?? currentSemester;
    final semesterText =
        semester == null ? 'семестр уточняется' : '$semester семестр';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFF8F4FF)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.account_balance_wallet_outlined,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Учебный профиль',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ContextPill(
                icon: Icons.groups_2_outlined,
                label: 'Группа',
                text: groupName,
              ),
              _ContextPill(
                icon: Icons.calendar_month_outlined,
                label: 'Семестр',
                text: semesterText,
              ),
              _ContextPill(
                icon: Icons.confirmation_number_outlined,
                label: '№ зачётки',
                text:
                    recordBookNumber == null ? 'не указана' : recordBookNumber,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ContextPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String text;

  const _ContextPill({
    required this.icon,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 16),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.black45,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                text,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.black87,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SemesterSubjectsSection extends StatelessWidget {
  final int? semester;
  final int? currentSemester;
  final List<_UsefulSubject> subjects;
  final Set<String> collapsedGroups;
  final ValueChanged<String> onGroupTap;

  const _SemesterSubjectsSection({
    required this.semester,
    required this.currentSemester,
    required this.subjects,
    required this.collapsedGroups,
    required this.onGroupTap,
  });

  @override
  Widget build(BuildContext context) {
    final grouped = _groupSubjectsByControl(subjects);
    final isCurrent = semester != null && semester == currentSemester;
    final title =
        isCurrent ? 'Текущий семестр' : '${semester ?? '-'}-й семестр';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.school_outlined,
                  color: Theme.of(context).colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${subjects.length} ${_pluralRu(subjects.length, 'дисциплина', 'дисциплины', 'дисциплин')}',
                      style:
                          const TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final entry in grouped.entries) ...[
            _ControlGroupBlock(
              label: entry.key,
              subjects: entry.value,
              collapsed: collapsedGroups.contains(entry.key),
              onTap: () => onGroupTap(entry.key),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

class _ControlGroupBlock extends StatelessWidget {
  final String label;
  final List<_UsefulSubject> subjects;
  final bool collapsed;
  final VoidCallback onTap;

  const _ControlGroupBlock({
    required this.label,
    required this.subjects,
    required this.collapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _controlAccent(label);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            margin: EdgeInsets.fromLTRB(0, 4, 0, collapsed ? 4 : 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.label_important_outline_rounded,
                  color: accent,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.black87,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${subjects.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          for (final subject in subjects) _SubjectCard(item: subject),
      ],
    );
  }
}

class _HelpSummaryCard extends StatelessWidget {
  const _HelpSummaryCard();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            primary.withValues(alpha: 0.88),
            primary.withValues(alpha: 0.52),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.20),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.help_outline_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Справочная информация',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Доступы, документы, программы, карта и частые вопросы',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.88),
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

class _SubjectControlsCard extends StatelessWidget {
  final List<int> semesters;
  final int? currentSemester;
  final int? selectedSemester;
  final _UsefulFilter selectedFilter;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<int> onSemesterSelected;
  final ValueChanged<_UsefulFilter> onFilterSelected;

  const _SubjectControlsCard({
    required this.semesters,
    required this.currentSemester,
    required this.selectedSemester,
    required this.selectedFilter,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onSemesterSelected,
    required this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semesterText = selectedSemester == null
        ? 'Семестр'
        : selectedSemester == currentSemester
            ? '$selectedSemester семестр, текущий'
            : '$selectedSemester семестр';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggleExpanded,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      Icons.grid_view_rounded,
                      color: theme.colorScheme.primary,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Предметы семестра',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: Colors.black,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$semesterText • ${_filterLabel(selectedFilter)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.black54,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  Expanded(
                    child: _FilterPill(
                      text: semesterText,
                      icon: Icons.school_outlined,
                      onTap: () => _showSemesterSheet(context),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _FilterPill(
                      text: _filterLabel(selectedFilter),
                      icon: Icons.fact_check_outlined,
                      onTap: () => _showTypeSheet(context),
                    ),
                  ),
                ],
              ),
            ),
            crossFadeState:
                expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
          ),
        ],
      ),
    );
  }

  Future<void> _showSemesterSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Семестр',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 10),
              ...semesters.map(
                (semester) => _ChoiceSheetTile(
                  title: 'Семестр $semester',
                  subtitle: semester == currentSemester ? 'текущий' : null,
                  selected: semester == selectedSemester,
                  onTap: () {
                    Navigator.of(sheetContext).pop(semester);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && selected != selectedSemester) {
      onSemesterSelected(selected);
    }
  }

  Future<void> _showTypeSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<_UsefulFilter>(
      context: context,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Тип',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 10),
              ..._UsefulFilter.values.map(
                (filter) => _ChoiceSheetTile(
                  title: _filterLabel(filter),
                  selected: filter == selectedFilter,
                  onTap: () {
                    Navigator.of(sheetContext).pop(filter);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && selected != selectedFilter) {
      onFilterSelected(selected);
    }
  }
}

class _FilterPill extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;

  const _FilterPill({
    required this.text,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F1FF),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 17, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.black87,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: Colors.black45,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceSheetTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceSheetTile({
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.10)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        subtitle!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle_rounded,
                  color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

class _HelpSection extends StatelessWidget {
  const _HelpSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        _HelpSummaryCard(),
        SizedBox(height: 12),
        _HelpGroupSection(
          title: 'Доступы',
          cards: [
            _HelpCard(
              icon: Icons.login_rounded,
              title: 'Как зайти в личный кабинет',
              subtitle: 'Краткая инструкция по входу и восстановлению доступа.',
            ),
            _HelpCard(
              icon: Icons.download_rounded,
              title: 'Как скачать нужные материалы',
              subtitle: 'Где искать файлы, методички и шаблоны.',
            ),
          ],
        ),
        _HelpGroupSection(
          title: 'Документы',
          cards: [
            _HelpCard(
              icon: Icons.description_outlined,
              title: 'Как заказать справку',
              subtitle:
                  'Основные действия для получения справки в университете.',
            ),
          ],
        ),
        _HelpGroupSection(
          title: 'Программы',
          cards: [
            _HelpCard(
              icon: Icons.computer_rounded,
              title: 'Как установить нужные программы',
              subtitle: 'AutoCAD, Revit, офисные программы и другое ПО.',
            ),
          ],
        ),
        _HelpGroupSection(
          title: 'Карта и аудитории',
          cards: [
            _HelpCard(
              icon: Icons.map_outlined,
              title: 'Карта и аудитории',
              subtitle: 'Как найти корпус, кабинет или аудиторию.',
            ),
          ],
        ),
        _HelpGroupSection(
          title: 'Частые вопросы',
          cards: [
            _HelpCard(
              icon: Icons.help_outline_rounded,
              title: 'Частые вопросы',
              subtitle: 'Ответы на бытовые вопросы по учёбе.',
            ),
          ],
        ),
      ],
    );
  }
}

const _demoJobs = [
  _DemoJob(
    title: 'Junior Flutter Developer',
    company: 'Campus Lab',
    type: 'Стажировка',
    city: 'Гибрид',
    salary: 'от 35 000 ₽',
    deadline: 'до 30 июня',
    description:
        'Помощь с мобильным приложением, простые экраны, фиксы UI и работа с наставником.',
    tags: ['Flutter', 'Dart', 'UI'],
    accent: Color(0xFF6A4BBC),
  ),
  _DemoJob(
    title: 'Ассистент преподавателя по программированию',
    company: 'Кафедра ИТ',
    type: 'Подработка',
    city: 'Университет',
    salary: 'по договорённости',
    deadline: 'на этой неделе',
    description:
        'Проверка лабораторных, помощь первокурсникам и подготовка коротких материалов.',
    tags: ['Python', 'Алгоритмы', 'Коммуникация'],
    accent: Color(0xFF2F80ED),
  ),
  _DemoJob(
    title: 'Дизайнер презентаций и лендингов',
    company: 'Студенческий проект',
    type: 'Проект',
    city: 'Удалённо',
    salary: 'за задачу',
    deadline: 'можно сегодня',
    description:
        'Нужно красиво упаковывать идеи: презентации, простые макеты и визуалы для демо.',
    tags: ['Figma', 'Canva', 'Визуал'],
    accent: Color(0xFFE16B8C),
  ),
];

class _DemoJob {
  final String title;
  final String company;
  final String type;
  final String city;
  final String salary;
  final String deadline;
  final String description;
  final List<String> tags;
  final Color accent;

  const _DemoJob({
    required this.title,
    required this.company,
    required this.type,
    required this.city,
    required this.salary,
    required this.deadline,
    required this.description,
    required this.tags,
    required this.accent,
  });
}

class _JobsSection extends StatelessWidget {
  const _JobsSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _JobsHeroCard(),
        const SizedBox(height: 12),
        const _JobBoardStats(),
        const SizedBox(height: 12),
        _JobsGroupSection(
          title: 'Свежие предложения',
          jobs: _demoJobs,
        ),
      ],
    );
  }
}

class _JobsHeroCard extends StatelessWidget {
  const _JobsHeroCard();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary.withValues(alpha: 0.92),
            const Color(0xFF8E6BE8),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.22),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.work_outline_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Доска вакансий',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Здесь студенты смогут искать подработки, стажировки и проектные задачи. Публикацию и правила модерации подключим отдельным шагом.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.88),
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _showPostJobPlaceholder(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Оставить вакансию'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: primary,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPostJobPlaceholder(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Размещение вакансии',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Форма появится позже. Пока можно показать идею: студент или модератор добавляет вакансию, а мы решаем правила публикации.',
            ),
          ],
        ),
      ),
    );
  }
}

class _JobBoardStats extends StatelessWidget {
  const _JobBoardStats();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(
          child: _JobStatPill(
            icon: Icons.flash_on_rounded,
            title: '3',
            subtitle: 'активные',
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: _JobStatPill(
            icon: Icons.verified_user_outlined,
            title: 'скоро',
            subtitle: 'модерация',
          ),
        ),
      ],
    );
  }
}

class _JobStatPill extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _JobStatPill({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: primary, size: 19),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.black54,
                        fontWeight: FontWeight.w700,
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

class _JobsGroupSection extends StatelessWidget {
  final String title;
  final List<_DemoJob> jobs;

  const _JobsGroupSection({
    required this.title,
    required this.jobs,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.local_fire_department_outlined,
                  color: Colors.black54,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  '${jobs.length}',
                  style: const TextStyle(
                    color: Colors.black45,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          for (final job in jobs) _JobCard(job: job),
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  final _DemoJob job;

  const _JobCard({required this.job});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => _showDetails(context),
      borderRadius: BorderRadius.circular(24),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surface,
              const Color(0xFFF8F4FF),
            ],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.045),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: job.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    Icons.business_center_outlined,
                    color: job.accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.black,
                          fontWeight: FontWeight.w900,
                          height: 1.12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${job.company} • ${job.city}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.black54,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, color: Colors.black38),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              job.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.black.withValues(alpha: 0.62),
                height: 1.32,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _JobChip(text: job.type, color: job.accent),
                _JobChip(text: job.salary, color: job.accent),
                _JobChip(text: job.deadline, color: job.accent),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                job.title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                '${job.company} • ${job.city}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.black54,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 14),
              Text(job.description),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in job.tags)
                    _JobChip(text: tag, color: job.accent),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Понятно'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobChip extends StatelessWidget {
  final String text;
  final Color color;

  const _JobChip({
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w900,
            ),
      ),
    );
  }
}

class _HelpGroupSection extends StatelessWidget {
  final String title;
  final List<Widget> cards;

  const _HelpGroupSection({
    required this.title,
    required this.cards,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          ...cards,
        ],
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _HelpCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => _showPlaceholder(context),
      borderRadius: BorderRadius.circular(26),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surface,
              const Color(0xFFF8F4FF),
            ],
          ),
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.045),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: const Color(0xFF6A4BBC)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.black38),
          ],
        ),
      ),
    );
  }

  void _showPlaceholder(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 8),
              const Text('Подробную инструкцию добавим в справочник.'),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubjectCard extends StatelessWidget {
  final _UsefulSubject item;

  const _SubjectCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controlText = item.controlForm.isEmpty
        ? 'Форма контроля уточняется'
        : item.controlForm;
    final accent = _controlAccent(controlText);

    return InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(22),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white,
              accent.withValues(alpha: 0.055),
            ],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: accent.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.035),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SubjectAvatar(title: item.title, size: 40, accent: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      height: 1.16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniControlPill(text: controlText, color: accent),
                _SubjectPlanPill(color: accent),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SubjectInfoScreen(
          title: item.title,
          subjectId: item.subjectId,
          subjectOfferingId: item.id,
          groupId: item.groupId,
          semesterNumber: item.semesterNumber,
        ),
      ),
    );
  }
}

class _SubjectAvatar extends StatelessWidget {
  final String title;
  final double size;
  final Color accent;

  const _SubjectAvatar({
    required this.title,
    this.size = 44,
    this.accent = const Color(0xFF6A4BBC),
  });

  @override
  Widget build(BuildContext context) {
    final trimmed = title.trim();
    final letter =
        trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.78), accent],
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.20),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: size * 0.38,
        ),
      ),
    );
  }
}

class _MiniControlPill extends StatelessWidget {
  final String text;
  final Color color;

  const _MiniControlPill({
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w900,
            ),
      ),
    );
  }
}

class _SubjectPlanPill extends StatelessWidget {
  final Color color;

  const _SubjectPlanPill({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.assignment_outlined, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            'Учебный план',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w900,
                ),
          ),
        ],
      ),
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double diameter;
  final Color color;

  const _GlowCircle({
    required this.diameter,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String text;
  final bool compact;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyState({
    required this.text,
    this.compact = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
