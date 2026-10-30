import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'package:student_platform/src/services/push/system_notification_sync.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

// Two real Android process launches. No mocked preferences and no backend writes.
// First run seeds a dedicated synthetic namespace; second reads and removes it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
      settings: const InitializationSettings(
          android:
              AndroidInitializationSettings('@drawable/ic_stat_notification')));
  await notifications.show(
      id: 987654,
      title: 'Synthetic audit',
      body: 'Local fixture',
      notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('audit_fixture', 'Audit fixture',
              importance: Importance.low)));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  Future<bool> visible() async =>
      (await notifications.getActiveNotifications()).any((n) => n.id == 987654);
  if (!await visible()) throw StateError('NATIVE_PERMISSION_REQUIRED');
  var unread = 1;
  final sync = SystemNotificationSync(
      currentUser: () => 'synthetic', unreadCount: () async => unread);
  await sync.reconcile();
  if (!await visible()) throw StateError('NATIVE_CLEARED_UNREAD');
  unread = 0;
  await sync.reconcile();
  if (await visible()) throw StateError('NATIVE_CLEAR_FAILED');
  debugPrint('NATIVE_NOTIFICATION_PASS: unread preserved, zero cleared');
  const user = 'cold-process-fixture';
  const marker = 'cold_process_fixture_ready';
  final prefs = await SharedPreferences.getInstance();
  ChatMessageCacheStore.debugUserIdOverride = user;
  if (prefs.getBool(marker) != true) {
    for (final chat in ['cold-dm', 'cold-team', 'cold-materials']) {
      await ChatMessageCacheStore.replace(
          chatId: chat,
          userId: user,
          messages: [
            Message(
                id: 'message-$chat',
                chatId: chat,
                authorId: user,
                authorLogin: 'fixture',
                authorName: 'Fixture',
                text: 'Persisted $chat',
                at: DateTime.utc(2026, 10, 30))
          ]);
    }
    await prefs.setBool(marker, true);
    debugPrint('COLD_PHASE_SEED_OK: terminate process before next run');
    runApp(const MaterialApp(home: Text('COLD SEED OK')));
    return;
  }
  // Startup warms from disk before rendering; nothing is seeded in this branch.
  await ChatMessageCacheStore.initializeCurrentUser();
  for (final chat in ['cold-dm', 'cold-team', 'cold-materials']) {
    final snapshot = ChatMessageCacheStore.peek(chat);
    if (!snapshot.found || snapshot.messages.single.text != 'Persisted $chat') {
      throw StateError('COLD_READ_FAILED $chat');
    }
    await prefs.remove('chat_msg_cache_v1_${user}_$chat');
  }
  await prefs.remove(marker);
  ChatMessageCacheStore.debugUserIdOverride = null;
  debugPrint('COLD_PHASE_READ_OK: three disk snapshots, first frame, cleaned');
  runApp(const MaterialApp(home: Text('COLD READ OK')));
}
