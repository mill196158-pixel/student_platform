import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/ui/learning/draft_recovery_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('commit then abruptly exit synthetic process', () async {
    if (Platform.isWindows) open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final path = Platform.environment['DRAFT_JOURNAL_TEST_PATH'];
    if (path == null || path.isEmpty) throw StateError('Synthetic path required');
    final database = await databaseFactoryFfi.openDatabase(path);
    final journal = DraftRecoveryJournal(open: () async => database);
    final saved = await journal.append(project: 'test-project', owner: 'owner-a',
        sessionId: 'session-a', conversation: 'chat',
        draft: {'text': 'survives synthetic crash', 'files': [], 'reply': null},
        permitted: () => true);
    if (!saved) throw StateError('Synthetic append failed');
    stdout.writeln('DRAFT_JOURNAL_COMMITTED');
    await stdout.flush();
    exit(86); // Deliberately terminate without closing the SQLite handle.
  });
}
