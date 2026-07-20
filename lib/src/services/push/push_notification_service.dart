import 'dart:async';
import 'dart:io';

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
  bool _promptInFlight = false;
  String? _installationId;
  bool get isSupportedPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  bool get isFirebaseReady => _firebaseReady;

  void bindNavigatorKey(GlobalKey<NavigatorState> key) {
    // Kept for call-site compatibility; navigation uses [rootNavigatorKey].
  }

  Future<void> bootstrapFirebase() async {
    if (!isSupportedPlatform) return;
    if (_firebaseReady) return;

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

  Future<void> onAuthenticated(BuildContext? context) async {
    if (!isSupportedPlatform) return;
    _sessionActive = true;
    PushNavigation.markReady();

    await bootstrapFirebase();
    if (!_firebaseReady) return;

    await _ensureInstallationId();
    await _attachListeners();
    await _handleInitialMessage();

    if (context != null && context.mounted) {
      await maybeShowPermissionPrompt(context);
    }

    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    if (_isAuthorized(settings.authorizationStatus)) {
      await _registerCurrentToken();
    }
  }

  Future<void> onLogout() async {
    PushNavigation.markNotReady();
    final installationId = await _ensureInstallationId();

    if (_sessionActive && Supabase.instance.client.auth.currentUser != null) {
      try {
        await Supabase.instance.client.rpc(
          'disable_device_push_token',
          params: {'p_installation_id': installationId},
        );
      } catch (e) {
        if (kDebugMode) debugPrint('[Push] disable token on logout: $e');
      }
    }

    await disposeListeners();
    _sessionActive = false;
  }

  Future<void> disposeListeners() async {
    await _onMessageSub?.cancel();
    await _onOpenedSub?.cancel();
    await _tokenRefreshSub?.cancel();
    _onMessageSub = null;
    _onOpenedSub = null;
    _tokenRefreshSub = null;
  }

  Future<void> maybeShowPermissionPrompt(BuildContext context) async {
    if (!isSupportedPlatform || !_firebaseReady) return;
    if (_promptInFlight) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kPermissionPromptSeenKey) == true) return;

    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    if (_isAuthorized(settings.authorizationStatus)) {
      await prefs.setBool(_kPermissionPromptSeenKey, true);
      await _registerCurrentToken();
      return;
    }

    // Do not ask on splash/login — caller must be post-auth home/shell.
    final route = ModalRoute.of(context)?.settings.name;
    if (route == '/splash' || route == '/login') return;

    _promptInFlight = true;
    try {
      final enable = await showPushPermissionPrompt(context);
      await prefs.setBool(_kPermissionPromptSeenKey, true);
      if (enable == true) {
        await requestSystemPermissionAndRegister();
      }
    } finally {
      _promptInFlight = false;
    }
  }

  Future<bool> requestSystemPermissionAndRegister() async {
    if (!isSupportedPlatform || !_firebaseReady) return false;

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
    if (granted) {
      await _registerCurrentToken();
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

  Future<void> _attachListeners() async {
    if (_onMessageSub != null) return;

    _onMessageSub = FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    _onOpenedSub =
        FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpened);
    _tokenRefreshSub =
        FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      if (!_sessionActive) return;
      await _upsertToken(token);
    });
  }

  Future<void> _handleInitialMessage() async {
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial == null) return;
    final payload = PushPayload.tryParse(initial.data);
    if (payload == null) return;
    PushNavigation.stash(payload);
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final payload = PushPayload.tryParse(message.data);
    final chatId = payload?.chatId ?? message.data['chat_id']?.toString();
    if (ActiveChatTracker.instance.isActive(chatId)) {
      return;
    }

    final title =
        message.notification?.title ?? payload?.raw['title'] ?? 'Уведомление';
    final body = message.notification?.body ?? payload?.raw['body'] ?? '';
    final eventType = payload?.type ?? message.data['type']?.toString() ?? '';

    InAppNotificationBus.instance.emit(
      InAppNotificationEvent(
        type: eventType,
        title: title.toString(),
        body: body.toString(),
        payload: payload,
      ),
    );

    // Quietly warm that thread so opening the chat is instant.
    if (chatId != null && chatId.isNotEmpty) {
      ChatWarmCoordinator.instance.prioritizeChat(chatId);
    }

    // Foreground chat/friend events use the floating in-app toast.
    // Skip a second OS banner so the tab bar isn't covered by a SnackBar-like strip.
    final useInAppToast = eventType == 'dm_message' ||
        eventType == 'team_message' ||
        eventType == 'team_reply' ||
        eventType == 'friend_request' ||
        eventType == 'friend_accept';
    if (useInAppToast) return;

    await _showLocalNotification(
      title: title.toString(),
      body: body.toString(),
      payload: payload,
      eventType: eventType,
    );
  }

  Future<void> _onMessageOpened(RemoteMessage message) async {
    final payload = PushPayload.tryParse(message.data);
    if (payload == null) return;
    final context = rootNavigatorContext;
    if (context == null) {
      PushNavigation.stash(payload);
      return;
    }
    await PushNavigation.handle(context, payload);
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
        final context = rootNavigatorContext;
        if (context == null) {
          PushNavigation.stash(parsed);
          return;
        }
        unawaited(PushNavigation.handle(context, parsed, force: true));
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

  Future<void> _registerCurrentToken() async {
    if (!_firebaseReady || !_sessionActive) return;

    for (var attempt = 1; attempt <= 5; attempt++) {
      if (!_sessionActive) return;
      try {
        if (Platform.isIOS) {
          final apns = await FirebaseMessaging.instance.getAPNSToken();
          if (apns == null || apns.isEmpty) {
            if (kDebugMode) {
              debugPrint('[Push] APNs token is not ready, retry $attempt/5');
            }
            await Future<void>.delayed(Duration(seconds: attempt));
            continue;
          }
        }

        final token = await FirebaseMessaging.instance.getToken();
        if (token == null || token.isEmpty) {
          if (kDebugMode) {
            debugPrint('[Push] FCM token is empty, retry $attempt/5');
          }
          await Future<void>.delayed(Duration(seconds: attempt));
          continue;
        }
        await _upsertToken(token);
        return;
      } catch (e) {
        if (kDebugMode)
          debugPrint('[Push] getToken failed attempt $attempt: $e');
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
  }

  Future<void> _upsertToken(String token) async {
    if (Supabase.instance.client.auth.currentUser == null) return;

    final installationId = await _ensureInstallationId();
    final platform = Platform.isIOS ? 'ios' : 'android';
    String? appVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}

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
