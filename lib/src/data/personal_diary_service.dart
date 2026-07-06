import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'academic_context_service.dart';
import '../ui/schedule/subject_diary/subject_diary.dart';

class PersonalDiaryData {
  final AcademicContext academicContext;
  final List<int> availableSemesters;
  final int? selectedSemesterNumber;
  final List<PersonalDiarySubject> allSubjects;
  final List<PersonalDiarySubject> subjects;
  final List<PersonalDiaryLatestEntry> latestEntries;
  final List<PersonalDiaryAssignment> publishedAssignments;
  final List<PersonalDiaryAssignment> upcomingAssignments;
  final List<PersonalDiaryTask> personalTasks;
  final List<PersonalDiaryTask> upcomingPersonalTasks;
  final int totalEntries;
  final int totalFiles;
  final int totalAssignments;
  final int pendingAssignmentsCount;
  final int completedAssignmentsCount;
  final int personalTasksTotal;
  final int personalTasksActive;
  final int personalTasksDone;

  const PersonalDiaryData({
    required this.academicContext,
    required this.availableSemesters,
    required this.selectedSemesterNumber,
    required this.allSubjects,
    required this.subjects,
    required this.latestEntries,
    this.publishedAssignments = const [],
    this.upcomingAssignments = const [],
    this.personalTasks = const [],
    this.upcomingPersonalTasks = const [],
    required this.totalEntries,
    required this.totalFiles,
    this.totalAssignments = 0,
    this.pendingAssignmentsCount = 0,
    this.completedAssignmentsCount = 0,
    this.personalTasksTotal = 0,
    this.personalTasksActive = 0,
    this.personalTasksDone = 0,
  });
}

class PersonalDiarySubject {
  final String subjectOfferingId;
  final String subjectId;
  final String title;
  final String? groupId;
  final int? semesterNumber;
  final int entryCount;
  final int fileCount;
  final int assignmentCount;
  final int incompleteAssignmentCount;
  final int personalTaskCount;
  final int activePersonalTaskCount;
  final DateTime? latestEntryDate;
  final String? latestPreview;

  const PersonalDiarySubject({
    required this.subjectOfferingId,
    required this.subjectId,
    required this.title,
    this.groupId,
    this.semesterNumber,
    required this.entryCount,
    required this.fileCount,
    this.assignmentCount = 0,
    this.incompleteAssignmentCount = 0,
    this.personalTaskCount = 0,
    this.activePersonalTaskCount = 0,
    this.latestEntryDate,
    this.latestPreview,
  });

  SubjectDiaryArgs toDiaryArgs() {
    return SubjectDiaryArgs(
      subjectOfferingId: subjectOfferingId,
      subjectId: subjectId.isEmpty ? null : subjectId,
      subjectTitle: title,
      groupId: groupId,
      semesterNumber: semesterNumber,
      legacySubjectKey: title,
    );
  }
}

class PersonalDiaryAssignment {
  final String id;
  final String subjectOfferingId;
  final String subjectTitle;
  final String title;
  final String description;
  final DateTime? dueAt;
  final String? dueText;
  final String status;
  final bool completedByMe;
  final String? teamId;
  final String? messageId;
  final DateTime createdAt;
  final DateTime? publishedAt;

  const PersonalDiaryAssignment({
    required this.id,
    required this.subjectOfferingId,
    required this.subjectTitle,
    required this.title,
    required this.description,
    this.dueAt,
    this.dueText,
    required this.status,
    required this.completedByMe,
    this.teamId,
    this.messageId,
    required this.createdAt,
    this.publishedAt,
  });

  bool get isDone => completedByMe;
}

class PersonalDiaryTask {
  final String id;
  final String? subjectOfferingId;
  final String subjectTitle;
  final String title;
  final String? description;
  final DateTime? dueAt;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  const PersonalDiaryTask({
    required this.id,
    this.subjectOfferingId,
    required this.subjectTitle,
    required this.title,
    this.description,
    this.dueAt,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
  });

  bool get isDone => status == 'done';
  bool get isGeneral => (subjectOfferingId ?? '').trim().isEmpty;

  String get statusLabel {
    switch (status) {
      case 'in_progress':
        return 'В работе';
      case 'done':
        return 'Готово';
      case 'todo':
      default:
        return 'Нужно сделать';
    }
  }

  String get nextStatus {
    switch (status) {
      case 'todo':
        return 'in_progress';
      case 'in_progress':
        return 'done';
      case 'done':
      default:
        return 'todo';
    }
  }
}

class PersonalDiaryLatestEntry {
  final String id;
  final String subjectOfferingId;
  final String subjectTitle;
  final DateTime date;
  final String? preview;
  final int fileCount;

  const PersonalDiaryLatestEntry({
    required this.id,
    required this.subjectOfferingId,
    required this.subjectTitle,
    required this.date,
    this.preview,
    required this.fileCount,
  });
}

class PersonalDiaryService {
  PersonalDiaryService({SupabaseClient? client})
      : _sb = client ?? Supabase.instance.client,
        _academicContextService = AcademicContextService(client: client);

  final SupabaseClient _sb;
  final AcademicContextService _academicContextService;

  // In-memory (RAM) layer of the cache. Survives across screen re-creations
  // within one app session, so re-opening the diary tab is instant with no
  // loading spinner. The SharedPreferences layer keeps data across restarts.
  static final Map<String, PersonalDiaryData> _memoryCache = {};

  /// Synchronous peek into the RAM cache. Returns instantly (no await), so the
  /// UI can render cached data on the very first frame.
  PersonalDiaryData? peekCached({int? semesterNumber}) {
    final userId = _sb.auth.currentUser?.id ?? '';
    if (userId.isEmpty) return null;
    return _memoryCache[_cacheKey(userId, semesterNumber)];
  }

  Future<PersonalDiaryData?> loadCached({int? semesterNumber}) async {
    final userId = _sb.auth.currentUser?.id ?? '';
    if (userId.isEmpty) return null;
    final key = _cacheKey(userId, semesterNumber);
    final memory = _memoryCache[key];
    if (memory != null) return memory;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = _dataFromJson(Map<String, dynamic>.from(decoded));
      _memoryCache[key] = data;
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<PersonalDiaryData> loadAndCache({int? semesterNumber}) async {
    final data = await load(semesterNumber: semesterNumber);
    await saveCached(data, semesterNumber: semesterNumber);
    return data;
  }

  Future<void> saveCached(
    PersonalDiaryData data, {
    int? semesterNumber,
  }) async {
    final userId =
        _sb.auth.currentUser?.id ?? data.academicContext.userId ?? '';
    if (userId.isEmpty) return;
    final key = _cacheKey(userId, semesterNumber);
    _memoryCache[key] = data;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(_dataToJson(data)));
    } catch (_) {}
  }

  String _cacheKey(String userId, int? semesterNumber) =>
      'personal_diary_data_cache_v2_${userId}_${semesterNumber ?? 'auto'}';

  Future<PersonalDiaryData> load({int? semesterNumber}) async {
    final context = await _academicContextService.loadFresh();
    final userId = _sb.auth.currentUser?.id ?? context.userId ?? '';
    final groupId = context.groupId ?? '';
    final currentSemester = context.currentSemesterNumber;

    if (userId.isEmpty || groupId.isEmpty) {
      return _emptyData(
        context,
        selectedSemesterNumber: semesterNumber ?? currentSemester,
      );
    }

    final semesterRows = await _sb
        .from('subject_offerings')
        .select('id,display_name,subject_id,group_id,semester_number')
        .eq('group_id', groupId)
        .order('semester_number')
        .order('display_name');

    final allOfferingRows = (semesterRows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();

    final availableSemesters = allOfferingRows
        .map((row) => _asInt((row as Map)['semester_number']))
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();
    final selectedSemester = semesterNumber ??
        currentSemester ??
        (availableSemesters.isEmpty ? null : availableSemesters.first);

    if (selectedSemester == null) {
      return _emptyData(
        context,
        availableSemesters: availableSemesters,
      );
    }

    final offerings = allOfferingRows
        .where((row) => _asInt(row['semester_number']) == selectedSemester)
        .toList();
    final allSubjects = allOfferingRows.map(_subjectFromOffering).toList();
    final offeringIds = offerings
        .map((row) => (row['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    final offeringTitleById = <String, String>{
      for (final offering in allOfferingRows)
        (offering['id'] ?? '').toString():
            _cleanTitle(offering['display_name']),
    };

    final entriesByOffering = <String, List<Map<String, dynamic>>>{};
    final filesByEntry = <String, int>{};
    final assignmentsByOffering = <String, List<PersonalDiaryAssignment>>{};
    final tasksByOffering = <String, List<PersonalDiaryTask>>{};
    final messageIdByAssignment = <String, String>{};
    final doneByAssignment = <String, bool>{};
    var generalTasks = const <PersonalDiaryTask>[];

    if (offeringIds.isNotEmpty) {
      var entries = const <Map<String, dynamic>>[];
      try {
        final entryRows = await _sb
            .from('subject_diary_entries')
            .select(
              'id,subject_offering_id,entry_date,text,files_count,created_at',
            )
            .eq('author_id', userId)
            .inFilter('subject_offering_id', offeringIds)
            .order('entry_date', ascending: false)
            .order('created_at', ascending: false);

        entries = (entryRows as List)
            .map((row) => Map<String, dynamic>.from(row as Map))
            .where(_isRealEntry)
            .toList();
      } catch (_) {
        entries = const [];
      }

      final entryIds = entries
          .map((row) => (row['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();

      if (entryIds.isNotEmpty) {
        try {
          final fileRows = await _sb
              .from('subject_diary_files')
              .select('id,entry_id')
              .inFilter('entry_id', entryIds);
          for (final raw in fileRows as List) {
            final row = Map<String, dynamic>.from(raw as Map);
            final entryId = (row['entry_id'] ?? '').toString();
            if (entryId.isEmpty) continue;
            filesByEntry[entryId] = (filesByEntry[entryId] ?? 0) + 1;
          }
        } catch (_) {}
      }

      for (final entry in entries) {
        final offeringId = (entry['subject_offering_id'] ?? '').toString();
        if (offeringId.isEmpty) continue;
        (entriesByOffering[offeringId] ??= []).add(entry);
      }

      var rawAssignments = const <Map<String, dynamic>>[];
      try {
        final assignmentRows = await _sb
            .from('assignments')
            .select(
              'id,team_id,title,body,description,due_at,due_text,status,published_at,created_at,subject_offering_id',
            )
            .eq('status', 'published')
            .inFilter('subject_offering_id', offeringIds)
            .order('due_at', ascending: true, nullsFirst: false)
            .order('created_at', ascending: true);

        rawAssignments = (assignmentRows as List)
            .map((row) => Map<String, dynamic>.from(row as Map))
            .where((row) =>
                (row['subject_offering_id'] ?? '').toString().isNotEmpty)
            .toList();
      } catch (_) {
        rawAssignments = const [];
      }

      final assignmentIds = rawAssignments
          .map((row) => (row['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();

      if (assignmentIds.isNotEmpty) {
        try {
          final messageRows = await _sb
              .from('messages')
              .select('id,assignment_id')
              .inFilter('assignment_id', assignmentIds);
          for (final raw in messageRows as List) {
            final row = Map<String, dynamic>.from(raw as Map);
            final assignmentId = (row['assignment_id'] ?? '').toString();
            final messageId = (row['id'] ?? '').toString();
            if (assignmentId.isNotEmpty && messageId.isNotEmpty) {
              messageIdByAssignment[assignmentId] = messageId;
            }
          }
        } catch (_) {}

        try {
          final doneRows = await _sb
              .from('assignment_done')
              .select('assignment_id,done,done_at')
              .eq('user_id', userId)
              .inFilter('assignment_id', assignmentIds);
          for (final raw in doneRows as List) {
            final row = Map<String, dynamic>.from(raw as Map);
            final assignmentId = (row['assignment_id'] ?? '').toString();
            if (assignmentId.isEmpty) continue;
            doneByAssignment[assignmentId] = (row['done'] ?? false) == true;
          }
        } catch (_) {}
      }

      for (final row in rawAssignments) {
        final offeringId = (row['subject_offering_id'] ?? '').toString();
        if (offeringId.isEmpty) continue;
        final id = (row['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final assignment = PersonalDiaryAssignment(
          id: id,
          subjectOfferingId: offeringId,
          subjectTitle: offeringTitleById[offeringId] ?? 'Предмет',
          title: _cleanTitle(row['title']),
          description: _assignmentDescription(row),
          dueAt: _nullableDate(row['due_at']),
          dueText: _nullIfEmpty(row['due_text']),
          status: (row['status'] ?? 'published').toString(),
          completedByMe: doneByAssignment[id] == true,
          teamId: _nullIfEmpty(row['team_id']),
          messageId: messageIdByAssignment[id],
          createdAt: _nullableDate(row['created_at']) ?? DateTime.now(),
          publishedAt: _nullableDate(row['published_at']),
        );
        (assignmentsByOffering[offeringId] ??= []).add(assignment);
      }

      final personalTasks = await loadPersonalTasksForOfferings(
        offeringIds: offeringIds,
        includeGeneral: true,
        subjectTitleByOffering: offeringTitleById,
      );
      generalTasks = personalTasks.where((task) => task.isGeneral).toList();
      for (final task in personalTasks.where((task) => !task.isGeneral)) {
        final offeringId = task.subjectOfferingId ?? '';
        if (offeringId.isEmpty) continue;
        (tasksByOffering[offeringId] ??= []).add(task);
      }
    }

    final subjectTitleByOffering = <String, String>{};
    final subjects = <PersonalDiarySubject>[];
    for (final offering in offerings) {
      final id = (offering['id'] ?? '').toString();
      final title = _cleanTitle(offering['display_name']);
      subjectTitleByOffering[id] = title;
      final entries = entriesByOffering[id] ?? const <Map<String, dynamic>>[];
      final assignments =
          assignmentsByOffering[id] ?? const <PersonalDiaryAssignment>[];
      final tasks = tasksByOffering[id] ?? const <PersonalDiaryTask>[];
      final fileCount = entries.fold<int>(
        0,
        (sum, entry) =>
            sum + (filesByEntry[(entry['id'] ?? '').toString()] ?? 0),
      );
      final latest = entries.isEmpty ? null : entries.first;
      subjects.add(
        PersonalDiarySubject(
          subjectOfferingId: id,
          subjectId: (offering['subject_id'] ?? '').toString(),
          title: title,
          groupId: (offering['group_id'] ?? '').toString(),
          semesterNumber: _asInt(offering['semester_number']),
          entryCount: entries.length,
          fileCount: fileCount,
          assignmentCount: assignments.length,
          incompleteAssignmentCount: assignments
              .where((assignment) => !assignment.completedByMe)
              .length,
          personalTaskCount: tasks.length,
          activePersonalTaskCount: tasks.where((task) => !task.isDone).length,
          latestEntryDate:
              latest == null ? null : _parseDate(latest['entry_date']),
          latestPreview: latest == null ? null : _preview(latest['text']),
        ),
      );
    }

    final latestEntries = entriesByOffering.entries
        .expand((bucket) => bucket.value.map((entry) {
              final entryId = (entry['id'] ?? '').toString();
              final offeringId =
                  (entry['subject_offering_id'] ?? '').toString();
              return PersonalDiaryLatestEntry(
                id: entryId,
                subjectOfferingId: offeringId,
                subjectTitle: subjectTitleByOffering[offeringId] ?? 'Предмет',
                date: _parseDate(entry['entry_date']),
                preview: _preview(entry['text']),
                fileCount: filesByEntry[entryId] ?? 0,
              );
            }))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    final limitedLatest = latestEntries.take(10).toList();
    final publishedAssignments = assignmentsByOffering.values
        .expand((items) => items)
        .toList()
      ..sort(_compareAssignments);
    final upcomingAssignments = publishedAssignments.take(5).toList();
    final personalTasks = [
      ...tasksByOffering.values.expand((items) => items),
      ...generalTasks,
    ]..sort(_compareTasks);
    final upcomingPersonalTasks = personalTasks.take(5).toList();
    final totalEntries = subjects.fold<int>(0, (sum, s) => sum + s.entryCount);
    final totalFiles = subjects.fold<int>(0, (sum, s) => sum + s.fileCount);
    final totalAssignments = publishedAssignments.length;
    final completedAssignmentsCount = publishedAssignments
        .where((assignment) => assignment.completedByMe)
        .length;
    final pendingAssignmentsCount =
        totalAssignments - completedAssignmentsCount;
    final personalTasksTotal = personalTasks.length;
    final personalTasksDone = personalTasks.where((task) => task.isDone).length;
    final personalTasksActive = personalTasksTotal - personalTasksDone;

    return PersonalDiaryData(
      academicContext: context,
      availableSemesters: availableSemesters,
      selectedSemesterNumber: selectedSemester,
      allSubjects: allSubjects,
      subjects: subjects,
      latestEntries: limitedLatest,
      publishedAssignments: publishedAssignments,
      upcomingAssignments: upcomingAssignments,
      personalTasks: personalTasks,
      upcomingPersonalTasks: upcomingPersonalTasks,
      totalEntries: totalEntries,
      totalFiles: totalFiles,
      totalAssignments: totalAssignments,
      pendingAssignmentsCount: pendingAssignmentsCount,
      completedAssignmentsCount: completedAssignmentsCount,
      personalTasksTotal: personalTasksTotal,
      personalTasksActive: personalTasksActive,
      personalTasksDone: personalTasksDone,
    );
  }

  PersonalDiaryData _emptyData(
    AcademicContext context, {
    List<int> availableSemesters = const [],
    int? selectedSemesterNumber,
  }) {
    return PersonalDiaryData(
      academicContext: context,
      availableSemesters: availableSemesters,
      selectedSemesterNumber: selectedSemesterNumber,
      allSubjects: const [],
      subjects: const [],
      latestEntries: const [],
      publishedAssignments: const [],
      upcomingAssignments: const [],
      personalTasks: const [],
      upcomingPersonalTasks: const [],
      totalEntries: 0,
      totalFiles: 0,
      totalAssignments: 0,
      pendingAssignmentsCount: 0,
      completedAssignmentsCount: 0,
      personalTasksTotal: 0,
      personalTasksActive: 0,
      personalTasksDone: 0,
    );
  }

  Map<String, dynamic> _dataToJson(PersonalDiaryData data) => {
        'academicContext': _academicContextToJson(data.academicContext),
        'availableSemesters': data.availableSemesters,
        'selectedSemesterNumber': data.selectedSemesterNumber,
        'allSubjects': data.allSubjects.map(_subjectToJson).toList(),
        'subjects': data.subjects.map(_subjectToJson).toList(),
        'latestEntries': data.latestEntries.map(_latestEntryToJson).toList(),
        'publishedAssignments':
            data.publishedAssignments.map(_assignmentToJson).toList(),
        'upcomingAssignments':
            data.upcomingAssignments.map(_assignmentToJson).toList(),
        'personalTasks': data.personalTasks.map(_taskToJson).toList(),
        'upcomingPersonalTasks':
            data.upcomingPersonalTasks.map(_taskToJson).toList(),
        'totalEntries': data.totalEntries,
        'totalFiles': data.totalFiles,
        'totalAssignments': data.totalAssignments,
        'pendingAssignmentsCount': data.pendingAssignmentsCount,
        'completedAssignmentsCount': data.completedAssignmentsCount,
        'personalTasksTotal': data.personalTasksTotal,
        'personalTasksActive': data.personalTasksActive,
        'personalTasksDone': data.personalTasksDone,
      };

  PersonalDiaryData _dataFromJson(Map<String, dynamic> json) {
    return PersonalDiaryData(
      academicContext: _academicContextFromJson(
        _mapFrom(json['academicContext']),
      ),
      availableSemesters: _intListFrom(json['availableSemesters']),
      selectedSemesterNumber: _asInt(json['selectedSemesterNumber']),
      allSubjects:
          _listFrom(json['allSubjects']).map(_subjectFromJson).toList(),
      subjects: _listFrom(json['subjects']).map(_subjectFromJson).toList(),
      latestEntries:
          _listFrom(json['latestEntries']).map(_latestEntryFromJson).toList(),
      publishedAssignments: _listFrom(json['publishedAssignments'])
          .map(_assignmentFromJson)
          .toList(),
      upcomingAssignments: _listFrom(json['upcomingAssignments'])
          .map(_assignmentFromJson)
          .toList(),
      personalTasks:
          _listFrom(json['personalTasks']).map(_taskFromJson).toList(),
      upcomingPersonalTasks:
          _listFrom(json['upcomingPersonalTasks']).map(_taskFromJson).toList(),
      totalEntries: _asInt(json['totalEntries']) ?? 0,
      totalFiles: _asInt(json['totalFiles']) ?? 0,
      totalAssignments: _asInt(json['totalAssignments']) ?? 0,
      pendingAssignmentsCount: _asInt(json['pendingAssignmentsCount']) ?? 0,
      completedAssignmentsCount: _asInt(json['completedAssignmentsCount']) ?? 0,
      personalTasksTotal: _asInt(json['personalTasksTotal']) ?? 0,
      personalTasksActive: _asInt(json['personalTasksActive']) ?? 0,
      personalTasksDone: _asInt(json['personalTasksDone']) ?? 0,
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
      currentSemesterNumber: _asInt(json['currentSemesterNumber']),
      academicYearId: _nullIfEmpty(json['academicYearId']),
      academicTermId: _nullIfEmpty(json['academicTermId']),
      hasActiveEnrollment: json['hasActiveEnrollment'] == true,
      loadWarning: _nullIfEmpty(json['loadWarning']),
    );
  }

  Map<String, dynamic> _subjectToJson(PersonalDiarySubject subject) => {
        'subjectOfferingId': subject.subjectOfferingId,
        'subjectId': subject.subjectId,
        'title': subject.title,
        'groupId': subject.groupId,
        'semesterNumber': subject.semesterNumber,
        'entryCount': subject.entryCount,
        'fileCount': subject.fileCount,
        'assignmentCount': subject.assignmentCount,
        'incompleteAssignmentCount': subject.incompleteAssignmentCount,
        'personalTaskCount': subject.personalTaskCount,
        'activePersonalTaskCount': subject.activePersonalTaskCount,
        'latestEntryDate': subject.latestEntryDate?.toIso8601String(),
        'latestPreview': subject.latestPreview,
      };

  PersonalDiarySubject _subjectFromJson(Map<String, dynamic> json) {
    return PersonalDiarySubject(
      subjectOfferingId: (json['subjectOfferingId'] ?? '').toString(),
      subjectId: (json['subjectId'] ?? '').toString(),
      title: _cleanTitle(json['title']),
      groupId: _nullIfEmpty(json['groupId']),
      semesterNumber: _asInt(json['semesterNumber']),
      entryCount: _asInt(json['entryCount']) ?? 0,
      fileCount: _asInt(json['fileCount']) ?? 0,
      assignmentCount: _asInt(json['assignmentCount']) ?? 0,
      incompleteAssignmentCount: _asInt(json['incompleteAssignmentCount']) ?? 0,
      personalTaskCount: _asInt(json['personalTaskCount']) ?? 0,
      activePersonalTaskCount: _asInt(json['activePersonalTaskCount']) ?? 0,
      latestEntryDate: _nullableDate(json['latestEntryDate']),
      latestPreview: _nullIfEmpty(json['latestPreview']),
    );
  }

  Map<String, dynamic> _assignmentToJson(PersonalDiaryAssignment assignment) =>
      {
        'id': assignment.id,
        'subjectOfferingId': assignment.subjectOfferingId,
        'subjectTitle': assignment.subjectTitle,
        'title': assignment.title,
        'description': assignment.description,
        'dueAt': assignment.dueAt?.toIso8601String(),
        'dueText': assignment.dueText,
        'status': assignment.status,
        'completedByMe': assignment.completedByMe,
        'teamId': assignment.teamId,
        'messageId': assignment.messageId,
        'createdAt': assignment.createdAt.toIso8601String(),
        'publishedAt': assignment.publishedAt?.toIso8601String(),
      };

  PersonalDiaryAssignment _assignmentFromJson(Map<String, dynamic> json) {
    return PersonalDiaryAssignment(
      id: (json['id'] ?? '').toString(),
      subjectOfferingId: (json['subjectOfferingId'] ?? '').toString(),
      subjectTitle: _cleanTitle(json['subjectTitle']),
      title: _cleanTitle(json['title']),
      description: (json['description'] ?? '').toString(),
      dueAt: _nullableDate(json['dueAt']),
      dueText: _nullIfEmpty(json['dueText']),
      status: (json['status'] ?? 'published').toString(),
      completedByMe: json['completedByMe'] == true,
      teamId: _nullIfEmpty(json['teamId']),
      messageId: _nullIfEmpty(json['messageId']),
      createdAt: _nullableDate(json['createdAt']) ?? DateTime.now(),
      publishedAt: _nullableDate(json['publishedAt']),
    );
  }

  Map<String, dynamic> _taskToJson(PersonalDiaryTask task) => {
        'id': task.id,
        'subjectOfferingId': task.subjectOfferingId,
        'subjectTitle': task.subjectTitle,
        'title': task.title,
        'description': task.description,
        'dueAt': task.dueAt?.toIso8601String(),
        'status': task.status,
        'createdAt': task.createdAt.toIso8601String(),
        'updatedAt': task.updatedAt.toIso8601String(),
        'completedAt': task.completedAt?.toIso8601String(),
      };

  PersonalDiaryTask _taskFromJson(Map<String, dynamic> json) {
    return PersonalDiaryTask(
      id: (json['id'] ?? '').toString(),
      subjectOfferingId: _nullIfEmpty(json['subjectOfferingId']),
      subjectTitle: _cleanTitle(json['subjectTitle']),
      title: (json['title'] ?? '').toString(),
      description: _nullIfEmpty(json['description']),
      dueAt: _nullableDate(json['dueAt']),
      status: (json['status'] ?? 'todo').toString(),
      createdAt: _nullableDate(json['createdAt']) ?? DateTime.now(),
      updatedAt: _nullableDate(json['updatedAt']) ?? DateTime.now(),
      completedAt: _nullableDate(json['completedAt']),
    );
  }

  Map<String, dynamic> _latestEntryToJson(PersonalDiaryLatestEntry entry) => {
        'id': entry.id,
        'subjectOfferingId': entry.subjectOfferingId,
        'subjectTitle': entry.subjectTitle,
        'date': entry.date.toIso8601String(),
        'preview': entry.preview,
        'fileCount': entry.fileCount,
      };

  PersonalDiaryLatestEntry _latestEntryFromJson(Map<String, dynamic> json) {
    return PersonalDiaryLatestEntry(
      id: (json['id'] ?? '').toString(),
      subjectOfferingId: (json['subjectOfferingId'] ?? '').toString(),
      subjectTitle: _cleanTitle(json['subjectTitle']),
      date: _nullableDate(json['date']) ?? DateTime.now(),
      preview: _nullIfEmpty(json['preview']),
      fileCount: _asInt(json['fileCount']) ?? 0,
    );
  }

  static Map<String, dynamic> _mapFrom(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  static List<Map<String, dynamic>> _listFrom(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  static List<int> _intListFrom(dynamic value) {
    if (value is! List) return const [];
    return value.map(_asInt).whereType<int>().toList();
  }

  Future<void> setAssignmentDone({
    required String assignmentId,
    required bool done,
  }) async {
    await _sb.rpc('set_assignment_done', params: {
      'p_assignment_id': assignmentId,
      'p_done': done,
    });
  }

  Future<List<PersonalDiaryAssignment>> loadPublishedAssignmentsForOffering({
    required String subjectOfferingId,
    String? subjectTitle,
  }) async {
    final userId = _sb.auth.currentUser?.id ?? '';
    if (userId.isEmpty || subjectOfferingId.trim().isEmpty) return const [];

    final rows = await _sb
        .from('assignments')
        .select(
          'id,team_id,title,body,description,due_at,due_text,status,published_at,created_at,subject_offering_id',
        )
        .eq('status', 'published')
        .eq('subject_offering_id', subjectOfferingId)
        .order('due_at', ascending: true, nullsFirst: false)
        .order('created_at', ascending: true);

    final rawAssignments = (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where(
            (row) => (row['subject_offering_id'] ?? '').toString().isNotEmpty)
        .toList();
    final ids = rawAssignments
        .map((row) => (row['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    final doneByAssignment = <String, bool>{};
    if (ids.isNotEmpty) {
      final doneRows = await _sb
          .from('assignment_done')
          .select('assignment_id,done')
          .eq('user_id', userId)
          .inFilter('assignment_id', ids);
      for (final raw in doneRows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = (row['assignment_id'] ?? '').toString();
        if (id.isNotEmpty)
          doneByAssignment[id] = (row['done'] ?? false) == true;
      }
    }

    final title = _cleanTitle(subjectTitle);
    return rawAssignments.map((row) {
      final id = (row['id'] ?? '').toString();
      return PersonalDiaryAssignment(
        id: id,
        subjectOfferingId: (row['subject_offering_id'] ?? '').toString(),
        subjectTitle: title,
        title: _cleanTitle(row['title']),
        description: _assignmentDescription(row),
        dueAt: _nullableDate(row['due_at']),
        dueText: _nullIfEmpty(row['due_text']),
        status: (row['status'] ?? 'published').toString(),
        completedByMe: doneByAssignment[id] == true,
        teamId: _nullIfEmpty(row['team_id']),
        createdAt: _nullableDate(row['created_at']) ?? DateTime.now(),
        publishedAt: _nullableDate(row['published_at']),
      );
    }).toList()
      ..sort(_compareAssignments);
  }

  Future<List<PersonalDiaryTask>> loadPersonalTasksForOfferings({
    required List<String> offeringIds,
    bool includeGeneral = false,
    Map<String, String> subjectTitleByOffering = const {},
  }) async {
    final userId = _sb.auth.currentUser?.id ?? '';
    if (userId.isEmpty) return const [];

    final rows = <Map<String, dynamic>>[];
    final cleanOfferingIds = offeringIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();

    if (cleanOfferingIds.isNotEmpty) {
      try {
        final subjectRows = await _sb
            .from('personal_diary_tasks')
            .select(
              'id,author_id,subject_offering_id,title,description,due_at,status,created_at,updated_at,completed_at',
            )
            .eq('author_id', userId)
            .inFilter('subject_offering_id', cleanOfferingIds)
            .order('due_at', ascending: true, nullsFirst: false)
            .order('created_at', ascending: true);
        rows.addAll((subjectRows as List)
            .map((row) => Map<String, dynamic>.from(row as Map)));
      } catch (_) {}
    }

    if (includeGeneral) {
      try {
        final generalRows = await _sb
            .from('personal_diary_tasks')
            .select(
              'id,author_id,subject_offering_id,title,description,due_at,status,created_at,updated_at,completed_at',
            )
            .eq('author_id', userId)
            .filter('subject_offering_id', 'is', null)
            .order('due_at', ascending: true, nullsFirst: false)
            .order('created_at', ascending: true);
        rows.addAll((generalRows as List)
            .map((row) => Map<String, dynamic>.from(row as Map)));
      } catch (_) {}
    }

    return rows
        .map((row) => _taskFromRow(row, subjectTitleByOffering))
        .followedBy(
          await _loadLocalPersonalTasks(
            userId: userId,
            offeringIds: offeringIds,
            includeGeneral: includeGeneral,
            subjectTitleByOffering: subjectTitleByOffering,
          ),
        )
        .toList()
      ..sort(_compareTasks);
  }

  Future<PersonalDiaryTask> createPersonalTask({
    required String title,
    String? description,
    String? subjectOfferingId,
    String? subjectTitle,
    DateTime? dueAt,
  }) async {
    final userId = _sb.auth.currentUser?.id ?? '';
    if (userId.isEmpty) {
      throw StateError('Пользователь не авторизован');
    }

    try {
      final row = await _sb
          .from('personal_diary_tasks')
          .insert({
            'author_id': userId,
            'subject_offering_id': _nullIfEmpty(subjectOfferingId),
            'title': title.trim(),
            'description': _nullIfEmpty(description),
            'due_at': dueAt?.toIso8601String(),
            'status': 'todo',
          })
          .select(
            'id,author_id,subject_offering_id,title,description,due_at,status,created_at,updated_at,completed_at',
          )
          .single();

      return _taskFromRow(Map<String, dynamic>.from(row as Map), {
        if (_nullIfEmpty(subjectOfferingId) != null)
          subjectOfferingId!.trim(): _cleanTitle(subjectTitle),
      });
    } catch (_) {
      return _createLocalPersonalTask(
        userId: userId,
        title: title,
        description: description,
        subjectOfferingId: subjectOfferingId,
        subjectTitle: subjectTitle,
        dueAt: dueAt,
      );
    }
  }

  Future<void> updatePersonalTaskStatus({
    required String taskId,
    required String status,
  }) async {
    if (!const ['todo', 'in_progress', 'done'].contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    if (taskId.startsWith('local-')) {
      final userId = _sb.auth.currentUser?.id ?? '';
      if (userId.isEmpty) return;
      await _updateLocalPersonalTaskStatus(
        userId: userId,
        taskId: taskId,
        status: status,
      );
      return;
    }
    await _sb.from('personal_diary_tasks').update({
      'status': status,
      'updated_at': DateTime.now().toIso8601String(),
      'completed_at':
          status == 'done' ? DateTime.now().toIso8601String() : null,
    }).eq('id', taskId);
  }

  Future<List<PersonalDiaryLesson>> loadScheduleLessons() async {
    final context = await _academicContextService.loadFresh();
    final groupId = context.groupId ?? '';
    if (groupId.isEmpty) return const [];

    final now = DateTime.now();
    final from = now.subtract(const Duration(days: 180));
    final to = now.add(const Duration(days: 180));
    final rows = await _sb
        .from('lessons')
        .select(
          'id,date,subject,group_id,subject_id,subject_offering_id,semester_number,pair_num,time_start',
        )
        .eq('group_id', groupId)
        .gte('date', _yyyyMmDd(from))
        .lte('date', _yyyyMmDd(to))
        .order('date', ascending: false)
        .order('pair_num', ascending: true)
        .limit(120);

    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where(
            (row) => (row['subject_offering_id'] ?? '').toString().isNotEmpty)
        .map(PersonalDiaryLesson.fromRow)
        .toList();
  }

  static bool _isRealEntry(Map<String, dynamic> row) {
    final text = (row['text'] ?? '').toString().trim();
    final filesCount = _asInt(row['files_count']) ?? 0;
    return text.isNotEmpty || filesCount > 0;
  }

  static String _cleanTitle(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? 'Предмет' : text;
  }

  static PersonalDiarySubject _subjectFromOffering(Map<String, dynamic> row) {
    return PersonalDiarySubject(
      subjectOfferingId: (row['id'] ?? '').toString(),
      subjectId: (row['subject_id'] ?? '').toString(),
      title: _cleanTitle(row['display_name']),
      groupId: (row['group_id'] ?? '').toString(),
      semesterNumber: _asInt(row['semester_number']),
      entryCount: 0,
      fileCount: 0,
    );
  }

  static String? _preview(dynamic value) {
    final text = (value ?? '').toString().trim();
    if (text.isEmpty) return null;
    return text.length <= 90 ? text : '${text.substring(0, 90)}...';
  }

  static String _assignmentDescription(Map<String, dynamic> row) {
    final description = (row['description'] ?? '').toString().trim();
    if (description.isNotEmpty) return description;
    return (row['body'] ?? '').toString().trim();
  }

  static String? _nullIfEmpty(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  static DateTime? _nullableDate(dynamic value) {
    final text = (value ?? '').toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  static int _compareAssignments(
    PersonalDiaryAssignment a,
    PersonalDiaryAssignment b,
  ) {
    final aDue = a.dueAt;
    final bDue = b.dueAt;
    if (aDue != null && bDue != null) {
      final dueCompare = aDue.compareTo(bDue);
      if (dueCompare != 0) return dueCompare;
    } else if (aDue != null) {
      return -1;
    } else if (bDue != null) {
      return 1;
    }
    return a.createdAt.compareTo(b.createdAt);
  }

  static PersonalDiaryTask _taskFromRow(
    Map<String, dynamic> row,
    Map<String, String> subjectTitleByOffering,
  ) {
    final offeringId = _nullIfEmpty(row['subject_offering_id']);
    return PersonalDiaryTask(
      id: (row['id'] ?? '').toString(),
      subjectOfferingId: offeringId,
      subjectTitle: offeringId == null
          ? 'Общие задачи'
          : subjectTitleByOffering[offeringId] ?? 'Предмет',
      title: (row['title'] ?? '').toString().trim(),
      description: _nullIfEmpty(row['description']),
      dueAt: _nullableDate(row['due_at']),
      status: (row['status'] ?? 'todo').toString(),
      createdAt: _nullableDate(row['created_at']) ?? DateTime.now(),
      updatedAt: _nullableDate(row['updated_at']) ?? DateTime.now(),
      completedAt: _nullableDate(row['completed_at']),
    );
  }

  Future<PersonalDiaryTask> _createLocalPersonalTask({
    required String userId,
    required String title,
    String? description,
    String? subjectOfferingId,
    String? subjectTitle,
    DateTime? dueAt,
  }) async {
    final now = DateTime.now();
    final row = <String, dynamic>{
      'id': 'local-${now.microsecondsSinceEpoch}',
      'author_id': userId,
      'subject_offering_id': _nullIfEmpty(subjectOfferingId),
      'title': title.trim(),
      'description': _nullIfEmpty(description),
      'due_at': dueAt?.toIso8601String(),
      'status': 'todo',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'completed_at': null,
    };
    final rows = await _loadLocalTaskRows(userId);
    rows.add(row);
    await _saveLocalTaskRows(userId, rows);
    return _taskFromRow(row, {
      if (_nullIfEmpty(subjectOfferingId) != null)
        subjectOfferingId!.trim(): _cleanTitle(subjectTitle),
    });
  }

  Future<List<PersonalDiaryTask>> _loadLocalPersonalTasks({
    required String userId,
    required List<String> offeringIds,
    required bool includeGeneral,
    required Map<String, String> subjectTitleByOffering,
  }) async {
    final offeringSet =
        offeringIds.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
    final rows = await _loadLocalTaskRows(userId);
    return rows
        .where((row) {
          final offeringId = _nullIfEmpty(row['subject_offering_id']);
          if (offeringId == null) return includeGeneral;
          return offeringSet.contains(offeringId);
        })
        .map((row) => _taskFromRow(row, subjectTitleByOffering))
        .toList();
  }

  Future<void> _updateLocalPersonalTaskStatus({
    required String userId,
    required String taskId,
    required String status,
  }) async {
    final rows = await _loadLocalTaskRows(userId);
    final now = DateTime.now().toIso8601String();
    for (final row in rows) {
      if ((row['id'] ?? '').toString() != taskId) continue;
      row['status'] = status;
      row['updated_at'] = now;
      row['completed_at'] = status == 'done' ? now : null;
      break;
    }
    await _saveLocalTaskRows(userId, rows);
  }

  Future<List<Map<String, dynamic>>> _loadLocalTaskRows(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localTasksKey(userId));
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveLocalTaskRows(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localTasksKey(userId), jsonEncode(rows));
  }

  String _localTasksKey(String userId) => 'personal_diary_tasks_local_$userId';

  static int _compareTasks(PersonalDiaryTask a, PersonalDiaryTask b) {
    final aDue = a.dueAt;
    final bDue = b.dueAt;
    if (aDue != null && bDue != null) {
      final dueCompare = aDue.compareTo(bDue);
      if (dueCompare != 0) return dueCompare;
    } else if (aDue != null) {
      return -1;
    } else if (bDue != null) {
      return 1;
    }
    return a.createdAt.compareTo(b.createdAt);
  }

  static DateTime _parseDate(dynamic value) {
    final text = (value ?? '').toString();
    return DateTime.tryParse(text.length > 10 ? text : '${text}T00:00:00') ??
        DateTime.now();
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  static String _yyyyMmDd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

class PersonalDiaryLesson {
  final String id;
  final DateTime date;
  final String subjectTitle;
  final String subjectOfferingId;
  final String? subjectId;
  final String? groupId;
  final int? semesterNumber;
  final int? pairNum;
  final String? timeStart;

  const PersonalDiaryLesson({
    required this.id,
    required this.date,
    required this.subjectTitle,
    required this.subjectOfferingId,
    this.subjectId,
    this.groupId,
    this.semesterNumber,
    this.pairNum,
    this.timeStart,
  });

  factory PersonalDiaryLesson.fromRow(Map<String, dynamic> row) {
    final dateText = (row['date'] ?? '').toString();
    return PersonalDiaryLesson(
      id: (row['id'] ?? '').toString(),
      date: DateTime.tryParse(dateText) ?? DateTime.now(),
      subjectTitle: (row['subject'] ?? 'Предмет')
          .toString()
          .replaceAll(RegExp(r'\((л|пр|лаб)\.\)\s*$'), '')
          .trim(),
      subjectOfferingId: (row['subject_offering_id'] ?? '').toString(),
      subjectId: _nullIfEmpty(row['subject_id']),
      groupId: _nullIfEmpty(row['group_id']),
      semesterNumber: PersonalDiaryService._asInt(row['semester_number']),
      pairNum: PersonalDiaryService._asInt(row['pair_num']),
      timeStart: _nullIfEmpty(row['time_start']),
    );
  }

  SubjectDiaryArgs toDiaryArgs() {
    return SubjectDiaryArgs(
      subjectOfferingId: subjectOfferingId,
      subjectId: subjectId,
      subjectTitle: subjectTitle,
      groupId: groupId,
      semesterNumber: semesterNumber,
      lessonId: id,
      date: date,
      legacySubjectKey: subjectTitle,
    );
  }

  static String? _nullIfEmpty(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }
}
