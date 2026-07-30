import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class StudentPointsRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseStudentPointsRpcClient implements StudentPointsRpcClient {
  SupabaseStudentPointsRpcClient([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

class StudentPointsLoadResult {
  const StudentPointsLoadResult({
    this.summary,
    this.isDemoFallback = false,
    this.rpcUnavailable = false,
    this.intentionallyEmpty = false,
    this.loadError = false,
  });

  final StudentPointsSummary? summary;
  final bool isDemoFallback;
  final bool rpcUnavailable;
  final bool intentionallyEmpty;
  final bool loadError;

  /// Successful empty response only — never hide on hard error.
  bool get hidePoints =>
      intentionallyEmpty && !isDemoFallback && !loadError;

  bool get showLoadError =>
      loadError && summary == null && !isDemoFallback;

  StudentPointsSummary get displaySummary =>
      summary ?? StudentPointsSummary.demo;
}

/// Thin mobile wrapper for `get_my_points_summary` (Stage 18).
///
/// Missing RPC → labeled demo fallback. Points are not money.
class StudentPointsService {
  StudentPointsService({
    StudentPointsRpcClient? rpcClient,
    String? Function()? currentUserId,
  })  : _rpc = rpcClient ?? SupabaseStudentPointsRpcClient(),
        _currentUserId = currentUserId ??
            (() => Supabase.instance.client.auth.currentUser?.id);

  final StudentPointsRpcClient _rpc;
  final String? Function() _currentUserId;

  Future<StudentPointsLoadResult> load({int limit = 20}) async {
    final userId = (_currentUserId() ?? '').trim();
    if (userId.isEmpty) {
      return const StudentPointsLoadResult(
        isDemoFallback: true,
        rpcUnavailable: true,
      );
    }

    try {
      final response = await _rpc.rpc(
        'get_my_points_summary',
        params: {'p_limit': limit},
      );
      final map = _asMap(response);
      final summary = StudentPointsSummary.tryParse(map);
      if (summary == null) {
        return const StudentPointsLoadResult(loadError: true);
      }
      if (summary.balance == 0 && summary.entries.isEmpty) {
        return StudentPointsLoadResult(
          summary: summary,
          intentionallyEmpty: true,
        );
      }
      return StudentPointsLoadResult(summary: summary);
    } on PostgrestException catch (error) {
      if (_isMissingRpc(error)) {
        debugPrint('[points] get_my_points_summary unavailable: ${error.message}');
        return const StudentPointsLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      rethrow;
    } catch (error) {
      if (_isMissingRpcMessage(error.toString())) {
        return const StudentPointsLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      debugPrint('[points] load failed: $error');
      return const StudentPointsLoadResult(loadError: true);
    }
  }

  bool _isMissingRpc(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    if (code == 'PGRST202' || code == '42883') return true;
    return _isMissingRpcMessage(error.message);
  }

  bool _isMissingRpcMessage(String raw) {
    final message = raw.toLowerCase();
    final namesFunction = message.contains('get_my_points_summary');
    final missingPhrase = message.contains('could not find the function') ||
        message.contains('does not exist') ||
        message.contains('undefined_function') ||
        message.contains('undefined function');
    return missingPhrase && namesFunction;
  }

  Map<String, dynamic>? _asMap(dynamic data) {
    dynamic value = data;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }
}
