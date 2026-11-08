import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';

void main() {
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
        home: CacheDiagnosticsScreen(measure: () async => result!)));
    await tester.pump();
    expect(find.text('Частичная оценка'), findsOneWidget);
    expect(find.text('Логический размер истории: неизвестно'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pump();
    expect(find.textContaining('не общий размер'), findsOneWidget);
    expect(find.textContaining('очистка пока недоступны'), findsOneWidget);
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
