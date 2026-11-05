import 'chat_file_access.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:student_platform/src/core/session.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/chats/data/chat_warm_coordinator.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/info/subject_card_service.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';
import 'package:student_platform/src/ui/info/subject_media_service.dart';
import 'package:student_platform/src/ui/info/reference_service.dart';
import 'package:student_platform/src/ui/info/vacancy_service.dart';
import 'package:student_platform/src/ui/info/vacancy_media_service.dart';
import 'package:student_platform/src/ui/profile/profile_feed_service.dart';
import 'package:student_platform/src/ui/profile/student_review_service.dart';

class AuthService {
  static final _sb = Supabase.instance.client;

  static Future<void> signOut(BuildContext context) async {
    AuthSessionScopeHost.maybeRead(context)?.invalidateForSignOut();
    ChatWarmCoordinator.instance.stop();
    var cleanupComplete = false;
    try {
      cleanupComplete = await runLogoutCleanup(
        cleanups: [
          () async {
            await PushNotificationService.instance.onLogout();
          },
          () async {
            await ChatFileAccess.clear();
            await DmApi.clearSessionState();
          },
          () async {
            await TeamCubit.clearSessionCaches();
          },
          () async {
            await ChatMessageCacheStore.clearOnLogout();
          },
          () async {
            await PublishedNewsCache(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await ProfileFeedService(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await SubjectCardService(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await SubjectMediaService(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await ContentMediaService(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await ReferenceService(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await VacancyService(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await VacancyMediaService(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await StudentReviewService(
              currentUserId: () => _sb.auth.currentUser?.id,
            ).clearAll();
          },
          () async {
            await NewsImageDiskCache().clear();
          },
          () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('user');
            await prefs.remove('loggedIn');
          },
        ],
        signOut: () => _sb.auth.signOut(),
        clearSession: AppSession.clear,
      );
    } finally {
      if (context.mounted && _sb.auth.currentSession == null) {
        context.go('/guest');
      }
    }
    if (!cleanupComplete && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Вы вышли из аккаунта, но часть локальных данных не удалось очистить.'),
      ));
    }
  }
}
