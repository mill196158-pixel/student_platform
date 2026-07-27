import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'group_space_organizer_models.dart';

class StudentItem {
  const StudentItem({
    required this.id,
    required this.login,
    this.name = '',
    this.surname = '',
    this.isActive = true,
    this.primaryGroupId,
    this.groupName,
  });

  final String id;
  final String login;
  final String name;
  final String surname;
  final bool isActive;
  final String? primaryGroupId;
  final String? groupName;

  factory StudentItem.fromJson(Map<String, dynamic> json) => StudentItem(
    id: '${json['id'] ?? ''}',
    login: '${json['login'] ?? ''}',
    name: '${json['name'] ?? ''}',
    surname: '${json['surname'] ?? ''}',
    isActive: json['is_active'] != false,
    primaryGroupId: json['primary_group_id']?.toString(),
    groupName: json['group_name']?.toString(),
  );
}

class GroupItem {
  const GroupItem({
    required this.id,
    required this.name,
    this.membersCount = 0,
  });
  final String id;
  final String name;
  final int membersCount;
  factory GroupItem.fromJson(Map<String, dynamic> json) => GroupItem(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    membersCount: int.tryParse('${json['members_count'] ?? 0}') ?? 0,
  );
}

class TermItem {
  const TermItem({
    required this.id,
    required this.label,
    this.isCurrent = false,
  });
  final String id;
  final String label;
  final bool isCurrent;
  factory TermItem.fromJson(Map<String, dynamic> json) => TermItem(
    id: '${json['id'] ?? ''}',
    label: '${json['name'] ?? json['year_name'] ?? json['id'] ?? ''}',
    isCurrent: json['is_current'] == true,
  );
}

abstract class StudentsRepository {
  Future<List<StudentItem>> listStudents({
    String? query,
    bool? active,
    String? groupId,
  });
  Future<List<GroupItem>> listGroups();
  Future<List<TermItem>> listTerms();
  Future<void> updateStudent({
    required String id,
    String? name,
    String? surname,
    bool? isActive,
  });
  Future<void> assignGroup({required String userId, required String groupId});
  Future<Map<String, dynamic>> importDryRun(List<Map<String, dynamic>> rows);
  Future<Map<String, dynamic>> importApply(List<Map<String, dynamic>> rows);
  Future<Map<String, dynamic>> prepareTermDryRun(String termId);
  Future<Map<String, dynamic>> prepareTermApply({
    required String termId,
    bool setCurrent = false,
  });
  Future<GroupItem> upsertGroup({String? id, required String name});
  Future<List<Map<String, dynamic>>> listOpsBatches({int limit = 20});
  Future<List<Map<String, dynamic>>> listOpsRows(String batchId);
  Future<Map<String, dynamic>> bulkSetActive({
    required List<String> userIds,
    required bool isActive,
  });
  Future<GroupSpaceOrganizerState> listGroupSpaceOrganizerState(String groupId);
  Future<void> setGroupSpaceOrganizer({
    required String groupId,
    required String userId,
    required bool isOrganizer,
  });
}

class LocalStudentsRepository implements StudentsRepository {
  LocalStudentsRepository()
    : _students = [
        const StudentItem(
          id: 's1',
          login: 'ivanov',
          name: 'Иван',
          surname: 'Иванов',
          primaryGroupId: 'g1',
          groupName: 'ИВТ-21',
        ),
        const StudentItem(
          id: 's2',
          login: 'petrova',
          name: 'Анна',
          surname: 'Петрова',
          isActive: false,
          primaryGroupId: 'g1',
          groupName: 'ИВТ-21',
        ),
        const StudentItem(
          id: 's3',
          login: 'starosta',
          name: 'Олег',
          surname: 'Старостин',
          primaryGroupId: 'g1',
          groupName: 'ИВТ-21',
        ),
      ],
      _groups = [const GroupItem(id: 'g1', name: 'ИВТ-21', membersCount: 3)],
      _terms = [
        const TermItem(id: 't1', label: '2025/2026 · 2', isCurrent: true),
        const TermItem(id: 't2', label: '2026/2027 · 1'),
      ],
      // Demo: natural organizer from active subject-team starosta.
      _subjectTeamOrganizers = {'s3'},
      _adminOrganizerGrants = {};

  final List<StudentItem> _students;
  final List<GroupItem> _groups;
  final List<TermItem> _terms;
  final Set<String> _hashes = {};
  final Set<String> _subjectTeamOrganizers;
  final Set<String> _adminOrganizerGrants;

  @override
  Future<List<StudentItem>> listStudents({
    String? query,
    bool? active,
    String? groupId,
  }) async {
    final needle = (query ?? '').toLowerCase();
    return _students.where((s) {
      return (active == null || s.isActive == active) &&
          (groupId == null || s.primaryGroupId == groupId) &&
          (needle.isEmpty ||
              s.login.contains(needle) ||
              s.name.toLowerCase().contains(needle) ||
              s.surname.toLowerCase().contains(needle));
    }).toList();
  }

  @override
  Future<List<GroupItem>> listGroups() async => _groups;

  @override
  Future<List<TermItem>> listTerms() async => _terms;

  @override
  Future<void> updateStudent({
    required String id,
    String? name,
    String? surname,
    bool? isActive,
  }) async {
    final index = _students.indexWhere((s) => s.id == id);
    if (index < 0) return;
    final current = _students[index];
    _students[index] = StudentItem(
      id: current.id,
      login: current.login,
      name: name ?? current.name,
      surname: surname ?? current.surname,
      isActive: isActive ?? current.isActive,
      primaryGroupId: current.primaryGroupId,
      groupName: current.groupName,
    );
  }

  @override
  Future<void> assignGroup({
    required String userId,
    required String groupId,
  }) async {
    final group = _groups.firstWhere((g) => g.id == groupId);
    final index = _students.indexWhere((s) => s.id == userId);
    if (index < 0) return;
    final current = _students[index];
    _students[index] = StudentItem(
      id: current.id,
      login: current.login,
      name: current.name,
      surname: current.surname,
      isActive: current.isActive,
      primaryGroupId: group.id,
      groupName: group.name,
    );
  }

  @override
  Future<Map<String, dynamic>> importDryRun(
    List<Map<String, dynamic>> rows,
  ) async {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var i = 0; i < rows.length; i++) {
      final login = (rows[i]['login'] ?? '').toString().trim().toLowerCase();
      String classification;
      String? matched;
      String? error;
      if (login.isEmpty) {
        classification = 'error';
        error = 'login_required';
      } else if (!seen.add(login)) {
        classification = 'duplicate';
        error = 'duplicate_in_file';
      } else {
        final existing = _students.where((s) => s.login == login).toList();
        if (existing.isEmpty) {
          classification = 'error';
          error = 'auth_user_missing';
        } else {
          classification = 'update';
          matched = existing.first.id;
        }
      }
      items.add({
        'row_number': i + 1,
        'classification': classification,
        'matched_user_id': matched,
        'error_text': error,
        'payload': rows[i],
      });
    }
    return {'rows': rows.length, 'items': items};
  }

  @override
  Future<Map<String, dynamic>> importApply(
    List<Map<String, dynamic>> rows,
  ) async {
    final hash = jsonEncode(rows);
    if (_hashes.contains(hash)) {
      return {'idempotent_replay': true, 'updated': 0};
    }
    final dry = await importDryRun(rows);
    var updated = 0;
    for (final item in (dry['items'] as List)) {
      if (item['classification'] != 'update') continue;
      final payload = Map<String, dynamic>.from(item['payload'] as Map);
      await updateStudent(
        id: '${item['matched_user_id']}',
        name: payload['name']?.toString(),
        surname: payload['surname']?.toString(),
      );
      updated++;
    }
    _hashes.add(hash);
    return {'idempotent_replay': false, 'updated': updated};
  }

  @override
  Future<Map<String, dynamic>> prepareTermDryRun(String termId) async => {
    'term_id': termId,
    'groups_count': _groups.length,
    'missing_offerings': 2,
    'missing_teams': 1,
  };

  @override
  Future<Map<String, dynamic>> prepareTermApply({
    required String termId,
    bool setCurrent = false,
  }) async {
    final key = '$termId:$setCurrent';
    if (_hashes.contains(key)) {
      return {'idempotent_replay': true};
    }
    _hashes.add(key);
    return {
      'idempotent_replay': false,
      'created_offerings': 2,
      'created_teams': 1,
      'synced_group_spaces': _groups.length,
      'set_current': setCurrent,
    };
  }

  @override
  Future<GroupItem> upsertGroup({String? id, required String name}) async {
    final item = GroupItem(
      id: id ?? 'g-${_groups.length + 1}',
      name: name,
      membersCount: 0,
    );
    final index = _groups.indexWhere((g) => g.id == item.id);
    if (index >= 0) {
      _groups[index] = item;
    } else {
      _groups.add(item);
    }
    return item;
  }

  final List<Map<String, dynamic>> _batches = [];

  @override
  Future<List<Map<String, dynamic>>> listOpsBatches({int limit = 20}) async =>
      _batches.take(limit).toList();

  @override
  Future<List<Map<String, dynamic>>> listOpsRows(String batchId) async =>
      const [];

  @override
  Future<Map<String, dynamic>> bulkSetActive({
    required List<String> userIds,
    required bool isActive,
  }) async {
    for (final id in userIds) {
      await updateStudent(id: id, isActive: isActive);
    }
    return {'ok': userIds, 'error': <String>[]};
  }

  @override
  Future<GroupSpaceOrganizerState> listGroupSpaceOrganizerState(
    String groupId,
  ) async {
    final index = _groups.indexWhere((g) => g.id == groupId);
    if (index < 0) {
      throw StateError('group_not_found');
    }
    final group = _groups[index];
    final members = _students.where((s) => s.primaryGroupId == groupId).map((
      s,
    ) {
      final hasAdmin = _adminOrganizerGrants.contains(s.id);
      final hasSubject = _subjectTeamOrganizers.contains(s.id);
      final sources = <String>[
        if (hasAdmin) 'admin',
        if (hasSubject) 'subject_team',
      ];
      return GroupSpaceMemberOrganizer(
        userId: s.id,
        login: s.login,
        name: s.name,
        surname: s.surname,
        isActive: s.isActive,
        hasAdminGrant: hasAdmin,
        hasSubjectTeamAuthority: hasSubject,
        subjectTeamRoles: hasSubject ? const ['starosta'] : const [],
        sources: sources,
      );
    }).toList();
    return GroupSpaceOrganizerState(
      groupId: group.id,
      groupName: group.name,
      spaceExists: true,
      teamId: 'team-$groupId',
      canManage: true,
      assistantsSupported: false,
      members: members,
    );
  }

  @override
  Future<void> setGroupSpaceOrganizer({
    required String groupId,
    required String userId,
    required bool isOrganizer,
  }) async {
    final belongs = _students.any(
      (s) => s.id == userId && s.primaryGroupId == groupId,
    );
    if (!belongs) {
      throw StateError('invalid_group_member');
    }
    if (isOrganizer) {
      _adminOrganizerGrants.add(userId);
    } else {
      // Only removes explicit admin grant; natural subject-team authority stays.
      _adminOrganizerGrants.remove(userId);
    }
  }
}

class SupabaseStudentsRepository implements StudentsRepository {
  SupabaseStudentsRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;
  final SupabaseClient _client;

  @override
  Future<List<StudentItem>> listStudents({
    String? query,
    bool? active,
    String? groupId,
  }) async {
    final result = await _client.rpc(
      'admin_list_students',
      params: {'p_query': query, 'p_group_id': groupId, 'p_active': active},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => StudentItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<List<GroupItem>> listGroups() async {
    final result = await _client.rpc('admin_list_groups');
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => GroupItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<List<TermItem>> listTerms() async {
    final result = await _client.rpc('admin_list_terms');
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => TermItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<void> updateStudent({
    required String id,
    String? name,
    String? surname,
    bool? isActive,
  }) async {
    await _client.rpc(
      'admin_upsert_student_profile',
      params: {
        'p_id': id,
        'p_name': name,
        'p_surname': surname,
        'p_is_active': isActive,
      },
    );
  }

  @override
  Future<void> assignGroup({
    required String userId,
    required String groupId,
  }) async {
    await _client.rpc(
      'admin_assign_student_group',
      params: {'p_user_id': userId, 'p_group_id': groupId},
    );
  }

  @override
  Future<Map<String, dynamic>> importDryRun(
    List<Map<String, dynamic>> rows,
  ) async {
    final result = await _client.rpc(
      'admin_student_import_dry_run',
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
      'admin_student_import_apply',
      params: {'p_rows': rows},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<Map<String, dynamic>> prepareTermDryRun(String termId) async {
    final result = await _client.rpc(
      'admin_prepare_term_dry_run',
      params: {'p_term_id': termId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<Map<String, dynamic>> prepareTermApply({
    required String termId,
    bool setCurrent = false,
  }) async {
    final result = await _client.rpc(
      'admin_prepare_term_apply',
      params: {'p_term_id': termId, 'p_set_current': setCurrent},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<GroupItem> upsertGroup({String? id, required String name}) async {
    final result = await _client.rpc(
      'admin_upsert_group',
      params: {'p_id': id, 'p_name': name},
    );
    return GroupItem(id: '$result', name: name);
  }

  @override
  Future<List<Map<String, dynamic>>> listOpsBatches({int limit = 20}) async {
    final result = await _client.rpc(
      'admin_list_term_ops_batches',
      params: {'p_limit': limit},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> listOpsRows(String batchId) async {
    final result = await _client.rpc(
      'admin_list_term_ops_rows',
      params: {'p_batch_id': batchId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<Map<String, dynamic>> bulkSetActive({
    required List<String> userIds,
    required bool isActive,
  }) async {
    final result = await _client.rpc(
      'admin_bulk_set_student_active',
      params: {'p_user_ids': userIds, 'p_is_active': isActive},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<GroupSpaceOrganizerState> listGroupSpaceOrganizerState(
    String groupId,
  ) async {
    final result = await _client.rpc(
      'admin_list_group_space_organizer_state',
      params: {'p_group_id': groupId},
    );
    final decoded = result is String ? jsonDecode(result) : result;
    return GroupSpaceOrganizerState.fromJson(
      Map<String, dynamic>.from(decoded as Map),
    );
  }

  @override
  Future<void> setGroupSpaceOrganizer({
    required String groupId,
    required String userId,
    required bool isOrganizer,
  }) async {
    await _client.rpc(
      'admin_set_group_space_organizer',
      params: {
        'p_group_id': groupId,
        'p_user_id': userId,
        'p_is_organizer': isOrganizer,
      },
    );
  }
}
