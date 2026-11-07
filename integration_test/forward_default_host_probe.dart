import 'dart:async';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_host.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Synthetic, separately installed Android application only. Never run with a
// production package ID. Exercises the real host's default database opener.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName != 'com.example.forward_host_qa') {
    throw StateError('Requires isolated package');
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('forward_outbox_qa_synthetic-chat', 'synthetic-legacy-outbox');
  final dbPath = path.join(await getDatabasesPath(), 'forward_outbox_v1.db');
  if (await databaseExists(dbPath)) throw StateError('Fresh QA package required');
  final db = await openDatabase(dbPath, version: 2, onCreate: (db, _) async {
    // Deliberately omit message_id. SQLite upgrade must fail atomically.
    await db.execute('CREATE TABLE forward_item (backend TEXT, uid TEXT, chat TEXT, op TEXT, version INTEGER, state TEXT, source TEXT, source_urls TEXT, source_ids TEXT, prepared TEXT, prepared_ids TEXT, sent_text TEXT, reply_id TEXT, sent_ids TEXT, PRIMARY KEY(backend,uid,chat))');
    await db.insert('forward_item', {'backend': SupabaseConfig.url, 'uid': 'qa', 'chat': 'synthetic-chat', 'op': 'old-operation', 'version': 0, 'state': 'queued', 'source': 'synthetic-payload', 'source_urls': '[]', 'source_ids': '[]'});
  });
  await db.close();
  final session = Session(accessToken: 'synthetic', refreshToken: 'synthetic', tokenType: 'bearer', user: User(id: 'qa', appMetadata: const {}, userMetadata: null, aud: '', createdAt: ''));
  final events = StreamController<AuthState>.broadcast(sync: true);
  final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
  events.add(AuthState(AuthChangeEvent.initialSession, session));
  runApp(MaterialApp(home: _Probe(scope: scope, dbPath: dbPath)));
}

class _Probe extends StatefulWidget {
  const _Probe({required this.scope, required this.dbPath});
  final AuthSessionScope scope;
  final String dbPath;
  @override State<_Probe> createState() => _ProbeState();
}
class _ProbeState extends State<_Probe> {
  int stage = 0;
  bool running = false;
  Future<void> exercise(BuildContext context) async {
    if (running) return;
    running = true;
    try {
      if (stage == 0) {
        var failed = false;
        try { await ForwardOutboxHost.durable(context); } catch (_) { failed = true; }
        if (!failed) throw StateError('Malformed old DB unexpectedly opened');
        final db = await openDatabase(widget.dbPath, singleInstance: false);
        final rows = await db.rawQuery('SELECT source,state FROM forward_item');
        final version = Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version'));
        if (rows.length != 1 || rows.single['source'] != 'synthetic-payload' || rows.single['state'] != 'queued' || version != 2) throw StateError('Failed upgrade changed source');
        await db.execute('ALTER TABLE forward_item ADD COLUMN message_id TEXT');
        await db.close();
        if (!mounted) return;
        setState(() { stage = 1; running = false; });
      } else {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString('forward_outbox_qa_synthetic-chat') != 'synthetic-legacy-outbox') throw StateError('Legacy prefs changed');
        final store = await ForwardOutboxHost.durable(context);
        final owner = widget.scope.capture();
        if (owner == null) throw StateError('Owner missing');
        final receipt = await store.peek(owner, 'synthetic-chat');
        if (receipt == null || receipt.source != 'synthetic-payload' || receipt.state.name != 'reservedUnverified') throw StateError('Upgraded source unavailable');
        final rows = await store.db.rawQuery('PRAGMA user_version');
        if (Sqflite.firstIntValue(rows) != 5) throw StateError('Version not upgraded');
        debugPrint('CODEX_FORWARD_DEFAULT_HOST_PROBE_PASS');
        if (mounted) setState(() { stage = 2; });
      }
    } catch (error) {
      debugPrint('CODEX_FORWARD_DEFAULT_HOST_PROBE_FAIL ${error.runtimeType}: $error');
      rethrow;
    }
  }
  @override Widget build(BuildContext context) => ForwardOutboxHost(
    key: ValueKey(stage), source: widget.scope, durableMode: ForwardOutboxHost.mobileProductionMode,
    child: Builder(builder: (context) {
      if (stage != 2) WidgetsBinding.instance.addPostFrameCallback((_) => exercise(context));
      return Scaffold(body: Center(child: Text('Изолированная проверка: $stage')));
    }));
}
