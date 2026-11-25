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

  Future<List<UsefulSubject>> load({required String groupId, int? currentSemester, bool Function()? isCurrent}) async {
    void checkCurrent() {
      if (isCurrent != null && !isCurrent()) throw StateError('Subject plan session changed');
    }
    checkCurrent();
    Object? rpcError;

    try {
      final rows = await _loadRpcRows();
      checkCurrent();
      if (rows.isNotEmpty) {
        return rows.map(UsefulSubject.fromRpcMap).toList(growable: false);
      }
    } catch (error) {
      checkCurrent();
      rpcError = error;
    }

    try {
      checkCurrent();
      final fallbackRows = await _loadFallbackRows(groupId);
      checkCurrent();
      Map<String, (String, String)> memberships = const {};
      if (rpcError is PostgrestException && rpcError.code == 'PGRST202' &&
          _fallbackLoader == null && fallbackRows.isNotEmpty && currentSemester != null) {
        memberships = await _confirmedChats(groupId);
        checkCurrent();
      }
      return [
        for (final row in fallbackRows)
          UsefulSubject.fromFallbackMap(row, membership: memberships[row['id']], currentSemester: currentSemester),
      ];
    } catch (fallbackError) {
      // Never mask a transport/RPC failure with an empty list.
      throw rpcError ?? fallbackError;
    }
  }

  Future<Map<String, (String, String)>> _confirmedChats(String groupId) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return {};
    try {
      final rows = await _sb.from('teams')
          .select('id,subject_offering_id,team_members!inner(user_id),chats!inner(id,type)')
          .eq('group_id', groupId).eq('team_members.user_id', uid).eq('chats.type', 'team_main');
      if (_sb.auth.currentUser?.id != uid) return {};
      final found = <String, (String, String)>{};
      final ambiguous = <String>{};
      for (final row in rows) {
        final offering = row['subject_offering_id'], team = row['id'];
        final members = row['team_members'], chats = row['chats'];
        if (offering is! String || team is! String || team.isEmpty || members is! List ||
            !members.any((m) => m is Map && m['user_id'] == uid) ||
            chats is! List || chats.length != 1) continue;
        final chat = chats.single;
        if (chat is! Map || chat['type'] != 'team_main' || chat['id'] is! String ||
            (chat['id'] as String).isEmpty) continue;
        if (found.containsKey(offering)) ambiguous.add(offering);
        found[offering] = (team, chat['id'] as String);
      }
      for (final offering in ambiguous) { found.remove(offering); }
      return found;
    } on PostgrestException {
      return {};
    } on Exception {
      return {};
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
