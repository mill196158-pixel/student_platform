import 'package:student_ui/student_ui.dart';

import 'vacancy_item.dart';

class VacancyAudiencePreview {
  const VacancyAudiencePreview({
    required this.recipientCount,
    required this.audienceMode,
    this.groupCount = 0,
    this.explicitUserCount = 0,
  });

  final int recipientCount;
  final String audienceMode;
  final int groupCount;
  final int explicitUserCount;

  factory VacancyAudiencePreview.fromJson(Map<String, dynamic> json) {
    final breakdown = json['breakdown'];
    final breakdownMap = breakdown is Map
        ? Map<String, dynamic>.from(breakdown)
        : const {};
    final groups = breakdownMap['groups'];
    final groupCount = groups is List
        ? groups.length
        : int.tryParse('${json['group_count'] ?? 0}') ?? 0;
    final explicit =
        int.tryParse(
          '${breakdownMap['explicit_users_count'] ?? json['explicit_users_count'] ?? 0}',
        ) ??
        0;
    return VacancyAudiencePreview(
      recipientCount: int.tryParse('${json['recipient_count'] ?? 0}') ?? 0,
      audienceMode: (json['audience_mode'] ?? 'all').toString(),
      groupCount: groupCount,
      explicitUserCount: explicit,
    );
  }
}

class VacancyVersionEntry {
  const VacancyVersionEntry({
    required this.id,
    required this.versionNumber,
    required this.createdAt,
    this.snapshotTitle,
  });

  final String id;
  final int versionNumber;
  final DateTime? createdAt;
  final String? snapshotTitle;

  factory VacancyVersionEntry.fromJson(Map<String, dynamic> json) {
    final snapshot = json['snapshot'];
    String? title;
    if (snapshot is Map) {
      title = snapshot['title']?.toString();
    }
    return VacancyVersionEntry(
      id: json['id']?.toString() ?? '',
      versionNumber: int.tryParse('${json['version_number'] ?? 0}') ?? 0,
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      snapshotTitle: title,
    );
  }
}

class VacancyModerationEntry {
  const VacancyModerationEntry({
    required this.action,
    this.fromStatus,
    this.toStatus,
    this.reasonText = '',
    this.createdAt,
  });

  final String action;
  final String? fromStatus;
  final String? toStatus;
  final String reasonText;
  final DateTime? createdAt;

  factory VacancyModerationEntry.fromJson(Map<String, dynamic> json) {
    return VacancyModerationEntry(
      action: (json['action'] ?? '').toString(),
      fromStatus: json['from_status']?.toString(),
      toStatus: json['to_status']?.toString(),
      reasonText: (json['reason_text'] ?? '').toString(),
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
    );
  }
}

class VacancyReportEntry {
  const VacancyReportEntry({
    required this.id,
    required this.vacancyId,
    required this.reasonCode,
    required this.status,
    this.vacancyTitle,
    this.note,
    this.createdAt,
  });

  final String id;
  final String vacancyId;
  final String reasonCode;
  final String status;
  final String? vacancyTitle;
  final String? note;
  final DateTime? createdAt;

  factory VacancyReportEntry.fromJson(Map<String, dynamic> json) {
    return VacancyReportEntry(
      id: json['id']?.toString() ?? '',
      vacancyId: json['vacancy_id']?.toString() ?? '',
      reasonCode: (json['reason_code'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      vacancyTitle: json['vacancy_title']?.toString(),
      note: json['note']?.toString(),
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
    );
  }
}

abstract class VacancyRepository {
  Future<List<VacancyItem>> list({String? status, String? origin});

  Future<VacancyItem> get(String id);

  Future<VacancyItem> createDraft({
    required VacancyItem draft,
    ContentOrigin origin = ContentOrigin.admin,
  });

  Future<VacancyItem> updateDraft(VacancyItem item);

  Future<VacancyItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  });

  Future<VacancyAudiencePreview> previewAudience(String id);

  Future<VacancyItem> publish(String id, int expectedRowVersion);

  /// Converts an existing demo vacancy to managed content; never creates a copy.
  Future<VacancyItem> promoteDemo(String id, int expectedRowVersion);

  /// Archived-only permanent delete + legacy tombstone (`admin_safe_delete_vacancy`).
  Future<void> safeDelete(String id, int expectedRowVersion);

  /// `admin_moderate_vacancy`: take_in_moderation | approve | reject.
  Future<VacancyItem> moderate({
    required String id,
    required String action,
    required int expectedRowVersion,
    String? reason,
  });

  /// `admin_set_vacancy_lifecycle`: unpublish | expire | archive.
  Future<VacancyItem> setLifecycle({
    required String id,
    required String action,
    required int expectedRowVersion,
    String? reason,
  });

  Future<List<VacancyVersionEntry>> listVersions(String id);

  Future<List<VacancyModerationEntry>> listModerationActions(String id);

  Future<List<VacancyReportEntry>> listReports({String status = 'open'});

  Future<void> resolveReport({
    required String reportId,
    required String action,
    String? reason,
  });

  Future<String> registerAsset({
    required String vacancyId,
    required List<int> bytes,
    required String contentType,
    String title = '',
  });

  Future<void> deleteAsset(String assetId);
}

class VacancyRepositoryException implements Exception {
  const VacancyRepositoryException(this.message, {this.isForbidden = false});

  final String message;
  final bool isForbidden;

  @override
  String toString() => message;
}

/// In-memory repository for local prototype / widget tests.
class LocalVacancyRepository implements VacancyRepository {
  LocalVacancyRepository() {
    _items = [
      for (var i = 0; i < VacancyCardPayload.demoVacancies.length; i++)
        VacancyItem(
          id: 'local-demo-vacancy-$i',
          status: VacancyStatus.draft,
          origin: ContentOrigin.demo,
          legacyKey: switch (i) {
            0 => 'vacancy:junior_flutter',
            1 => 'vacancy:teaching_assistant',
            _ => 'vacancy:presentation_designer',
          },
          title: VacancyCardPayload.demoVacancies[i].title,
          companyName: VacancyCardPayload.demoVacancies[i].companyName,
          summary: VacancyCardPayload.demoVacancies[i].summary,
          description: VacancyCardPayload.demoVacancies[i].summary,
          employmentType: VacancyCardPayload.demoVacancies[i].employmentType,
          workFormat: VacancyCardPayload.demoVacancies[i].workFormat,
          location: VacancyCardPayload.demoVacancies[i].location,
          salaryText: VacancyCardPayload.demoVacancies[i].salaryText,
          rowVersion: 1,
          priority: VacancyCardPayload.demoVacancies.length - i,
          audienceMode: 'all',
        ),
      VacancyItem(
        id: 'local-user-submission-1',
        status: VacancyStatus.submitted,
        origin: ContentOrigin.userSubmission,
        title: 'Стажёр в лаборатории',
        companyName: 'Студенческий проект',
        summary: 'Помощь с тестами и документацией.',
        description: VacancyItem.buildDescription(
          'Нужен внимательный студент для рутинных задач.',
          'Базовый Python, аккуратность.',
        ),
        employmentType: VacancyEmploymentType.internship,
        workFormat: VacancyWorkFormat.hybrid,
        location: 'Кампус',
        contacts: const {'email': 'lab@example.edu'},
        rowVersion: 1,
        priority: 0,
        audienceMode: 'all',
      ),
      VacancyItem(
        id: 'local-rejected-1',
        status: VacancyStatus.rejected,
        origin: ContentOrigin.userSubmission,
        title: 'Быстрые деньги без опыта',
        companyName: '???',
        summary: 'Подозрительное объявление.',
        description: 'Требуется перевод средств.',
        rowVersion: 1,
        priority: 0,
        audienceMode: 'all',
        rejectionReason: 'Подозрение на мошенничество',
      ),
    ];
    _moderationJournal['local-user-submission-1'] = [
      const VacancyModerationEntry(action: 'submit', toStatus: 'submitted'),
    ];
    _reports.add(
      const VacancyReportEntry(
        id: 'local-report-1',
        vacancyId: 'local-demo-vacancy-0',
        reasonCode: 'spam',
        status: 'open',
        vacancyTitle: 'Junior Flutter Developer',
      ),
    );
  }

  late List<VacancyItem> _items;
  int _seq = 1;
  final Map<String, List<VacancyModerationEntry>> _moderationJournal = {};
  final List<VacancyReportEntry> _reports = [];
  final Map<String, List<String>> _assetsByVacancy = {};

  @override
  Future<List<VacancyItem>> list({String? status, String? origin}) async {
    var filtered = _items;
    if (status != null) {
      filtered = filtered
          .where((e) => vacancyStatusWire(e.status) == status)
          .toList();
    }
    if (origin != null) {
      filtered = filtered
          .where((e) => _originWire(e.origin) == origin)
          .toList();
    }
    final copy = [...filtered]
      ..sort((a, b) => b.priority.compareTo(a.priority));
    return copy;
  }

  @override
  Future<VacancyItem> get(String id) async {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    throw const VacancyRepositoryException('Вакансия не найдена.');
  }

  @override
  Future<VacancyItem> createDraft({
    required VacancyItem draft,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    if (origin != ContentOrigin.admin && origin != ContentOrigin.demo) {
      throw const VacancyRepositoryException(
        'Ручное создание только с origin admin|demo.',
      );
    }
    final item = VacancyItem(
      id: 'local-vacancy-${_seq++}',
      status: VacancyStatus.draft,
      origin: origin,
      title: draft.title,
      companyName: draft.companyName,
      summary: draft.summary,
      description: draft.description,
      employmentType: draft.employmentType,
      workFormat: draft.workFormat,
      location: draft.location,
      salaryText: draft.salaryText,
      externalUrl: draft.externalUrl,
      contacts: draft.contacts,
      rowVersion: 1,
      priority: draft.priority,
      audienceMode: 'all',
      expiresAt: draft.expiresAt,
    );
    _items = [..._items, item];
    _moderationJournal[item.id] = [
      const VacancyModerationEntry(action: 'create_draft', toStatus: 'draft'),
    ];
    return item;
  }

  @override
  Future<VacancyItem> updateDraft(VacancyItem item) async {
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      throw const VacancyRepositoryException('Вакансия не найдена.');
    }
    final current = _items[idx];
    if (!_isEditable(current.status)) {
      throw const VacancyRepositoryException(
        'Редактировать можно только в draft|submitted|rejected.',
      );
    }
    final next = item.copyWith(rowVersion: current.rowVersion + 1);
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<VacancyItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  }) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const VacancyRepositoryException('Вакансия не найдена.');
    }
    final current = _items[idx];
    if (!_isEditable(current.status)) {
      throw const VacancyRepositoryException(
        'Аудиторию можно менять только в draft|submitted|rejected.',
      );
    }
    if (current.rowVersion != expectedRowVersion) {
      throw const VacancyRepositoryException(
        'Вакансия изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      audienceMode: audienceMode,
      audienceGroupIds: groupIds,
      audienceUserIds: userIds,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<VacancyAudiencePreview> previewAudience(String id) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const VacancyRepositoryException('Вакансия не найдена.');
    }
    final item = _items[idx];
    final count = switch (item.audienceMode) {
      'all' => 100,
      'groups' => item.audienceGroupIds.length * 10,
      'users' => item.audienceUserIds.length,
      'groups_and_users' =>
        item.audienceGroupIds.length * 10 + item.audienceUserIds.length,
      _ => 0,
    };
    return VacancyAudiencePreview(
      recipientCount: count,
      audienceMode: item.audienceMode,
      groupCount: item.audienceGroupIds.length,
      explicitUserCount: item.audienceUserIds.length,
    );
  }

  @override
  Future<VacancyItem> publish(String id, int expectedRowVersion) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const VacancyRepositoryException('Вакансия не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const VacancyRepositoryException(
        'Вакансия изменилась. Обновите список.',
      );
    }
    if (current.status != VacancyStatus.approved) {
      throw const VacancyRepositoryException(
        'Публикация доступна только после одобрения (approved).',
      );
    }
    final next = current.copyWith(
      status: VacancyStatus.published,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    _appendJournal(id, 'publish', 'approved', 'published');
    return next;
  }

  @override
  Future<VacancyItem> promoteDemo(String id, int expectedRowVersion) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) throw const VacancyRepositoryException('Вакансия не найдена.');
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const VacancyRepositoryException(
        'Вакансия изменилась. Обновите список.',
      );
    }
    if (current.origin != ContentOrigin.demo) {
      throw const VacancyRepositoryException(
        'Перевести можно только демо-вакансию.',
      );
    }
    final next = current.copyWith(
      origin: ContentOrigin.admin,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<void> safeDelete(String id, int expectedRowVersion) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) throw const VacancyRepositoryException('Вакансия не найдена.');
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const VacancyRepositoryException(
        'Вакансия изменилась. Обновите список.',
      );
    }
    if (current.status != VacancyStatus.archived) {
      throw const VacancyRepositoryException(
        'Удалить можно только архивную вакансию.',
      );
    }
    _items = [..._items]..removeAt(idx);
  }

  @override
  Future<VacancyItem> moderate({
    required String id,
    required String action,
    required int expectedRowVersion,
    String? reason,
  }) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const VacancyRepositoryException('Вакансия не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const VacancyRepositoryException(
        'Вакансия изменилась. Обновите список.',
      );
    }
    if (action == 'reject' && (reason == null || reason.trim().isEmpty)) {
      throw const VacancyRepositoryException('Укажите причину отклонения.');
    }
    if (action == 'approve' && current.status != VacancyStatus.inModeration) {
      throw const VacancyRepositoryException(
        'Одобрить можно только вакансию на модерации (in_moderation).',
      );
    }

    final nextStatus = switch (action) {
      'take_in_moderation' => VacancyStatus.inModeration,
      'approve' => VacancyStatus.approved,
      'reject' => VacancyStatus.rejected,
      _ => throw const VacancyRepositoryException('Неизвестное действие.'),
    };

    final next = current.copyWith(
      status: nextStatus,
      rejectionReason: action == 'reject' ? reason?.trim() : null,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    _appendJournal(
      id,
      action,
      vacancyStatusWire(current.status),
      vacancyStatusWire(nextStatus),
      reason: reason,
    );
    return next;
  }

  @override
  Future<VacancyItem> setLifecycle({
    required String id,
    required String action,
    required int expectedRowVersion,
    String? reason,
  }) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const VacancyRepositoryException('Вакансия не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const VacancyRepositoryException(
        'Вакансия изменилась. Обновите список.',
      );
    }
    final nextStatus = switch (action) {
      'unpublish' => VacancyStatus.approved,
      'expire' => VacancyStatus.expired,
      'archive' => VacancyStatus.archived,
      _ => throw const VacancyRepositoryException('Неизвестное действие.'),
    };
    final next = current.copyWith(
      status: nextStatus,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    _appendJournal(
      id,
      action,
      vacancyStatusWire(current.status),
      vacancyStatusWire(nextStatus),
      reason: reason,
    );
    return next;
  }

  @override
  Future<List<VacancyVersionEntry>> listVersions(String id) async {
    final item = await get(id);
    return [
      VacancyVersionEntry(
        id: 'local-version-${item.rowVersion}',
        versionNumber: item.rowVersion,
        createdAt: DateTime.now(),
        snapshotTitle: item.title,
      ),
    ];
  }

  @override
  Future<List<VacancyModerationEntry>> listModerationActions(String id) async {
    return _moderationJournal[id] ?? const [];
  }

  @override
  Future<List<VacancyReportEntry>> listReports({String status = 'open'}) async {
    return _reports.where((r) => r.status == status).toList();
  }

  @override
  Future<void> resolveReport({
    required String reportId,
    required String action,
    String? reason,
  }) async {
    final idx = _reports.indexWhere((r) => r.id == reportId);
    if (idx < 0) {
      throw const VacancyRepositoryException('Жалоба не найдена.');
    }
    final report = _reports[idx];
    _reports[idx] = VacancyReportEntry(
      id: report.id,
      vacancyId: report.vacancyId,
      reasonCode: report.reasonCode,
      status: action == 'resolve' ? 'resolved' : 'rejected',
      vacancyTitle: report.vacancyTitle,
      note: reason ?? report.note,
      createdAt: report.createdAt,
    );
  }

  @override
  Future<String> registerAsset({
    required String vacancyId,
    required List<int> bytes,
    required String contentType,
    String title = '',
  }) async {
    final item = await get(vacancyId);
    if (!_isEditable(item.status)) {
      throw const VacancyRepositoryException(
        'Вложения можно добавлять только в draft|submitted|rejected.',
      );
    }
    final assetId = 'local-asset-${_seq++}';
    _assetsByVacancy.putIfAbsent(vacancyId, () => []).add(assetId);
    final idx = _items.indexWhere((e) => e.id == vacancyId);
    if (idx >= 0) {
      final current = _items[idx];
      _items = [..._items]
        ..[idx] = current.copyWith(
          assetIds: [...current.assetIds, assetId],
          rowVersion: current.rowVersion + 1,
        );
    }
    return assetId;
  }

  @override
  Future<void> deleteAsset(String assetId) async {
    for (final entry in _assetsByVacancy.entries) {
      entry.value.remove(assetId);
    }
  }

  void _appendJournal(
    String vacancyId,
    String action,
    String? from,
    String? to, {
    String? reason,
  }) {
    _moderationJournal
        .putIfAbsent(vacancyId, () => [])
        .add(
          VacancyModerationEntry(
            action: action,
            fromStatus: from,
            toStatus: to,
            reasonText: reason ?? '',
            createdAt: DateTime.now(),
          ),
        );
  }

  bool _isEditable(VacancyStatus status) {
    return status == VacancyStatus.draft ||
        status == VacancyStatus.submitted ||
        status == VacancyStatus.rejected;
  }

  String _originWire(ContentOrigin origin) {
    switch (origin) {
      case ContentOrigin.demo:
        return 'demo';
      case ContentOrigin.admin:
        return 'admin';
      case ContentOrigin.importSource:
        return 'import';
      case ContentOrigin.userSubmission:
        return 'user_submission';
    }
  }
}
