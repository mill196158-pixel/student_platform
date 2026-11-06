// Manual process-kill reproducer: synthetic data, isolated QA app id only.
// Phase 1 pauses after the current destructive take, before preparation/send.
// Kill the process and relaunch: phase 2 reports whether the source survived.
// It does not upload, send a message, contact Supabase, or use real accounts.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_preferences.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid ||
      (await PackageInfo.fromPlatform()).packageName !=
          'com.example.offline_grant_qa') {
    throw StateError('Run only in the isolated offline_grant_qa app');
  }
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('Synthetic forward crash QA')))));
  final dir = await getApplicationDocumentsDirectory();
  final status = File('${dir.path}/forward_crash_repro_status.txt');
  final events = StreamController<AuthState>.broadcast(sync: true);
  final session = Session(
      accessToken: 'synthetic',
      refreshToken: 'synthetic',
      tokenType: 'bearer',
      user: User(
          id: 'qa-synthetic',
          appMetadata: const {},
          userMetadata: null,
          aud: '',
          createdAt: ''));
  final scope = AuthSessionScope(
      currentSession: () => session, authEvents: events.stream);
  events.add(AuthState(AuthChangeEvent.initialSession, session));
  final store = ForwardOutboxStore(
      scope, ForwardOutboxCoordinator(PreferencesForwardOutboxStorage()));
  final owner = scope.capture()!;
  const chatId = 'qa-synthetic-forward-crash';
  try {
    if (!await status.exists()) {
      if (await store.peek(owner, chatId) != null) {
        throw StateError('QA outbox is not empty');
      }
      await store.putIfVacant(owner, chatId,
          text: 'synthetic forward', files: ['synthetic-file']);
      final entry = await store.peek(owner, chatId);
      if (entry == null ||
          await store.acknowledge(entry) != ForwardAcknowledgeResult.removed) {
        throw StateError('Could not reproduce current take');
      }
      await status.writeAsString('paused_before_prepare_or_send', flush: true);
      await Completer<void>().future;
    } else {
      final remaining = await store.peek(owner, chatId);
      await status.writeAsString(
          remaining == null ? 'loss_reproduced' : 'entry_survived',
          flush: true);
    }
  } catch (error) {
    await status.writeAsString('failed:${error.runtimeType}', flush: true);
  }
}
