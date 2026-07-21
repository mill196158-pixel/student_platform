import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../learning/models/team.dart';
import '../learning/team_details_screen.dart';
import '../schedule/subject_diary/subject_diary.dart';
import '../schedule/subject_diary_screen.dart';
import 'teacher_profile_screen.dart';

class SubjectInfoScreen extends StatefulWidget {
  final String title;
  final String? subjectId;
  final String subjectOfferingId;
  final String? lessonId;
  final String? groupId;
  final int? semesterNumber;

  const SubjectInfoScreen({
    super.key,
    required this.title,
    required this.subjectOfferingId,
    this.subjectId,
    this.lessonId,
    this.groupId,
    this.semesterNumber,
  });

  @override
  State<SubjectInfoScreen> createState() => _SubjectInfoScreenState();
}

class _SubjectInfoScreenState extends State<SubjectInfoScreen> {
  late Future<_SubjectInfoData> _future = _load();
  final _scrollController = ScrollController();
  final _filesKey = GlobalKey();
  final _repository = _SubjectInfoRepository();
  bool _voting = false;

  Future<_SubjectInfoData> _load() async {
    return _repository.load(
      subjectOfferingId: widget.subjectOfferingId,
      fallbackTitle: widget.title,
      fallbackSubjectId: widget.subjectId,
      fallbackGroupId: widget.groupId,
      fallbackSemesterNumber: widget.semesterNumber,
    );
  }

  Future<void> _reload() async {
    final next = await _load();
    if (!mounted) return;
    setState(() => _future = Future<_SubjectInfoData>.value(next));
  }

  Future<void> _rateSubject(_SubjectInfoData data) async {
    if (_voting) return;
    var difficulty = data.mySubjectScore ?? 3;
    var isSaving = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> submit() async {
              if (isSaving) return;
              setSheetState(() => isSaving = true);
              setState(() => _voting = true);
              try {
                await _repository.voteSubjectDifficulty(
                  subjectOfferingId: data.subjectOfferingId,
                  difficultyRating: difficulty,
                );
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                await _reload();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Оценка сохранена')),
                );
              } catch (_) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Не удалось сохранить оценку')),
                );
              } finally {
                if (mounted) setState(() => _voting = false);
                if (context.mounted) setSheetState(() => isSaving = false);
              }
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                16,
                18,
                MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Оценить сложность предмета',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    data.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.black54,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 14),
                  _CompactRatingCircles(
                    value: difficulty,
                    onChanged: (value) =>
                        setSheetState(() => difficulty = value),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: isSaving ? null : submit,
                      child: Text(isSaving ? 'Сохраняю...' : 'Сохранить'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBFAFF),
      appBar: AppBar(title: const Text('Информация о предмете')),
      body: FutureBuilder<_SubjectInfoData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data ??
              _SubjectInfoData.fallback(
                title: widget.title,
                subjectOfferingId: widget.subjectOfferingId,
                semesterNumber: widget.semesterNumber,
              );

          return ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: [
              _HeroCard(data: data),
              const SizedBox(height: 10),
              _TeacherDifficultyGlance(
                data: data,
                ratingBusy: _voting,
                onOpenTeacher: data.hasTeacher
                    ? () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TeacherProfileScreen(
                              teacherName: data.teacherName,
                              subjectTitle: data.displayTitle,
                              department: data.department,
                              semesterNumber: data.semesterNumber,
                              difficultyScore: data.teacherDifficultyAvg,
                              subjectOfferingId: data.subjectOfferingId,
                              subjectDifficultyAvg: data.subjectDifficultyAvg,
                            ),
                          ),
                        )
                    : null,
                onRateSubject:
                    data.canVoteSubject ? () => _rateSubject(data) : null,
              ),
              const SizedBox(height: 10),
              _QuickActions(
                canOpenChat: data.canOpenChat,
                onChatTap:
                    data.canOpenChat ? () => _openChat(context, data) : null,
                onDiaryTap: () => _openDiary(context, data),
                onFilesTap: _scrollToFiles,
              ),
              const SizedBox(height: 10),
              _SummaryCard(data: data),
              const SizedBox(height: 10),
              _FilesCard(key: _filesKey),
              const SizedBox(height: 10),
              _LargeActionCard(
                icon: Icons.chat_bubble_outline_rounded,
                title: 'Чат предмета',
                subtitle: data.canOpenChat
                    ? 'Обсуждения, вопросы и материалы группы'
                    : 'Чат пока не создан',
                actionLabel: 'Открыть чат',
                enabled: data.canOpenChat,
                onTap: data.canOpenChat ? () => _openChat(context, data) : null,
              ),
              const SizedBox(height: 10),
              _LargeActionCard(
                icon: Icons.menu_book_outlined,
                title: 'Дневник предмета',
                subtitle: 'Заметки, фото конспектов и файлы по предмету',
                actionLabel: 'Открыть дневник',
                enabled: true,
                onTap: () => _openDiary(context, data),
              ),
              const SizedBox(height: 10),
              const _HelpCard(),
            ],
          );
        },
      ),
    );
  }

  void _openChat(BuildContext context, _SubjectInfoData data) {
    final team = Team(
      id: data.teamId!,
      name: data.teamName.isEmpty ? data.displayTitle : data.teamName,
      teacher: data.teacherName,
      groupCode: data.teamGroupName,
      icon: data.teamIcon.isEmpty ? 'school' : data.teamIcon,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeamDetailsScreen(
          team: team,
          initialTabIndex: 1,
        ),
      ),
    );
  }

  void _openDiary(BuildContext context, _SubjectInfoData data) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SubjectDiaryScreen(
          args: SubjectDiaryArgs(
            subjectOfferingId: data.subjectOfferingId,
            subjectId: data.subjectId,
            subjectTitle: data.displayTitle,
            groupId: data.groupId,
            semesterNumber: data.semesterNumber,
            lessonId: widget.lessonId,
            legacySubjectKey: data.displayTitle,
          ),
        ),
      ),
    );
  }

  void _scrollToFiles() {
    final context = _filesKey.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }
}

class _SubjectInfoRepository {
  _SubjectInfoRepository({SupabaseClient? client})
      : _sb = client ?? Supabase.instance.client;

  final SupabaseClient _sb;

  Future<_SubjectInfoData> load({
    required String subjectOfferingId,
    required String fallbackTitle,
    String? fallbackSubjectId,
    String? fallbackGroupId,
    int? fallbackSemesterNumber,
  }) async {
    final offering = await _sb
        .from('subject_offerings')
        .select(
          'id,display_name,subject_id,group_id,curriculum_subject_id,semester_number,status',
        )
        .eq('id', subjectOfferingId)
        .maybeSingle();

    final offeringMap = _asMap(offering);
    final subjectId = _stringOrNull(offeringMap?['subject_id']) ??
        _stringOrNull(fallbackSubjectId);
    final curriculumSubjectId =
        _stringOrNull(offeringMap?['curriculum_subject_id']);

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
          .select(
            'display_name,raw_subject_name,control_form,department,hours_total,credits,block_name,subject_index',
          )
          .eq('id', curriculumSubjectId)
          .maybeSingle());
    }

    final team = _asMap(await _sb
        .from('teams')
        .select('id,name,teacher,icon,group_name')
        .eq('subject_offering_id', subjectOfferingId)
        .limit(1)
        .maybeSingle());

    final teamId = _stringOrNull(team?['id']);
    Map<String, dynamic>? chat;
    if (teamId != null) {
      chat = _asMap(await _sb
          .from('chats')
          .select('id,type')
          .eq('team_id', teamId)
          .eq('type', 'team_main')
          .limit(1)
          .maybeSingle());
    }

    final title = _firstNonEmpty([
      offeringMap?['display_name'],
      subject?['canonical_name'],
      curriculum?['display_name'],
      fallbackTitle,
    ]);

    final teacherName = _firstNonEmpty([team?['teacher']]);
    final subjectRating = await _loadSubjectRating(subjectOfferingId);
    final teacherRating = await _loadTeacherRating(teacherName);

    return _SubjectInfoData(
      title: title,
      subjectOfferingId: subjectOfferingId,
      subjectId: subjectId,
      groupId: _stringOrNull(offeringMap?['group_id']) ??
          _stringOrNull(fallbackGroupId),
      semesterNumber:
          _asInt(offeringMap?['semester_number']) ?? fallbackSemesterNumber,
      description: _firstNonEmpty([subject?['description']]),
      controlForm: _firstNonEmpty([curriculum?['control_form']]),
      teacherName: teacherName,
      department: _firstNonEmpty([curriculum?['department']]),
      credits: _firstNonEmpty([curriculum?['credits']]),
      hoursTotal: _firstNonEmpty([curriculum?['hours_total']]),
      teamId: teamId,
      teamName: _firstNonEmpty([team?['name']]),
      teamIcon: _firstNonEmpty([team?['icon']]),
      teamGroupName: _firstNonEmpty([team?['group_name']]),
      chatId: _stringOrNull(chat?['id']),
      subjectDifficultyAvg: subjectRating.$1,
      mySubjectScore: subjectRating.$2,
      canVoteSubject: subjectRating.$3,
      teacherDifficultyAvg: teacherRating,
    );
  }

  Future<(double?, int?, bool)> _loadSubjectRating(String offeringId) async {
    try {
      final res = await _sb.rpc('rpc_get_my_subjects_v2');
      final rows = (res as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      for (final row in rows) {
        if ((row['subject_offering_id'] ?? '').toString() != offeringId) {
          continue;
        }
        final global = _asDouble(row['avg_difficulty_global']);
        final local = _asDouble(row['avg_difficulty_local']);
        final avg = global > 0 ? global : local;
        final vote = _asMap(row['user_vote']);
        final myScore = vote == null ? null : _asInt(vote['difficulty_rating']);
        final canVote = row['can_vote'] == true;
        return (
          avg > 0 ? avg : null,
          (myScore != null && myScore >= 1 && myScore <= 5) ? myScore : null,
          canVote,
        );
      }
    } catch (_) {}
    return (null, null, false);
  }

  Future<double?> _loadTeacherRating(String teacherName) async {
    final normalized = teacherName
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();
    if (normalized.isEmpty) return null;
    try {
      final target = await _sb
          .from('teacher_difficulty_targets')
          .select('id')
          .eq('normalized_name', normalized)
          .maybeSingle();
      final teacherId = (target?['id'] ?? '').toString().trim();
      if (teacherId.isEmpty) return null;
      final summary = await _sb
          .from('teacher_difficulty_summaries')
          .select('vote_count,score_total')
          .eq('teacher_id', teacherId)
          .maybeSingle();
      final voteCount = _asInt(summary?['vote_count']) ?? 0;
      final scoreTotal = _asInt(summary?['score_total']) ?? 0;
      if (voteCount <= 0) return null;
      return scoreTotal / voteCount;
    } catch (_) {
      return null;
    }
  }

  Future<void> voteSubjectDifficulty({
    required String subjectOfferingId,
    required int difficultyRating,
  }) async {
    await _sb.rpc(
      'rpc_vote_subject_difficulty_v2',
      params: {
        'p_subject_offering_id': subjectOfferingId,
        'p_difficulty_rating': difficultyRating,
        'p_workload_rating': null,
        'p_usefulness_rating': null,
        'p_exam_stress_rating': null,
        'p_comment': null,
        'p_is_anonymous': true,
      },
    );
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

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse((value ?? '').toString().replaceAll(',', '.')) ?? 0;
  }

  String _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = (value ?? '').toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }
}

class _SubjectInfoData {
  final String title;
  final String subjectOfferingId;
  final String? subjectId;
  final String? groupId;
  final int? semesterNumber;
  final String description;
  final String controlForm;
  final String teacherName;
  final String department;
  final String credits;
  final String hoursTotal;
  final String? teamId;
  final String teamName;
  final String teamIcon;
  final String teamGroupName;
  final String? chatId;
  final double? subjectDifficultyAvg;
  final int? mySubjectScore;
  final bool canVoteSubject;
  final double? teacherDifficultyAvg;

  const _SubjectInfoData({
    required this.title,
    required this.subjectOfferingId,
    this.subjectId,
    this.groupId,
    this.semesterNumber,
    required this.description,
    required this.controlForm,
    required this.teacherName,
    required this.department,
    required this.credits,
    required this.hoursTotal,
    this.teamId,
    required this.teamName,
    required this.teamIcon,
    required this.teamGroupName,
    this.chatId,
    this.subjectDifficultyAvg,
    this.mySubjectScore,
    this.canVoteSubject = false,
    this.teacherDifficultyAvg,
  });

  bool get canOpenChat => teamId != null && chatId != null;

  String get displayTitle {
    final clean = _cleanHumanText(title);
    return clean ?? 'Предмет';
  }

  String get displayDescription {
    return _cleanHumanText(description) ??
        'Информация по предмету будет добавлена позже.';
  }

  bool get hasDescription => _cleanHumanText(description) != null;

  String get displayControlForm {
    return _cleanHumanText(controlForm) ?? 'Тип контроля уточняется';
  }

  bool get hasControlForm => _cleanHumanText(controlForm) != null;

  String get displayTeacherName {
    return _cleanHumanText(teacherName) ?? 'Преподаватель будет указан позже.';
  }

  bool get hasTeacher => _cleanHumanText(teacherName) != null;

  List<String> get heroDetails {
    return [
      if (semesterNumber != null) '$semesterNumber-й семестр',
      displayControlForm,
    ];
  }

  String? get displayCredits {
    final clean = _cleanHumanText(credits);
    if (clean == null || _isZeroValue(clean)) return null;
    return '$clean з.е.';
  }

  String? get displayHours {
    final clean = _cleanHumanText(hoursTotal);
    if (clean == null || _isZeroValue(clean)) return null;
    return '$clean ч.';
  }

  static String? _cleanHumanText(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;

    final normalized = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final technicalExact = {
      'null',
      'none',
      'dev',
      'test',
      'stage2_schedule_subject_resolver',
    };
    if (technicalExact.contains(normalized)) return null;
    if (normalized.contains('stage2_') || normalized.contains('_resolver')) {
      return null;
    }
    return text;
  }

  static bool _isZeroValue(String value) {
    final normalized = value.replaceAll(',', '.').trim();
    final parsed = double.tryParse(normalized);
    return parsed != null && parsed == 0;
  }

  factory _SubjectInfoData.fallback({
    required String title,
    required String subjectOfferingId,
    int? semesterNumber,
  }) {
    return _SubjectInfoData(
      title: title,
      subjectOfferingId: subjectOfferingId,
      semesterNumber: semesterNumber,
      description: '',
      controlForm: '',
      teacherName: '',
      department: '',
      credits: '',
      hoursTotal: '',
      teamName: '',
      teamIcon: '',
      teamGroupName: '',
      subjectDifficultyAvg: null,
      mySubjectScore: null,
      canVoteSubject: false,
      teacherDifficultyAvg: null,
    );
  }

  String get subjectDifficultyLabel {
    final value = subjectDifficultyAvg;
    if (value == null || value <= 0) return 'нет оценок';
    return '${value.toStringAsFixed(1)} / 5';
  }

  String get teacherDifficultyLabel {
    final value = teacherDifficultyAvg;
    if (value == null || value <= 0) return 'нет оценок';
    return '${value.toStringAsFixed(1)} / 5';
  }
}

class _HeroCard extends StatelessWidget {
  final _SubjectInfoData data;

  const _HeroCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = data.displayTitle;
    final details = [
      ...data.heroDetails,
      if (data.displayCredits != null) data.displayCredits!,
      if (data.displayHours != null) data.displayHours!,
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF3ECFF), Color(0xFFFFFFFF)],
        ),
        borderRadius: BorderRadius.circular(22),
        border:
            Border.all(color: const Color(0xFF6A4BBC).withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6A4BBC).withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubjectIcon(title: title, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: Colors.black,
                    height: 1.12,
                  ),
                ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    details.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.58),
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  final bool canOpenChat;
  final VoidCallback? onChatTap;
  final VoidCallback onDiaryTap;
  final VoidCallback onFilesTap;

  const _QuickActions({
    required this.canOpenChat,
    required this.onChatTap,
    required this.onDiaryTap,
    required this.onFilesTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _QuickActionCard(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'Чат',
            subtitle: canOpenChat ? 'Открыть' : 'Позже',
            enabled: canOpenChat,
            onTap: onChatTap,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _QuickActionCard(
            icon: Icons.menu_book_outlined,
            title: 'Дневник',
            subtitle: 'Заметки',
            enabled: true,
            onTap: onDiaryTap,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _QuickActionCard(
            icon: Icons.folder_outlined,
            title: 'Файлы',
            subtitle: 'Материалы',
            enabled: true,
            onTap: onFilesTap,
          ),
        ),
      ],
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback? onTap;

  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled ? const Color(0xFF6A4BBC) : Colors.black38;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        constraints: const BoxConstraints(minHeight: 82),
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
        decoration: BoxDecoration(
          color: enabled
              ? theme.colorScheme.surface
              : Colors.white.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: enabled ? 0.035 : 0.02),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: enabled ? Colors.black : Colors.black45,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: enabled ? Colors.black54 : Colors.black38,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final _SubjectInfoData data;

  const _SummaryCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return _ContentCard(
      icon: Icons.info_outline_rounded,
      title: 'Краткая информация',
      child: Column(
        children: [
          if (!data.hasDescription && !data.hasControlForm) ...[
            const _EmptyContentCallout(
              icon: Icons.auto_stories_outlined,
              title: 'Информация будет добавлена',
              subtitle:
                  'Здесь появятся описание предмета, формат сдачи, материалы и заметки.',
            ),
            const SizedBox(height: 10),
          ],
          _InfoTile(
            title: 'Описание',
            value: data.displayDescription,
            icon: Icons.notes_rounded,
          ),
          _InfoTile(
            title: 'Как сдаётся',
            value: data.displayControlForm == 'Тип контроля уточняется'
                ? 'Формат сдачи будет уточнён после заполнения материалов.'
                : data.displayControlForm,
            icon: Icons.task_alt_rounded,
          ),
          const _InfoTile(
            title: 'Что обычно важно',
            value:
                'Материалы, требования преподавателя и заметки появятся здесь позже.',
            icon: Icons.star_border_rounded,
          ),
        ],
      ),
    );
  }
}

class _TeacherDifficultyGlance extends StatelessWidget {
  final _SubjectInfoData data;
  final bool ratingBusy;
  final VoidCallback? onOpenTeacher;
  final VoidCallback? onRateSubject;

  const _TeacherDifficultyGlance({
    required this.data,
    required this.ratingBusy,
    required this.onOpenTeacher,
    required this.onRateSubject,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onOpenTeacher,
            borderRadius: BorderRadius.circular(14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
                  ),
                  child: const Icon(
                    Icons.person_outline_rounded,
                    color: Color(0xFF6A4BBC),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.displayTeacherName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.black,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        data.hasTeacher
                            ? 'Сдача: ${data.teacherDifficultyLabel}'
                            : 'Преподаватель пока не указан',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.black54,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onOpenTeacher != null)
                  const Icon(Icons.chevron_right_rounded,
                      color: Colors.black38, size: 22),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _GlanceStatChip(
                  icon: Icons.local_fire_department_rounded,
                  label: 'Предмет',
                  value: data.subjectDifficultyLabel,
                ),
              ),
              const SizedBox(width: 8),
              if (onRateSubject != null)
                Material(
                  color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    onTap: ratingBusy ? null : onRateSubject,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            data.mySubjectScore == null
                                ? Icons.star_border_rounded
                                : Icons.star_rounded,
                            size: 18,
                            color: const Color(0xFF6A4BBC),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            data.mySubjectScore == null
                                ? 'Оценить'
                                : 'Моя: ${data.mySubjectScore}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: const Color(0xFF6A4BBC),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlanceStatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _GlanceStatChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5FF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: const Color(0xFF6A4BBC)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$label: $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.black87,
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactRatingCircles extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _CompactRatingCircles({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 1; i <= 5; i++)
          InkWell(
            onTap: () => onChanged(i),
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i <= value
                    ? const Color(0xFF6A4BBC)
                    : const Color(0xFFF0ECF8),
              ),
              child: Text(
                '$i',
                style: TextStyle(
                  color: i <= value ? Colors.white : Colors.black54,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FilesCard extends StatelessWidget {
  const _FilesCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ContentCard(
      icon: Icons.folder_outlined,
      title: 'Полезные файлы',
      child: Column(
        children: [
          _EmptyContentCallout(
            icon: Icons.folder_open_outlined,
            title: 'Материалы пока не загружены',
            subtitle:
                'Шаблоны, примеры работ, методички и загруженные файлы появятся здесь позже.',
          ),
        ],
      ),
    );
  }
}

class _LargeActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final bool enabled;
  final VoidCallback? onTap;

  const _LargeActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled ? const Color(0xFF6A4BBC) : Colors.black38;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: enabled ? Colors.black : Colors.black45,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: enabled ? Colors.black54 : Colors.black38,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _InlineAction(text: actionLabel, enabled: enabled),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: enabled ? Colors.black38 : Colors.black26,
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEFF4FF), Color(0xFFFFFFFF)],
        ),
        borderRadius: BorderRadius.circular(26),
        border:
            Border.all(color: const Color(0xFF6A4BBC).withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.volunteer_activism_outlined,
                color: Color(0xFF6A4BBC)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Сложно с предметом?',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Можно разобрать задание, подготовиться к сдаче или задать вопрос.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.black54,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 10),
                const _InlineAction(text: 'Задать вопрос', enabled: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContentCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _ContentCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFF6A4BBC), size: 19),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const _InfoTile({
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFAFF),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF6A4BBC)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.black54,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.black87,
                    height: 1.28,
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

class _EmptyContentCallout extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyContentCallout({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF7F1FF), Color(0xFFFFFFFF)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF6A4BBC).withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 20, color: const Color(0xFF6A4BBC)),
          ),
          const SizedBox(width: 10),
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
                    color: Colors.black54,
                    height: 1.25,
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

class _SubjectIcon extends StatelessWidget {
  final String title;
  final double size;

  const _SubjectIcon({
    required this.title,
    required this.size,
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
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF8E6BE8), Color(0xFF6A4BBC)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6A4BBC).withValues(alpha: 0.22),
            blurRadius: 16,
            offset: const Offset(0, 6),
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

class _InlineAction extends StatelessWidget {
  final String text;
  final bool enabled;

  const _InlineAction({
    required this.text,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled ? const Color(0xFF6A4BBC) : Colors.black38;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: color,
                fontWeight: FontWeight.w900,
              ),
        ),
        const SizedBox(width: 4),
        Icon(Icons.arrow_forward_rounded, size: 16, color: color),
      ],
    );
  }
}
