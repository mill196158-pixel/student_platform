import 'package:supabase_flutter/supabase_flutter.dart';

class AppNotificationItem {
  const AppNotificationItem({
    required this.id,
    required this.eventType,
    required this.title,
    required this.body,
    required this.data,
    required this.createdAt,
    this.readAt,
    this.sourceId,
  });

  final String id;
  final String eventType;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final DateTime? readAt;
  final String? sourceId;

  bool get isUnread => readAt == null;

  factory AppNotificationItem.fromJson(Map<String, dynamic> json) {
    DateTime? parseTs(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString())?.toLocal();
    }

    final dataRaw = json['data'];
    return AppNotificationItem(
      id: (json['id'] ?? '').toString(),
      eventType: (json['event_type'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      data: dataRaw is Map
          ? Map<String, dynamic>.from(dataRaw)
          : const <String, dynamic>{},
      createdAt: parseTs(json['created_at']) ?? DateTime.now(),
      readAt: parseTs(json['read_at']),
      sourceId: json['source_id']?.toString(),
    );
  }
}

class AppNotificationsApi {
  AppNotificationsApi({SupabaseClient? client})
      : _sb = client ?? Supabase.instance.client;

  final SupabaseClient _sb;

  Future<List<AppNotificationItem>> listMine({int limit = 50}) async {
    try {
      final res = await _sb.rpc(
        'get_my_app_notifications',
        params: {'p_limit': limit},
      );
      if (res is! List) return const [];
      return res
          .whereType<Map>()
          .map((row) => AppNotificationItem.fromJson(
                Map<String, dynamic>.from(row),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<int> unreadCount() async {
    try {
      final res = await _sb.rpc('get_my_unread_notification_count');
      if (res is int) return res;
      if (res is num) return res.toInt();
      return int.tryParse('$res') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> markRead(String id) async {
    await _sb.rpc('mark_notification_read', params: {
      'p_notification_id': id,
    });
  }

  Future<void> markAllRead() async {
    await _sb.rpc('mark_all_notifications_read');
  }

  Future<void> hide(String id) async {
    await _sb.rpc('hide_notification_for_me', params: {
      'p_notification_id': id,
    });
  }
}
