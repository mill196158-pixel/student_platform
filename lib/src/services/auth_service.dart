import 'chat_file_access.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:student_platform/src/core/session.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';
import 'package:student_platform/src/core/logout_feedback.dart';
import 'package:student_platform/src/navigation/root_nav.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/auth_transition_host.dart';
import 'package:student_platform/src/core/auth_transition_coordinator.dart';
import 'package:student_platform/src/core/session_capabilities_host.dart';
import 'package:student_platform/src/core/offline_policy_grant_host.dart';
import 'package:student_platform/src/core/offline_grant_logout.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/learning/state/team_snapshot_host.dart';
import 'package:student_platform/src/ui/learning/state/team_snapshot_logout.dart';
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
  static LogoutRetryOwner? _retryOwner;
  static Future<void>? _signOutInFlight;

  static Future<void> signOut(BuildContext context) {
    final existing = _signOutInFlight;
    if (existing != null) return existing;
    final operation = _signOut(context);
    _signOutInFlight = operation;
    unawaited(operation.then<void>((_) {
      if (identical(_signOutInFlight, operation)) _signOutInFlight = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_signOutInFlight, operation)) _signOutInFlight = null;
    }));
    return operation;
  }

  static Future<void> _signOut(BuildContext context) async {
    final scope = AuthSessionScopeHost.maybeRead(context);
    final transition = AuthTransitionHost.maybeRead(context);
    final owner = scope == null ? null : AuthTransitionOwner.capture(scope);
    final initialSession = _sb.auth.currentSession;
    final retry = _retryOwner;
    if (scope == null ||
        transition == null ||
        initialSession == null ||
        (owner == null &&
            (retry == null || !retry.matches(scope, initialSession)))) {
      showLogoutFeedback(
          rootScaffoldMessengerKey, LogoutCleanupResult.blockedBeforeSignOut);
      return;
    }
    final originalIdentity = LogoutSessionIdentity(initialSession,
        '${SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '')}/auth/v1');
    var expectedGeneration = scope.generation;
    bool ownerIsCurrent() {
      final session = _sb.auth.currentSession;
      return originalIdentity.matches(session) &&
          scope.generation == expectedGeneration;
    }

    final capabilities = SessionCapabilitiesHost.maybeRead(context);
    final teamCoordinator = TeamSnapshotHost.maybeRead(context);
    final oldUserId = _sb.auth.currentUser?.id;
    final access = OfflinePolicyGrantHost.maybeRead(context);
    final sqliteStore = access?.sqliteStore;
    final sqliteBinding = sqliteStore == null ? null : access?.currentBinding();
    Object? attachmentFence;
    PushLogoutReservation? pushReservation;
    var result = LogoutCleanupResult.blockedBeforeSignOut;
    try {
      Future<void> action() async {
        result = await runLogoutCleanup(
          isOwnerCurrent: ownerIsCurrent,
          mayClearSession: () => _sb.auth.currentSession == null,
          memoryFence: () => runLogoutMemoryFences([
            () => pushReservation = PushNotificationService.instance.reserveGuardedLogout(
                isOwnerCurrent: ownerIsCurrent),
            () => capabilities?.block(),
            () {
              expectedGeneration++;
              scope.invalidateForSignOut();
            },
            () => attachmentFence = ChatFileAccess.fenceForLogout(),
          ]),
          durableRevoke: sqliteStore == null
              ? null
              : () async {
                  if (sqliteBinding == null || !ownerIsCurrent()) return false;
                  await sqliteStore.beginRevoke(sqliteBinding,
                      stillCurrent: ownerIsCurrent);
                  return ownerIsCurrent();
                },
          cleanups: [
            () async {
              Future<bool> safely(Future<bool> Function() start) async {
                try {
                  return await start();
                } catch (_) {
                  return false;
                }
              }

              ChatWarmCoordinator.instance.stop();
              final results = await Future.wait([
                safely(() => beginOfflineGrantLogout(
                      access: access,
                      invalidate: () {},
                    )),
                safely(() => beginTeamSnapshotLogout(
                      coordinator: teamCoordinator,
                      project: SupabaseConfig.url,
                      userId: oldUserId,
                    )),
                safely(() async {
                  await ChatFileAccess.clear();
                  return true;
                }),
              ]);
              if (results.any((value) => !value)) {
                throw StateError('Local cleanup incomplete');
              }
            },
            () async {
              try {
                await PushNotificationService.instance.onLogout(reservation: pushReservation);
              } finally {
                pushReservation?.finish();
              }
            },
            () async {
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
        // Complete A's attachment fence before releasing the serialized
        // transition; otherwise a queued B sign-in can overtake finalization.
        if ((result == LogoutCleanupResult.signedOut ||
                result == LogoutCleanupResult.signedOutCleanupIncomplete ||
                result == LogoutCleanupResult.signOutUnconfirmed) &&
            _sb.auth.currentSession == null &&
            attachmentFence != null) {
          ChatFileAccess.completeLogoutFence(attachmentFence!);
        }
      }

      final started = owner != null
          ? await transition.logout(owner, action: action)
          : await transition.run(() async {
              if (retry == null ||
                  !retry.matches(scope, _sb.auth.currentSession)) {
                return false;
              }
              await action();
              return true;
            });
      if (!started) result = LogoutCleanupResult.ownerChanged;
    } finally {
      pushReservation?.finish();
      if (result == LogoutCleanupResult.blockedBeforeSignOut &&
          ownerIsCurrent()) {
        _retryOwner = LogoutRetryOwner.capture(
            scope, originalIdentity, _sb.auth.currentSession);
      } else {
        _retryOwner = null;
      }
      if (result != LogoutCleanupResult.ownerChanged &&
          context.mounted &&
          _sb.auth.currentSession == null) {
        context.go('/guest');
      }
    }
    showLogoutFeedback(rootScaffoldMessengerKey, result);
  }
}
