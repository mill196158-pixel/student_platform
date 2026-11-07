import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName != 'com.example.offline_grant_qa') {
    throw StateError('Probe requires isolated package');
  }
  try {
    final prefs = await SharedPreferences.getInstance();
    final phase = prefs.getString('codex_guard_probe_phase_v4');
    final path = phase == 'armed' ? prefs.getString('codex_guard_probe_path_v4')!
        : '${await getDatabasesPath()}/guard_probe_${DateTime.now().microsecondsSinceEpoch}.db';
    final session = Session(accessToken: 'synthetic', refreshToken: 'synthetic', tokenType: 'bearer',
      user: User(id: 'qa', appMetadata: const {}, userMetadata: null, aud: '', createdAt: ''));
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://example.invalid/auth/v1', userId: 'qa',
      sessionId: 'synthetic', notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    final db = await openProjectChatServerDatabase(path);
    if (debugProjectChatDatabaseGuard(db) == null) throw StateError('normal guard missing');
    final cache = ProjectChatServerCache(db: db, scope: scope, currentBinding: () => binding,
      project: 'https://example.invalid');
    if (phase != 'armed') {
      final ticket = await cache.begin('qa-chat');
      if (ticket == null) throw StateError('synthetic ticket unavailable');
      final message = Message.fromJson({'id': 'qa-message', 'chat_id': 'qa-chat', 'author_id': 'qa',
        'content': 'x' * 500000, 'created_at': now.toIso8601String()});
      if (!await cache.saveServerPage(ticket, [message], hasMore: false)) throw StateError('save failed');
      if (await cache.acquireHistoryRouteLease('qa-chat') == null) throw StateError('route lease failed');
      await prefs.setString('codex_guard_probe_path_v4', path);
      await prefs.setString('codex_guard_probe_phase_v4', 'armed');
      debugPrint('CODEX_ISOLATED_GUARD_READY_FOR_KILL');
      runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Изолированная проверка: этап 1')))));
      return; // Deliberately leave this QA process and lock alive for crash probe.
    }

    final guard = await cache.beginHistoryAppGuard(1, allEnginesGuarded: true);
    if (guard == null || guard.logicalBytesEvicted <= 0) throw StateError('crash recovery or LRU failed');
    final compacted = await cache.compactHistory(guard);
    if (compacted == null) throw StateError('compaction failed');
    var actual = 0;
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (await file.exists()) actual += (await file.stat()).size;
    }
    if (compacted.afterBytes != actual) throw StateError('physical accounting mismatch');
    await cache.releaseHistoryAppGuard(guard);
    await db.close();

    debugBeforeDatabaseGuard = () async => throw FileSystemException('simulated lock refusal');
    final fallback = await openProjectChatServerDatabase(path);
    debugBeforeDatabaseGuard = null;
    final fallbackCache = ProjectChatServerCache(db: fallback, scope: scope,
      currentBinding: () => binding, project: 'https://example.invalid');
    final ticket = await fallbackCache.begin('fallback-chat');
    if (ticket == null) throw StateError('fallback ticket unavailable');
    final message = Message.fromJson({'id': 'fallback-message', 'chat_id': 'fallback-chat', 'author_id': 'qa',
      'content': 'synthetic', 'created_at': now.toIso8601String()});
    if (!await fallbackCache.saveServerPage(ticket, [message], hasMore: false)) throw StateError('fallback save failed');
    final caps = SessionCapabilities(scope);
    if (!caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!)) {
      throw StateError('capability failed');
    }
    if ((await fallbackCache.read('fallback-chat', caps))?.single.text != 'synthetic') {
      throw StateError('offline read failed');
    }
    if (await fallbackCache.beginHistoryAppGuard(1, allEnginesGuarded: true) != null) {
      throw StateError('unsafe eviction allowed');
    }
    caps.dispose(); scope.dispose(); await events.close(); await fallback.close();
    await prefs.setString('codex_guard_probe_phase_v4', 'complete');
    debugPrint('CODEX_ISOLATED_GUARD_PROBE_PASS freed=${compacted.physicallyFreedBytes}');
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Изолированная проверка пройдена')))));
  } catch (error) {
    debugPrint('CODEX_ISOLATED_GUARD_PROBE_FAIL ${error.runtimeType}: $error');
    rethrow;
  }
}
