import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';

void main() {
  testWidgets('revoked offline permit blocks pending confirmation',
      (tester) async {
    var allowed = true, clears = 0;
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
      canAccess: () => allowed,
      measure: () async => measurement(),
      clearNews: () async {
        clears++;
        return const PublicNewsClearResult(PublicNewsClearStatus.complete);
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Очистить кэш'));
    await tester.pumpAndSettle();
    allowed = false;
    await tester.tap(find.text('Очистить'));
    await tester.pumpAndSettle();
    expect(clears, 0);
  });

  testWidgets(
      'only the replaceable total is shown and inventory leaves protected bytes intact',
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
        home: CacheDiagnosticsScreen(measure: () async => result!)));
    await tester.pump();
    expect(find.text('20 Б'), findsOneWidget);
    expect(find.text('3 Б'), findsNothing);
    expect(find.text('Дополнительно'), findsNothing);
  });

  testWidgets('resume refreshes the total automatically without clearing',
      (tester) async {
    var measured = 21, clears = 0;
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
      measure: () async => measurement(measured),
      clearNews: () async {
        clears++;
        return const PublicNewsClearResult(PublicNewsClearStatus.complete);
      },
    )));
    await tester.pump();
    expect(find.text('21 Б'), findsOneWidget);
    measured = 64;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('64 Б'), findsOneWidget);
    expect(find.text('Обновить'), findsNothing);
    expect(clears, 0);
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
      clearNews: () async {
        clears++;
        if (clears == 1) return first.future;
        if (clears == 2) throw StateError('unavailable');
        return const PublicNewsClearResult(PublicNewsClearStatus.complete,
            filesRemoved: 2);
      },
    )));
    await tester.pumpAndSettle();
    final action = find.widgetWithText(OutlinedButton, 'Очистить кэш');
    Future<void> openDialog() async {
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }

    Future<void> confirm() async {
      await openDialog();
      await tester.tap(find.text('Очистить'));
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
    expect(
        find.textContaining('Часть временных файлов осталась'), findsOneWidget);
    expect(measurements, 2);
    await confirm();
    expect(find.textContaining('Не удалось очистить кэш'), findsOneWidget);
    await confirm();
    expect(find.text('Кэш очищен.'), findsOneWidget);
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
            measure: () => pending.future)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('0 Б'), findsNothing);
    expect(find.text('Очистить кэш'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: []));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

InventorySnapshot measurement([int? bytes]) => InventorySnapshot(
      startedAt: DateTime(2026, 11, 27),
      finishedAt: DateTime(2026, 11, 27),
      observations: [
        InventoryObservation(
            'public_news_blobs_v2', InventoryClass.optional, bytes)
      ],
    );
