import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/attachment_storage_inventory.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';
import 'package:student_ui/student_ui.dart';
import 'cached_drawing_journey.dart';

/// Same test session and student as the profile UI. The temp directory keeps
/// the test's downloaded drawing and public news storage apart from user files.
Future<void> exerciseStudentStorage(WidgetTester tester, String chat) async {
  sqfliteFfiInit();
  final temp = await Directory.systemTemp.createTemp('student-storage-');
  final downloads =
      await Directory('${temp.path}/downloaded_chat_files').create();
  final bytes = Uint8List.fromList(List.generate(127, (i) => i));
  final drawing = await File('${downloads.path}/first.dwg').writeAsBytes(bytes);
  final pinned = await Directory('${temp.path}/pinned_media_v1').create();
  final saved = await File('${pinned.path}/saved-offline.pdf')
      .writeAsBytes([5, 7, 11, 13]);
  final history = await File('${temp.path}/offline_chat_ordinary_v1.db')
      .writeAsBytes([17, 19, 23]);
  final drafts =
      await File('${temp.path}/draft_recovery_v1.db').writeAsBytes([29, 31]);
  final db = await databaseFactoryFfi.openDatabase('${temp.path}/index.db');
  final store = NewsSqliteImageStore.forCollectionTest(
      database: db, root: Directory('${temp.path}/blobs'));
  final key = NewsImageCacheKey(path: 'public/cover', version: 'version1');
  final inventory =
      AttachmentStorageInventory.forTesting(cacheRoot: () async => temp);
  final budget =
      OptionalImageCacheBudget(roots: () async => [temp], persistPolicy: true);
  final news =
      PublicNewsImageCache(openStore: () async => store, budget: budget);
  Future<void> waitFor(Finder f) async {
    for (var i = 0; i < 100 && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 45));
    }
    expect(f, findsWidgets,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .whereType<String>()
            .join(' | '));
  }

  Future<void> tap(String label) async {
    final f = find.text(label);
    if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 180);
    await tester.ensureVisible(f.first);
    await tester.pump(const Duration(milliseconds: 280));
    await tester.tap(f.first);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> show() async {
    await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!),
        home: CacheDiagnosticsScreen(
            clearNews: news.clearStoredCopies,
            measure: () async => InventorySnapshot(
                    startedAt: DateTime.now(),
                    finishedAt: DateTime.now(),
                    observations: [
                      InventoryObservation(
                          'public_news_blobs_v2',
                          InventoryClass.optional,
                          (await store.read(key))?.length ?? 0),
                    ]))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  try {
    final cad = await CachedDrawingJourney.prepare(temp, chat);
    expect(
        await store.put(
            key, Uint8List.fromList([1, 2, 3]), await store.capture(key)),
        isTrue);
    expect(await budget.setLimit(250000000), isTrue);
    final reload = OptionalImageCacheBudget(
        roots: () async => [temp], persistPolicy: true);
    await reload.waitForPolicy();
    expect(reload.limitBytes, 250000000);
    await show();
    await waitFor(find.text('3 Б'));
    expect(find.text('Очистить кэш').hitTestable(), findsOneWidget);
    expect(find.text('Изменить целевой лимит'), findsNothing);
    debugPrint(
        'PASS E2E-091 large text 390px shows the clear action and internal cache policy still survives reload');
    await tap('Очистить кэш');
    await tap('Очистить');
    await waitFor(find.text('Кэш очищен.'));
    await waitFor(find.text('0 Б'));
    expect(await store.read(key), isNull);
    expect(await drawing.readAsBytes(), orderedEquals(bytes));
    expect(await saved.readAsBytes(), [5, 7, 11, 13]);
    expect(await history.readAsBytes(), [17, 19, 23]);
    expect(await drafts.readAsBytes(), [29, 31]);
    if (cad == null) {
      debugPrint(
          'PASS E2E-092 news removed and saved file, chat, draft and attachment bytes preserved');
    } else {
      await cad.openAfterClear(tester);
    }
    expect((await inventory.collect()).downloadedFilesBytes, 127);
    await File('${downloads.path}/second.dwg')
        .writeAsBytes(List.filled(211, 0x7A));
    expect((await inventory.collect()).downloadedFilesBytes, 338);
    expect((await inventory.collect()).downloadedFilesBytes, 338);
    debugPrint(
        'PASS E2E-093 internal inventory counts 127 + 211 = 338 bytes on repeated reads');
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
    await temp.delete(recursive: true);
  }
}
