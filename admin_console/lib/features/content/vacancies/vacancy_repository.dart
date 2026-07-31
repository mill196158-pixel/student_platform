import 'package:student_ui/student_ui.dart';

import 'vacancy_item.dart';
import '../shared/local_content_working_draft.dart';

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

  /// Atomic draft→published for admin/demo authored vacancies (no submitter).
  Future<VacancyItem> readyPublish(String id, int expectedRowVersion);

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
    String role = 'attachment',
  });

  Future<void> setAssetRole({required String assetId, required String role});

  /// Clears a visual role. With a working draft, canonical assets stay until publish.
  Future<VacancyItem> clearVisualRole({
    required String vacancyId,
    required String role,
  });

  Future<void> deleteAsset(String assetId);

  Future<VacancyItem> beginEdit(String id);

  Future<VacancyItem> saveWorkingDraft(
    VacancyItem item, {
    required int expectedDraftRowVersion,
  });

  Future<VacancyItem> publishWorkingDraft(
    String id, {
    required int expectedDraftRowVersion,
  });

  Future<VacancyItem> discardWorkingDraft(String id);
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
  final Map<String, _VacancyWorkingDraft> _workingDrafts = {};

  VacancyItem _withWorkingDraftFlag(VacancyItem item) {
    if (!_workingDrafts.containsKey(item.id)) return item;
    return item.copyWith(hasWorkingDraft: true);
  }

  VacancyItem _withWorkingDraftOverlay(VacancyItem item) {
    final draft = _workingDrafts[item.id];
    if (draft == null) return item;
    return item.copyWith(
      title: draft.title,
      companyName: draft.companyName,
      summary: draft.summary,
      description: draft.description,
      priority: draft.priority,
      audienceMode: draft.audienceMode,
      employmentType: draft.employmentType,
      workFormat: draft.workFormat,
      location: draft.location,
      salaryText: draft.salaryText,
      externalUrl: draft.externalUrl,
      contacts: draft.contacts,
      startsAt: draft.startsAt,
      endsAt: draft.endsAt,
      expiresAt: draft.expiresAt,
      isHidden: draft.isHidden,
      audienceGroupIds: draft.audienceGroupIds,
      audienceUserIds: draft.audienceUserIds,
      hasWorkingDraft: true,
      workingDraftRowVersion: draft.rowVersion,
    );
  }

  void _assertNoWorkingDraft(String id) {
    assertNoLocalWorkingDraft(_workingDrafts, id);
  }

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
    final copy = [...filtered.map(_withWorkingDraftFlag)]
      ..sort((a, b) => b.priority.compareTo(a.priority));
    return copy;
  }

  @override
  Future<VacancyItem> get(String id) async {
    for (final item in _items) {
      if (item.id == id) {
        return _withWorkingDraftFlag(item);
      }
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
  Future<VacancyItem> readyPublish(String id, int expectedRowVersion) async {
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
    if (!current.isReadyPublishEligible) {
      throw const VacancyRepositoryException(
        'Быстрая публикация доступна только для черновиков admin/demo '
        'без заявки пользователя.',
      );
    }
    // Mirror server: draft → in_moderation → approved → published (+3 rv).
    var next = current.copyWith(
      status: VacancyStatus.inModeration,
      rowVersion: current.rowVersion + 1,
    );
    _appendJournal(id, 'take_in_moderation', 'draft', 'in_moderation');
    next = next.copyWith(
      status: VacancyStatus.approved,
      rowVersion: next.rowVersion + 1,
    );
    _appendJournal(id, 'approve', 'in_moderation', 'approved');
    next = next.copyWith(
      status: VacancyStatus.published,
      rowVersion: next.rowVersion + 1,
    );
    _appendJournal(id, 'publish', 'approved', 'published');
    _items = [..._items]..[idx] = next;
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
    _assertNoWorkingDraft(id);
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
    if (action == 'take_in_moderation' &&
        current.status != VacancyStatus.submitted &&
        current.status != VacancyStatus.draft) {
      throw const VacancyRepositoryException(
        'На модерацию можно взять только draft или submitted.',
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
    _assertNoWorkingDraft(id);
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

  final Map<String, String> _assetRoles = {};

  @override
  Future<String> registerAsset({
    required String vacancyId,
    required List<int> bytes,
    required String contentType,
    String title = '',
    String role = 'attachment',
  }) async {
    final item = await get(vacancyId);
    final hasDraft = _workingDrafts.containsKey(vacancyId);
    if (!_isEditable(item.status) && !hasDraft) {
      throw const VacancyRepositoryException(
        'Вложения можно добавлять в draft|submitted|rejected '
        'или во время редактирования опубликованной вакансии.',
      );
    }
    final assetId = 'local-asset-${_seq++}';
    _assetsByVacancy.putIfAbsent(vacancyId, () => []).add(assetId);
    final isDraftAsset = hasDraft;
    final idx = _items.indexWhere((e) => e.id == vacancyId);
    if (idx >= 0) {
      final current = _items[idx];
      final nextAssets = [
        ...current.assets,
        VacancyAssetRef(
          id: assetId,
          role: 'attachment',
          title: title,
          mimeType: contentType,
          isDraftAsset: isDraftAsset,
        ),
      ];
      final cleared = [...current.clearedVisualRoles]..remove(role);
      _items = [..._items]
        ..[idx] = current.copyWith(
          assetIds: [...current.assetIds, assetId],
          assets: nextAssets,
          clearedVisualRoles: cleared,
          rowVersion: hasDraft ? current.rowVersion : current.rowVersion + 1,
        );
    }
    if (hasDraft) {
      _workingDrafts[vacancyId]?.draftAssetIds.add(assetId);
    }
    _assetRoles[assetId] = 'attachment';
    await setAssetRole(assetId: assetId, role: role);
    return assetId;
  }

  @override
  Future<void> setAssetRole({
    required String assetId,
    required String role,
  }) async {
    if (!const {'attachment', 'logo', 'cover', 'background'}.contains(role)) {
      throw const VacancyRepositoryException('Недопустимая роль вложения.');
    }
    String? vacancyId;
    for (final entry in _assetsByVacancy.entries) {
      if (entry.value.contains(assetId)) {
        vacancyId = entry.key;
        break;
      }
    }
    _assetRoles[assetId] = role;
    if (vacancyId == null) return;
    final idx = _items.indexWhere((e) => e.id == vacancyId);
    if (idx < 0) return;
    final current = _items[idx];
    final target = current.assets.cast<VacancyAssetRef?>().firstWhere(
      (a) => a?.id == assetId,
      orElse: () => null,
    );
    final targetIsDraft =
        target?.isDraftAsset ?? _workingDrafts.containsKey(vacancyId);
    final nextAssets = current.assets.map((asset) {
      if (asset.id == assetId) {
        return VacancyAssetRef(
          id: asset.id,
          role: role,
          title: asset.title,
          mimeType: asset.mimeType,
          isDraftAsset: asset.isDraftAsset,
        );
      }
      if (asset.role == role &&
          asset.id != assetId &&
          asset.isDraftAsset == targetIsDraft &&
          (role == 'logo' || role == 'cover' || role == 'background')) {
        _assetRoles[asset.id] = 'attachment';
        return VacancyAssetRef(
          id: asset.id,
          role: 'attachment',
          title: asset.title,
          mimeType: asset.mimeType,
          isDraftAsset: asset.isDraftAsset,
        );
      }
      return asset;
    }).toList();
    if (!nextAssets.any((a) => a.id == assetId)) {
      nextAssets.add(
        VacancyAssetRef(id: assetId, role: role, isDraftAsset: targetIsDraft),
      );
    }
    final cleared = [...current.clearedVisualRoles]..remove(role);
    _items = [..._items]
      ..[idx] = current.copyWith(
        assets: nextAssets,
        clearedVisualRoles: cleared,
      );
  }

  String? assetRole(String assetId) => _assetRoles[assetId];

  @override
  Future<VacancyItem> clearVisualRole({
    required String vacancyId,
    required String role,
  }) async {
    if (!const {'logo', 'cover', 'background'}.contains(role)) {
      throw const VacancyRepositoryException('Недопустимая роль вложения.');
    }
    final idx = _items.indexWhere((e) => e.id == vacancyId);
    if (idx < 0) throw const VacancyRepositoryException('Вакансия не найдена.');
    final current = _items[idx];
    final hasDraft = _workingDrafts.containsKey(vacancyId);
    final toDelete = current.assets
        .where(
          (a) =>
              a.role == role && (hasDraft ? a.isDraftAsset : !a.isDraftAsset),
        )
        .map((a) => a.id)
        .toList();
    for (final assetId in toDelete) {
      await deleteAsset(assetId);
    }
    final refreshed = await get(vacancyId);
    if (hasDraft) {
      final cleared = {...refreshed.clearedVisualRoles, role}.toList();
      final next = refreshed.copyWith(clearedVisualRoles: cleared);
      final nextIdx = _items.indexWhere((e) => e.id == vacancyId);
      _items = [..._items]..[nextIdx] = next;
      return next;
    }
    return refreshed;
  }

  @override
  Future<void> deleteAsset(String assetId) async {
    _assetRoles.remove(assetId);
    for (final entry in _assetsByVacancy.entries) {
      entry.value.remove(assetId);
    }
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (!item.assetIds.contains(assetId)) continue;
      final kept = item.assetIds.where((id) => id != assetId).toList();
      final assets = item.assets.where((a) => a.id != assetId).toList();
      _items = [..._items]..[i] = item.copyWith(assetIds: kept, assets: assets);
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

  @override
  Future<VacancyItem> beginEdit(String id) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) throw const VacancyRepositoryException('Вакансия не найдена.');
    final current = _items[idx];
    if (_isEditable(current.status)) {
      throw const VacancyRepositoryException(
        'Черновик редактируется напрямую.',
      );
    }
    if (current.status == VacancyStatus.archived) {
      throw const VacancyRepositoryException(
        'Архивную вакансию нельзя редактировать.',
      );
    }
    if (!_workingDrafts.containsKey(id)) {
      _workingDrafts[id] = _VacancyWorkingDraft.fromItem(current);
    }
    return _withWorkingDraftOverlay(current);
  }

  @override
  Future<VacancyItem> saveWorkingDraft(
    VacancyItem item, {
    required int expectedDraftRowVersion,
  }) async {
    final current = _items[_items.indexWhere((e) => e.id == item.id)];
    final draft = _workingDrafts[item.id];
    if (draft == null) {
      throw const VacancyRepositoryException('Черновик изменений не найден.');
    }
    if (draft.rowVersion != expectedDraftRowVersion) {
      throw const VacancyRepositoryException('Черновик изменился. Обновите.');
    }
    draft.apply(item);
    draft.rowVersion += 1;
    return _withWorkingDraftOverlay(current);
  }

  @override
  Future<VacancyItem> publishWorkingDraft(
    String id, {
    required int expectedDraftRowVersion,
  }) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) throw const VacancyRepositoryException('Вакансия не найдена.');
    final current = _items[idx];
    final draft = _workingDrafts[id];
    if (draft == null) {
      throw const VacancyRepositoryException('Черновик изменений не найден.');
    }
    if (draft.rowVersion != expectedDraftRowVersion) {
      throw const VacancyRepositoryException('Черновик изменился. Обновите.');
    }
    // Reconcile visual roles: remove superseded/cleared canonical assets,
    // then promote draft assets to canonical.
    final rolesToReplace = <String>{
      ...current.clearedVisualRoles,
      for (final asset in current.assets)
        if (asset.isDraftAsset &&
            (asset.role == 'logo' ||
                asset.role == 'cover' ||
                asset.role == 'background'))
          asset.role,
    };
    final removedCanonicalIds = <String>{};
    for (final role in rolesToReplace) {
      for (final asset in current.assets) {
        if (!asset.isDraftAsset && asset.role == role) {
          removedCanonicalIds.add(asset.id);
        }
      }
    }
    for (final assetId in removedCanonicalIds) {
      await deleteAsset(assetId);
    }
    final afterDelete = await get(id);
    final promotedAssets = afterDelete.assets
        .map(
          (a) => VacancyAssetRef(
            id: a.id,
            role: a.role,
            title: a.title,
            mimeType: a.mimeType,
            isDraftAsset: false,
          ),
        )
        .toList();
    final next = afterDelete.copyWith(
      title: draft.title,
      companyName: draft.companyName,
      summary: draft.summary,
      description: draft.description,
      priority: draft.priority,
      audienceMode: draft.audienceMode,
      employmentType: draft.employmentType,
      workFormat: draft.workFormat,
      location: draft.location,
      salaryText: draft.salaryText,
      externalUrl: draft.externalUrl,
      contacts: draft.contacts,
      startsAt: draft.startsAt,
      endsAt: draft.endsAt,
      expiresAt: draft.expiresAt,
      isHidden: draft.isHidden,
      audienceGroupIds: draft.audienceGroupIds,
      audienceUserIds: draft.audienceUserIds,
      assets: promotedAssets,
      clearedVisualRoles: const [],
      rowVersion: afterDelete.rowVersion + 1,
      hasWorkingDraft: false,
      clearWorkingDraftRowVersion: true,
    );
    final nextIdx = _items.indexWhere((e) => e.id == id);
    _items = [..._items]..[nextIdx] = next;
    _workingDrafts.remove(id);
    return next;
  }

  @override
  Future<VacancyItem> discardWorkingDraft(String id) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) throw const VacancyRepositoryException('Вакансия не найдена.');
    final current = _items[idx];
    final draft = _workingDrafts.remove(id);
    final orphanIds = draft?.draftAssetIds ?? const <String>[];
    if (orphanIds.isNotEmpty) {
      final kept = current.assetIds
          .where((assetId) => !orphanIds.contains(assetId))
          .toList();
      final keptAssets = current.assets
          .where((asset) => !orphanIds.contains(asset.id))
          .toList();
      _assetsByVacancy[id]?.removeWhere(orphanIds.contains);
      for (final orphanId in orphanIds) {
        _assetRoles.remove(orphanId);
      }
      _items = [..._items]
        ..[idx] = current.copyWith(
          assetIds: kept,
          assets: keptAssets,
          clearedVisualRoles: const [],
          hasWorkingDraft: false,
          clearWorkingDraftRowVersion: true,
        );
      return _items[idx];
    }
    return current.copyWith(
      clearedVisualRoles: const [],
      hasWorkingDraft: false,
      clearWorkingDraftRowVersion: true,
    );
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

class _VacancyWorkingDraft {
  _VacancyWorkingDraft({
    required this.rowVersion,
    required this.title,
    required this.companyName,
    required this.summary,
    required this.description,
    required this.priority,
    required this.audienceMode,
    required this.contacts,
    required this.isHidden,
    required this.audienceGroupIds,
    required this.audienceUserIds,
    this.employmentType,
    this.workFormat,
    this.location,
    this.salaryText,
    this.externalUrl,
    this.startsAt,
    this.endsAt,
    this.expiresAt,
  });

  factory _VacancyWorkingDraft.fromItem(VacancyItem item) {
    return _VacancyWorkingDraft(
      rowVersion: 1,
      title: item.title,
      companyName: item.companyName,
      summary: item.summary,
      description: item.description,
      priority: item.priority,
      audienceMode: item.audienceMode,
      employmentType: item.employmentType,
      workFormat: item.workFormat,
      location: item.location,
      salaryText: item.salaryText,
      externalUrl: item.externalUrl,
      contacts: Map<String, dynamic>.from(item.contacts),
      startsAt: item.startsAt,
      endsAt: item.endsAt,
      expiresAt: item.expiresAt,
      isHidden: item.isHidden,
      audienceGroupIds: List<String>.from(item.audienceGroupIds),
      audienceUserIds: List<String>.from(item.audienceUserIds),
    );
  }

  int rowVersion;
  String title;
  String companyName;
  String summary;
  String description;
  int priority;
  String audienceMode;
  VacancyEmploymentType? employmentType;
  VacancyWorkFormat? workFormat;
  String? location;
  String? salaryText;
  String? externalUrl;
  Map<String, dynamic> contacts;
  DateTime? startsAt;
  DateTime? endsAt;
  DateTime? expiresAt;
  bool isHidden;
  List<String> audienceGroupIds;
  List<String> audienceUserIds;
  final List<String> draftAssetIds = [];

  void apply(VacancyItem item) {
    title = item.title;
    companyName = item.companyName;
    summary = item.summary;
    description = item.description;
    priority = item.priority;
    audienceMode = item.audienceMode;
    employmentType = item.employmentType;
    workFormat = item.workFormat;
    location = item.location;
    salaryText = item.salaryText;
    externalUrl = item.externalUrl;
    contacts = Map<String, dynamic>.from(item.contacts);
    startsAt = item.startsAt;
    endsAt = item.endsAt;
    expiresAt = item.expiresAt;
    isHidden = item.isHidden;
    audienceGroupIds = List<String>.from(item.audienceGroupIds);
    audienceUserIds = List<String>.from(item.audienceUserIds);
  }
}
