import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/temporary_cache_budget.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

class StartupCacheBudgetResult {
  const StartupCacheBudgetResult(this.provenTemporaryBytes,
      this.logicalHistoryBytesEvicted, this.physicalHistoryBytesFreed);
  final int provenTemporaryBytes, logicalHistoryBytesEvicted, physicalHistoryBytesFreed;
}

/// Conservative startup maintenance. Unknown/protected bytes are not used
/// to justify eviction. This is a lower bound, not a hard global disk quota.
Future<StartupCacheBudgetResult?> runStartupCacheBudget(ProjectChatServerCache cache,
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
        TemporaryCacheBudget.measureProvenTemporary(cache.db, root: root, prefs: prefs))
        .timeout(scanTimeout, onTimeout: () => null);
    if (proven == null) return null;
    final excess = proven > limitBytes ? proven - limitBytes : 0;
    final guard = await cache.beginHistoryAppGuard(excess, allEnginesGuarded: true);
    if (guard == null) return null;
    try {
      final compacted = guard.logicalBytesEvicted == 0 ? null : await cache.compactHistory(guard);
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
