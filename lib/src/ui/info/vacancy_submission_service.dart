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
    this.isLocalFallback = false,
    this.rpcUnavailable = false,
    this.errorMessage,
  });

  final bool ok;
  final String? id;
  final String status;
  final bool isLocalFallback;
  final bool rpcUnavailable;
  final String? errorMessage;

  bool get isSubmitted => ok && status == 'submitted';
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

  bool _isMissingRpc(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    if (code == 'PGRST202' || code == '42883') return true;
    return _isMissingRpcMessage(error.message);
  }

  bool _isMissingRpcMessage(String raw) {
    final message = raw.toLowerCase();
    final namesFunction = message.contains('submit_vacancy');
    final missingPhrase = message.contains('could not find the function') ||
        message.contains('does not exist') ||
        message.contains('undefined_function') ||
        message.contains('undefined function');
    return missingPhrase && namesFunction;
  }
}
