import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/auth_session.dart';

class ActiveEnrollment {
  final String id;
  final String userId;
  final String groupId;

  const ActiveEnrollment({
    required this.id,
    required this.userId,
    required this.groupId,
  });
}

class CurrentGroup {
  final String id;
  final String name;

  const CurrentGroup({
    required this.id,
    required this.name,
  });
}

class CurrentSemester {
  final int? number;
  final String? academicYearId;
  final String? academicTermId;

  const CurrentSemester({
    this.number,
    this.academicYearId,
    this.academicTermId,
  });
}

class AcademicContext {
  final String? userId;
  final String? publicUserId;
  final String? recordBookNumber;
  final String? activeEnrollmentId;
  final String? groupId;
  final String? groupName;
  final int? currentSemesterNumber;
  final String? academicYearId;
  final String? academicTermId;
  final bool hasActiveEnrollment;
  final String? loadWarning;

  const AcademicContext({
    this.userId,
    this.publicUserId,
    this.recordBookNumber,
    this.activeEnrollmentId,
    this.groupId,
    this.groupName,
    this.currentSemesterNumber,
    this.academicYearId,
    this.academicTermId,
    required this.hasActiveEnrollment,
    this.loadWarning,
  });

  const AcademicContext.empty({String? warning})
      : userId = null,
        publicUserId = null,
        recordBookNumber = null,
        activeEnrollmentId = null,
        groupId = null,
        groupName = null,
        currentSemesterNumber = null,
        academicYearId = null,
        academicTermId = null,
        hasActiveEnrollment = false,
        loadWarning = warning;
}

class AcademicContextService {
  AcademicContextService({SupabaseClient? client})
      : _sb = client ?? Supabase.instance.client;

  final SupabaseClient _sb;

  Future<AcademicContext> load() async {
    final authUser = _sb.auth.currentUser;
    if (authUser == null) {
      return const AcademicContext.empty(
          warning: 'Пользователь не авторизован');
    }

    try {
      await AuthSession.ensureFreshSession(_sb);
      return await _loadForUser(authUser.id).timeout(
        const Duration(seconds: 8),
      );
    } catch (e) {
      if (AuthSession.isAuthFailure(e)) {
        try {
          await _sb.auth.refreshSession();
          return await _loadForUser(authUser.id).timeout(
            const Duration(seconds: 8),
          );
        } catch (_) {
          return AcademicContext(
            userId: authUser.id,
            hasActiveEnrollment: false,
            loadWarning: AuthSession.sessionExpiredMessage,
          );
        }
      }

      return AcademicContext(
        userId: authUser.id,
        hasActiveEnrollment: false,
        loadWarning: 'Не удалось загрузить учебный контекст: $e',
      );
    }
  }

  Future<AcademicContext> _loadForUser(String authUserId) async {
    final publicUser = await _sb
        .from('users')
        .select('id,login')
        .eq('id', authUserId)
        .maybeSingle()
        .timeout(const Duration(seconds: 5));
    final publicUserId = (publicUser?['id'] ?? '').toString();
    final recordBookNumber = _asNullableString(publicUser?['login']);

    final enrollment = await _sb
        .from('student_enrollments')
        .select('id,user_id,group_id')
        .eq('user_id', authUserId)
        .eq('status', 'active')
        .filter('ended_at', 'is', null)
        .limit(1)
        .maybeSingle()
        .timeout(const Duration(seconds: 5));

    if (enrollment == null) {
      return AcademicContext(
        userId: authUserId,
        publicUserId: publicUserId.isEmpty ? null : publicUserId,
        recordBookNumber: recordBookNumber,
        hasActiveEnrollment: false,
        loadWarning: 'Активное зачисление не найдено',
      );
    }

    final activeEnrollment = ActiveEnrollment(
      id: (enrollment['id'] ?? '').toString(),
      userId: (enrollment['user_id'] ?? '').toString(),
      groupId: (enrollment['group_id'] ?? '').toString(),
    );

    final group = await _loadGroup(activeEnrollment.groupId);
    final semester = await _loadCurrentSemester(activeEnrollment.groupId);

    return AcademicContext(
      userId: authUserId,
      publicUserId: publicUserId.isEmpty ? null : publicUserId,
      recordBookNumber: recordBookNumber,
      activeEnrollmentId:
          activeEnrollment.id.isEmpty ? null : activeEnrollment.id,
      groupId:
          activeEnrollment.groupId.isEmpty ? null : activeEnrollment.groupId,
      groupName: group?.name,
      currentSemesterNumber: semester.number,
      academicYearId: semester.academicYearId,
      academicTermId: semester.academicTermId,
      hasActiveEnrollment: true,
      loadWarning:
          group == null ? 'Группа активного зачисления не найдена' : null,
    );
  }

  Future<CurrentGroup?> _loadGroup(String groupId) async {
    if (groupId.isEmpty) return null;
    final row = await _sb
        .from('groups')
        .select('id,name')
        .eq('id', groupId)
        .maybeSingle()
        .timeout(const Duration(seconds: 4));
    if (row == null) return null;
    return CurrentGroup(
      id: (row['id'] ?? '').toString(),
      name: (row['name'] ?? '').toString(),
    );
  }

  Future<CurrentSemester> _loadCurrentSemester(String groupId) async {
    if (groupId.isEmpty) return const CurrentSemester();

    final rows = await _sb
        .from('group_term_semesters')
        .select(
          'semester_number,academic_year_id,academic_term_id,academic_terms(is_current,starts_on,ends_on)',
        )
        .eq('group_id', groupId)
        .order('semester_number', ascending: false)
        .timeout(const Duration(seconds: 5));

    if (rows.isEmpty) return const CurrentSemester();

    final now = DateTime.now();
    Map<String, dynamic>? selected;

    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw as Map);
      final term = _asMap(row['academic_terms']);
      if (term?['is_current'] == true) {
        selected = row;
        break;
      }
    }

    selected ??=
        rows.map((raw) => Map<String, dynamic>.from(raw as Map)).firstWhere(
      (row) {
        final term = _asMap(row['academic_terms']);
        final startsOn =
            DateTime.tryParse((term?['starts_on'] ?? '').toString());
        final endsOn = DateTime.tryParse((term?['ends_on'] ?? '').toString());
        if (startsOn == null || endsOn == null) return false;
        return !now.isBefore(startsOn) && !now.isAfter(endsOn);
      },
      orElse: () => Map<String, dynamic>.from(rows.first as Map),
    );

    return CurrentSemester(
      number: _asInt(selected['semester_number']),
      academicYearId: _asNullableString(selected['academic_year_id']),
      academicTermId: _asNullableString(selected['academic_term_id']),
    );
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  String? _asNullableString(dynamic value) {
    final text = (value ?? '').toString();
    return text.isEmpty ? null : text;
  }
}
