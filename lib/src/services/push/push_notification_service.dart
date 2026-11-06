import 'dart:async';
import 'dart:io';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'package:student_platform/src/core/single_flight_initialization.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'guarded_push_open.dart';
import 'guarded_push_hint.dart';
import 'guarded_push_qa_route.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/firebase_options.dart';
import 'package:student_platform/src/navigation/root_nav.dart';
import 'package:student_platform/src/services/push/active_chat_tracker.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/push_background_handler.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/chats/data/chat_warm_coordinator.dart';
import 'package:student_platform/src/ui/notifications/push_permission_prompt.dart';

const _kInstallationIdKey = 'push_installation_id';
const _kPermissionPromptSeenKey = 'push_permission_prompt_seen';
const _guardedPushHintQa = bool.fromEnvironment('GUARDED_PUSH_HINT_QA');
const _guardedPushDmQa = bool.fromEnvironment('GUARDED_PUSH_DM_QA');
const _guardedPushTeamQa = bool.fromEnvironment('GUARDED_PUSH_TEAM_QA');
const _guardedPushActionQa = bool.fromEnvironment('GUARDED_PUSH_ACTION_QA');
@visibleForTesting
bool get debugGuardedPushHintQaEnabled => _guardedPushHintQa;

/// Single app-wide push service. Init after auth; dispose on logout.
class PushNotificationService {
  PushNotificationService._();
  static final PushNotificationService instance = PushNotificationService._();

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onOpenedSub;
  StreamSubscription<String>? _tokenRefreshSub;

  bool _firebaseReady = false;
  bool _localReady = false;
  bool _sessionActive = false;
  int _sessionRevision = 0;
  OnlineSideEffectBarrier? _guardedBarrier;
  bool _strictPushGuard = false;
  bool Function()? _guardedCurrent;
  (PushPayload, OnlineSideEffectBarrier)? _guardedPending;
  bool _promptInFlight = false;
  String? _installationId;
  bool get isSupportedPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  bool get isFirebaseReady => _firebaseReady;

  /// Reserve the guarded logout cleanup before the synchronous session fence.
  /// The reservation itself performs no network or filesystem work.
  PushLogoutReservation? reserveGuardedLogout({required bool Function() isOwnerCurrent}) {
    final barrier = _guardedBarrier;
    if (barrier == null || !barrier.isOpen) return null;
    return PushLogoutReservation._(barrier, isOwnerCurrent);
  }

  void bindNavigatorKey(GlobalKey<NavigatorState> key) {
    // Kept for call-site compatibility; navigation uses [rootNavigatorKey].
  }

  final _firebaseBootstrap = SingleFlightInitialization();
  Future<void> bootstrapFirebase() {
    if (qaNoAutomaticWrites) return Future.value();
    if (!isSupportedPlatform || _firebaseReady) return Future.value();
    // Framework post-frame callbacks precede rasterization. Do not start the
    // secondary messaging engine while the first visible frame is rendering.
    // The separate background-message handler does not use this UI gate.
    return _firebaseBootstrap.run(_initializeFirebase,
        after: WidgetsBinding.instance.waitUntilFirstFrameRasterized);
  }

  Future<void> _initializeFirebase() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await _initLocalNotifications();
      _firebaseReady = true;
      if (kDebugMode) debugPrint('[Push] Firebase ready');
    } catch (e) {
      _firebaseReady = false;
      if (kDebugMode) {
        debugPrint('[Push] Firebase unavailable (config missing?): $e');
      }
    }
  }

  Future<void> onAuthenticated(BuildContext? context,
      {OnlineSideEffectBarrier? barrier, bool Function()? isCurrent}) async {
    if (qaNoAutomaticWrites) return;
    if (!isSupportedPlatform) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    final revision = ++_sessionRevision;
    _guardedBarrier = barrier;
    _strictPushGuard = barrier != null;
    bool sameSession() =>
        _sessionActive &&
        _sessionRevision == revision &&
        (barrier?.isOpen ?? true) && (isCurrent?.call() ?? true) &&
        Supabase.instance.client.auth.currentUser?.id == userId;
    _sessionActive = true;
    _guardedCurrent = barrier == null ? null : sameSession;
    PushNavigation.markReady();

    await bootstrapFirebase();
    if (!_firebaseReady || !sameSession()) return;

    await _ensureInstallationId();
    if (!sameSession()) return;
    await _attachListeners(isCurrent: sameSession, barrier: barrier);
    if (!sameSession()) return;
    await _handleInitialMessage(sameSession);
    if (!sameSession()) return;

    if (context != null && context.mounted) {
      await maybeShowPermissionPrompt(context, isCurrent: sameSession);
    }
    if (!sameSession()) return;
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    if (sameSession() && _isAuthorized(settings.authorizationStatus)) {
      await _registerCurrentToken(isCurrent: sameSession);
    }
  }

  Future<void> onLogout({PushLogoutReservation? reservation}) async {
    if (reservation != null && !reservation.isOwnerCurrent) return;
    PushNavigation.markNotReady();
    _sessionActive = false;
    final revision = ++_sessionRevision;
    final original = Supabase.instance.client.auth.currentSession;
    bool sameOwner() {
      final current = Supabase.instance.client.auth.currentSession;
      return (reservation?.isOwnerCurrent ?? true) && _sessionRevision == revision &&
          current?.user.id == original?.user.id &&
          current?.accessToken == original?.accessToken &&
          current?.refreshToken == original?.refreshToken;
    }
    try {
      if (_localReady) await _local.cancelAll();
      if (!sameOwner()) return;
      if (!kIsWeb && Platform.isAndroid) {
        await const MethodChannel('student_platform/notifications')
            .invokeMethod<void>('clearNotifications');
      }
    } catch (_) {}
    if (!sameOwner()) return;
    final installationId = await _ensureInstallationId();
    if (!sameOwner()) return;

    if (!qaNoAutomaticWrites && Supabase.instance.client.auth.currentUser != null) {
      try {
        await Supabase.instance.client.rpc(
          'disable_device_push_token',
          params: {'p_installation_id': installationId},
        );
      } catch (e) {
        if (kDebugMode) debugPrint('[Push] disable token on logout: $e');
      }
    }
    if (!sameOwner()) return;
    await disposeListeners();
    if (!sameOwner()) return;
    _sessionActive = false;
  }

  Future<void> disposeListeners() async {
    final message = _onMessageSub, opened = _onOpenedSub, token = _tokenRefreshSub;
    _onMessageSub = null;
    _onOpenedSub = null;
    _tokenRefreshSub = null;
    await message?.cancel();
    await opened?.cancel();
    await token?.cancel();
  }

  /// Synchronously invalidates this guarded session before detaching its
  /// listeners. Cancellation remains tracked by its old barrier.
  void closeGuardedSession(OnlineSideEffectBarrier barrier) {
    if (!identical(_guardedBarrier, barrier)) return;
    _guardedBarrier = null;
    _guardedPending = null;
    _sessionActive = false;
    _guardedCurrent = null;
    _sessionRevision++;
    final message = _onMessageSub, opened = _onOpenedSub, token = _tokenRefreshSub;
    _onMessageSub = null;
    _onOpenedSub = null;
    _tokenRefreshSub = null;
    unawaited(barrier.trackTeardown(() async {
      await message?.cancel();
      await opened?.cancel();
      await token?.cancel();
    }));
  }

  Future<void> maybeShowPermissionPrompt(BuildContext context,
      {bool Function()? isCurrent}) async {
    bool current() => isCurrent?.call() ?? true;
    if (!current()) return;
    if (!isSupportedPlatform || !_firebaseReady) return;
    if (_promptInFlight) return;

    final prefs = await SharedPreferences.getInstance();
    if (!current()) return;
    if (prefs.getBool(_kPermissionPromptSeenKey) == true) return;

    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    if (!current()) return;
    if (_isAuthorized(settings.authorizationStatus)) {
      await prefs.setBool(_kPermissionPromptSeenKey, true);
      if (current()) await _registerCurrentToken(isCurrent: current);
      return;
    }

    // Do not ask on splash/login — caller must be post-auth home/shell.
    final route = ModalRoute.of(context)?.settings.name;
    if (route == '/splash' || route == '/login') return;

    _promptInFlight = true;
    try {
      final enable = await showPushPermissionPrompt(context);
      if (!current()) return;
      await prefs.setBool(_kPermissionPromptSeenKey, true);
      if (enable == true && current()) {
        await requestSystemPermissionAndRegister(isCurrent: current);
      }
    } finally {
      _promptInFlight = false;
    }
  }

  Future<bool> requestSystemPermissionAndRegister({bool Function()? isCurrent}) async {
    if (!isSupportedPlatform || !_firebaseReady) return false;
    if (!(isCurrent?.call() ?? true)) return false;

    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      announcement: false,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
    );

    final granted = _isAuthorized(settings.authorizationStatus);
    if (granted && (isCurrent?.call() ?? true)) {
      await _registerCurrentToken(isCurrent: isCurrent);
    }
    return granted;
  }

  Future<AuthorizationStatus> currentAuthorizationStatus() async {
    if (!isSupportedPlatform || !_firebaseReady) {
      return AuthorizationStatus.notDetermined;
    }
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    return settings.authorizationStatus;
  }

  Future<void> openSystemNotificationSettings() async {
    if (!isSupportedPlatform) return;
    try {
      const channel = MethodChannel('student_platform/notifications');
      await channel.invokeMethod<void>('openNotificationSettings');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Push] openNotificationSettings failed: $e');
      }
    }
  }

  Future<void> _attachListeners({bool Function()? isCurrent,
      OnlineSideEffectBarrier? barrier}) async {
    bool current() => isCurrent?.call() ?? true;
    // Existing callbacks capture the former session. Remove them before
    // replacing and never attach a stale continuation after the await.
    await disposeListeners();
    if (!current()) return;
    void dispatch(Future<void> Function() operation) {
      if (!current()) return;
      if (barrier == null) {
        unawaited(operation());
      } else {
        unawaited(barrier.run(operation));
      }
    }
    _onMessageSub = FirebaseMessaging.onMessage.listen((message) =>
        dispatch(() => _onForegroundMessage(message, isCurrent: current)));
    _onOpenedSub =
        FirebaseMessaging.onMessageOpenedApp.listen((message) =>
            dispatch(() => _onMessageOpened(message, isCurrent: current)));
    _tokenRefreshSub =
        FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      if (!_sessionActive || !current()) return;
      dispatch(() => _upsertToken(token, isCurrent: current));
    });
  }

  Future<void> _handleInitialMessage(bool Function() sameSession) async {
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial == null || !sameSession()) return;
    final payload = PushPayload.tryParse(initial.data);
    if (payload == null) return;
    if (_strictPushGuard) {
      final barrier = _guardedBarrier;
      if (barrier != null && sameSession()) _guardedPending = (payload, barrier);
      return;
    }
    PushNavigation.stash(payload);
  }

  Future<void> flushGuardedPending(OnlineSideEffectBarrier barrier) async {
    final pending = _guardedPending;
    if (pending == null || !identical(pending.$2, barrier) || !barrier.isOpen) return;
    _guardedPending = null;
    await openGuardedPayload(pending.$1);
  }

  Future<void> _onForegroundMessage(RemoteMessage message, {bool Function()? isCurrent}) async {
    final payload = PushPayload.tryParse(message.data);
    final chatId = payload?.chatId ?? message.data['chat_id']?.toString();
    final eventType = payload?.type ?? message.data['type']?.toString() ?? '';
    if (!_sessionActive || !(isCurrent?.call() ?? true) ||
        InAppNotificationBus.instance.wasDismissed(payload?.notificationId) ||
        ActiveChatTracker.instance.isActive(chatId)) {
      return;
    }

    // FCM can arrive after the notification was read on another device.
    // Verify the current recipient before presenting a delayed OS payload.
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    if (payload?.notificationId != null) {
      try {
        final row = await Supabase.instance.client
            .from('app_notifications')
            .select('id,read_at,deleted_at')
            .eq('id', payload!.notificationId!)
            .eq('recipient_id', uid)
            .maybeSingle();
        if (row == null || row['read_at'] != null || row['deleted_at'] != null)
          return;
      } catch (_) {
        // Realtime can still deliver fresh events; do not display an unverifiable delayed push.
        return;
      }
      if (!_sessionActive || !(isCurrent?.call() ?? true) ||
          Supabase.instance.client.auth.currentUser?.id != uid ||
          InAppNotificationBus.instance.wasDismissed(payload.notificationId) ||
          ActiveChatTracker.instance.isActive(chatId)) return;
    }

    final title =
        message.notification?.title ?? payload?.raw['title'] ?? 'Уведомление';
    final body = message.notification?.body ?? payload?.raw['body'] ?? '';

    final toastTitle = title.toString();
    final toastBody = body.toString();
    InAppNotificationBus.instance.emit(
      InAppNotificationEvent(
        type: eventType,
        title: toastTitle,
        body: toastBody,
        payload: PushNavigation.withDisplayFields(
          payload,
          title: toastTitle,
          body: toastBody,
        ),
      ),
    );

    // Quietly warm that thread so opening the chat is instant.
    if (chatId != null && chatId.isNotEmpty && _guardedBarrier == null) {
      ChatWarmCoordinator.instance.prioritizeChat(chatId);
    }

    // Known foreground events use the global in-app banner. Do not also
    // display a system notification for the same event.
    if (PushPayload.knownTypes.contains(eventType)) return;

    await _showLocalNotification(
      title: title.toString(),
      body: body.toString(),
      payload: payload,
      eventType: eventType,
    );
  }

  Future<void> _onMessageOpened(RemoteMessage message, {bool Function()? isCurrent}) async {
    if (!(isCurrent?.call() ?? true)) return;
    final payload = PushPayload.tryParse(message.data);
    if (payload == null) return;
    if (_strictPushGuard) {
      await openGuardedPayload(payload);
      return;
    }
    final context = rootNavigatorContext;
    if (context == null) {
      PushNavigation.stash(payload);
      return;
    }
    await PushNavigation.handle(context, payload);
  }

  /// Opens a guarded payload only after confirming it belongs to this owner.
  /// Payloads without a server notification id remain unavailable offline.
  Future<void> openGuardedPayload(PushPayload payload) async {
    final barrier = _guardedBarrier, guard = _guardedCurrent;
    final client = Supabase.instance.client;
    final session = client.auth.currentSession;
    final user = session?.user.id;
    final id = payload.notificationId;
    if (barrier == null || guard == null || user == null || session == null) return;
    bool current() => barrier.isOpen && identical(_guardedBarrier, barrier) &&
        guard() && identical(Supabase.instance.client, client) &&
        client.auth.currentSession?.user.id == user &&
        client.auth.currentSession?.accessToken == session.accessToken &&
        client.auth.currentSession?.refreshToken == session.refreshToken;
    if (id == null || id.isEmpty) {
      if (!_guardedPushHintQa || !current()) return;
      final navigator = rootNavigatorKey.currentState;
      if (navigator == null || !navigator.mounted) return;
      await openGuardedPushHint(navigator: navigator, payload: payload,
          barrier: barrier, isCurrent: current,
          fetchSummaries: () async => await client.rpc('get_my_chat_summaries'),
          buildVerifiedTarget: (_guardedPushDmQa || _guardedPushTeamQa || _guardedPushActionQa)
              ? (target) => buildGuardedPushQaTarget(incoming: payload, target: target,
                  client: client, user: user, barrier: barrier, current: current,
                  dmEnabled: _guardedPushDmQa, teamEnabled: _guardedPushTeamQa,
                  actionEnabled: _guardedPushActionQa)
              : null);
      return;
    }
    await openVerifiedPush(barrier: barrier, isCurrent: current, verify: () async {
      try {
        final row = await Supabase.instance.client.from('app_notifications')
            .select('id,recipient_id,deleted_at').eq('id', id)
            .eq('recipient_id', user).maybeSingle();
        return row != null && row['deleted_at'] == null && row['recipient_id'] == user;
      } catch (_) { return false; }
    }, open: () async {
        final context = rootNavigatorContext;
        if (context == null || !context.mounted || !current()) return;
        await PushNavigation.handle(context, payload, force: true,
            isCurrent: current, barrier: barrier);
    });
  }

  Future<void> _showLocalNotification({
    required String title,
    required String body,
    PushPayload? payload,
    String? eventType,
  }) async {
    if (!_localReady) return;

    final androidDetails = AndroidNotificationDetails(
      _channelIdFor(eventType),
      _channelNameFor(eventType),
      channelDescription: _channelDescriptionFor(eventType),
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_stat_notification',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _local.show(
      id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      payload: payload?.toLocalPayload(),
    );
  }

  Future<void> _initLocalNotifications() async {
    if (_localReady) return;

    const androidInit =
        AndroidInitializationSettings('@drawable/ic_stat_notification');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _local.initialize(
      settings:
          const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (response) {
        final parsed = PushPayload.tryParseLocalPayload(response.payload);
        if (parsed == null) return;
        if (_strictPushGuard) {
          unawaited(openGuardedPayload(parsed));
          return;
        }
        final barrier = _guardedBarrier;
        final context = rootNavigatorContext;
        if (context == null) {
          PushNavigation.stash(parsed);
          return;
        }
        if (barrier == null) {
          unawaited(PushNavigation.handle(context, parsed, force: true));
        } else {
          unawaited(barrier.run(() async {
            if (_guardedCurrent?.call() ?? false) {
              await PushNavigation.handle(context, parsed, force: true);
            }
          }));
        }
      },
    );

    final androidPlugin = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'messages',
        'Сообщения',
        description: 'Личные и учебные сообщения',
        importance: Importance.high,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'study',
        'Учёба',
        description: 'Задания и изменения расписания',
        importance: Importance.high,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'social',
        'Друзья',
        description: 'Заявки и принятие в друзья',
        importance: Importance.defaultImportance,
      ),
    );

    _localReady = true;
  }

  Future<void> _registerCurrentToken({bool Function()? isCurrent}) async {
    if (qaNoAutomaticWrites) return;
    bool current() => _sessionActive && (isCurrent?.call() ?? true);
    if (!_firebaseReady || !current()) return;

    for (var attempt = 1; attempt <= 5; attempt++) {
      if (!current()) return;
      try {
        if (Platform.isIOS) {
          final apns = await FirebaseMessaging.instance.getAPNSToken();
          if (!current()) return;
          if (apns == null || apns.isEmpty) {
            if (kDebugMode) {
              debugPrint('[Push] APNs token is not ready, retry $attempt/5');
            }
            await Future<void>.delayed(Duration(seconds: attempt));
            continue;
          }
        }

        final token = await FirebaseMessaging.instance.getToken();
        if (!current()) return;
        if (token == null || token.isEmpty) {
          if (kDebugMode) {
            debugPrint('[Push] FCM token is empty, retry $attempt/5');
          }
          await Future<void>.delayed(Duration(seconds: attempt));
          continue;
        }
        await _upsertToken(token, isCurrent: current);
        return;
      } catch (e) {
        if (kDebugMode)
          debugPrint('[Push] getToken failed attempt $attempt: $e');
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
  }

  Future<void> _upsertToken(String token, {bool Function()? isCurrent}) async {
    bool current() => isCurrent?.call() ?? true;
    if (!current() || Supabase.instance.client.auth.currentUser == null) return;

    final installationId = await _ensureInstallationId();
    if (!current()) return;
    final platform = Platform.isIOS ? 'ios' : 'android';
    String? appVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    if (!current()) return;

    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    final timezone = DateTime.now().timeZoneName;

    try {
      await Supabase.instance.client.rpc(
        'register_device_push_token',
        params: {
          'p_installation_id': installationId,
          'p_token': token,
          'p_platform': platform,
          'p_app_version': appVersion,
          'p_locale': locale,
          'p_timezone': timezone,
        },
      );
      if (kDebugMode) {
        final hint = token.length <= 8
            ? '***'
            : '${token.substring(0, 4)}…${token.substring(token.length - 4)}';
        debugPrint('[Push] token registered ($hint)');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Push] register token failed: $e');
    }
  }

  Future<String> _ensureInstallationId() async {
    if (_installationId != null) return _installationId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kInstallationIdKey);
    if (id == null || id.isEmpty) {
      id = _newInstallationId();
      await prefs.setString(_kInstallationIdKey, id);
    }
    _installationId = id;
    return id;
  }

  bool _isAuthorized(AuthorizationStatus status) {
    return status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
  }

  String _channelIdFor(String? eventType) {
    switch (eventType) {
      case 'friend_request':
      case 'friend_accepted':
        return 'social';
      case 'assignment':
      case 'schedule_change':
      case 'announcement':
        return 'study';
      default:
        return 'messages';
    }
  }

  String _channelNameFor(String? eventType) {
    switch (_channelIdFor(eventType)) {
      case 'social':
        return 'Друзья';
      case 'study':
        return 'Учёба';
      default:
        return 'Сообщения';
    }
  }

  String _channelDescriptionFor(String? eventType) {
    switch (_channelIdFor(eventType)) {
      case 'social':
        return 'Заявки и принятие в друзья';
      case 'study':
        return 'Задания и изменения расписания';
      default:
        return 'Личные и учебные сообщения';
    }
  }

  String _newInstallationId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final rand = UniqueKey().hashCode.toUnsigned(32).toRadixString(16);
    return '$now-$rand';
  }
}

class PushLogoutReservation {
  PushLogoutReservation._(OnlineSideEffectBarrier barrier, this._current) {
    unawaited(barrier.trackTeardown(() => _done.future));
  }
  @visibleForTesting
  factory PushLogoutReservation.forTesting(OnlineSideEffectBarrier barrier,
      {bool Function()? isOwnerCurrent}) =>
      PushLogoutReservation._(barrier, isOwnerCurrent ?? (() => true));
  final Completer<void> _done = Completer<void>();
  final bool Function() _current;
  bool get isOwnerCurrent { try { return _current(); } catch (_) { return false; } }
  void finish() { if (!_done.isCompleted) _done.complete(); }
}
