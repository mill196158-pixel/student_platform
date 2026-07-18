import 'package:supabase_flutter/supabase_flutter.dart';

class NotificationPreferences {
  const NotificationPreferences({
    required this.dmMessages,
    required this.friendRequests,
    required this.friendAccepts,
    required this.studyAssignments,
    required this.scheduleChanges,
    required this.studyAnnouncements,
    required this.groupReplies,
    required this.groupMentions,
    required this.groupAllMessages,
    required this.showMessagePreview,
    required this.pushEnabled,
  });

  final bool dmMessages;
  final bool friendRequests;
  final bool friendAccepts;
  final bool studyAssignments;
  final bool scheduleChanges;
  final bool studyAnnouncements;
  final bool groupReplies;
  final bool groupMentions;
  final bool groupAllMessages;
  final bool showMessagePreview;
  final bool pushEnabled;

  factory NotificationPreferences.defaults() => const NotificationPreferences(
        dmMessages: true,
        friendRequests: true,
        friendAccepts: true,
        studyAssignments: true,
        scheduleChanges: true,
        studyAnnouncements: true,
        groupReplies: true,
        groupMentions: true,
        groupAllMessages: false,
        showMessagePreview: true,
        pushEnabled: true,
      );

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    bool b(String key, {bool fallback = true}) =>
        json[key] is bool ? json[key] as bool : fallback;

    return NotificationPreferences(
      dmMessages: b('dm_messages'),
      friendRequests: b('friend_requests'),
      friendAccepts: b('friend_accepts'),
      studyAssignments: b('study_assignments'),
      scheduleChanges: b('schedule_changes'),
      studyAnnouncements: b('study_announcements'),
      groupReplies: b('group_replies'),
      groupMentions: b('group_mentions'),
      groupAllMessages: b('group_all_messages', fallback: false),
      showMessagePreview: b('show_message_preview'),
      pushEnabled: b('push_enabled'),
    );
  }

  Map<String, dynamic> toPatch({
    bool? dmMessages,
    bool? friendRequests,
    bool? friendAccepts,
    bool? studyAssignments,
    bool? scheduleChanges,
    bool? studyAnnouncements,
    bool? groupReplies,
    bool? groupMentions,
    bool? groupAllMessages,
    bool? showMessagePreview,
    bool? pushEnabled,
  }) {
    return {
      if (dmMessages != null) 'dm_messages': dmMessages,
      if (friendRequests != null) 'friend_requests': friendRequests,
      if (friendAccepts != null) 'friend_accepts': friendAccepts,
      if (studyAssignments != null) 'study_assignments': studyAssignments,
      if (scheduleChanges != null) 'schedule_changes': scheduleChanges,
      if (studyAnnouncements != null) 'study_announcements': studyAnnouncements,
      if (groupReplies != null) 'group_replies': groupReplies,
      if (groupMentions != null) 'group_mentions': groupMentions,
      if (groupAllMessages != null) 'group_all_messages': groupAllMessages,
      if (showMessagePreview != null)
        'show_message_preview': showMessagePreview,
      if (pushEnabled != null) 'push_enabled': pushEnabled,
    };
  }
}

class NotificationPreferencesApi {
  NotificationPreferencesApi({SupabaseClient? client})
      : _sb = client ?? Supabase.instance.client;

  final SupabaseClient _sb;

  Future<NotificationPreferences> getMine() async {
    try {
      final res = await _sb.rpc('get_my_notification_preferences');
      if (res is Map) {
        return NotificationPreferences.fromJson(
          Map<String, dynamic>.from(res),
        );
      }
    } catch (_) {
      // Missing migration / RPC → defaults.
    }
    return NotificationPreferences.defaults();
  }

  Future<NotificationPreferences> updateMine(Map<String, dynamic> patch) async {
    final res = await _sb.rpc(
      'update_my_notification_preferences',
      params: {'p_patch': patch},
    );
    if (res is Map) {
      return NotificationPreferences.fromJson(Map<String, dynamic>.from(res));
    }
    return getMine();
  }
}
