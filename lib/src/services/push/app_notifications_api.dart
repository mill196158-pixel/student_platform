import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/chat_read_progress.dart';

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
  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  /// The mounted push host binds a receipt to the verified session that
  /// started this write. A later host may belong to a different session.
  static void Function(Set<String>?)? Function(SupabaseClient)? captureReadReceipt;

  void Function(Set<String>?) _captureDismiss() {
    final session = _sb.auth.currentSession;
    final receipt = captureReadReceipt?.call(_sb);
    return (ids) {
      if (!identical(_sb.auth.currentSession, session)) return;
      receipt?.call(ids);
      InAppNotificationBus.instance.dismissNotifications(ids);
    };
  }

  Future<List<AppNotificationItem>> listMine({int limit = 50}) async {
    final res = await _sb.rpc(
      'get_my_app_notifications',
      params: {'p_limit': limit},
    );
    if (res is! List) throw const FormatException('Invalid notification list');
    return res.map((row) {
      if (row is! Map) throw const FormatException('Invalid notification row');
      if (row['id'] is! String || (row['id'] as String).trim().isEmpty ||
          row['event_type'] is! String || (row['event_type'] as String).trim().isEmpty ||
          row['title'] is! String || row['body'] is! String ||
          row['created_at'] is! String || DateTime.tryParse(row['created_at'] as String) == null ||
          (row['read_at'] != null && (row['read_at'] is! String ||
              DateTime.tryParse(row['read_at'] as String) == null))) {
        throw const FormatException('Invalid notification row');
      }
      return AppNotificationItem.fromJson(Map<String, dynamic>.from(row));
    }).toList();
  }

  Future<int> unreadCount() async {
    final res = await _sb.rpc('get_my_unread_notification_count');
    if (res is int && res >= 0) return res;
    throw const FormatException('Invalid unread notification count');
  }

  /// Only positive read rows authorize exact removal. RLS may hide missing
  /// or soft-deleted rows; absence alone cannot prove this user read them.
  Future<Set<String>> readDeliveredIds(String owner, Set<String> ids) async {
    final session = _sb.auth.currentSession;
    if (session == null || session.user.id != owner) return {};
    final result = <String>{};
    final pending = ids.toList();
    for (var offset = 0; offset < pending.length; offset += 50) {
      if (!identical(session, _sb.auth.currentSession)) return {};
      final batch = pending.skip(offset).take(50).toList();
      final rows = await _sb.from('app_notifications').select('id,recipient_id,read_at')
          .eq('recipient_id', owner).inFilter('id', batch).not('read_at', 'is', null);
      for (final row in rows) {
        final id = row['id'];
        final readAt = row['read_at'];
        if (row['recipient_id'] != owner || id is! String || !batch.contains(id) ||
            readAt is! String || DateTime.tryParse(readAt) == null) {
          throw const FormatException('Invalid notification read receipt');
        }
        result.add(id);
      }
    }
    return identical(session, _sb.auth.currentSession) ? result : {};
  }

  Future<void> markRead(String id) async {
    final dismiss = _captureDismiss();
    await _sb.rpc('mark_notification_read', params: {
      'p_notification_id': id,
    });
    dismiss({id});
  }

  Future<void> markAllRead() async {
    final dismiss = _captureDismiss();
    await _sb.rpc('mark_all_notifications_read');
    dismiss(null);
  }

  /// Keeps the notification-center badge in sync with the chat read cursor.
  Future<void> markLatestChatRead(String chatId,
      {required bool Function() isCurrent}) async {
    final session = _sb.auth.currentSession;
    bool current() => session != null && identical(session, _sb.auth.currentSession) && isCurrent();
    if (!current()) return;
    final latest = await _sb.from('messages').select('id,created_at')
        .eq('chat_id', chatId).order('created_at', ascending: false)
        .order('id', ascending: false).limit(1).maybeSingle();
    final messageId = latest?['id'];
    final at = DateTime.tryParse(latest?['created_at']?.toString() ?? '');
    if (messageId is! String || messageId.isEmpty || at == null || !current()) return;
    await ChatReadProgress().mark(scope: (session, chatId), messageId: messageId,
        current: current, markCursor: () async {
          await _sb.rpc('mark_chat_read', params: {'p_chat_id': chatId, 'p_message_id': messageId});
        }, syncNotifications: () => markReadForChat(chatId,
            through: (messageId: messageId, at: at), isCurrent: current));
  }

  Future<void> markReadForChat(String chatId, {
    ({String messageId, DateTime at})? through,
    bool Function()? isCurrent,
  }) async {
    final normalized = chatId.trim();
    if (normalized.isEmpty || !(isCurrent?.call() ?? true)) return;
    final session = _sb.auth.currentSession;
    final dismiss = _captureDismiss();

    bool current() => identical(session, _sb.auth.currentSession) &&
        (isCurrent?.call() ?? true);
    String? after;
    while (current()) {
      var query = _sb.from('app_notifications').select(
          through == null ? 'id' : 'id,data,created_at')
          .isFilter('read_at', null).isFilter('deleted_at', null)
          .contains('data', <String, dynamic>{'chat_id': normalized});
      if (after != null) query = query.gt('id', after);
      const pageSize = 50;
      final rows = await query.order('id').limit(pageSize);
      if (!current() || rows.isEmpty) return;
      final ids = <String>[];
      for (final row in rows) {
        final id = row['id'];
        if (id is! String || id.isEmpty) {
          throw const FormatException('Missing notification id');
        }
        final data = row['data'];
        final at = DateTime.tryParse(row['created_at']?.toString() ?? '');
        final messageId = data is Map ? data['message_id'] : null;
        if (through == null || messageId == through.messageId ||
            at != null && at.isBefore(through.at)) {
          ids.add(id);
        } else if (at != null && at.isAtSameMomentAs(through.at) && messageId is String &&
            _uuid.hasMatch(messageId) && _uuid.hasMatch(through.messageId) &&
            messageId.compareTo(through.messageId) < 0) {
          // The message page breaks equal database timestamps by UUID.
          ids.add(id);
        }
      }
      final confirmed = <String>{};
      try {
        for (var start = 0; start < ids.length && current(); start += 8) {
          await Future.wait(ids.skip(start).take(8).map((id) async {
            await _sb.rpc('mark_notification_read', params: {'p_notification_id': id});
            confirmed.add(id);
          }));
        }
      } finally {
        if (confirmed.isNotEmpty && current()) dismiss(confirmed);
      }
      if (rows.length < pageSize) return;
      final last = rows.last['id'] as String;
      if (after != null && last.compareTo(after) <= 0) {
        throw const FormatException('Notification page did not advance');
      }
      after = last;
    }
  }

  Future<void> hide(String id) async {
    final dismiss = _captureDismiss();
    await _sb.rpc('hide_notification_for_me', params: {
      'p_notification_id': id,
    });
    dismiss({id});
  }
}
