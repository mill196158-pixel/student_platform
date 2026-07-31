import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'subject_item.dart';

class SubjectOfferingAdminItem {
  const SubjectOfferingAdminItem({
    required this.id,
    required this.subjectId,
    this.displayName,
    this.groupId,
    this.status = 'active',
    this.hoursTotal,
    this.credits,
    this.teachersRowVersion = 1,
    this.overrideRowVersion = 0,
    this.overrideStatus,
    this.localDescription,
    this.teacherSpecificNote,
    this.assessmentNote,
    this.workloadNote,
    this.semesterTips,
    this.teacherIds = const [],
  });

  final String id;
  final String subjectId;
  final String? displayName;
  final String? groupId;
  final String status;
  final num? hoursTotal;
  final num? credits;
  final int teachersRowVersion;
  final int overrideRowVersion;
  final String? overrideStatus;
  final String? localDescription;
  final String? teacherSpecificNote;
  final String? assessmentNote;
  final String? workloadNote;
  final String? semesterTips;
  final List<String> teacherIds;

  factory SubjectOfferingAdminItem.fromJson(Map<String, dynamic> json) {
    return SubjectOfferingAdminItem(
      id: '${json['id'] ?? ''}',
      subjectId: '${json['subject_id'] ?? ''}',
      displayName: json['display_name']?.toString(),
      groupId: json['group_id']?.toString(),
      status: '${json['status'] ?? 'active'}',
      hoursTotal: json['hours_total'] is num
          ? json['hours_total'] as num
          : num.tryParse('${json['hours_total'] ?? ''}'),
      credits: json['credits'] is num
          ? json['credits'] as num
          : num.tryParse('${json['credits'] ?? ''}'),
      teachersRowVersion:
          int.tryParse('${json['teachers_row_version'] ?? 1}') ?? 1,
      overrideRowVersion:
          int.tryParse('${json['override_row_version'] ?? 0}') ?? 0,
      overrideStatus: json['override_status']?.toString(),
      localDescription: json['local_description']?.toString(),
      teacherSpecificNote: json['teacher_specific_note']?.toString(),
      assessmentNote: json['assessment_note']?.toString(),
      workloadNote: json['workload_note']?.toString(),
      semesterTips: json['semester_tips']?.toString(),
      teacherIds: [
        for (final id in (json['teacher_ids'] as List? ?? const []))
          id.toString(),
      ],
    );
  }
}

class SubjectsRepositoryException implements Exception {
  const SubjectsRepositoryException(this.message, {this.isConflict = false});
  final String message;
  final bool isConflict;
  @override
  String toString() => message;
}

abstract class SubjectsRepository {
  Future<List<SubjectItem>> list({
    String? query,
    SubjectStatus? status,
    String sort = 'name_asc',
  });
  Future<SubjectItem> save(SubjectItem item);
  Future<List<SubjectOfferingAdminItem>> listOfferings(String subjectId);
  Future<SubjectOfferingAdminItem> setOfferingTeachers({
    required String offeringId,
    required int expectedTeachersRowVersion,
    required List<String> teacherIds,
  });
  Future<SubjectOfferingAdminItem> saveOfferingOverride({
    required String offeringId,
    required int expectedRowVersion,
    String? localDescription,
    String? teacherSpecificNote,
    String? assessmentNote,
    String? workloadNote,
    String? semesterTips,
    String moderationStatus = 'draft',
  });
  Future<List<Map<String, dynamic>>> listOfferingProfileVersions(
    String offeringId,
  );
  Future<SubjectOfferingAdminItem> restoreOfferingProfile({
    required String offeringId,
    required int versionNumber,
    required int expectedRowVersion,
  });
  Future<Map<String, dynamic>> importDryRun(List<Map<String, dynamic>> rows);
  Future<Map<String, dynamic>> importApply(List<Map<String, dynamic>> rows);
  Future<List<Map<String, dynamic>>> listImportBatches({int limit = 20});
  Future<List<Map<String, dynamic>>> listImportRows(String batchId);
  Future<List<Map<String, dynamic>>> listVersions(String subjectId);
  Future<void> restoreVersion(
    String subjectId,
    int versionNumber, {
    required int expectedCatalogRowVersion,
    required int expectedProfileRowVersion,
  });
}

class LocalSubjectsRepository implements SubjectsRepository {
  LocalSubjectsRepository({List<SubjectItem>? seed})
    : _items =
          seed ??
          [
            const SubjectItem(
              id: 'local-1',
              canonicalName: 'Базы данных',
              department: 'ИТ',
              controlForm: 'Экзамен',
              shortDescription: 'Реляционные модели и SQL.',
              status: SubjectStatus.published,
              relatedTeachers: ['Иванов И.И.'],
            ),
            const SubjectItem(
              id: 'local-2',
              canonicalName: 'Архитектура информационных систем',
              department: 'ИТ',
              status: SubjectStatus.draft,
            ),
          ];

  List<SubjectItem> _items;
  final Set<String> _appliedHashes = {};
  final List<Map<String, dynamic>> _batches = [];
  final Map<String, List<Map<String, dynamic>>> _batchRows = {};
  final Map<String, List<Map<String, dynamic>>> _versions = {};
  final Map<String, List<SubjectOfferingAdminItem>> _offerings = {};
  final Map<String, List<Map<String, dynamic>>> _offeringVersions = {};

  @override
  Future<List<SubjectItem>> list({
    String? query,
    SubjectStatus? status,
    String sort = 'name_asc',
  }) async {
    final needle = (query ?? '').toLowerCase();
    final rows = _items.where((item) {
      return (status == null || item.status == status) &&
          (needle.isEmpty ||
              item.canonicalName.toLowerCase().contains(needle) ||
              (item.department ?? '').toLowerCase().contains(needle));
    }).toList();
    rows.sort((a, b) {
      if (sort == 'name_desc') {
        return b.canonicalName.compareTo(a.canonicalName);
      }
      return a.canonicalName.compareTo(b.canonicalName);
    });
    return rows;
  }

  @override
  Future<SubjectItem> save(SubjectItem item) async {
    final index = _items.indexWhere((e) => e.id == item.id);
    if (index >= 0) {
      final current = _items[index];
      if (current.catalogRowVersion != item.catalogRowVersion ||
          current.profileRowVersion != item.profileRowVersion) {
        throw const SubjectsRepositoryException(
          'Карточка изменилась. Обновите список.',
          isConflict: true,
        );
      }
      final next = item.copyWith(
        catalogRowVersion: current.catalogRowVersion + 1,
        profileRowVersion: current.profileRowVersion + 1,
      );
      _items[index] = next;
      final versions = _versions.putIfAbsent(item.id, () => []);
      versions.insert(0, {
        'version_number': versions.length + 1,
        'snapshot': next.toJson(),
      });
      return next;
    }
    final created = item.copyWith(
      catalogRowVersion: 1,
      profileRowVersion: 1,
    );
    _items = [..._items, created];
    _versions[created.id] = [
      {'version_number': 1, 'snapshot': created.toJson()},
    ];
    return created;
  }

  @override
  Future<List<SubjectOfferingAdminItem>> listOfferings(String subjectId) async {
    return List<SubjectOfferingAdminItem>.from(_offerings[subjectId] ?? const []);
  }

  @override
  Future<SubjectOfferingAdminItem> setOfferingTeachers({
    required String offeringId,
    required int expectedTeachersRowVersion,
    required List<String> teacherIds,
  }) async {
    for (final entry in _offerings.entries) {
      final idx = entry.value.indexWhere((e) => e.id == offeringId);
      if (idx < 0) continue;
      final current = entry.value[idx];
      if (current.teachersRowVersion != expectedTeachersRowVersion) {
        throw const SubjectsRepositoryException(
          'Offering teachers изменились.',
          isConflict: true,
        );
      }
      if (teacherIds.length != teacherIds.toSet().length) {
        throw const SubjectsRepositoryException('duplicate_teacher_ids');
      }
      final next = SubjectOfferingAdminItem(
        id: current.id,
        subjectId: current.subjectId,
        displayName: current.displayName,
        groupId: current.groupId,
        status: current.status,
        hoursTotal: current.hoursTotal,
        credits: current.credits,
        teachersRowVersion: current.teachersRowVersion + 1,
        overrideRowVersion: current.overrideRowVersion,
        overrideStatus: current.overrideStatus,
        localDescription: current.localDescription,
        teacherSpecificNote: current.teacherSpecificNote,
        assessmentNote: current.assessmentNote,
        workloadNote: current.workloadNote,
        semesterTips: current.semesterTips,
        teacherIds: teacherIds,
      );
      final copy = [...entry.value]..[idx] = next;
      _offerings[entry.key] = copy;
      return next;
    }
    throw const SubjectsRepositoryException('Offering не найден.');
  }

  @override
  Future<SubjectOfferingAdminItem> saveOfferingOverride({
    required String offeringId,
    required int expectedRowVersion,
    String? localDescription,
    String? teacherSpecificNote,
    String? assessmentNote,
    String? workloadNote,
    String? semesterTips,
    String moderationStatus = 'draft',
  }) async {
    for (final entry in _offerings.entries) {
      final idx = entry.value.indexWhere((e) => e.id == offeringId);
      if (idx < 0) continue;
      final current = entry.value[idx];
      if (current.overrideRowVersion != expectedRowVersion) {
        throw const SubjectsRepositoryException(
          'Override изменился.',
          isConflict: true,
        );
      }
      final next = SubjectOfferingAdminItem(
        id: current.id,
        subjectId: current.subjectId,
        displayName: current.displayName,
        groupId: current.groupId,
        status: current.status,
        hoursTotal: current.hoursTotal,
        credits: current.credits,
        teachersRowVersion: current.teachersRowVersion,
        overrideRowVersion: current.overrideRowVersion + 1,
        overrideStatus: moderationStatus,
        localDescription: localDescription,
        teacherSpecificNote: teacherSpecificNote,
        assessmentNote: assessmentNote,
        workloadNote: workloadNote,
        semesterTips: semesterTips,
        teacherIds: current.teacherIds,
      );
      final copy = [...entry.value]..[idx] = next;
      _offerings[entry.key] = copy;
      final versions = _offeringVersions.putIfAbsent(offeringId, () => []);
      versions.insert(0, {
        'version_number': versions.length + 1,
        'created_at': DateTime.now().toIso8601String(),
        'snapshot': {
          'local_description': localDescription,
          'teacher_specific_note': teacherSpecificNote,
          'assessment_note': assessmentNote,
          'workload_note': workloadNote,
          'semester_tips': semesterTips,
          'moderation_status': moderationStatus,
        },
      });
      return next;
    }
    throw const SubjectsRepositoryException('Offering не найден.');
  }

  @override
  Future<List<Map<String, dynamic>>> listOfferingProfileVersions(
    String offeringId,
  ) async {
    return List<Map<String, dynamic>>.from(
      _offeringVersions[offeringId] ?? const [],
    );
  }

  @override
  Future<SubjectOfferingAdminItem> restoreOfferingProfile({
    required String offeringId,
    required int versionNumber,
    required int expectedRowVersion,
  }) async {
    final versions = _offeringVersions[offeringId] ?? const [];
    final match = versions.firstWhere(
      (v) => v['version_number'] == versionNumber,
      orElse: () => throw const SubjectsRepositoryException('version_not_found'),
    );
    final snapshot = Map<String, dynamic>.from(match['snapshot'] as Map);
    SubjectOfferingAdminItem? current;
    for (final entry in _offerings.entries) {
      for (final o in entry.value) {
        if (o.id == offeringId) current = o;
      }
    }
    if (current == null) {
      throw const SubjectsRepositoryException('Offering не найден.');
    }
    if (current.overrideRowVersion != expectedRowVersion) {
      throw const SubjectsRepositoryException(
        'Override изменился.',
        isConflict: true,
      );
    }
    return saveOfferingOverride(
      offeringId: offeringId,
      expectedRowVersion: expectedRowVersion,
      localDescription: snapshot['local_description']?.toString(),
      teacherSpecificNote: snapshot['teacher_specific_note']?.toString(),
      assessmentNote: snapshot['assessment_note']?.toString(),
      workloadNote: snapshot['workload_note']?.toString(),
      semesterTips: snapshot['semester_tips']?.toString(),
      moderationStatus: '${snapshot['moderation_status'] ?? 'draft'}',
    );
  }

  /// Test helper: seed offerings for a subject.
  void seedOffering(SubjectOfferingAdminItem offering) {
    final list = _offerings.putIfAbsent(offering.subjectId, () => []);
    _offerings[offering.subjectId] = [...list, offering];
  }

  @override
  Future<Map<String, dynamic>> importDryRun(
    List<Map<String, dynamic>> rows,
  ) async {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final name = (row['canonical_name'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      String classification;
      String? matched;
      String? error;
      if (name.isEmpty) {
        classification = 'error';
        error = 'canonical_name_required';
      } else if (!seen.add(name)) {
        classification = 'duplicate';
        error = 'duplicate_in_file';
      } else {
        final existing = _items
            .where((e) => e.canonicalName.trim().toLowerCase() == name)
            .toList();
        if (existing.length == 1) {
          classification = 'update';
          matched = existing.first.id;
        } else if (existing.length > 1) {
          classification = 'duplicate';
          error = 'ambiguous_name';
        } else {
          classification = 'new';
        }
      }
      items.add({
        'row_number': i + 1,
        'classification': classification,
        'matched_subject_id': matched,
        'error_text': error,
        'payload': row,
      });
    }
    return {'rows': rows.length, 'items': items};
  }

  @override
  Future<Map<String, dynamic>> importApply(
    List<Map<String, dynamic>> rows,
  ) async {
    final hash = jsonEncode(rows);
    if (_appliedHashes.contains(hash)) {
      return {'idempotent_replay': true, 'created': 0, 'updated': 0};
    }
    final dry = await importDryRun(rows);
    var created = 0;
    var updated = 0;
    for (final item in (dry['items'] as List)) {
      final map = Map<String, dynamic>.from(item as Map);
      final payload = Map<String, dynamic>.from(map['payload'] as Map);
      final classification = map['classification']?.toString();
      if (classification == 'new') {
        await save(
          SubjectItem(
            id: 'local-${DateTime.now().microsecondsSinceEpoch}-$created',
            canonicalName: '${payload['canonical_name'] ?? ''}',
            department: payload['department']?.toString(),
            controlForm: payload['control_form']?.toString(),
            description: '${payload['description'] ?? ''}',
            shortDescription: '${payload['short_description'] ?? ''}',
          ),
        );
        created++;
      } else if (classification == 'update') {
        final id = map['matched_subject_id']?.toString();
        final current = _items.firstWhere((e) => e.id == id);
        await save(
          current.copyWith(
            canonicalName:
                '${payload['canonical_name'] ?? current.canonicalName}',
            department: payload['department']?.toString(),
            controlForm: payload['control_form']?.toString(),
            description: '${payload['description'] ?? current.description}',
            shortDescription:
                '${payload['short_description'] ?? current.shortDescription}',
          ),
        );
        updated++;
      }
    }
    _appliedHashes.add(hash);
    final batchId = 'batch-${_batches.length + 1}';
    _batches.insert(0, {
      'id': batchId,
      'status': 'applied',
      'summary': {'created': created, 'updated': updated},
      'created_at': DateTime.now().toIso8601String(),
    });
    _batchRows[batchId] = [
      for (final item in (dry['items'] as List))
        Map<String, dynamic>.from(item as Map),
    ];
    return {'created': created, 'updated': updated, 'idempotent_replay': false};
  }

  @override
  Future<List<Map<String, dynamic>>> listImportBatches({
    int limit = 20,
  }) async => _batches.take(limit).toList();

  @override
  Future<List<Map<String, dynamic>>> listImportRows(String batchId) async =>
      List<Map<String, dynamic>>.from(_batchRows[batchId] ?? const []);

  @override
  Future<List<Map<String, dynamic>>> listVersions(String subjectId) async =>
      List<Map<String, dynamic>>.from(_versions[subjectId] ?? const []);

  @override
  Future<void> restoreVersion(
    String subjectId,
    int versionNumber, {
    required int expectedCatalogRowVersion,
    required int expectedProfileRowVersion,
  }) async {
    final current = _items.firstWhere((e) => e.id == subjectId);
    if (current.catalogRowVersion != expectedCatalogRowVersion ||
        current.profileRowVersion != expectedProfileRowVersion) {
      throw const SubjectsRepositoryException(
        'Карточка изменилась. Обновите список.',
        isConflict: true,
      );
    }
    final match = (_versions[subjectId] ?? const []).firstWhere(
      (v) => v['version_number'] == versionNumber,
    );
    await save(
      SubjectItem.fromJson({
        ...Map<String, dynamic>.from(match['snapshot'] as Map),
        'id': subjectId,
        'catalog_row_version': expectedCatalogRowVersion,
        'profile_row_version': expectedProfileRowVersion,
      }),
    );
  }
}

class SupabaseSubjectsRepository implements SubjectsRepository {
  SupabaseSubjectsRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;
  final SupabaseClient _client;

  @override
  Future<List<SubjectItem>> list({
    String? query,
    SubjectStatus? status,
    String sort = 'name_asc',
  }) async {
    final result = await _client.rpc(
      'admin_list_subjects',
      params: {'p_query': query, 'p_status': status?.name, 'p_sort': sort},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((value) => SubjectItem.fromJson(Map<String, dynamic>.from(value)))
        .toList();
  }

  @override
  Future<SubjectItem> save(SubjectItem item) async {
    try {
      final isNew =
          item.id.isEmpty ||
          item.id.startsWith('local-') ||
          item.id.startsWith('new-');
      final result = await _client.rpc(
        'admin_upsert_subject_card',
        params: {
          'p_id': isNew ? null : item.id,
          'p_expected_catalog_row_version': isNew ? 0 : item.catalogRowVersion,
          'p_expected_profile_row_version': isNew ? 0 : item.profileRowVersion,
          'p_canonical_name': item.canonicalName,
          'p_description': item.description,
          'p_department': item.department,
          'p_control_form': item.controlForm,
          'p_difficulty_label': item.difficultyLabel,
          'p_requirements': item.requirements,
          'p_learning_outcomes': item.learningOutcomes,
          'p_useful_links': item.usefulLinks
              .map(
                (link) =>
                    link is Map ? link : {'title': '$link', 'url': '$link'},
              )
              .toList(),
          'p_status': item.status.name,
          'p_short_description': item.shortDescription,
          'p_what_to_expect': item.whatToExpect,
          'p_how_to_pass': item.howToPass,
          'p_useful_materials_note': item.usefulMaterialsNote,
          'p_common_pitfalls': item.commonPitfalls,
          'p_relevance_date': item.relevanceDate,
          'p_section_order': item.sectionOrder,
        },
      );
      final decoded = result is String ? jsonDecode(result) : result;
      final map = Map<String, dynamic>.from(decoded as Map);
      return SubjectItem.fromJson({
        ...item.toJson(),
        'id': '${map['id']}',
        'catalog_row_version': map['catalog_row_version'],
        'profile_row_version': map['profile_row_version'],
      });
    } on PostgrestException catch (error) {
      final message = error.message.toLowerCase();
      if (message.contains('row_version_conflict') || error.code == '40001') {
        throw const SubjectsRepositoryException(
          'Карточка изменилась. Обновите список.',
          isConflict: true,
        );
      }
      rethrow;
    }
  }

  @override
  Future<List<SubjectOfferingAdminItem>> listOfferings(String subjectId) async {
    final result = await _client.rpc(
      'admin_list_subject_offerings',
      params: {'p_subject_id': subjectId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map(
          (e) => SubjectOfferingAdminItem.fromJson(
            Map<String, dynamic>.from(e as Map),
          ),
        )
        .toList();
  }

  @override
  Future<SubjectOfferingAdminItem> setOfferingTeachers({
    required String offeringId,
    required int expectedTeachersRowVersion,
    required List<String> teacherIds,
  }) async {
    try {
      final result = await _client.rpc(
        'admin_set_offering_teachers',
        params: {
          'p_subject_offering_id': offeringId,
          'p_expected_teachers_row_version': expectedTeachersRowVersion,
          'p_teacher_ids': teacherIds,
        },
      );
      final decoded = result is String ? jsonDecode(result) : result;
      final map = Map<String, dynamic>.from(decoded as Map);
      return SubjectOfferingAdminItem(
        id: offeringId,
        subjectId: '',
        teachersRowVersion:
            int.tryParse('${map['teachers_row_version'] ?? 1}') ?? 1,
        teacherIds: [
          for (final id in (map['teacher_ids'] as List? ?? const []))
            id.toString(),
        ],
      );
    } on PostgrestException catch (error) {
      if ((error.message.toLowerCase().contains('row_version_conflict')) ||
          error.code == '40001') {
        throw const SubjectsRepositoryException(
          'Offering teachers изменились.',
          isConflict: true,
        );
      }
      rethrow;
    }
  }

  @override
  Future<SubjectOfferingAdminItem> saveOfferingOverride({
    required String offeringId,
    required int expectedRowVersion,
    String? localDescription,
    String? teacherSpecificNote,
    String? assessmentNote,
    String? workloadNote,
    String? semesterTips,
    String moderationStatus = 'draft',
  }) async {
    try {
      final result = await _client.rpc(
        'admin_upsert_offering_student_profile',
        params: {
          'p_subject_offering_id': offeringId,
          'p_expected_row_version': expectedRowVersion,
          'p_local_description': localDescription,
          'p_teacher_specific_note': teacherSpecificNote,
          'p_assessment_note': assessmentNote,
          'p_workload_note': workloadNote,
          'p_semester_tips': semesterTips,
          'p_moderation_status': moderationStatus,
        },
      );
      final decoded = result is String ? jsonDecode(result) : result;
      final map = Map<String, dynamic>.from(decoded as Map);
      return SubjectOfferingAdminItem(
        id: offeringId,
        subjectId: '',
        overrideRowVersion: int.tryParse('${map['row_version'] ?? 1}') ?? 1,
        overrideStatus: moderationStatus,
        localDescription: localDescription,
        teacherSpecificNote: teacherSpecificNote,
        assessmentNote: assessmentNote,
        workloadNote: workloadNote,
        semesterTips: semesterTips,
      );
    } on PostgrestException catch (error) {
      if ((error.message.toLowerCase().contains('row_version_conflict')) ||
          error.code == '40001') {
        throw const SubjectsRepositoryException(
          'Override изменился.',
          isConflict: true,
        );
      }
      rethrow;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listOfferingProfileVersions(
    String offeringId,
  ) async {
    final result = await _client.rpc(
      'admin_list_offering_profile_versions',
      params: {'p_subject_offering_id': offeringId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return [
      for (final row in (decoded as List))
        Map<String, dynamic>.from(row as Map),
    ];
  }

  @override
  Future<SubjectOfferingAdminItem> restoreOfferingProfile({
    required String offeringId,
    required int versionNumber,
    required int expectedRowVersion,
  }) async {
    final result = await _client.rpc(
      'admin_restore_offering_student_profile',
      params: {
        'p_subject_offering_id': offeringId,
        'p_version_number': versionNumber,
        'p_expected_row_version': expectedRowVersion,
      },
    );
    final decoded = result is String ? jsonDecode(result) : result;
    final map = Map<String, dynamic>.from(decoded as Map);
    return SubjectOfferingAdminItem(
      id: offeringId,
      subjectId: '',
      overrideRowVersion: int.tryParse('${map['row_version'] ?? 1}') ?? 1,
      localDescription: map['local_description']?.toString(),
      teacherSpecificNote: map['teacher_specific_note']?.toString(),
      assessmentNote: map['assessment_note']?.toString(),
      workloadNote: map['workload_note']?.toString(),
      semesterTips: map['semester_tips']?.toString(),
      overrideStatus: map['moderation_status']?.toString(),
    );
  }

  @override
  Future<Map<String, dynamic>> importDryRun(
    List<Map<String, dynamic>> rows,
  ) async {
    final result = await _client.rpc(
      'admin_subject_import_dry_run',
      params: {'p_rows': rows},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<Map<String, dynamic>> importApply(
    List<Map<String, dynamic>> rows,
  ) async {
    final result = await _client.rpc(
      'admin_subject_import_apply',
      params: {'p_rows': rows},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<List<Map<String, dynamic>>> listImportBatches({int limit = 20}) async {
    final result = await _client.rpc(
      'admin_list_subject_import_batches',
      params: {'p_limit': limit},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> listImportRows(String batchId) async {
    final result = await _client.rpc(
      'admin_list_subject_import_rows',
      params: {'p_batch_id': batchId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> listVersions(String subjectId) async {
    final result = await _client.rpc(
      'admin_list_subject_versions',
      params: {'p_id': subjectId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<void> restoreVersion(
    String subjectId,
    int versionNumber, {
    required int expectedCatalogRowVersion,
    required int expectedProfileRowVersion,
  }) async {
    try {
      await _client.rpc(
        'admin_restore_subject_version',
        params: {
          'p_id': subjectId,
          'p_version_number': versionNumber,
          'p_expected_catalog_row_version': expectedCatalogRowVersion,
          'p_expected_profile_row_version': expectedProfileRowVersion,
        },
      );
    } on PostgrestException catch (error) {
      if ((error.message.toLowerCase().contains('row_version_conflict')) ||
          error.code == '40001') {
        throw const SubjectsRepositoryException(
          'Карточка изменилась. Обновите список.',
          isConflict: true,
        );
      }
      rethrow;
    }
  }
}
