import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/config/auth_email_adapter.dart';
import 'package:student_platform/src/core/session.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/ui/authentication/screens/change_password_screen.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';
import 'package:student_platform/src/ui/info/subject_card_service.dart';
import 'package:student_platform/src/ui/info/subject_media_service.dart';
import 'package:student_platform/src/ui/info/reference_service.dart';
import 'package:student_platform/src/ui/profile/profile_feed_service.dart';

class AuthService {
  static final _sb = Supabase.instance.client;

  /// Вход по логину (или email) + пароль.
  /// НИКАКИХ запросов к таблицам здесь не делаем.
  static Future<void> signInWithLoginOrEmail(
    BuildContext context, {
    required String loginOrEmail,
    required String password,
  }) async {
    final email = toAuthEmail(loginOrEmail);
    await _sb.auth.signInWithPassword(email: email, password: password);

    // Сессия уже есть -> подхватываем профиль отдельным вызовом RPC
    await AppSession.loadFromServer(); // не падает, если профиля нет

    final uid = _sb.auth.currentUser?.id;
    var mustChangePassword = false;
    if (uid != null) {
      final row = await _sb
          .from('users')
          .select('must_change_password')
          .eq('id', uid)
          .maybeSingle();
      mustChangePassword = row?['must_change_password'] == true;
    }

    if (context.mounted) {
      if (mustChangePassword) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
        );
      } else {
        context.go('/home');
      }
    }
  }

  static Future<void> signOut(BuildContext context) async {
    await PushNotificationService.instance.onLogout();
    await DmApi.clearSessionState();
    await TeamCubit.clearSessionCaches();
    await ChatMessageCacheStore.clearOnLogout();
    // Stage 15.2: never leave user A's news JSON/images for user B.
    await PublishedNewsCache(
      currentUserId: () => _sb.auth.currentUser?.id,
    ).clearAll();
    await ProfileFeedService(
      currentUserId: () => _sb.auth.currentUser?.id,
    ).clearAll();
    await SubjectCardService(
      currentUserId: () => _sb.auth.currentUser?.id,
    ).clearAll();
    await SubjectMediaService(
      currentUserId: () => _sb.auth.currentUser?.id,
    ).clearAll();
    await ContentMediaService(
      currentUserId: () => _sb.auth.currentUser?.id,
    ).clearAll();
    await ReferenceService(
      currentUserId: () => _sb.auth.currentUser?.id,
    ).clearAll();
    await NewsImageDiskCache().clear();
    await _sb.auth.signOut();
    AppSession.clear();
    if (context.mounted) context.go('/login');
  }
}
