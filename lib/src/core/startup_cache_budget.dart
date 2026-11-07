import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:path_provider/path_provider.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/core/temporary_cache_budget.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

class StartupCacheBudgetResult {
  const StartupCacheBudgetResult(this.provenTemporaryBytes,
      this.logicalHistoryBytesEvicted, this.physicalHistoryBytesFreed);
  final int provenTemporaryBytes,
      logicalHistoryBytesEvicted,
      physicalHistoryBytesFreed;
}

/// Conservative startup maintenance. Unknown/protected bytes are not used
/// to justify eviction. This is a lower bound, not a hard global disk quota.
Future<StartupCacheBudgetResult?> runStartupCacheBudget(
    ProjectChatServerCache cache,
    {required bool allEnginesGuarded,
    @visibleForTesting Directory? root,
    @visibleForTesting SharedPreferences? prefs,
    @visibleForTesting int limitBytes = TemporaryCacheBudget.limitBytes,
    @visibleForTesting Duration scanTimeout = const Duration(milliseconds: 500),
    @visibleForTesting Future<int?> Function()? debugMeasure}) async {
  if (!allEnginesGuarded || limitBytes < 0) return null;
  try {
    // Only the read-only inventory is time-limited. A timed-out inventory
    // cannot later start eviction, even though its underlying future may run.
    final proven = await (debugMeasure?.call() ??
            TemporaryCacheBudget.measureProvenTemporary(cache.db,
                root: root, prefs: prefs))
        .timeout(scanTimeout, onTimeout: () => null);
    if (proven == null) return null;
    final excess = proven > limitBytes ? proven - limitBytes : 0;
    final guard =
        await cache.beginHistoryAppGuard(excess, allEnginesGuarded: true);
    if (guard == null) return null;
    try {
      final compacted = guard.logicalBytesEvicted == 0
          ? null
          : await cache.compactHistory(guard);
      return StartupCacheBudgetResult(proven, guard.logicalBytesEvicted,
          compacted?.physicallyFreedBytes ?? 0);
    } finally {
      await cache.releaseHistoryAppGuard(guard);
    }
  } catch (_) {
    // A failed inventory, SQLite operation or release never triggers fallback
    // deletion and must not prevent normal startup.
    return null;
  }
}

/// QA-only inventory for the three v2 news namespaces. This does not count
/// legacy, the coordination DB, other caches, chat history or protected data.
class QaNewsBudgetResult {
  const QaNewsBudgetResult(
      this.beforeBytes, this.confirmedFreedBytes, this.afterBytes);
  final int beforeBytes, confirmedFreedBytes, afterBytes;
}

/// Never called from production startup. In the absence of a proven engine
/// enrollment this only inventories; the proof hook is for synthetic tests,
/// not an assertion that a boolean proves ownership in a real installation.
@visibleForTesting
Future<QaNewsBudgetResult?> runQaNewsCacheMaintenance({
  required int limitBytes,
  @visibleForTesting Directory? temporaryRoot,
  @visibleForTesting sqlite.Database? database,
  @visibleForTesting bool Function()? debugSyntheticEngineProof,
}) async {
  if (!const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA') || limitBytes < 0)
    return null;
  try {
    final base = temporaryRoot ?? await getTemporaryDirectory();
    final caches = <NewsImageDiskCache>[];
    final dirs = <Directory>[];
    for (final name in [
      'news_images_v1',
      'guest_news_images_v1',
      'content_media_images_v1'
    ]) {
      final folder = Directory('${base.path}/${name}_immutable_qa_v2');
      dirs.add(folder);
      caches.add(NewsImageDiskCache(
          directoryName: name,
          rootOverride: temporaryRoot == null ? null : () => folder,
          immutableQaDatabase: database));
    }
    Future<int> size() async {
      var total = 0;
      for (final dir in dirs) {
        final type = await FileSystemEntity.type(dir.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (type != FileSystemEntityType.directory)
          throw StateError('Unsafe namespace');
        await for (final item
            in dir.list(recursive: true, followLinks: false)) {
          final type =
              await FileSystemEntity.type(item.path, followLinks: false);
          if (type == FileSystemEntityType.link)
            throw StateError('Unexpected link');
          if (type == FileSystemEntityType.file)
            total += (await item.stat()).size;
        }
      }
      return total;
    }

    final before = await size();
    var freed = 0;
    if (before > limitBytes && debugSyntheticEngineProof?.call() == true) {
      for (final cache in caches) {
        freed += await cache.collectQaOrphans(allOperationsParticipate: true);
      }
    }
    return QaNewsBudgetResult(before, freed, await size());
  } catch (_) {
    return null;
  }
}
