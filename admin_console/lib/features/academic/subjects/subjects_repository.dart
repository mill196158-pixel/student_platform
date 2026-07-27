import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'subject_item.dart';

abstract class SubjectsRepository {
  Future<List<SubjectItem>> list({
    String? query,
    SubjectStatus? status,
    String sort = 'name_asc',
  });
  Future<SubjectItem> save(SubjectItem item);
  Future<Map<String, dynamic>> importDryRun(List<Map<String, dynamic>> rows);
  Future<Map<String, dynamic>> importApply(List<Map<String, dynamic>> rows);
  Future<List<Map<String, dynamic>>> listImportBatches({int limit = 20});
  Future<List<Map<String, dynamic>>> listImportRows(String batchId);
  Future<List<Map<String, dynamic>>> listVersions(String subjectId);
  Future<void> restoreVersion(String subjectId, int versionNumber);
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
      _items[index] = item;
    } else {
      _items = [..._items, item];
    }
    final versions = _versions.putIfAbsent(item.id, () => []);
    versions.insert(0, {
      'version_number': versions.length + 1,
      'snapshot': item.toJson(),
    });
    return item;
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
  Future<void> restoreVersion(String subjectId, int versionNumber) async {
    final match = (_versions[subjectId] ?? const []).firstWhere(
      (v) => v['version_number'] == versionNumber,
    );
    await save(
      SubjectItem.fromJson({
        ...Map<String, dynamic>.from(match['snapshot'] as Map),
        'id': subjectId,
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
    final id = await _client.rpc(
      'admin_upsert_subject',
      params: {
        'p_id': item.id.startsWith('local-') || item.id.startsWith('new-')
            ? null
            : item.id,
        'p_canonical_name': item.canonicalName,
        'p_description': item.description,
        'p_department': item.department,
        'p_control_form': item.controlForm,
        'p_difficulty_label': item.difficultyLabel,
        'p_requirements': item.requirements,
        'p_learning_outcomes': item.learningOutcomes,
        'p_useful_links': item.usefulLinks
            .map(
              (link) => link is Map ? link : {'title': '$link', 'url': '$link'},
            )
            .toList(),
        'p_status': item.status.name,
        'p_short_description': item.shortDescription,
        'p_what_to_expect': item.whatToExpect,
        'p_how_to_pass': item.howToPass,
        'p_useful_materials_note': item.usefulMaterialsNote,
        'p_common_pitfalls': item.commonPitfalls,
      },
    );
    return SubjectItem.fromJson({...item.toJson(), 'id': '$id'});
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
  Future<void> restoreVersion(String subjectId, int versionNumber) async {
    await _client.rpc(
      'admin_restore_subject_version',
      params: {'p_id': subjectId, 'p_version_number': versionNumber},
    );
  }
}
