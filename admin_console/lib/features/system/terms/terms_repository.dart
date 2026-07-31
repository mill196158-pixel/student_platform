import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'terms_models.dart';

abstract class TermsRepository {
  Future<List<AcademicTermView>> listTerms();
  Future<TermReadiness> readiness({String? termId});
  Future<Map<String, dynamic>> backfillDryRun(String termId);
  Future<Map<String, dynamic>> backfill(String termId);
  Future<TermTransitionPreview> startNextDryRun(String termId);
  Future<Map<String, dynamic>> startNext({
    required String termId,
    required String confirmName,
  });
}

class LocalTermsRepository implements TermsRepository {
  LocalTermsRepository()
    : _terms = [
        AcademicTermView(
          id: 't1',
          name: 'осень 2025',
          lifecycle: 'completed',
          isCurrent: false,
          isNearestNext: false,
          startsOn: DateTime(2025, 9, 1),
          endsOn: DateTime(2026, 1, 31),
          yearName: '2025/2026',
          termSequence: 20251,
        ),
        AcademicTermView(
          id: 't2',
          name: 'весна 2026',
          lifecycle: 'active',
          isCurrent: true,
          isNearestNext: false,
          startsOn: DateTime(2026, 2, 1),
          endsOn: DateTime(2026, 6, 30),
          yearName: '2025/2026',
          termSequence: 20252,
        ),
        AcademicTermView(
          id: 't3',
          name: 'осень 2026',
          lifecycle: 'planned',
          isCurrent: false,
          isNearestNext: true,
          startsOn: DateTime(2026, 9, 1),
          endsOn: DateTime(2027, 1, 31),
          yearName: '2026/2027',
          termSequence: 20261,
        ),
      ],
      _missingSubjects = {'t1': 0, 't2': 0, 't3': 3},
      _missingChats = {'t1': 0, 't2': 0, 't3': 2},
      _backfilled = <String>{};

  final List<AcademicTermView> _terms;
  final Map<String, int> _missingSubjects;
  final Map<String, int> _missingChats;
  final Set<String> _backfilled;
  final Set<String> _started = {};

  @override
  Future<List<AcademicTermView>> listTerms() async =>
      List<AcademicTermView>.from(_terms);

  @override
  Future<TermReadiness> readiness({String? termId}) async {
    final term = _terms.firstWhere(
      (t) => termId == null ? t.isNearestNext || t.isCurrent : t.id == termId,
      orElse: () => _terms.firstWhere((t) => t.isCurrent),
    );
    final missingSubjects = _backfilled.contains(term.id)
        ? 0
        : (_missingSubjects[term.id] ?? 0);
    final missingChats = _backfilled.contains(term.id)
        ? 0
        : (_missingChats[term.id] ?? 0);
    final readinessPercent = missingSubjects == 0 && missingChats == 0
        ? 100
        : (((5 - missingSubjects).clamp(0, 5) +
                      (5 - missingChats).clamp(0, 5)) *
                  10)
              .round();
    return TermReadiness(
      termId: term.id,
      termName: term.name,
      readinessPercent: readinessPercent,
      groupsCount: 2,
      subjectsCount: 5 - missingSubjects,
      subjectChatsCount: 5 - missingChats,
      missingSubjects: missingSubjects,
      missingSubjectChats: missingChats,
      notification: term.isNearestNext
          ? '${term.name} подготовлена на $readinessPercent%. Не хватает $missingSubjects предметов и $missingChats предметных чатов.'
          : null,
      approaching: term.isNearestNext,
      automationActive: false,
      blockers: term.isNearestNext && missingSubjects > 10
          ? const ['Нет учебного плана']
          : const [],
    );
  }

  @override
  Future<Map<String, dynamic>> backfillDryRun(String termId) async {
    final term = _terms.firstWhere((t) => t.id == termId);
    final missingSubjects = _backfilled.contains(termId)
        ? 0
        : (_missingSubjects[termId] ?? 0);
    final missingChats = _backfilled.contains(termId)
        ? 0
        : (_missingChats[termId] ?? 0);
    return {
      'term_id': termId,
      'term_name': term.name,
      'missing_subjects': missingSubjects,
      'missing_subject_chats': missingChats,
      'current_unchanged': true,
      'chats_not_archived': true,
      'message': 'Текущий семестр и действующие чаты не изменятся',
    };
  }

  @override
  Future<Map<String, dynamic>> backfill(String termId) async {
    if (_backfilled.contains(termId)) {
      return {
        'idempotent_replay': true,
        'created_subjects': 0,
        'created_subject_chats': 0,
        'current_unchanged': true,
        'chats_not_archived': true,
      };
    }
    final createdSubjects = _missingSubjects[termId] ?? 0;
    final createdChats = _missingChats[termId] ?? 0;
    _backfilled.add(termId);
    _missingSubjects[termId] = 0;
    _missingChats[termId] = 0;
    return {
      'idempotent_replay': false,
      'created_subjects': createdSubjects,
      'created_subject_chats': createdChats,
      'current_unchanged': true,
      'chats_not_archived': true,
    };
  }

  @override
  Future<TermTransitionPreview> startNextDryRun(String termId) async {
    final current = _terms.firstWhere((t) => t.isCurrent);
    final target = _terms.firstWhere((t) => t.id == termId);
    final ok = target.isNearestNext;
    return TermTransitionPreview(
      ok: ok,
      currentTermName: current.name,
      newTermName: target.name,
      archivableSubjectChats: ok ? 10 : 0,
      willCreateSubjects: _missingSubjects[termId] ?? 0,
      willCreateSubjectChats: _missingChats[termId] ?? 0,
      confirmNameRequired: target.name,
      blockers: ok
          ? const []
          : const ['Можно активировать только ближайший следующий семестр'],
      idempotentReplay: target.isCurrent,
    );
  }

  @override
  Future<Map<String, dynamic>> startNext({
    required String termId,
    required String confirmName,
  }) async {
    final target = _terms.firstWhere((t) => t.id == termId);
    if (confirmName.trim() != target.name) {
      throw StateError('confirm_name_mismatch');
    }
    if (!target.isNearestNext && !target.isCurrent) {
      throw StateError('not_nearest_next');
    }
    if (target.isCurrent || _started.contains(termId)) {
      return {
        'idempotent_replay': true,
        'new_term_id': termId,
        'new_term_name': target.name,
        'archived_subject_chats': 0,
        'group_space_preserved': true,
      };
    }
    final currentIndex = _terms.indexWhere((t) => t.isCurrent);
    final targetIndex = _terms.indexWhere((t) => t.id == termId);
    _terms[currentIndex] = AcademicTermView(
      id: _terms[currentIndex].id,
      name: _terms[currentIndex].name,
      lifecycle: 'completed',
      isCurrent: false,
      isNearestNext: false,
      startsOn: _terms[currentIndex].startsOn,
      endsOn: _terms[currentIndex].endsOn,
      yearName: _terms[currentIndex].yearName,
      termSequence: _terms[currentIndex].termSequence,
    );
    _terms[targetIndex] = AcademicTermView(
      id: target.id,
      name: target.name,
      lifecycle: 'active',
      isCurrent: true,
      isNearestNext: false,
      startsOn: target.startsOn,
      endsOn: target.endsOn,
      yearName: target.yearName,
      termSequence: target.termSequence,
    );
    _started.add(termId);
    await backfill(termId);
    return {
      'idempotent_replay': false,
      'new_term_id': termId,
      'new_term_name': target.name,
      'archived_subject_chats': 10,
      'created_subjects': 0,
      'created_subject_chats': 0,
      'group_space_preserved': true,
    };
  }
}

class SupabaseTermsRepository implements TermsRepository {
  SupabaseTermsRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Map<String, dynamic> _asMap(dynamic result) {
    final decoded = result is String ? jsonDecode(result) : result;
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<List<AcademicTermView>> listTerms() async {
    final result = await _client.rpc('admin_list_terms');
    final decoded = result is String ? jsonDecode(result) : result;
    return (decoded as List)
        .map(
          (e) => AcademicTermView.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList();
  }

  @override
  Future<TermReadiness> readiness({String? termId}) async {
    final result = await _client.rpc(
      'admin_term_readiness',
      params: {'p_term_id': termId},
    );
    return TermReadiness.fromJson(_asMap(result));
  }

  @override
  Future<Map<String, dynamic>> backfillDryRun(String termId) async {
    final result = await _client.rpc(
      'admin_term_backfill_dry_run',
      params: {'p_term_id': termId},
    );
    return _asMap(result);
  }

  @override
  Future<Map<String, dynamic>> backfill(String termId) async {
    final result = await _client.rpc(
      'admin_term_backfill',
      params: {'p_term_id': termId},
    );
    return _asMap(result);
  }

  @override
  Future<TermTransitionPreview> startNextDryRun(String termId) async {
    final result = await _client.rpc(
      'admin_start_next_term_dry_run',
      params: {'p_term_id': termId},
    );
    return TermTransitionPreview.fromJson(_asMap(result));
  }

  @override
  Future<Map<String, dynamic>> startNext({
    required String termId,
    required String confirmName,
  }) async {
    final result = await _client.rpc(
      'admin_start_next_term',
      params: {'p_term_id': termId, 'p_confirm_name': confirmName},
    );
    return _asMap(result);
  }
}
