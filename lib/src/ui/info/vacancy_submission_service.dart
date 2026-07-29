import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Student proposal payload for `submit_vacancy(p_patch)`.
class VacancySubmissionDraft {
  const VacancySubmissionDraft({
    required this.title,
    this.companyName = '',
    this.summary = '',
    this.description = '',
    this.requirements = '',
    this.employmentType,
    this.workFormat,
    this.location,
    this.salaryText,
    this.externalUrl,
    this.contacts = const {},
  });

  final String title;
  final String companyName;
  final String summary;
  final String description;
  final String requirements;
  final VacancyEmploymentType? employmentType;
  final VacancyWorkFormat? workFormat;
  final String? location;
  final String? salaryText;
  final String? externalUrl;
  final Map<String, dynamic> contacts;

  static const _requirementsMarker = '\n\n---\nТребования:\n';

  String get fullDescription {
    final body = description.trim();
    final req = requirements.trim();
    if (req.isEmpty) return body;
    if (body.isEmpty) return '${_requirementsMarker.trim()}$req';
    return '$body$_requirementsMarker$req';
  }

  Map<String, dynamic> toSubmitPatch() {
    return {
      'title': title.trim(),
      'company_name': companyName.trim(),
      'summary': summary.trim(),
      'description': fullDescription,
      if (employmentType != null) 'employment_type': employmentType!.wireValue,
      if (workFormat != null) 'work_format': workFormat!.wireValue,
      if (location != null && location!.trim().isNotEmpty)
        'location': location!.trim(),
      if (salaryText != null && salaryText!.trim().isNotEmpty)
        'salary_text': salaryText!.trim(),
      if (externalUrl != null && externalUrl!.trim().isNotEmpty)
        'external_url': externalUrl!.trim(),
      if (contacts.isNotEmpty) 'contacts': contacts,
    };
  }
}

/// Result of mobile `submit_vacancy(p_patch)` (or local demo fallback).
class VacancySubmissionResult {
  const VacancySubmissionResult({
    required this.ok,
    this.id,
    this.status = 'submitted',
    this.rowVersion,
    this.isLocalFallback = false,
    this.rpcUnavailable = false,
    this.errorMessage,
  });

  final bool ok;
  final String? id;
  final String status;
  final int? rowVersion;
  final bool isLocalFallback;
  final bool rpcUnavailable;
  final String? errorMessage;

  bool get isSubmitted => ok && status == 'submitted';
}

/// Author-scoped row from `get_my_vacancy_submissions`.
class MyVacancySubmissionItem {
  const MyVacancySubmissionItem({
    required this.id,
    required this.title,
    required this.status,
    required this.rowVersion,
    this.companyName = '',
    this.summary = '',
    this.description = '',
    this.employmentType,
    this.workFormat,
    this.location,
    this.salaryText,
    this.externalUrl,
    this.contacts = const {},
    this.rejectionReason,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String status;
  final int rowVersion;
  final String companyName;
  final String summary;
  final String description;
  final String? employmentType;
  final String? workFormat;
  final String? location;
  final String? salaryText;
  final String? externalUrl;
  final Map<String, dynamic> contacts;
  final String? rejectionReason;
  final DateTime? updatedAt;

  bool get needsAuthorAction =>
      status == 'draft' &&
      (rejectionReason != null && rejectionReason!.trim().isNotEmpty);

  static MyVacancySubmissionItem? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['id']?.toString().trim();
    final title = json['title']?.toString().trim();
    final status = json['status']?.toString().trim();
    final rowVersionRaw = json['row_version'] ?? json['rowVersion'];
    final rowVersion = rowVersionRaw is num
        ? rowVersionRaw.toInt()
        : int.tryParse('$rowVersionRaw');
    if (id == null ||
        id.isEmpty ||
        title == null ||
        title.isEmpty ||
        status == null ||
        status.isEmpty ||
        rowVersion == null) {
      return null;
    }
    final contactsRaw = json['contacts'];
    return MyVacancySubmissionItem(
      id: id,
      title: title,
      status: status,
      rowVersion: rowVersion,
      companyName: json['company_name']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      employmentType: json['employment_type']?.toString(),
      workFormat: json['work_format']?.toString(),
      location: json['location']?.toString(),
      salaryText: json['salary_text']?.toString(),
      externalUrl: json['external_url']?.toString(),
      contacts: contactsRaw is Map
          ? Map<String, dynamic>.from(contactsRaw)
          : const {},
      rejectionReason: () {
        final raw = json['rejection_reason'] ?? json['rejectionReason'];
        final text = raw?.toString().trim();
        return (text == null || text.isEmpty) ? null : text;
      }(),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }

  VacancySubmissionDraft toDraft() {
    const marker = '\n\n---\nТребования:\n';
    var description = this.description;
    var requirements = '';
    final idx = description.indexOf(marker);
    if (idx >= 0) {
      requirements = description.substring(idx + marker.length);
      description = description.substring(0, idx);
    }
    return VacancySubmissionDraft(
      title: title,
      companyName: companyName,
      summary: summary,
      description: description,
      requirements: requirements,
      employmentType: VacancyEmploymentType.tryParse(employmentType),
      workFormat: VacancyWorkFormat.tryParse(workFormat),
      location: location,
      salaryText: salaryText,
      externalUrl: externalUrl,
      contacts: contacts,
    );
  }
}

abstract class VacancySubmissionRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseVacancySubmissionRpcClient implements VacancySubmissionRpcClient {
  SupabaseVacancySubmissionRpcClient([SupabaseClient? client])
      : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _resolvedClient => _client ?? Supabase.instance.client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _resolvedClient.rpc(function, params: params);
  }
}

/// Student vacancy proposal — RPC `submit_vacancy` with local fallback.
///
/// User submissions always enter `submitted` status; never auto-published.
class VacancySubmissionService {
  VacancySubmissionService({
    VacancySubmissionRpcClient? rpcClient,
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _rpc = rpcClient ?? SupabaseVacancySubmissionRpcClient(),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId ??
            (() => Supabase.instance.client.auth.currentUser?.id);

  final VacancySubmissionRpcClient _rpc;
  final Future<SharedPreferences> Function() _prefs;
  final String? Function() _currentUserId;

  static const String localSubmissionsKey = 'vacancy_submissions_v1';

  Future<VacancySubmissionResult> submit(VacancySubmissionDraft draft) async {
    final patch = draft.toSubmitPatch();
    if ((patch['title']?.toString().trim().isEmpty ?? true)) {
      return const VacancySubmissionResult(
        ok: false,
        errorMessage: 'Укажите название вакансии.',
      );
    }

    try {
      final response =
          await _rpc.rpc('submit_vacancy', params: {'p_patch': patch});
      final map = _asMap(response);
      final status = (map['status'] ?? 'submitted').toString();
      return VacancySubmissionResult(
        ok: map['ok'] == true || map['id'] != null,
        id: map['id']?.toString(),
        status: status,
      );
    } on PostgrestException catch (error) {
      if (_isMissingRpc(error)) {
        return _localSubmit(draft);
      }
      return VacancySubmissionResult(
        ok: false,
        errorMessage: error.message,
      );
    } catch (error) {
      if (_isMissingRpcMessage(error.toString())) {
        return _localSubmit(draft);
      }
      return VacancySubmissionResult(
        ok: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<List<Map<String, dynamic>>> listLocalSubmissions() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_localKey());
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e) {
      debugPrint('[vacancy_submit] local list failed: $e');
      return const [];
    }
  }

  Future<List<MyVacancySubmissionItem>> listMySubmissions({
    int limit = 50,
  }) async {
    try {
      final response = await _rpc.rpc(
        'get_my_vacancy_submissions',
        params: {'p_limit': limit},
      );
      return _parseSubmissionList(response);
    } on PostgrestException catch (error) {
      if (_isMissingRpcNamed(error, 'get_my_vacancy_submissions')) {
        return _localSubmissionItems();
      }
      debugPrint('[vacancy_submit] list failed: ${error.message}');
      return const [];
    } catch (error) {
      if (_isMissingRpcMessageNamed(
        error.toString(),
        'get_my_vacancy_submissions',
      )) {
        return _localSubmissionItems();
      }
      debugPrint('[vacancy_submit] list failed: $error');
      return const [];
    }
  }

  Future<VacancySubmissionResult> updateDraft({
    required String id,
    required VacancySubmissionDraft draft,
    required int expectedRowVersion,
  }) async {
    final patch = draft.toSubmitPatch();
    if ((patch['title']?.toString().trim().isEmpty ?? true)) {
      return const VacancySubmissionResult(
        ok: false,
        errorMessage: 'Укажите название вакансии.',
      );
    }
    try {
      final response = await _rpc.rpc(
        'update_my_vacancy_draft',
        params: {
          'p_id': id,
          'p_patch': patch,
          'p_expected_row_version': expectedRowVersion,
        },
      );
      final map = _asMap(response);
      final rowVersionRaw = map['row_version'];
      return VacancySubmissionResult(
        ok: map['ok'] == true || map['id'] != null,
        id: map['id']?.toString() ?? id,
        status: (map['status'] ?? 'draft').toString(),
        rowVersion: rowVersionRaw is num
            ? rowVersionRaw.toInt()
            : int.tryParse('$rowVersionRaw'),
      );
    } on PostgrestException catch (error) {
      return VacancySubmissionResult(ok: false, errorMessage: error.message);
    } catch (error) {
      return VacancySubmissionResult(ok: false, errorMessage: error.toString());
    }
  }

  Future<VacancySubmissionResult> resubmit({
    required String id,
    required int expectedRowVersion,
  }) async {
    try {
      final response = await _rpc.rpc(
        'resubmit_my_vacancy',
        params: {
          'p_id': id,
          'p_expected_row_version': expectedRowVersion,
        },
      );
      final map = _asMap(response);
      final rowVersionRaw = map['row_version'];
      return VacancySubmissionResult(
        ok: map['ok'] == true || map['id'] != null,
        id: map['id']?.toString() ?? id,
        status: (map['status'] ?? 'submitted').toString(),
        rowVersion: rowVersionRaw is num
            ? rowVersionRaw.toInt()
            : int.tryParse('$rowVersionRaw'),
      );
    } on PostgrestException catch (error) {
      return VacancySubmissionResult(ok: false, errorMessage: error.message);
    } catch (error) {
      return VacancySubmissionResult(ok: false, errorMessage: error.toString());
    }
  }

  Future<VacancySubmissionResult> _localSubmit(
    VacancySubmissionDraft draft,
  ) async {
    final id = 'local-submit-${DateTime.now().millisecondsSinceEpoch}';
    final row = {
      'id': id,
      'status': 'submitted',
      'origin': 'user_submission',
      ...draft.toSubmitPatch(),
      'submitted_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      final prefs = await _prefs();
      final existing = await listLocalSubmissions();
      await prefs.setString(
        _localKey(),
        jsonEncode([...existing, row]),
      );
    } catch (e) {
      debugPrint('[vacancy_submit] local write failed: $e');
    }

    return VacancySubmissionResult(
      ok: true,
      id: id,
      status: 'submitted',
      isLocalFallback: true,
      rpcUnavailable: true,
    );
  }

  String _localKey() {
    final id = (_currentUserId() ?? '').trim();
    return id.isEmpty
        ? '${localSubmissionsKey}__anon'
        : '${localSubmissionsKey}__$id';
  }

  Map<String, dynamic> _asMap(dynamic data) {
    dynamic value = data;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return const {};
      }
    }
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }

  Future<List<MyVacancySubmissionItem>> _localSubmissionItems() async {
    final rows = await listLocalSubmissions();
    final items = <MyVacancySubmissionItem>[];
    for (final row in rows) {
      final item = MyVacancySubmissionItem.tryParse({
        ...row,
        'row_version': row['row_version'] ?? 1,
        'status': row['status'] ?? 'submitted',
      });
      if (item != null) items.add(item);
    }
    return items;
  }

  List<MyVacancySubmissionItem> _parseSubmissionList(dynamic data) {
    dynamic value = data;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return const [];
      }
    }
    if (value is! List) return const [];
    final items = <MyVacancySubmissionItem>[];
    for (final row in value) {
      if (row is! Map) continue;
      final item =
          MyVacancySubmissionItem.tryParse(Map<String, dynamic>.from(row));
      if (item != null) items.add(item);
    }
    return items;
  }

  bool _isMissingRpc(PostgrestException error) {
    return _isMissingRpcNamed(error, 'submit_vacancy');
  }

  bool _isMissingRpcMessage(String raw) {
    return _isMissingRpcMessageNamed(raw, 'submit_vacancy');
  }

  bool _isMissingRpcNamed(PostgrestException error, String functionName) {
    final code = (error.code ?? '').toUpperCase();
    if (code == 'PGRST202' || code == '42883') {
      return _isMissingRpcMessageNamed(error.message, functionName) ||
          error.message.toLowerCase().contains(functionName.toLowerCase());
    }
    return _isMissingRpcMessageNamed(error.message, functionName);
  }

  bool _isMissingRpcMessageNamed(String raw, String functionName) {
    final message = raw.toLowerCase();
    final namesFunction = message.contains(functionName.toLowerCase());
    final missingPhrase = message.contains('could not find the function') ||
        message.contains('does not exist') ||
        message.contains('undefined_function') ||
        message.contains('undefined function');
    return missingPhrase && namesFunction;
  }
}
