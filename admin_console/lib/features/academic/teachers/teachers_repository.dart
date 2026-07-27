import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'teacher_item.dart';

abstract class TeachersRepository {
  Future<List<TeacherItem>> list({
    String? query,
    TeacherStatus? status,
    String sort = 'name_asc',
  });
  Future<TeacherItem> save(TeacherItem item);
  Future<Map<String, dynamic>> importDryRun(List<Map<String, dynamic>> rows);
  Future<Map<String, dynamic>> importApply(List<Map<String, dynamic>> rows);
  Future<List<Map<String, dynamic>>> listImportBatches({int limit = 20});
  Future<List<Map<String, dynamic>>> listImportRows(String batchId);
  Future<List<Map<String, dynamic>>> listVersions(String teacherId);
  Future<void> restoreVersion(String teacherId, int versionNumber);
}

class LocalTeachersRepository implements TeachersRepository {
  LocalTeachersRepository({List<TeacherItem>? seed})
    : _items =
          seed ??
          [
            const TeacherItem(
              id: 'local-1',
              fullName: 'Анна Викторовна Соколова',
              department: 'Информационные системы',
              status: TeacherStatus.draft,
              relatedSubjects: ['Базы данных'],
            ),
            const TeacherItem(
              id: 'local-2',
              fullName: 'Михаил Сергеевич Лебедев',
              department: 'Прикладная математика',
              aboutText: 'Ведёт профильные дисциплины.',
              status: TeacherStatus.published,
            ),
          ];
  List<TeacherItem> _items;
  final Set<String> _appliedHashes = {};
  final List<Map<String, dynamic>> _batches = [];
  final Map<String, List<Map<String, dynamic>>> _batchRows = {};
  final Map<String, List<Map<String, dynamic>>> _versions = {};

  @override
  Future<List<TeacherItem>> list({
    String? query,
    TeacherStatus? status,
    String sort = 'name_asc',
  }) async {
    final needle = (query ?? '').toLowerCase();
    final rows = _items.where((item) {
      return (status == null || item.status == status) &&
          (needle.isEmpty ||
              item.fullName.toLowerCase().contains(needle) ||
              (item.department ?? '').toLowerCase().contains(needle));
    }).toList();
    rows.sort((a, b) {
      if (sort == 'name_desc') return b.fullName.compareTo(a.fullName);
      return a.fullName.compareTo(b.fullName);
    });
    return rows;
  }

  @override
  Future<TeacherItem> save(TeacherItem item) async {
    final index = _items.indexWhere((candidate) => candidate.id == item.id);
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
      final name = (row['full_name'] ?? '').toString().trim().toLowerCase();
      String classification;
      String? matched;
      String? error;
      if (name.isEmpty) {
        classification = 'error';
        error = 'full_name_required';
      } else if (!seen.add(name)) {
        classification = 'duplicate';
        error = 'duplicate_in_file';
      } else {
        final existing = _items
            .where((e) => e.fullName.trim().toLowerCase() == name)
            .toList();
        if (existing.length > 1) {
          classification = 'duplicate';
          error = 'ambiguous_name';
        } else if (existing.length == 1) {
          classification = 'update';
          matched = existing.first.id;
        } else {
          classification = 'new';
        }
      }
      items.add({
        'row_number': i + 1,
        'classification': classification,
        'matched_teacher_id': matched,
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
          TeacherItem(
            id: 'local-${DateTime.now().microsecondsSinceEpoch}-$created',
            fullName: '${payload['full_name'] ?? ''}',
            department: payload['department']?.toString(),
            position: payload['position']?.toString(),
            academicDegree: payload['academic_degree']?.toString(),
            aboutText: '${payload['about_text'] ?? ''}',
          ),
        );
        created++;
      } else if (classification == 'update') {
        final id = map['matched_teacher_id']?.toString();
        final current = _items.firstWhere((e) => e.id == id);
        await save(
          current.copyWith(
            fullName: '${payload['full_name'] ?? current.fullName}',
            department: payload['department']?.toString(),
            position: payload['position']?.toString(),
            academicDegree: payload['academic_degree']?.toString(),
            aboutText: '${payload['about_text'] ?? current.aboutText}',
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
  Future<List<Map<String, dynamic>>> listImportBatches({int limit = 20}) async {
    return _batches.take(limit).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> listImportRows(String batchId) async {
    return List<Map<String, dynamic>>.from(_batchRows[batchId] ?? const []);
  }

  @override
  Future<List<Map<String, dynamic>>> listVersions(String teacherId) async {
    return List<Map<String, dynamic>>.from(_versions[teacherId] ?? const []);
  }

  @override
  Future<void> restoreVersion(String teacherId, int versionNumber) async {
    final versions = _versions[teacherId] ?? const [];
    final match = versions.firstWhere(
      (v) => v['version_number'] == versionNumber,
    );
    final snapshot = Map<String, dynamic>.from(match['snapshot'] as Map);
    await save(TeacherItem.fromJson({...snapshot, 'id': teacherId}));
  }
}

class SupabaseTeachersRepository implements TeachersRepository {
  SupabaseTeachersRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;
  final SupabaseClient _client;

  @override
  Future<List<TeacherItem>> list({
    String? query,
    TeacherStatus? status,
    String sort = 'name_asc',
  }) async {
    final result = await _client.rpc(
      'admin_list_teachers',
      params: {'p_query': query, 'p_status': status?.name, 'p_sort': sort},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((value) => TeacherItem.fromJson(Map<String, dynamic>.from(value)))
        .toList();
  }

  @override
  Future<TeacherItem> save(TeacherItem item) async {
    final id = await _client.rpc(
      'admin_upsert_teacher',
      params: {
        'p_id': item.id.startsWith('local-') || item.id.startsWith('new-')
            ? null
            : item.id,
        'p_full_name': item.fullName,
        'p_department': item.department,
        'p_position': item.position,
        'p_academic_degree': item.academicDegree,
        'p_about_text': item.aboutText,
        'p_status': item.status.name,
        'p_contacts_public': item.contactsPublic,
        'p_photo_path': item.photoPath,
      },
    );
    return TeacherItem.fromJson({...item.toJson(), 'id': '$id'});
  }

  @override
  Future<Map<String, dynamic>> importDryRun(
    List<Map<String, dynamic>> rows,
  ) async {
    final result = await _client.rpc(
      'admin_teacher_import_dry_run',
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
      'admin_teacher_import_apply',
      params: {'p_rows': rows},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<List<Map<String, dynamic>>> listImportBatches({int limit = 20}) async {
    final result = await _client.rpc(
      'admin_list_teacher_import_batches',
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
      'admin_list_teacher_import_rows',
      params: {'p_batch_id': batchId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> listVersions(String teacherId) async {
    final result = await _client.rpc(
      'admin_list_teacher_versions',
      params: {'p_id': teacherId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<void> restoreVersion(String teacherId, int versionNumber) async {
    await _client.rpc(
      'admin_restore_teacher_version',
      params: {'p_id': teacherId, 'p_version_number': versionNumber},
    );
  }
}
