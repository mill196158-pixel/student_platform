import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/core/pinned_media_store.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName != 'com.example.offline_grant_qa') throw StateError('isolated QA package required');
  try {
    const project = 'https://example.invalid', uid = 'synthetic', key = 'chats/test/file', sid = 'qa-session';
    await Supabase.initialize(url: project, publishableKey: 'synthetic',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final prefs = await SharedPreferences.getInstance();
    final db = await openProjectChatServerDatabase('${await getDatabasesPath()}/pinned_crash_probe_v1.db');
    final root = await getApplicationCacheDirectory(), support = await getApplicationSupportDirectory();
    final registry = MediaCacheProtection(db: db, root: root, project: project,
        databaseToken: debugProjectChatDatabaseGuard(db)!, currentOwner: () => uid);
    final fence = PinnedAccessFence(db, databaseToken: registry.databaseToken);
    ChatFileAccess.mediaProtection = registry;
    final source = File('${root.path}/authorized_chat_files/$uid/${registry.digest(uid, key)}');
    final archive = PinnedMediaStore(db: db, supportRoot: support, legacy: registry,
        project: project, uid: uid, sessionId: sid, permit: () => true,
        freeBytes: (_) async => 10000000, verifyLegacyProvenance: (_, __, ___, ____, _____) async => true);
    if (prefs.getBool('codex_pin_crash_armed') != true) {
      await source.parent.create(recursive: true); await source.writeAsBytes([1]);
      if (!await archive.pinFromLegacy(key)) throw StateError('initial pin failed');
      final initial = await fence.begin(project, uid, key); await fence.finish(initial, allowed: true);
      await prefs.setBool('codex_pin_crash_armed', true);
      unawaited(ChatFileAccess.debugWithLegacyMutation(() async {
        final temp = File('${source.path}.new'); await temp.writeAsBytes([2], flush: true);
        await temp.rename(source.path);
        debugPrint('CODEX_PIN_CRASH_READY');
        await Completer<void>().future;
      }, uid: uid, key: key));
      runApp(const MaterialApp(home: Scaffold(body: Text('Isolated crash probe: armed'))));
      return;
    }
    final auth = Session(accessToken: 'synthetic', refreshToken: 'synthetic', tokenType: 'bearer',
        user: User(id: uid, appMetadata: const {}, userMetadata: null, aud: '', createdAt: ''));
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => auth, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, auth));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: '$project/auth/v1', userId: uid, sessionId: sid,
        notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope, currentBinding: () => binding, project: project);
    await cache.recoverDeadAccessGuards();
    if (await fence.canRead(project, uid, key)) throw StateError('crash must deny');
    if (await source.exists()) await source.delete();
    final revalidate = await fence.begin(project, uid, key); await fence.finish(revalidate, allowed: true);
    if (await fence.canRead(project, uid, key)) throw StateError('dirty was cleared by allow');
    await source.writeAsBytes([2]);
    if (!await archive.pinFromLegacy(key)) throw StateError('repin failed');
    if (!await fence.canRead(project, uid, key)) throw StateError('repin recovery failed');
    if ((await archive.readPinned(key))?.single != 2) throw StateError('wrong version');
    await prefs.setBool('codex_pin_crash_armed', false);
    debugPrint('CODEX_PIN_CRASH_PASS');
    runApp(const MaterialApp(home: Scaffold(body: Text('Isolated crash probe: pass'))));
  } catch (error, stack) {
    debugPrint('CODEX_PIN_CRASH_FAIL $error $stack');
    runApp(const MaterialApp(home: Scaffold(body: Text('Isolated crash probe: failed'))));
  }
}
