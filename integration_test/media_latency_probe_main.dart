import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName != 'com.example.offline_grant_qa') {
    throw StateError('Probe requires isolated package');
  }
  try {
    final root = await getApplicationCacheDirectory();
    final db = await openDatabase('${await getDatabasesPath()}/media_perf_${DateTime.now().microsecondsSinceEpoch}.db');
    const uid = 'synthetic', key = 'chats/synthetic/photo';
    final registry = MediaCacheProtection(db: db, root: root, project: 'synthetic',
        databaseToken: 'synthetic', currentOwner: () => uid);
    await registry.initialize();
    await db.execute('CREATE TABLE chat_app_guards (token TEXT NOT NULL, project TEXT NOT NULL)');
    await db.insert('chat_app_guards', {'token': 'synthetic', 'project': '*'});
    if (!await registry.beginOwnerReadWindow(uid, () => true)) throw StateError('window');
    final file = File('${root.path}/authorized_chat_files/$uid/${registry.digest(uid, key)}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(Uint8List(200000), flush: true);
    final baseline = <int>[], protected = <int>[];
    for (var i = 0; i < 35; i++) {
      var watch = Stopwatch()..start();
      if ((await file.readAsBytes()).length != 200000) throw StateError('baseline bytes');
      watch.stop();
      if (i >= 5) baseline.add(watch.elapsedMicroseconds);
      watch = Stopwatch()..start();
      final bytes = await registry.readInOwnerWindow(uid, () => true, file.readAsBytes);
      if (bytes.length != 200000) throw StateError('leased bytes');
      watch.stop();
      if (i >= 5) protected.add(watch.elapsedMicroseconds);
    }
    baseline.sort(); protected.sort();
    int percentile(List<int> values, double fraction) => values[((values.length - 1) * fraction).ceil()];
    debugPrint('CODEX_MEDIA_LATENCY_PASS '
      'baseline_p50_us=${percentile(baseline, .50)} baseline_p95_us=${percentile(baseline, .95)} '
      'registry_p50_us=${percentile(protected, .50)} registry_p95_us=${percentile(protected, .95)}');
    await registry.endOwnerReadWindow(uid);
    await db.close();
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Изолированная проверка пройдена')))));
  } catch (error) {
    debugPrint('CODEX_MEDIA_LATENCY_FAIL ${error.runtimeType}: $error');
    rethrow;
  }
}
