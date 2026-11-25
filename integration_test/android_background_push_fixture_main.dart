// Standalone Android E2E entrypoint. Its only account backend is a host-local
// test server forwarded with adb reverse. No credentials are compiled in.
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';
import 'package:student_platform/src/ui/notifications/push_session_host.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode ||
      !Platform.isAndroid ||
      (await PackageInfo.fromPlatform()).packageName !=
          'com.mill453020.studentplatform.offlinefixture') {
    throw StateError('An isolated Android debug fixture is required.');
  }
  await initializeDateFormatting('ru_RU');
  runApp(const MaterialApp(home: _Fixture()));
}

class _Fixture extends StatefulWidget {
  const _Fixture();

  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
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

  Future<void> _signIn() async {
    if (connecting) return;
    setState(() => connecting = true);
    try {
      final files = await getApplicationSupportDirectory();
      final cfg = jsonDecode(
        await File('${files.path}/student_push_qa_config.json').readAsString(),
      ) as Map<String, dynamic>;
      final port = cfg['port'];
      if (port is! int || port < 1024 || port > 65535) {
        throw StateError('Invalid local port');
      }
      if (!initializedBackend) {
        await Supabase.initialize(
          url: 'http://127.0.0.1:$port',
          publishableKey: cfg['anonKey'] as String,
          authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: EmptyLocalStorage(),
          ),
        );
        initializedBackend = true;
      }
      final result = await Supabase.instance.client.auth.signInWithPassword(
        email: cfg['email'] as String,
        password: cfg['password'] as String,
      );
      if (result.user == null) throw StateError('Missing test user');
      final session = result.session!;
      barrier = OnlineSideEffectBarrier(
        ownerIsCurrent: () =>
            identical(Supabase.instance.client.auth.currentSession, session),
      );
      if (mounted) {
        setState(() {
          signedIn = true;
          status = 'Test student signed in';
        });
      }
    } catch (e) {
      _setStatus('Local test login failed (${e.runtimeType})');
    } finally {
      if (mounted) setState(() => connecting = false);
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
            ],
          ),
        ),
      ),
    );
    return signedIn ? PushSessionHost(barrier: barrier, child: screen) : screen;
  }
}
