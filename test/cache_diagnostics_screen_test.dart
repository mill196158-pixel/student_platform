import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/attachment_storage_inventory.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';

class _CountingLimit extends OptionalImageCacheBudget {
  _CountingLimit() : super(roots: () async => []);
  int writes = 0;
  @override
  Future<bool> setLimit(int value) async {
    writes++;
    return true;
  }
}

void main() {
  testWidgets('a revoked offline permit blocks both outstanding dialogs',
      (tester) async {
    var allowed = true, clears = 0;
    final budget = _CountingLimit();
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
      canAccess: () => allowed,
      budget: budget,
      measure: () async => InventorySnapshot(
          startedAt: DateTime.now(),
          finishedAt: DateTime.now(),
          observations: []),
      measureAttachments: () async => const AttachmentStorageReport(),
      clearNews: () async {
        clears++;
        return const PublicNewsClearResult(PublicNewsClearStatus.complete);
      },
    )));
    await tester.pumpAndSettle();
    final limit = find.widgetWithText(OutlinedButton, 'Изменить целевой лимит');
    await tester.scrollUntilVisible(limit, 170);
    await tester.pumpAndSettle();
    await tester.tap(limit);
    await tester.pumpAndSettle();
    allowed = false;
    await tester.tap(find.text('250 МБ'));
    await tester.pumpAndSettle();
    expect(budget.writes, 0);

    allowed = true;
    final clear = find.text('Очистить кэш публичных новостей');
    await tester.scrollUntilVisible(clear, 170);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    allowed = false;
    await tester.tap(find.text('Удалить копии'));
    await tester.pumpAndSettle();
    expect(clears, 0);
  });

  testWidgets('real collector shows named partial estimates without cleanup',
      (tester) async {
    late Directory root;
    final result = await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('inventory_fixture_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final temp = await Directory('${root.path}/temp').create();
      final db = await Directory('${root.path}/db').create();
      final support = await Directory('${root.path}/support').create();
      final news =
          await Directory('${temp.path}/public_news_blobs_v2').create();
      await File('${news.path}/item').writeAsBytes(List.filled(20, 7));
      final protected = File('${db.path}/forward_outbox_v1.db');
      await protected.writeAsBytes([1, 2, 3]);
      final collector = CacheInventoryCollector(
          temporaryRoot: () async => temp,
          databaseRoot: () async => db,
          supportRoot: () async => support);
      final result = await collector.collect();
      expect(
          result.observations
              .firstWhere((o) => o.name == 'public_news_blobs_v2')
              .bytes,
          20);
      expect(
          result.observations
              .firstWhere((o) => o.name == 'forward_outbox_v1.db')
              .bytes,
          3);
      expect(result.logicalHistoryBytes, isNull);
      expect(await protected.readAsBytes(), [1, 2, 3]);
      return result;
    });
    expect(result, isNotNull);
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
            measureAttachments: () async => const AttachmentStorageReport(),
            measure: () async => result!)));
    await tester.pump();
    expect(find.text('Частичная оценка'), findsOneWidget);
    expect(find.textContaining('Логический размер'), findsNothing);
    await tester.scrollUntilVisible(find.text('Дополнительно'), 260);
    await tester.tap(find.text('Дополнительно'));
    await tester.pumpAndSettle();
    expect(
        find.text('Логический размер подтверждённой части истории: неизвестно'),
        findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining('не общий размер'), 240);
    expect(find.textContaining('не общий размер'), findsOneWidget);
  });

  testWidgets('attachment sizes display independently and never invoke cleanup',
      (tester) async {
    final busy = Completer<InventorySnapshot>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
      measure: () => busy.future,
      measureAttachments: () async => const AttachmentStorageReport(
          authorizedFilesBytes: 1500000, downloadedFilesBytes: 352),
      clearNews: () async {
        calls++;
        return const PublicNewsClearResult(PublicNewsClearStatus.complete);
      },
    )));
    await tester.pump();
    expect(find.text('Скачанные вложения: 352 Б'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Дополнительно'), 260);
    await tester.tap(find.text('Дополнительно'));
    await tester.pumpAndSettle();
    expect(find.text('Рабочие файлы чатов и данные доступа: 1.5 МБ'),
        findsOneWidget);
    expect(find.text('Копии для просмотра: неизвестно'), findsOneWidget);
    expect(calls, 0);
    busy.complete(InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: []));
    await tester.pump();
  });

  testWidgets(
      'manual news cleanup requires confirmation and reports its result',
      (tester) async {
    final first = Completer<PublicNewsClearResult>();
    var clears = 0, measurements = 0;
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
      measure: () async {
        measurements++;
        return InventorySnapshot(
            startedAt: DateTime.now(),
            finishedAt: DateTime.now(),
            observations: []);
      },
      measureAttachments: () async => const AttachmentStorageReport(),
      clearNews: () async {
        clears++;
        if (clears == 1) return first.future;
        if (clears == 2) throw StateError('unavailable');
        return const PublicNewsClearResult(PublicNewsClearStatus.complete,
            filesRemoved: 2);
      },
    )));
    await tester.pumpAndSettle();
    final action =
        find.widgetWithText(OutlinedButton, 'Очистить кэш публичных новостей');
    Future<void> openDialog() async {
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }

    Future<void> confirm() async {
      await openDialog();
      await tester.tap(find.text('Удалить копии'));
      await tester.pumpAndSettle();
    }

    await openDialog();
    expect(clears, 0);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(clears, 0);
    await confirm();
    expect(clears, 1);
    expect(tester.widget<OutlinedButton>(action).onPressed, isNull);
    first.complete(const PublicNewsClearResult(PublicNewsClearStatus.partial,
        filesRemoved: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('частично. Удалено файлов: 3.'), findsOneWidget);
    expect(measurements, 2);
    await confirm();
    expect(
        find.textContaining('Не удалось подтвердить очистку'), findsOneWidget);
    await confirm();
    expect(find.text('Очистка завершена. Удалено файлов: 2.'), findsOneWidget);
    expect(clears, 3);
  });

  test('logical history is separate and malformed data is unknown', () async {
    sqfliteFfiInit();
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(database.close);
    await database
        .execute('CREATE TABLE chat_server_snapshot (chat TEXT, payload TEXT)');
    const body = '[{"id":"a","delivery_status":"sent"}]';
    await database
        .insert('chat_server_snapshot', {'chat': 'chat', 'payload': body});
    expect(await readLogicalHistory(database), body.length);
    await database
        .insert('chat_server_snapshot', {'chat': 'other', 'payload': '[{}]'});
    expect(await readLogicalHistory(database), isNull);
  });

  test('missing root and orphan WAL are unknown; concurrent scans coalesce',
      () async {
    final root = await Directory.systemTemp.createTemp('inventory_unknown_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final db = await Directory('${root.path}/db').create();
    final support = await Directory('${root.path}/support').create();
    await File('${db.path}/public_news_index_v2.db-wal').writeAsBytes([1]);
    await File('${support.path}/pinned_media_guard_ordinary_v1.db-wal')
        .writeAsBytes([2]);
    final gate = Completer<Directory>();
    var calls = 0;
    final collector = CacheInventoryCollector(
        temporaryRoot: () {
          calls++;
          return gate.future;
        },
        databaseRoot: () async => db,
        supportRoot: () async => support);
    final first = collector.collect(), second = collector.collect();
    expect(identical(first, second), isTrue);
    gate.complete(Directory('${root.path}/missing'));
    final result = await first;
    expect(calls, 1);
    expect(
        result.observations
            .firstWhere((o) => o.name == 'public_news_blobs_v2')
            .bytes,
        isNull);
    expect(
        result.observations
            .firstWhere((o) => o.name == 'public_news_index_v2.db')
            .bytes,
        isNull);
    expect(
        result.observations
            .firstWhere((o) => o.name == 'pinned_media_guard_ordinary_v1.db')
            .bytes,
        isNull);
    expect(await File('${db.path}/public_news_index_v2.db-wal').readAsBytes(),
        [1]);
  });

  testWidgets('timeout and error ignore late results and disposed UI',
      (tester) async {
    final pending = Completer<InventorySnapshot>();
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
            timeout: const Duration(seconds: 1),
            measureAttachments: () async => const AttachmentStorageReport(),
            measure: () => pending.future)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Сейчас недоступно'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: []));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
