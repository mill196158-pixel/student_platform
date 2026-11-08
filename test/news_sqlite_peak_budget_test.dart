import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/news_sqlite_peak_budget.dart';

int? peak({int? observed = 10, int? pages = 8, int? page = 4096,
    int? sector = 512, int? footer = 64, int? control = 128,
    int? blob = 100}) =>
    NewsSqlitePeakBudget.estimate(observedBytes: observed,
        maxDatabasePages: pages, pageSize: page, maxSectorSize: sector,
        footerAllowance: footer, controlAllowance: control, maxBlobBytes: blob)?.fileLengthBytes;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('counts database, journal header and padding, blob peak and control', () {
    final expected = 10 + 8 * 4096 + 8 * (4096 + 8) + 9 * 512 +
        9 * (512 - 1) + 2 * 100 + 64 + 128;
    expect(peak(), expected);
  });

  test('unknown, invalid values and overflow refuse', () {
    expect(peak(observed: null), isNull);
    expect(peak(page: 4097), isNull);
    expect(peak(sector: 1), isNull);
    expect(peak(sector: 511), isNull);
    expect(peak(footer: null), isNull);
    expect(peak(footer: -1), isNull);
    expect(peak(control: -1), isNull);
    expect(peak(control: 9223372036854775807), isNull);
    expect(peak(pages: 9223372036854775807), isNull);
  });

  test('lab rollback journal stays within envelope for a synthetic update', () async {
    final root = await Directory.systemTemp.createTemp('news-peak-lab-');
    final path = '${root.path}/index.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    try {
      await db.execute('PRAGMA page_size=4096');
      expect((await db.rawQuery('PRAGMA journal_mode=DELETE')).single.values.single, 'delete');
      await db.execute('PRAGMA temp_store=MEMORY');
      final maxPages = (await db.rawQuery('PRAGMA max_page_count=128')).single.values.single as int;
      final pageSize = (await db.rawQuery('PRAGMA page_size')).single.values.single as int;
      await db.execute('CREATE TABLE images (id INTEGER PRIMARY KEY, data BLOB)');
      await db.insert('images', {'id': 1, 'data': Uint8List(64 * 1024)});
      final envelope = peak(observed: 0, pages: maxPages, page: pageSize,
          sector: 65536, footer: 4096, control: 4096, blob: 1)!;
      await db.transaction((tx) async {
        await tx.update('images', {'data': Uint8List.fromList(List.filled(64 * 1024, 1))}, where: 'id=1');
        final mainBytes = await File(path).length();
        final journal = File('$path-journal');
        expect(await journal.exists(), isTrue);
        expect(mainBytes + await journal.length(), lessThanOrEqualTo(envelope));
      });
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
