import 'dart:async';
import 'dart:io';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/pinned_media_runtime.dart';
import 'package:student_platform/src/core/pinned_media_availability.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Independent access-fence database. A damaged message/content cache must
/// not disable online file access or invalidate a healthy pinned archive.
class PinnedMediaHost {
  PinnedMediaHost({required this.scope, required this.project, required this.currentSession,
    required this.currentBinding, required this.supportDirectory, required this.cacheDirectory,
    this.databaseFactory, this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)]});
  final AuthSessionScope scope;
  final String project;
  final Session? Function() currentSession;
  final OfflineSessionBinding? Function() currentBinding;
  final Future<Directory> Function() supportDirectory, cacheDirectory;
  final sqlite.DatabaseFactory? databaseFactory;
  final List<Duration> retryDelays;
  sqlite.Database? _db;
  PinnedMediaRuntime? _runtime;
  Timer? _retry;
  bool _stopped = false, _starting = false;
  int _failures = 0;

  void start() {
    PinnedMediaAvailability.attach(this, retry);
    unawaited(_open());
  }

  void retry() {
    if (_stopped) return;
    _retry?.cancel(); _retry = null; _failures = 0;
    PinnedMediaAvailability.preparing(this);
    if (_runtime != null) { _runtime!.retry(); } else { unawaited(_open()); }
  }

  Future<void> _open() async {
    if (_stopped || _starting || _db != null) return;
    _starting = true;
    sqlite.Database? opened;
    try {
      final root = await supportDirectory().timeout(const Duration(seconds: 3));
      if (_stopped) return;
      var abandoned = false;
      final opening = openProjectChatServerDatabase('${root.path}/pinned_media_guard_ordinary_v1.db',
          factory: databaseFactory);
      unawaited(opening.then<void>((lateDb) async {
        if (abandoned) { try { await lateDb.close(); } catch (_) {} }
      }, onError: (Object _, StackTrace __) {}));
      opened = await opening.timeout(const Duration(seconds: 3), onTimeout: () {
        abandoned = true; throw TimeoutException('Media guard opening timed out');
      });
      if (_stopped) { await opened.close(); return; }
      final cache = ProjectChatServerCache(db: opened, scope: scope,
          currentBinding: currentBinding, project: project);
      final runtime = PinnedMediaRuntime(scope: scope, cache: cache,
          currentSession: currentSession, cacheDirectory: cacheDirectory,
          onUnavailable: () => PinnedMediaAvailability.unavailable(this));
      runtime.start();
      _db = opened; _runtime = runtime;
      _failures = 0;
      _retry?.cancel(); _retry = null;
    } catch (_) {
      if (opened != null && !identical(opened, _db)) {
        try { await opened.close(); } catch (_) {}
      }
      if (!_stopped) {
        PinnedMediaAvailability.unavailable(this);
        _failures++;
        if (_failures <= retryDelays.length) {
          _retry?.cancel();
          _retry = Timer(retryDelays[_failures - 1], () => unawaited(_open()));
        }
      }
    } finally { _starting = false; }
  }

  Future<void> dispose() async {
    _stopped = true; _retry?.cancel();
    PinnedMediaAvailability.detach(this);
    await _runtime?.dispose(); _runtime = null;
    final db = _db; _db = null;
    if (db != null) await db.close();
  }
}
