import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/cache_budget_policy_experiment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('synthetic SQLite counts database and live WAL/SHM physical bytes separately', () async {
    if (Platform.isWindows) {
      open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('budget-footprint-test-');
    final name = p.join(dir.path, 'cache.sqlite');
    final db = await databaseFactoryFfi.openDatabase(name,
        options: OpenDatabaseOptions(singleInstance: false, onConfigure: (db) async {
          await db.execute('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA wal_autocheckpoint=0');
        }));
    try {
      await db.execute('CREATE TABLE test_data (id INTEGER PRIMARY KEY, content BLOB)');
      await db.insert('test_data', {'content': Uint8List(8192)});
      final files = [File(name), File('$name-wal'), File('$name-shm')];
      final sizes = <int>[];
      for (final file in files) {
        expect(await file.exists(), isTrue);
        sizes.add(await file.length());
      }
      expect(sizes[1], greaterThan(0), reason: 'WAL must contain uncheckpointed synthetic data');
      final estimate = CacheBudgetPolicyExperiment.estimate([
        for (var i = 0; i < files.length; i++)
          CacheFootprintObservation(physicalIdentity: 'synthetic-physical-$i', bytes: sizes[i],
            classification: CacheFootprintClass.mixed, kind: CacheFootprintKind.conversation),
      ], complete: true)!;
      expect(estimate.measuredBytes, sizes.reduce((a, b) => a + b));
      expect(estimate.protectedOrMixedBytes, estimate.measuredBytes);
      expect(estimate.budgetClassificationComplete, isFalse);
      expect(estimate.confirmedReclaimableBytes, 0);
    } finally {
      await db.close();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final resolved = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, resolved) || !p.basename(resolved).startsWith('budget-footprint-test-')) {
        throw StateError('Unsafe synthetic cleanup target');
      }
      await dir.delete(recursive: true);
    }
  });
}
