class AcademicTermView {
  const AcademicTermView({
    required this.id,
    required this.name,
    required this.lifecycle,
    required this.isCurrent,
    required this.isNearestNext,
    this.startsOn,
    this.endsOn,
    this.yearName,
    this.termSequence,
    this.autoActivationEnabled = false,
  });

  final String id;
  final String name;
  final String lifecycle;
  final bool isCurrent;
  final bool isNearestNext;
  final DateTime? startsOn;
  final DateTime? endsOn;
  final String? yearName;
  final int? termSequence;
  final bool autoActivationEnabled;

  factory AcademicTermView.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString());
    }

    return AcademicTermView(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['year_name'] ?? json['id'] ?? ''}',
      lifecycle:
          '${json['lifecycle'] ?? (json['is_current'] == true ? 'active' : 'completed')}',
      isCurrent: json['is_current'] == true,
      isNearestNext: json['is_nearest_next'] == true,
      startsOn: parseDate(json['starts_on']),
      endsOn: parseDate(json['ends_on']),
      yearName: json['year_name']?.toString(),
      termSequence: int.tryParse('${json['term_sequence'] ?? ''}'),
      autoActivationEnabled: json['auto_activation_enabled'] == true,
    );
  }

  String get lifecycleLabel {
    switch (lifecycle) {
      case 'active':
        return 'Текущий';
      case 'planned':
        return 'Будущий';
      case 'completed':
        return 'Завершённый';
      default:
        return lifecycle;
    }
  }
}

class TermReadiness {
  const TermReadiness({
    required this.termId,
    required this.termName,
    required this.readinessPercent,
    required this.groupsCount,
    required this.subjectsCount,
    required this.subjectChatsCount,
    required this.missingSubjects,
    required this.missingSubjectChats,
    this.notification,
    this.approaching = false,
    this.automationActive = false,
    this.blockers = const [],
  });

  final String termId;
  final String termName;
  final int readinessPercent;
  final int groupsCount;
  final int subjectsCount;
  final int subjectChatsCount;
  final int missingSubjects;
  final int missingSubjectChats;
  final String? notification;
  final bool approaching;
  final bool automationActive;
  final List<String> blockers;

  factory TermReadiness.fromJson(Map<String, dynamic> json) {
    final counts = json['counts'] is Map
        ? Map<String, dynamic>.from(json['counts'] as Map)
        : json;
    final transition = json['transition'] is Map
        ? Map<String, dynamic>.from(json['transition'] as Map)
        : const <String, dynamic>{};
    final rawBlockers = transition['blockers'];
    final blockers = <String>[];
    if (rawBlockers is List) {
      for (final item in rawBlockers) {
        if (item is Map && item['message'] != null) {
          blockers.add('${item['message']}');
        } else if (item != null) {
          blockers.add('$item');
        }
      }
    }
    return TermReadiness(
      termId: '${json['term_id'] ?? counts['term_id'] ?? ''}',
      termName: '${json['term_name'] ?? ''}',
      readinessPercent:
          int.tryParse(
            '${counts['readiness_percent'] ?? json['readiness_percent'] ?? 0}',
          ) ??
          0,
      groupsCount: int.tryParse('${counts['groups_count'] ?? 0}') ?? 0,
      subjectsCount: int.tryParse('${counts['subjects_count'] ?? 0}') ?? 0,
      subjectChatsCount:
          int.tryParse('${counts['subject_chats_count'] ?? 0}') ?? 0,
      missingSubjects: int.tryParse('${counts['missing_subjects'] ?? 0}') ?? 0,
      missingSubjectChats:
          int.tryParse('${counts['missing_subject_chats'] ?? 0}') ?? 0,
      notification: json['notification']?.toString(),
      approaching: json['approaching'] == true,
      automationActive: json['automation_active'] == true,
      blockers: blockers,
    );
  }
}

class TermTransitionPreview {
  const TermTransitionPreview({
    required this.ok,
    required this.currentTermName,
    required this.newTermName,
    required this.archivableSubjectChats,
    required this.willCreateSubjects,
    required this.willCreateSubjectChats,
    required this.confirmNameRequired,
    this.blockers = const [],
    this.idempotentReplay = false,
  });

  final bool ok;
  final String currentTermName;
  final String newTermName;
  final int archivableSubjectChats;
  final int willCreateSubjects;
  final int willCreateSubjectChats;
  final String confirmNameRequired;
  final List<String> blockers;
  final bool idempotentReplay;

  factory TermTransitionPreview.fromJson(Map<String, dynamic> json) {
    final rawBlockers = json['blockers'];
    final blockers = <String>[];
    if (rawBlockers is List) {
      for (final item in rawBlockers) {
        if (item is Map && item['message'] != null) {
          blockers.add('${item['message']}');
        } else if (item != null) {
          blockers.add('$item');
        }
      }
    }
    return TermTransitionPreview(
      ok: json['ok'] == true,
      currentTermName: '${json['current_term_name'] ?? ''}',
      newTermName: '${json['new_term_name'] ?? ''}',
      archivableSubjectChats:
          int.tryParse('${json['archivable_subject_chats'] ?? 0}') ?? 0,
      willCreateSubjects:
          int.tryParse('${json['will_create_subjects'] ?? 0}') ?? 0,
      willCreateSubjectChats:
          int.tryParse('${json['will_create_subject_chats'] ?? 0}') ?? 0,
      confirmNameRequired:
          '${json['confirm_name_required'] ?? json['new_term_name'] ?? ''}',
      blockers: blockers,
      idempotentReplay: json['idempotent_replay'] == true,
    );
  }
}
