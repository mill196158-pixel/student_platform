import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/qa_news_payload_ledger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('synthetic abrupt termination', () async {
    final path = Platform.environment['SYNTHETIC_QA_LEDGER_PATH'];
    if (path == null) return;
    final db = await databaseFactoryFfi.openDatabase(path);
    final ledger = (await QaNewsPayloadLedger.openExisting(db, 'ns', 'epoch'))!;
    final ticket = (await ledger.reserve(8, 10))!;
    if (Platform.environment['SYNTHETIC_QA_LEDGER_PHASE'] == 'published') {
      if (!await ledger.publish(ticket)) throw StateError('publish failed');
    }
    stdout.writeln('SYNTHETIC_QA_LEDGER_TERMINATION');
    await stdout.flush();
    exit(42);
  });
}
