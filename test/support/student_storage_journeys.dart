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

  void listTop() {
    final scroll = find
        .descendant(
            of: find.byType(CacheDiagnosticsScreen),
            matching: find.byType(Scrollable))
        .first;
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
  }

  Future<void> show(OptionalImageCacheBudget policy) async {
    await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!),
        home: CacheDiagnosticsScreen(
            budget: policy,
            measureAttachments: inventory.collect,
            clearNews: news.clearStoredCopies,
            measure: () async => InventorySnapshot(
                startedAt: DateTime.now(),
                finishedAt: DateTime.now(),
                observations: []))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  try {
    final cad = await CachedDrawingJourney.prepare(temp, chat);
    expect(
        await store.put(
            key, Uint8List.fromList([1, 2, 3]), await store.capture(key)),
        isTrue);
    await show(budget);
    await tap('Изменить целевой лимит');
    await waitFor(find.byType(SimpleDialog));
    await tap('250 МБ');
    await budget.waitForPolicy();
    expect(budget.limitBytes, 250000000,
        reason: 'Choice must persist before returning to the list');
    listTop();
    await tester.pump(const Duration(milliseconds: 300));
    await waitFor(find.textContaining('250.0 МБ'));
    await tester.pumpWidget(const SizedBox.shrink());
    final reload = OptionalImageCacheBudget(
        roots: () async => [temp], persistPolicy: true);
    await show(reload);
    listTop();
    await waitFor(find.textContaining('250.0 МБ'));
    expect(reload.limitBytes, 250000000);
    debugPrint(
        'PARTIAL E2E-091 large text 390px, limit survives policy and screen recreation in this process');
    await tap('Очистить кэш публичных новостей');
    await tap('Удалить копии');
    await waitFor(find.textContaining('Очистка завершена.'));
    expect(await store.read(key), isNull);
    expect(await drawing.readAsBytes(), orderedEquals(bytes));
    if (cad == null) {
      debugPrint('PARTIAL E2E-092 news removed and on-disk attachment unchanged');
    } else {
      await cad.openAfterClear(tester);
      await show(reload);
    }
    final measured = find.text('Скачанные вложения: 127 Б');
    if (measured.evaluate().isEmpty) {
      listTop();
      await tester.scrollUntilVisible(measured, 180);
    }
    await waitFor(measured);
    await File('${downloads.path}/second.dwg')
        .writeAsBytes(List.filled(211, 0x7A));
    await tap('Обновить');
    await waitFor(find.text('Скачанные вложения: 338 Б'));
    await tap('Обновить');
    await waitFor(find.text('Скачанные вложения: 338 Б'));
    expect((await inventory.collect()).downloadedFilesBytes, 338);
    debugPrint(
        'PASS E2E-093 actual storage 127 + 211 = 338 bytes across two refresh actions');
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
    await temp.delete(recursive: true);
  }
}
