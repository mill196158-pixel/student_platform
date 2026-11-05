import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/state/team_assignment_snapshot_store.dart';
import 'package:student_platform/src/ui/learning/state/team_snapshot_host.dart';
import 'package:student_platform/src/ui/learning/state/team_snapshot_preferences.dart';

class _Storage implements TeamSnapshotStorage {
  int calls = 0;
  @override
  Future<Set<String>> keys() async {
    calls++;
    return {};
  }

  @override
  Future<String?> read(String key) async {
    calls++;
    return null;
  }

  @override
  Future<bool> write(String key, String value) async {
    calls++;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    calls++;
    return true;
  }
}

void main() {
  testWidgets('host rebuilds without reading storage or replacing coordinator',
      (tester) async {
    final storage = _Storage();
    TeamSnapshotCoordinator? seen;
    Widget app(Brightness brightness) => MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: TeamSnapshotHost(
            storage: storage,
            child: Builder(builder: (context) {
              seen = TeamSnapshotHost.maybeRead(context);
              return const SizedBox();
            })));
    await tester.pumpWidget(app(Brightness.light));
    final first = seen;
    expect(first, isNotNull);
    await tester.pumpWidget(app(Brightness.dark));
    expect(seen, same(first));
    expect(storage.calls, 0);
  });

  test('preferences adapter preserves exact values and other keys', () async {
    SharedPreferences.setMockInitialValues({'other': 'safe'});
    final prefs = await SharedPreferences.getInstance();
    final storage =
        PreferencesTeamSnapshotStorage(preferences: () async => prefs);
    expect(await storage.read('key'), isNull);
    expect(await storage.write('key', '{"value":1}'), isTrue);
    expect(await storage.read('key'), '{"value":1}');
    expect(await storage.remove('key'), isTrue);
    expect(await storage.read('key'), isNull);
    expect(prefs.getString('other'), 'safe');
  });
}
