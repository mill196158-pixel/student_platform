// Standalone Android E2E entrypoint. Its only account backend is a host-local
// test server forwarded with adb reverse. No credentials are compiled in.
// For the foreground DM composer, set E2E_FOREGROUND_ROUTES=true and set
// SUPABASE_URL to the local GoTrue project URL so draft ownership can resolve.
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/navigation/root_nav.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:student_platform/src/ui/notifications/in_app_toast_host.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';
import 'package:student_platform/src/ui/notifications/push_session_host.dart';
import 'package:student_platform/src/ui/schedule/lesson_details_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _foregroundRoutes = bool.fromEnvironment('E2E_FOREGROUND_ROUTES');
final _foregroundBarrier = ValueNotifier<OnlineSideEffectBarrier?>(null);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode ||
      !Platform.isAndroid ||
      (await PackageInfo.fromPlatform()).packageName !=
          'com.mill453020.studentplatform.offlinefixture') {
    throw StateError('An isolated Android debug fixture is required.');
  }
  await initializeDateFormatting('ru_RU');
  runApp(MaterialApp(
    navigatorKey: rootNavigatorKey,
    home: const _Fixture(),
    builder: _foregroundRoutes
        ? (_, routes) => ValueListenableBuilder<OnlineSideEffectBarrier?>(
              valueListenable: _foregroundBarrier,
              child: routes,
              builder: (_, current, child) {
                final overlay = InAppToastHost(
                  barrier: current,
                  child: child ?? const SizedBox.shrink(),
                );
                // The real identity scope also owns routes opened by a banner.
                return current == null ? overlay : AuthSessionScopeHost(child: overlay);
              },
            )
        : null,
  ));
}

class _Fixture extends StatefulWidget {
  const _Fixture();

  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  static const coldTap = bool.fromEnvironment('E2E_COLD_PUSH_TAP');
  String status = 'Starting Firebase';
  bool ready = false;
  bool signedIn = false;
  bool connecting = false;
  bool initializedBackend = false;
  OnlineSideEffectBarrier? barrier;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _register());
  }

  void _setStatus(String text) {
    if (mounted) setState(() => status = text);
  }

  Future<void> _register() async {
    try {
      await PushNotificationService.instance.bootstrapFirebase();
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(minutes: 2));
      if (token == null || token.isEmpty) throw StateError('Missing token');
      final files = await getApplicationSupportDirectory();
      await File('${files.path}/student_push_qa_token')
          .writeAsString(token, flush: true);
      if (coldTap) {
        final backend = File('${files.path}/student_push_qa_backend.json');
        if (await backend.exists()) {
          await _initializeBackend(
              jsonDecode(await backend.readAsString()) as Map<String, dynamic>);
          final session = Supabase.instance.client.auth.currentSession;
          if (session != null) {
            _admit(session);
            return;
          }
        }
      }
      if (mounted) {
        setState(() {
          ready = true;
          status = 'Firebase ready';
        });
      }
    } catch (e) {
      _setStatus('Firebase registration failed (${e.runtimeType})');
    }
  }

  Future<void> _initializeBackend(Map<String, dynamic> cfg) async {
    if (initializedBackend) return;
    final port = cfg['port'];
    if (port is! int || port < 1024 || port > 65535) {
      throw StateError('Invalid local port');
    }
    await Supabase.initialize(
      url: 'http://127.0.0.1:$port',
      publishableKey: cfg['anonKey'] as String,
      authOptions: FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: coldTap ? null : const EmptyLocalStorage(),
      ),
    );
    initializedBackend = true;
  }

  void _admit(Session session) {
    barrier = OnlineSideEffectBarrier(
      ownerIsCurrent: () {
        final current = Supabase.instance.client.auth.currentSession;
        return current?.user.id == session.user.id &&
            current?.accessToken == session.accessToken &&
            current?.refreshToken == session.refreshToken;
      },
    );
    if (_foregroundRoutes) _foregroundBarrier.value = barrier;
    if (mounted) {
      setState(() {
        signedIn = true;
        status = 'Test student signed in';
      });
    }
  }

  Future<void> _signIn() async {
    if (connecting) return;
    setState(() => connecting = true);
    try {
      final files = await getApplicationSupportDirectory();
      final cfg = jsonDecode(
        await File('${files.path}/student_push_qa_config.json').readAsString(),
      ) as Map<String, dynamic>;
      await _initializeBackend(cfg);
      final result = await Supabase.instance.client.auth.signInWithPassword(
        email: cfg['email'] as String,
        password: cfg['password'] as String,
      );
      if (result.user == null) throw StateError('Missing test user');
      if (coldTap) {
        await File('${files.path}/student_push_qa_backend.json').writeAsString(
            jsonEncode({'port': cfg['port'], 'anonKey': cfg['anonKey']}),
            flush: true);
        await File('${files.path}/student_push_qa_config.json').delete();
      }
      _admit(result.session!);
    } catch (e) {
      _setStatus('Local test login failed (${e.runtimeType})');
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<void> _openChat() async {
    final files = await getApplicationSupportDirectory();
    final raw = await File('${files.path}/student_push_qa_peer.json').readAsString();
    final peer = jsonDecode(raw) as Map<String, dynamic>;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DirectChatScreen(
        peerId: peer['peerId'] as String,
        peerName: peer['peerName'] as String,
        initialChatId: peer['chatId'] as String,
      ),
    ));
  }

  Future<void> _switchAccount() async {
    final auth = Supabase.instance.client.auth;
    final session = auth.currentSession;
    final service = PushNotificationService.instance;
    final reservation = service.reserveGuardedLogout(
      isOwnerCurrent: () => session != null && identical(auth.currentSession, session),
    );
    if (reservation == null) throw StateError('No active test push session');
    try {
      await service.onLogout(reservation: reservation);
      await auth.signOut(scope: SignOutScope.local);
    } finally {
      reservation.finish();
    }
    barrier?.close();
    _foregroundBarrier.value = null;
    if (mounted) {
      setState(() {
        signedIn = false;
        ready = true;
        status = 'Firebase ready';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(status),
              if (ready && !signedIn)
                FilledButton(
                  onPressed: connecting ? null : _signIn,
                  child: const Text('Sign in to the local test account'),
                ),
              if (signedIn)
                FilledButton(
                  onPressed: () => showNotificationCenterSheet(context),
                  child: const Text('Open notification center'),
                ),
              if (_foregroundRoutes && signedIn)
                FilledButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => LessonDetailsScreen(lesson: Lesson(
                      id: 'foreground-push-lesson',
                      date: DateTime(2026, 11, 25),
                      week: 1,
                      day: 'СР',
                      pairNum: 1,
                      start: const TimeOfDay(hour: 9, minute: 0),
                      end: const TimeOfDay(hour: 10, minute: 30),
                      subjectRaw: 'Foreground QA lesson',
                    )),
                  )),
                  child: const Text('Open test lesson'),
                ),
              if (_foregroundRoutes && signedIn) ...[
                FilledButton(onPressed: _openChat, child: const Text('Open test conversation')),
                TextButton(onPressed: _switchAccount, child: const Text('Switch test student')),
              ],
            ],
          ),
        ),
      ),
    );
    return signedIn ? PushSessionHost(barrier: barrier, child: screen) : screen;
  }
}
