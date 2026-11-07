import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, PostgrestException;

/// Converts only a complete successful RPC result. Kinds are accepted solely
/// from the separately confirmed teams metadata; missing/failed hydration is
/// explicitly unknown rather than guessed from legacy defaults.
List<Team> confirmedTeamCatalogFromRows(List<dynamic> raw,
    {required List<dynamic>? hydrated}) {
  if (raw.length > 500) throw const FormatException('Too many teams');
  final types = <String, String>{};
  for (final value in hydrated ?? const []) {
    if (value is! Map || value['id'] is! String)
      throw const FormatException('Invalid metadata');
    final id = value['id'] as String;
    if (types.containsKey(id))
      throw const FormatException('Duplicate metadata');
    final kind = value['kind'];
    types[id] =
        kind == 'subject' || kind == 'group_space' ? kind as String : 'unknown';
  }
  final teams = <Team>[];
  final seen = <String>{};
  for (final value in raw) {
    if (value is! Map || value['id'] is! String || value['name'] is! String) {
      throw const FormatException('Invalid team');
    }
    final id = value['id'] as String, name = value['name'] as String;
    if (id.isEmpty || !seen.add(id))
      throw const FormatException('Duplicate or empty team');
    String text(String field) {
      final v = value[field];
      if (v == null) return '';
      if (v is! String) throw const FormatException('Invalid team field');
      return v;
    }

    teams.add(Team(
        id: id,
        name: name,
        teacher: text('teacher'),
        groupCode: text('group_name'),
        icon: text('icon'),
        kind: types[id] ?? 'unknown'));
  }
  return List.unmodifiable(teams);
}

/// Only definitive auth/RLS errors revoke a previously confirmed snapshot.
bool isConfirmedCatalogDenial(Object error) =>
    (error is AuthException &&
        (error.statusCode == '401' || error.statusCode == '403')) ||
    (error is PostgrestException &&
        const {
          '401',
          '403',
          '42501',
          'PGRST301',
          'PGRST302',
          'PGRST303',
          'PT401',
          'PT403'
        }.contains(error.code));
