import 'package:supabase_flutter/supabase_flutter.dart';

import 'useful_subject.dart';

typedef UsefulSubjectsRpcLoader = Future<List<Map<String, dynamic>>> Function();
typedef UsefulSubjectsFallbackLoader = Future<List<Map<String, dynamic>>>
    Function(String groupId);

/// Loads the student's subjects for the Info tab.
///
/// Primary path: one `rpc_get_my_subjects_v2` call (no per-subject queries).
/// Fallback: one nested `subject_offerings` select (still O(1) in N).
class UsefulSubjectsRepository {
  UsefulSubjectsRepository({
    SupabaseClient? client,
    UsefulSubjectsRpcLoader? rpcLoader,
    UsefulSubjectsFallbackLoader? fallbackLoader,
  })  : _client = client,
        _rpcLoader = rpcLoader,
        _fallbackLoader = fallbackLoader;

  SupabaseClient? _client;
  final UsefulSubjectsRpcLoader? _rpcLoader;
  final UsefulSubjectsFallbackLoader? _fallbackLoader;

  int rpcCallCount = 0;
  int fallbackCallCount = 0;

  SupabaseClient get _sb => _client ??= Supabase.instance.client;

  Future<List<UsefulSubject>> load({required String groupId}) async {
    Object? rpcError;

    try {
      final rows = await _loadRpcRows();
      if (rows.isNotEmpty) {
        return rows.map(UsefulSubject.fromRpcMap).toList(growable: false);
      }
    } catch (error) {
      rpcError = error;
    }

    try {
      final fallbackRows = await _loadFallbackRows(groupId);
      return fallbackRows
          .map(UsefulSubject.fromFallbackMap)
          .toList(growable: false);
    } catch (fallbackError) {
      // Never mask a transport/RPC failure with an empty list.
      throw rpcError ?? fallbackError;
    }
  }

  Future<List<Map<String, dynamic>>> _loadRpcRows() async {
    rpcCallCount += 1;
    if (_rpcLoader != null) {
      return _rpcLoader();
    }

    final res = await _sb.rpc('rpc_get_my_subjects_v2');
    final list = res as List? ?? const [];
    return list
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _loadFallbackRows(String groupId) async {
    fallbackCallCount += 1;
    if (_fallbackLoader != null) {
      return _fallbackLoader(groupId);
    }

    // Single nested select — request count does not grow with N.
    final rows = await _sb
        .from('subject_offerings')
        .select('''
          id,
          subject_id,
          group_id,
          display_name,
          semester_number,
          curriculum_subjects(
            display_name,
            raw_subject_name,
            control_form
          ),
          subject_catalog(canonical_name, description)
        ''')
        .eq('group_id', groupId)
        .order('semester_number')
        .order('display_name');

    return (rows as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }
}
