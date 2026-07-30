import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:student_ui/student_ui.dart';

import '../../core/auth_session.dart';
import '../../data/academic_context_service.dart';
import '../../services/auth_service.dart';
import 'content_media_service.dart';
import 'info_subjects_cache.dart';
import 'subject_attachment_open.dart';
import 'subject_difficulty.dart';
import 'reference_service.dart';
import 'my_vacancy_submissions_screen.dart';
import 'propose_vacancy_screen.dart';
import 'vacancy_media_service.dart';
import 'vacancy_service.dart';
import 'vacancy_submission_service.dart';
import 'subject_info_screen.dart';
import 'useful_subject.dart';
import 'useful_subjects_repository.dart';

enum _UsefulFilter { all, exams, credits, practices, courseWorks }

enum _UsefulSection { subjects, help, jobs }

BoxConstraints _fullWidthSheetConstraints(BuildContext context) {
  return BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width);
}

class InfoScreen extends StatefulWidget {
  const InfoScreen({
    super.key,
    this.subjectsRepository,
    this.academicContextService,
    this.planLoader,
    this.debugUserId,
    this.vacancyService,
    this.vacancySubmissionService,
    this.vacancyMediaService,
    this.referenceService,
    this.initialSectionName,
  });

  /// Optional DI for tests; production uses [UsefulSubjectsRepository].
  final UsefulSubjectsRepository? subjectsRepository;

  /// Optional DI for tests; production uses [AcademicContextService].
  final AcademicContextService? academicContextService;

  /// Optional full-plan loader override for focused cache/refresh tests.
  final Future<InfoPlanState> Function()? planLoader;

  /// Optional auth user id override for cache-key tests without Supabase auth.
  final String? debugUserId;

  /// Optional DI for tests; production uses [VacancyService].
  final VacancyService? vacancyService;

  /// Optional DI for tests; production uses [VacancySubmissionService].
  final VacancySubmissionService? vacancySubmissionService;

  /// Optional DI for tests; production uses [VacancyMediaService].
  final VacancyMediaService? vacancyMediaService;

  /// Optional DI for tests; production uses [ReferenceService].
  final ReferenceService? referenceService;

  /// Opens a non-default Info tab section without navigating the section sheet.
  /// Allowed values: `subjects`, `help`, `jobs`.
  @visibleForTesting
  final String? initialSectionName;

  @visibleForTesting
  static void debugClearMemoryCache() => _InfoScreenState.clearMemoryCache();

  @override
  State<InfoScreen> createState() => _InfoScreenState();
}

class _InfoScreenState extends State<InfoScreen> {
  // In-memory (RAM) layer of the cache. Survives across screen re-creations
  // within one app session, so re-opening the tab is instant with no spinner.
  // The SharedPreferences layer keeps data across app restarts.
  static final Map<String, InfoPlanState> _memoryCache = {};

  @visibleForTesting
  static void clearMemoryCache() => _memoryCache.clear();

  late Future<InfoPlanState> _future;
  InfoPlanState? _latestState;
  Future<void>? _reloadInFlight;
  bool _needsRevealAfterCover = false;
  int? _selectedSemester;
  _UsefulFilter _filter = _UsefulFilter.all;
  _UsefulSection _section = _UsefulSection.subjects;
  bool _controlGroupsTouched = false;
  final Set<String> _collapsedControlGroups = {};
  late final ReferenceService _referenceService;
  ReferenceLoadResult _reference =
      const ReferenceLoadResult(isDemoFallback: true);
  int _referenceLoadGeneration = 0;
  bool _referenceLoadInFlight = false;
  late final VacancyService _vacancyService;
  late final VacancySubmissionService _vacancySubmissionService;
  late final VacancyMediaService _vacancyMediaService;
  VacancyLoadResult _vacancies =
      const VacancyLoadResult(isDemoFallback: true);
  int _vacancyLoadGeneration = 0;
  bool _vacancyLoadInFlight = false;

  UsefulSubjectsRepository get _subjectsRepository =>
      widget.subjectsRepository ?? UsefulSubjectsRepository();

  AcademicContextService get _academicContextService =>
      widget.academicContextService ?? AcademicContextService();

  bool get _isCoveredByRoute => ModalRoute.of(context)?.isCurrent != true;

  @override
  void initState() {
    super.initState();
    _vacancyService = widget.vacancyService ??
        VacancyService(
          currentUserId: () =>
              widget.debugUserId ??
              Supabase.instance.client.auth.currentUser?.id,
        );
    _vacancySubmissionService = widget.vacancySubmissionService ??
        VacancySubmissionService(
          currentUserId: () =>
              widget.debugUserId ??
              Supabase.instance.client.auth.currentUser?.id,
        );
    _vacancyMediaService = widget.vacancyMediaService ??
        VacancyMediaService(
          currentUserId: () =>
              widget.debugUserId ??
              Supabase.instance.client.auth.currentUser?.id,
        );
    _referenceService = widget.referenceService ??
        ReferenceService(
          currentUserId: () =>
              widget.debugUserId ??
              Supabase.instance.client.auth.currentUser?.id,
        );
    if (widget.initialSectionName == 'help') {
      _section = _UsefulSection.help;
    } else if (widget.initialSectionName == 'jobs') {
      _section = _UsefulSection.jobs;
    }
    InfoSubjectsCache.attachMemoryClear(clearMemoryCache);
    InfoSubjectsCache.revision.addListener(_onSubjectsCacheInvalidated);
    // Instant RAM cache: show already-loaded subjects on the first frame and
    // refresh quietly in the background.
    final memoryCached = _peekMemoryCache();
    if (memoryCached != null) {
      _latestState = memoryCached;
      _future = Future<InfoPlanState>.value(memoryCached);
      _refreshSilently();
    } else {
      _future = _loadWithCache();
    }
    unawaited(_loadReference());
    unawaited(_loadVacancies());
  }

  Future<void> _loadVacancies() async {
    if (_vacancyLoadInFlight) return;
    final generation = ++_vacancyLoadGeneration;
    _vacancyLoadInFlight = true;
    try {
      final cached = await _vacancyService.loadCached();
      if (!mounted || generation != _vacancyLoadGeneration) return;
      if (cached.cards.isNotEmpty) {
        setState(() => _vacancies = cached);
      }
      try {
        final next = await _vacancyService.load();
        if (!mounted || generation != _vacancyLoadGeneration) return;
        setState(() => _vacancies = next);
      } catch (error) {
        debugPrint('[info] vacancies load failed: $error');
        if (!mounted || generation != _vacancyLoadGeneration) return;
        if (_vacancies.cards.isNotEmpty) {
          setState(
            () => _vacancies = VacancyLoadResult(
              cards: _vacancies.cards,
              loadError: true,
            ),
          );
        } else {
          setState(
            () => _vacancies = const VacancyLoadResult(loadError: true),
          );
        }
      }
    } finally {
      _vacancyLoadInFlight = false;
    }
  }

  Future<void> _loadReference() async {
    if (_referenceLoadInFlight) return;
    final generation = ++_referenceLoadGeneration;
    _referenceLoadInFlight = true;
    try {
      final cached = await _referenceService.loadCached();
      if (!mounted || generation != _referenceLoadGeneration) return;
      if (cached.bundle != null && cached.bundle!.articles.isNotEmpty) {
        setState(() => _reference = cached);
      }
      try {
        final next = await _referenceService.load();
        if (!mounted || generation != _referenceLoadGeneration) return;
        setState(() => _reference = next);
      } catch (error) {
        debugPrint('[info] reference load failed: $error');
        if (!mounted || generation != _referenceLoadGeneration) return;
        if (_reference.bundle != null &&
            _reference.bundle!.articles.isNotEmpty) {
          setState(
            () => _reference = ReferenceLoadResult(
              bundle: _reference.bundle,
              loadError: true,
            ),
          );
        } else {
          setState(
            () => _reference = const ReferenceLoadResult(loadError: true),
          );
        }
      }
    } finally {
      _referenceLoadInFlight = false;
    }
  }

  @override
  void dispose() {
    InfoSubjectsCache.revision.removeListener(_onSubjectsCacheInvalidated);
    InfoSubjectsCache.detachMemoryClear(clearMemoryCache);
    super.dispose();
  }

  void _onSubjectsCacheInvalidated() {
    if (!mounted) return;
    // Patch under the subject route, then confirm from RPC without jank on pop.
    _applyOptimisticVotePatch();
    unawaited(_reloadQuietly());
  }

  void _publishState(InfoPlanState state) {
    _latestState = state;
    _future = Future<InfoPlanState>.value(state);
  }

  void _commitState(InfoPlanState state) {
    _publishState(state);
    if (_isCoveredByRoute) {
      // Defer FutureBuilder rebuild until subject route is popped.
      _needsRevealAfterCover = true;
      return;
    }
    setState(() {});
  }

  void _applyOptimisticVotePatch() {
    final pending = InfoSubjectsCache.takePendingVote();
    final current = _latestState;
    if (pending == null || current == null) return;

    final avg = pending.effectiveDifficulty;
    final subjects = current.subjects.map((subject) {
      if (subject.id != pending.subjectOfferingId) return subject;
      final nextGlobal =
          avg != null && avg > 0 ? avg : subject.avgDifficultyGlobal;
      final nextLocal =
          avg != null && avg > 0 ? 0.0 : subject.avgDifficultyLocal;
      return UsefulSubject(
        id: subject.id,
        title: subject.title,
        subjectId: subject.subjectId,
        groupId: subject.groupId,
        semesterNumber: subject.semesterNumber,
        controlForm: subject.controlForm,
        description: subject.description,
        teacherName: subject.teacherName,
        teamId: subject.teamId,
        teamName: subject.teamName,
        teamIcon: subject.teamIcon,
        teamGroupName: subject.teamGroupName,
        chatId: subject.chatId,
        avgDifficultyGlobal: nextGlobal,
        avgDifficultyLocal: nextLocal,
        votesCountGlobal:
            avg != null && avg > 0 && subject.votesCountGlobal <= 0
                ? 1
                : subject.votesCountGlobal,
        votesCountLocal: subject.votesCountLocal,
      );
    }).toList(growable: false);

    _commitState(
      InfoPlanState(
        contextData: current.contextData,
        subjects: subjects,
        warning: current.warning,
      ),
    );
  }

  Future<void> _reloadQuietly() {
    if (_reloadInFlight != null) return _reloadInFlight!;

    late final Future<void> future;
    future = () async {
      try {
        final fresh = await _loadFreshAndCache();
        if (!mounted) return;
        if (_sameDifficultySnapshot(_latestState, fresh)) {
          _latestState = fresh;
          return;
        }
        _commitState(fresh);
      } catch (_) {
        // Keep last-good data on screen.
      }
    }()
        .whenComplete(() {
      if (identical(_reloadInFlight, future)) {
        _reloadInFlight = null;
      }
    });
    _reloadInFlight = future;
    return future;
  }

  Future<void> _openSubjectAndRefresh(UsefulSubject item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => subjectInfoScreenFor(item),
      ),
    );
    if (!mounted) return;

    // One calm reveal after pop if a vote/update landed while covered.
    // No awaited network reload — that was the source of the list jump.
    if (_needsRevealAfterCover) {
      _needsRevealAfterCover = false;
      final latest = _latestState;
      if (latest != null) {
        setState(() => _publishState(latest));
      }
    }
    unawaited(_reloadQuietly());
  }

  bool _sameDifficultySnapshot(InfoPlanState? a, InfoPlanState? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.subjects.length != b.subjects.length) return false;
    if (a.contextData.currentSemesterNumber !=
        b.contextData.currentSemesterNumber) {
      return false;
    }
    for (var i = 0; i < a.subjects.length; i++) {
      final left = a.subjects[i];
      final right = b.subjects[i];
      if (left.id != right.id) return false;
      if (left.avgDifficultyGlobal != right.avgDifficultyGlobal) return false;
      if (left.avgDifficultyLocal != right.avgDifficultyLocal) return false;
      if (left.votesCountGlobal != right.votesCountGlobal) return false;
      if (left.votesCountLocal != right.votesCountLocal) return false;
    }
    return true;
  }

  Future<InfoPlanState> _loadFresh() async {
    if (widget.planLoader != null) {
      return widget.planLoader!();
    }

    final contextData = await _academicContextService.loadFresh();
    final groupId = contextData.groupId;

    if (groupId == null) {
      return InfoPlanState(
        contextData: contextData,
        subjects: const [],
        warning: contextData.loadWarning ?? 'Учебный контекст не найден',
      );
    }

    final subjects = await _subjectsRepository.load(groupId: groupId);

    return InfoPlanState(
      contextData: contextData,
      subjects: subjects,
    );
  }

  Future<InfoPlanState> _loadWithCache() async {
    final cached = await _readCachedPlan();
    if (cached != null) {
      _latestState = cached;
      _refreshSilently();
      return cached;
    }
    return _loadFreshAndCache();
  }

  Future<InfoPlanState> _loadFreshAndCache() async {
    final fresh = await _loadFresh();
    _latestState = fresh;
    if (fresh.warning == null) await _saveCachedPlan(fresh);
    return fresh;
  }

  void _refreshSilently() {
    _loadFreshAndCache().then((fresh) {
      if (!mounted) return;
      setState(() => _publishState(fresh));
    }, onError: (_) {
      // Keep last-good cache already shown on screen.
    });
  }

  String? get _cacheUserId {
    final debugUserId = widget.debugUserId?.trim() ?? '';
    if (debugUserId.isNotEmpty) return debugUserId;
    return Supabase.instance.client.auth.currentUser?.id;
  }

  InfoPlanState? _peekMemoryCache() {
    final userId = _cacheUserId ?? '';
    if (userId.isEmpty) return null;
    return _memoryCache[_infoCacheKey(userId)];
  }

  Future<InfoPlanState?> _readCachedPlan() async {
    final userId = _cacheUserId ?? '';
    if (userId.isEmpty) return null;
    final key = _infoCacheKey(userId);
    final memory = _memoryCache[key];
    if (memory != null) return memory;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final plan = _planFromJson(Map<String, dynamic>.from(decoded));
      _memoryCache[key] = plan;
      return plan;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCachedPlan(InfoPlanState state) async {
    final userId = _cacheUserId ?? state.contextData.userId ?? '';
    if (userId.isEmpty) return;
    final key = _infoCacheKey(userId);
    _memoryCache[key] = state;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(_planToJson(state)));
    } catch (_) {}
  }

  /// Cache schema v3 includes difficulty / vote counts. Old v2 JSON is ignored
  /// so missing fields cannot surface as a fake `0 / 5`.
  String _infoCacheKey(String userId) => InfoSubjectsCache.prefsKey(userId);

  Map<String, dynamic> _planToJson(InfoPlanState state) => {
        'contextData': _academicContextToJson(state.contextData),
        'subjects': state.subjects.map((subject) => subject.toJson()).toList(),
        'warning': state.warning,
      };

  InfoPlanState _planFromJson(Map<String, dynamic> json) {
    return InfoPlanState(
      contextData: _academicContextFromJson(_mapFrom(json['contextData'])),
      subjects:
          _listFrom(json['subjects']).map(UsefulSubject.fromJson).toList(),
      warning: _nullIfEmpty(json['warning']),
    );
  }

  Map<String, dynamic> _academicContextToJson(AcademicContext context) => {
        'userId': context.userId,
        'publicUserId': context.publicUserId,
        'recordBookNumber': context.recordBookNumber,
        'activeEnrollmentId': context.activeEnrollmentId,
        'groupId': context.groupId,
        'groupName': context.groupName,
        'currentSemesterNumber': context.currentSemesterNumber,
        'academicYearId': context.academicYearId,
        'academicTermId': context.academicTermId,
        'hasActiveEnrollment': context.hasActiveEnrollment,
        'loadWarning': context.loadWarning,
      };

  AcademicContext _academicContextFromJson(Map<String, dynamic> json) {
    return AcademicContext(
      userId: _nullIfEmpty(json['userId']),
      publicUserId: _nullIfEmpty(json['publicUserId']),
      recordBookNumber: _nullIfEmpty(json['recordBookNumber']),
      activeEnrollmentId: _nullIfEmpty(json['activeEnrollmentId']),
      groupId: _nullIfEmpty(json['groupId']),
      groupName: _nullIfEmpty(json['groupName']),
      currentSemesterNumber: _intOrNull(json['currentSemesterNumber']),
      academicYearId: _nullIfEmpty(json['academicYearId']),
      academicTermId: _nullIfEmpty(json['academicTermId']),
      hasActiveEnrollment: json['hasActiveEnrollment'] == true,
      loadWarning: _nullIfEmpty(json['loadWarning']),
    );
  }

  Map<String, dynamic> _mapFrom(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  List<Map<String, dynamic>> _listFrom(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  int? _intOrNull(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  String? _nullIfEmpty(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final headerHeight =
        (MediaQuery.paddingOf(context).top + 86.0).clamp(128.0, 150.0);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7FB),
      body: FutureBuilder<InfoPlanState>(
        future: _future,
        builder: (context, snapshot) {
          final state = snapshot.data;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: headerHeight,
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
    AsyncSnapshot<InfoPlanState> snapshot,
    InfoPlanState? state,
  ) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_section == _UsefulSection.help) {
      return _PullSearchHost(
        key: const ValueKey('help-search'),
        hintText: 'Найти в справочнике…',
        builder: (context, query) => [
          _HelpSection(
            query: query,
            reference: _reference,
            referenceService: _referenceService,
            onRefresh: _loadReference,
          ),
        ],
      );
    }

    if (_section == _UsefulSection.jobs) {
      return _PullSearchHost(
        key: const ValueKey('jobs-search'),
        hintText: 'Найти вакансию, компанию, тег…',
        builder: (context, query) => [
          _JobsSection(
            query: query,
            vacancies: _vacancies,
            onRefresh: _loadVacancies,
            submissionService: _vacancySubmissionService,
            vacancyService: _vacancyService,
            vacancyMediaService: _vacancyMediaService,
          ),
        ],
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
        setState(() => _future = _loadFreshAndCache());
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
            InfoAcademicContextStrip(
              contextData: state.contextData,
              sessionDifficulty: SessionDifficultySummary.fromSubjects(
                currentSemesterNumber: state.contextData.currentSemesterNumber,
                subjects: state.subjects.map(
                  (item) => (
                    semesterNumber: item.semesterNumber,
                    difficulty: item.difficulty,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _SemesterSubjectsSection(
              semester: selectedSemester,
              currentSemester: currentSemester,
              semesters: semesters,
              selectedFilter: _filter,
              subjects: visibleSubjects,
              collapsedGroups: effectiveCollapsedControlGroups,
              onSubjectOpen: _openSubjectAndRefresh,
              onSortApplied: (semester, filter) {
                setState(() {
                  if (semester != null) {
                    _selectedSemester = semester;
                  }
                  _filter = filter;
                  _controlGroupsTouched = false;
                  _collapsedControlGroups.clear();
                });
              },
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

  bool _matchesFilter(UsefulSubject item, _UsefulFilter filter) {
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
    if (selected == _UsefulSection.help) {
      unawaited(_loadReference());
    } else if (selected == _UsefulSection.jobs) {
      unawaited(_loadVacancies());
    }
  }

  void _showInfoSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.78;
        final bottom = MediaQuery.paddingOf(sheetContext).bottom;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(18, 4, 18, 20 + bottom),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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

Map<String, List<UsefulSubject>> _groupSubjectsByControl(
  List<UsefulSubject> subjects,
) {
  final grouped = <String, List<UsefulSubject>>{};
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

class InfoPlanState {
  final AcademicContext contextData;
  final List<UsefulSubject> subjects;
  final String? warning;

  const InfoPlanState({
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
    final compact = MediaQuery.sizeOf(context).height < 760;
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
              padding: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, 6),
              child: Align(
                alignment: Alignment(-1, compact ? 0.08 : 0.18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: EdgeInsets.all(compact ? 10 : 12),
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
                        size: compact ? 26 : 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'База',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontSize: compact ? 30 : null,
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
                          SizedBox(height: compact ? 2 : 4),
                          Text(
                            _sectionSubtitle(selectedSection),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: (compact
                                    ? theme.textTheme.bodySmall
                                    : theme.textTheme.bodyMedium)
                                ?.copyWith(
                              color: Colors.black.withValues(alpha: 0.64),
                              height: 1.12,
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

/// Public context strip used by Info tab (exported for focused widget tests).
class InfoAcademicContextStrip extends StatelessWidget {
  final AcademicContext contextData;
  final SessionDifficultySummary sessionDifficulty;

  const InfoAcademicContextStrip({
    super.key,
    required this.contextData,
    required this.sessionDifficulty,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groupName = contextData.groupName ?? 'Группа не указана';
    final recordBookNumber = contextData.recordBookNumber;

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
              Expanded(
                child: _ContextPill(
                  icon: Icons.groups_2_outlined,
                  label: 'Группа',
                  text: groupName,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ContextPill(
                  icon: Icons.confirmation_number_outlined,
                  label: '№ зачётки',
                  text: recordBookNumber == null
                      ? 'не указана'
                      : recordBookNumber,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SessionDifficultyMeter(summary: sessionDifficulty),
          // Stage 13.9: group chat entry lives only in «Обучение», not in Info.
        ],
      ),
    );
  }
}

class _SessionDifficultyMeter extends StatelessWidget {
  final SessionDifficultySummary summary;

  const _SessionDifficultyMeter({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final hasRatings = summary.hasRatings;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.90),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            hasRatings
                ? Icons.local_fire_department_rounded
                : Icons.thermostat_outlined,
            color: accent,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Сложность сессии',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.black45,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  summary.valueLabel,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.black87,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
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
        border: Border.all(
          color: Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.black87,
                    fontWeight: FontWeight.w900,
                    height: 1,
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

class _SemesterSubjectsSection extends StatelessWidget {
  final int? semester;
  final int? currentSemester;
  final List<int> semesters;
  final _UsefulFilter selectedFilter;
  final List<UsefulSubject> subjects;
  final Set<String> collapsedGroups;
  final ValueChanged<UsefulSubject> onSubjectOpen;
  final void Function(int? semester, _UsefulFilter filter) onSortApplied;
  final ValueChanged<String> onGroupTap;

  const _SemesterSubjectsSection({
    required this.semester,
    required this.currentSemester,
    required this.semesters,
    required this.selectedFilter,
    required this.subjects,
    required this.collapsedGroups,
    required this.onSubjectOpen,
    required this.onSortApplied,
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
          InkWell(
            onTap: semesters.isEmpty
                ? null
                : () => _showSubjectsSortSheet(context),
            borderRadius: BorderRadius.circular(16),
            child: Row(
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
                        style: const TextStyle(
                            color: Colors.black54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (semesters.isNotEmpty)
                  TextButton(
                    onPressed: () => _showSubjectsSortSheet(context),
                    child: const Text('Изменить'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (subjects.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 8, 4, 16),
              child: _EmptyState(
                text: 'В этом фильтре предметы не найдены',
                compact: true,
              ),
            )
          else
            for (final entry in grouped.entries) ...[
              _ControlGroupBlock(
                label: entry.key,
                subjects: entry.value,
                collapsed: collapsedGroups.contains(entry.key),
                onTap: () => onGroupTap(entry.key),
                onSubjectOpen: onSubjectOpen,
              ),
              const SizedBox(height: 6),
            ],
        ],
      ),
    );
  }

  Future<void> _showSubjectsSortSheet(BuildContext context) async {
    var draftSemester = semester;
    var draftFilter = selectedFilter;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Предметы семестра',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    color: Colors.black,
                                    fontWeight: FontWeight.w900,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Выберите семестр и тип контроля',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Colors.black54,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Семестр',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w900,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        ...semesters.map(
                          (value) => _ChoiceSheetTile(
                            title: 'Семестр $value',
                            subtitle:
                                value == currentSemester ? 'текущий' : null,
                            selected: value == draftSemester,
                            onTap: () {
                              setSheetState(() => draftSemester = value);
                            },
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Тип',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w900,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        ..._UsefulFilter.values.map(
                          (filter) => _ChoiceSheetTile(
                            title: _filterLabel(filter),
                            selected: filter == draftFilter,
                            onTap: () {
                              setSheetState(() => draftFilter = filter);
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                              final semesterChanged = draftSemester != null &&
                                  draftSemester != semester;
                              final filterChanged =
                                  draftFilter != selectedFilter;
                              if (semesterChanged || filterChanged) {
                                onSortApplied(
                                  semesterChanged ? draftSemester : null,
                                  draftFilter,
                                );
                              }
                            },
                            child: const Text('Готово'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ControlGroupBlock extends StatelessWidget {
  final String label;
  final List<UsefulSubject> subjects;
  final bool collapsed;
  final VoidCallback onTap;
  final ValueChanged<UsefulSubject> onSubjectOpen;

  const _ControlGroupBlock({
    required this.label,
    required this.subjects,
    required this.collapsed,
    required this.onTap,
    required this.onSubjectOpen,
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
          for (final subject in subjects)
            InfoSubjectCard(
              item: subject,
              onOpen: onSubjectOpen,
            ),
      ],
    );
  }
}

typedef _SearchChildrenBuilder = List<Widget> Function(
  BuildContext context,
  String query,
);

class _PullSearchHost extends StatefulWidget {
  final String hintText;
  final _SearchChildrenBuilder builder;

  const _PullSearchHost({
    super.key,
    required this.hintText,
    required this.builder,
  });

  @override
  State<_PullSearchHost> createState() => _PullSearchHostState();
}

class _PullSearchHostState extends State<_PullSearchHost>
    with SingleTickerProviderStateMixin {
  static const _openThreshold = 44.0;
  static const _closeScrollThreshold = 28.0;

  final _field = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  late final AnimationController _anim;
  String _query = '';
  bool _revealed = false;
  double _pull = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _field.addListener(() {
      final next = _field.text.trim();
      if (next == _query) return;
      setState(() => _query = next);
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    _scroll.dispose();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _openSearch() async {
    if (_revealed) return;
    setState(() {
      _revealed = true;
      _pull = 0;
    });
    await _anim.forward();
    // Don't autofocus: keyboard only after an intentional tap on the field.
  }

  Future<void> _closeSearch() async {
    if (!_revealed) return;
    FocusScope.of(context).unfocus();
    _field.clear();
    setState(() {
      _query = '';
      _pull = 0;
    });
    await _anim.reverse();
    if (!mounted) return;
    setState(() => _revealed = false);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;

    // Open search only on a direct finger pull-down at the top.
    // Ignore inertial bounce after scrolling up from below.
    if (notification is OverscrollNotification) {
      final dragging = notification.dragDetails != null;
      if (!_revealed &&
          dragging &&
          notification.overscroll < 0 &&
          notification.metrics.pixels <= 0) {
        final next = (_pull + (-notification.overscroll) * 0.55)
            .clamp(0.0, _openThreshold + 24);
        if (next != _pull) setState(() => _pull = next);
        if (next >= _openThreshold) {
          _openSearch();
        }
      }
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      final pixels = notification.metrics.pixels;
      final delta = notification.scrollDelta ?? 0;
      final dragging = notification.dragDetails != null;

      if (!_revealed) {
        if (dragging && pixels < 0) {
          // Direct finger pull at the top only.
          final next = (-pixels).clamp(0.0, _openThreshold + 24);
          if (next != _pull) setState(() => _pull = next);
          if (next >= _openThreshold) _openSearch();
        } else if (_pull > 0 && pixels >= 0) {
          // Settled back to content — clear leftover pull progress.
          setState(() => _pull = 0);
        }
        // Inertial bounce (pixels < 0, not dragging): ignore completely.
      } else if (_query.isEmpty &&
          pixels > _closeScrollThreshold &&
          delta > 0) {
        _closeSearch();
      }
    }

    if (notification is ScrollEndNotification && !_revealed && _pull > 0) {
      // _pull is only accumulated while dragging, so a high value here
      // means a deliberate pull-down, not an inertial top bounce.
      if (_pull >= _openThreshold * 0.72) {
        _openSearch();
      } else {
        setState(() => _pull = 0);
      }
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final pullT = (_pull / _openThreshold).clamp(0.0, 1.0);
    final showHint = !_revealed && pullT > 0.02;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizeTransition(
          sizeFactor: _anim,
          axis: Axis.vertical,
          alignment: Alignment.topCenter,
          child: TapRegion(
            onTapOutside: (_) {
              if (_revealed) _closeSearch();
            },
            child: _FancySearchPanel(
              controller: _field,
              focusNode: _focus,
              hintText: widget.hintText,
              onClose: _closeSearch,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
            ),
          ),
        ),
        if (showHint) _PullSearchHint(progress: pullT),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _revealed ? _closeSearch : null,
              child: ListView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: widget.builder(context, _query),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PullSearchHint extends StatelessWidget {
  final double progress;

  const _PullSearchHint({required this.progress});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final opacity = Curves.easeOut.transform(progress.clamp(0.0, 1.0));
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.only(
          top: 2 + 6 * progress,
          bottom: 1,
        ),
        child: Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, -6 * (1 - progress)),
            child: Column(
              children: [
                Container(
                  width: 28 + 8 * progress,
                  height: 3,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: LinearGradient(
                      colors: [
                        primary.withValues(alpha: 0.25),
                        primary.withValues(alpha: 0.85),
                        const Color(0xFF8E6BE8).withValues(alpha: 0.85),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: primary.withValues(alpha: 0.22 * progress),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  progress >= 0.95
                      ? 'Отпусти для поиска'
                      : 'Потяни вниз для поиска',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: primary.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.15,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FancySearchPanel extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final VoidCallback onClose;
  final ValueChanged<String>? onSubmitted;

  const _FancySearchPanel({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onClose,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v < -220) onClose();
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.94),
                    primary.withValues(alpha: 0.09),
                    const Color(0xFF8E6BE8).withValues(alpha: 0.11),
                  ],
                ),
                border: Border.all(
                  color: primary.withValues(alpha: 0.16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.12),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Positioned(
                    right: -14,
                    top: -16,
                    child: IgnorePointer(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: primary.withValues(alpha: 0.09),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(7, 6, 2, 6),
                    child: Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                primary.withValues(alpha: 0.95),
                                const Color(0xFF8E6BE8),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: primary.withValues(alpha: 0.22),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.search_rounded,
                            color: Colors.white,
                            size: 17,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            focusNode: focusNode,
                            textInputAction: TextInputAction.search,
                            onSubmitted: onSubmitted,
                            style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              height: 1.15,
                            ),
                            cursorColor: primary,
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: hintText,
                              hintStyle: TextStyle(
                                color: Colors.black.withValues(alpha: 0.38),
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                        ),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: controller,
                          builder: (_, value, __) {
                            Widget btn({
                              required String tooltip,
                              required VoidCallback onPressed,
                              required IconData icon,
                              double size = 18,
                            }) {
                              return IconButton(
                                tooltip: tooltip,
                                onPressed: onPressed,
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                icon: Icon(
                                  icon,
                                  size: size,
                                  color: Colors.black.withValues(alpha: 0.42),
                                ),
                              );
                            }

                            if (value.text.isEmpty) {
                              return btn(
                                tooltip: 'Закрыть',
                                onPressed: onClose,
                                icon: Icons.close_rounded,
                              );
                            }
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                btn(
                                  tooltip: 'Очистить',
                                  onPressed: controller.clear,
                                  icon: Icons.backspace_outlined,
                                  size: 16,
                                ),
                                btn(
                                  tooltip: 'Закрыть',
                                  onPressed: onClose,
                                  icon: Icons.close_rounded,
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HelpSummaryCard extends StatelessWidget {
  final bool showLegacyDemoBadge;

  const _HelpSummaryCard({this.showLegacyDemoBadge = false});

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
                  showLegacyDemoBadge
                      ? 'Пример — managed RPC ещё не применён'
                      : 'Доступы, документы, программы, карта и частые вопросы',
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
  final String query;
  final ReferenceLoadResult reference;
  final ReferenceService referenceService;
  final Future<void> Function() onRefresh;
  final ContentMediaService _mediaService;

  _HelpSection({
    this.query = '',
    required this.reference,
    required this.referenceService,
    required this.onRefresh,
    ContentMediaService? mediaService,
  }) : _mediaService = mediaService ?? ContentMediaService();

  @override
  Widget build(BuildContext context) {
    if (reference.hideReference) {
      return Column(
        children: [
          const _HelpSummaryCard(),
          const SizedBox(height: 12),
          const _EmptyState(
            text: 'Справочник пока пуст',
            compact: true,
          ),
        ],
      );
    }

    if (reference.showLoadError) {
      return Column(
        children: [
          const _HelpSummaryCard(),
          const SizedBox(height: 12),
          _EmptyState(
            text: 'Не удалось обновить справочник',
            compact: true,
            actionLabel: 'Повторить',
            onAction: () => unawaited(onRefresh()),
          ),
        ],
      );
    }

    final articles = reference.displayArticles
        .where((article) => article.matchesQuery(query))
        .toList();
    final groups = <String, List<ManagedReferenceArticle>>{};
    for (final article in articles) {
      groups.putIfAbsent(article.categoryTitle, () => []).add(article);
    }

    final showRpcBadge = reference.rpcUnavailable && reference.isDemoFallback;

    return Column(
      children: [
        _HelpSummaryCard(showLegacyDemoBadge: showRpcBadge),
        const SizedBox(height: 12),
        if (articles.isEmpty)
          const _EmptyState(
            text: 'По запросу ничего не найдено',
            compact: true,
          )
        else
          for (final entry in groups.entries)
            _HelpGroupSection(
              title: entry.key,
              cards: [
                for (final article in entry.value)
                  StudentReferenceArticleCard(
                    article: article,
                    showDemoBadge: reference.isDemoFallback ||
                        article.showDemoBadge,
                    onTap: () => _openArticle(context, article),
                  ),
              ],
            ),
      ],
    );
  }

  void _openArticle(BuildContext context, ManagedReferenceArticle article) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: StudentReferenceArticleDetail(
            article: article,
            showDemoBadge:
                reference.isDemoFallback || article.showDemoBadge,
            onReportError: article.isManaged
                ? () => _reportError(context, article)
                : null,
            onOpenAsset: article.isManaged
                ? (assetId) => _openAsset(context, assetId)
                : null,
            onOpenUrl: (url) => _openExternalUrl(context, url),
            onOpenCta: (cta) => _openCta(context, cta),
          ),
        ),
      ),
    );
  }

  Future<void> _openAsset(BuildContext context, String assetId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final download = await _mediaService.resolveDownload(assetId);
      if (!context.mounted) return;
      if (download == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Файл недоступен')),
        );
        return;
      }
      final mime = (download.mimeType ?? 'application/octet-stream').trim();
      final ext = mime.contains('png')
          ? 'png'
          : mime.contains('webp')
              ? 'webp'
              : mime.contains('pdf')
                  ? 'pdf'
                  : mime.contains('jpeg') || mime.contains('jpg')
                      ? 'jpg'
                      : 'bin';
      final fileName =
          'content_${assetId.replaceAll('-', '').substring(0, 8)}.$ext';
      if (kIsWeb) {
        await openSubjectAttachmentBytes(
          bytes: Uint8List(0),
          fileName: fileName,
          mimeType: mime,
          signedUrl: download.signedUrl,
        );
        return;
      }
      final bytes = await _mediaService.fetchBytes(assetId);
      if (!context.mounted) return;
      if (bytes == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Файл недоступен')),
        );
        return;
      }
      await openSubjectAttachmentBytes(
        bytes: bytes,
        fileName: fileName,
        mimeType: mime,
        signedUrl: download.signedUrl,
      );
    } catch (error) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось открыть файл: $error')),
      );
    }
  }

  Future<void> _openExternalUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ссылка недоступна')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть ссылку')),
      );
    }
  }

  Future<void> _openCta(BuildContext context, ReferenceArticleCta cta) async {
    final route = (cta.route ?? '').trim();
    if (route.startsWith('/')) {
      context.push(route);
      return;
    }
    final url = (cta.url ?? '').trim();
    if (url.isNotEmpty) {
      await _openExternalUrl(context, url);
    }
  }

  Future<void> _reportError(
    BuildContext context,
    ManagedReferenceArticle article,
  ) async {
    final note = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Сообщить об ошибке'),
          content: TextField(
            controller: controller,
            maxLines: 4,
            maxLength: 1000,
            decoration: const InputDecoration(
              hintText: 'Опишите, что не так в этой статье',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context, controller.text.trim());
              },
              child: const Text('Отправить'),
            ),
          ],
        );
      },
    );
    if (note == null || note.isEmpty || !context.mounted) return;
    try {
      await referenceService.submitCorrection(
        contentItemId: article.id,
        note: note,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сообщение отправлено модераторам')),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить: $error')),
      );
    }
  }
}

class _JobsSection extends StatelessWidget {
  final String query;
  final VacancyLoadResult vacancies;
  final Future<void> Function() onRefresh;
  final VacancySubmissionService submissionService;
  final VacancyService vacancyService;
  final VacancyMediaService vacancyMediaService;

  const _JobsSection({
    this.query = '',
    required this.vacancies,
    required this.onRefresh,
    required this.submissionService,
    required this.vacancyService,
    required this.vacancyMediaService,
  });

  @override
  Widget build(BuildContext context) {
    if (vacancies.hideVacancies) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _JobsHeroCard(submissionService: submissionService),
          const SizedBox(height: 12),
          const _JobBoardStats(),
          const SizedBox(height: 12),
          const _EmptyState(
            text: 'Вакансии пока пусты',
            compact: true,
          ),
        ],
      );
    }

    if (vacancies.showLoadError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _JobsHeroCard(submissionService: submissionService),
          const SizedBox(height: 12),
          const _JobBoardStats(),
          const SizedBox(height: 12),
          _EmptyState(
            text: 'Не удалось обновить вакансии',
            compact: true,
            actionLabel: 'Повторить',
            onAction: () => unawaited(onRefresh()),
          ),
        ],
      );
    }

    final cards = vacancies.displayCards
        .where((card) => card.matchesQuery(query))
        .toList();
    final showRpcBadge = vacancies.rpcUnavailable && vacancies.isDemoFallback;
    final activeCount = vacancies.displayCards.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _JobsHeroCard(
          showLegacyDemoBadge: showRpcBadge,
          submissionService: submissionService,
        ),
        const SizedBox(height: 12),
        _JobBoardStats(activeCount: activeCount),
        const SizedBox(height: 12),
        if (cards.isEmpty)
          const _EmptyState(
            text: 'По запросу ничего не найдено',
            compact: true,
          )
        else
          _JobsGroupSection(
            title: query.isEmpty ? 'Свежие предложения' : 'Результаты поиска',
            cards: cards,
            showDemoBadge: vacancies.isDemoFallback,
            vacancyService: vacancyService,
            vacancyMediaService: vacancyMediaService,
          ),
      ],
    );
  }
}

class _JobsHeroCard extends StatelessWidget {
  final bool showLegacyDemoBadge;
  final VacancySubmissionService submissionService;

  const _JobsHeroCard({
    this.showLegacyDemoBadge = false,
    required this.submissionService,
  });

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
            showLegacyDemoBadge
                ? 'Пример — managed RPC ещё не применён'
                : 'Здесь студенты смогут искать подработки, стажировки и проектные задачи. Публикацию и правила модерации подключим отдельным шагом.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.88),
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openProposeVacancy(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Предложить вакансию'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: primary,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openMyVacancySubmissions(context),
              icon: const Icon(Icons.inbox_outlined),
              label: const Text('Мои заявки'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white70),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openProposeVacancy(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ProposeVacancyScreen(
          submissionService: submissionService,
        ),
      ),
    );
  }

  void _openMyVacancySubmissions(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MyVacancySubmissionsScreen(
          submissionService: submissionService,
        ),
      ),
    );
  }
}

class _JobBoardStats extends StatelessWidget {
  final int? activeCount;

  const _JobBoardStats({this.activeCount});

  @override
  Widget build(BuildContext context) {
    final activeLabel = activeCount?.toString() ?? '3';
    return Row(
      children: [
        Expanded(
          child: _JobStatPill(
            icon: Icons.flash_on_rounded,
            title: activeLabel,
            subtitle: 'активные',
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
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
  final List<ManagedVacancyCard> cards;
  final bool showDemoBadge;
  final VacancyService vacancyService;
  final VacancyMediaService vacancyMediaService;

  const _JobsGroupSection({
    required this.title,
    required this.cards,
    required this.showDemoBadge,
    required this.vacancyService,
    required this.vacancyMediaService,
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
                  '${cards.length}',
                  style: const TextStyle(
                    color: Colors.black45,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          for (final card in cards)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: StudentVacancyCard(
                payload: card.payload,
                showDemoBadge: showDemoBadge || card.showDemoBadge,
                expiresLabel: vacancyExpiresLabel(card.expiresAt),
                hasContacts: card.hasContacts,
                onTap: () => _openVacancy(context, card, showDemoBadge),
              ),
            ),
        ],
      ),
    );
  }

  void _openVacancy(
    BuildContext context,
    ManagedVacancyCard card,
    bool sectionDemoFallback,
  ) {
    final isDemo = sectionDemoFallback || card.showDemoBadge;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: _fullWidthSheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: StudentVacancyDetailSheet(
            card: card,
            showDemoBadge: isDemo,
            onOpenExternalUrl: isDemo
                ? null
                : (url) async {
                    final uri = Uri.parse(url);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
            onRevealContacts: isDemo || !card.hasContacts
                ? null
                : () => vacancyService.fetchContacts(card.id),
            onOpenAsset: isDemo
                ? null
                : (assetId) async {
                    final url = await vacancyMediaService.openAsset(assetId);
                    if (url == null) return;
                    final uri = Uri.parse(url);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
            onReport: isDemo
                ? null
                : (reason, note) => vacancyService.reportVacancy(
                      vacancyId: card.id,
                      reason: reason,
                      note: note,
                    ),
          ),
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

/// Public subject card used by Info tab (exported for focused widget tests).
class InfoSubjectCard extends StatelessWidget {
  final UsefulSubject item;
  final ValueChanged<UsefulSubject>? onOpen;

  const InfoSubjectCard({
    super.key,
    required this.item,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controlText = item.controlForm.isEmpty
        ? 'Форма контроля уточняется'
        : item.controlForm;
    final accent = _controlAccent(controlText);

    return InkWell(
      onTap: () {
        if (onOpen != null) {
          onOpen!(item);
          return;
        }
        _openSubjectInfo(context, item);
      },
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
                _SubjectDifficultyPill(
                  difficulty: item.difficulty,
                  color: accent,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
SubjectInfoScreen subjectInfoScreenFor(UsefulSubject item) {
  return SubjectInfoScreen(
    title: item.title,
    subjectId: item.subjectId,
    subjectOfferingId: item.id,
    groupId: item.groupId,
    semesterNumber: item.semesterNumber,
  );
}

void _openSubjectInfo(BuildContext context, UsefulSubject item) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => subjectInfoScreenFor(item),
    ),
  );
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

class _SubjectDifficultyPill extends StatelessWidget {
  final SubjectDifficultySummary difficulty;
  final Color color;

  const _SubjectDifficultyPill({
    required this.difficulty,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final hasRating = difficulty.hasRating;
    final label = hasRating
        ? 'Сложность: ${difficulty.displayLabel}'
        : difficulty.displayLabel;

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
          Icon(
            hasRating
                ? Icons.local_fire_department_rounded
                : Icons.thermostat_outlined,
            color: color,
            size: 14,
          ),
          const SizedBox(width: 4),
          Text(
            label,
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
