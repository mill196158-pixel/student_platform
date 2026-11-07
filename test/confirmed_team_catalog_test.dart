import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/data/confirmed_team_catalog.dart';

void main() {
  test('confirmed RPC order is retained and failed hydration is unknown', () {
    final raw = [
      {
        'id': 'a',
        'name': 'First',
        'teacher': 'T',
        'group_name': 'G',
        'icon': '',
        'kind': 'subject'
      },
      {
        'id': 'b',
        'name': 'Second',
        'teacher': '',
        'group_name': 'G',
        'icon': ''
      },
    ];
    final unknown = confirmedTeamCatalogFromRows(raw, hydrated: null);
    expect(unknown.map((t) => t.id), ['a', 'b']);
    expect(unknown.map((t) => t.kind), ['unknown', 'unknown']);
    final mixed = confirmedTeamCatalogFromRows(raw, hydrated: [
      {'id': 'a', 'kind': 'group_space'},
      {'id': 'b', 'kind': 'new_server_kind'},
    ]);
    expect(mixed.map((t) => t.kind), ['group_space', 'unknown']);
    expect(
        () => confirmedTeamCatalogFromRows([raw.first, raw.first],
            hydrated: null),
        throwsFormatException);
    expect(
        () => confirmedTeamCatalogFromRows([
              {'id': 'x'}
            ], hydrated: null),
        throwsFormatException);
  });
}
