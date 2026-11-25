import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/session_capabilities_host.dart';
import 'package:student_platform/src/services/push/active_chat_tracker.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';

const _dmNotice = 'Личное сообщение';

bool _genericDmTitle(String title) =>
    isUnresolvedDmTitle(title) ||
    const {_dmNotice, 'Уведомление', 'Новое сообщение'}.contains(title.trim());

/// Floating iOS-style in-app banner (not a bottom SnackBar over the tab bar).
class InAppToastHost extends StatefulWidget {
  const InAppToastHost({super.key, required this.child, this.barrier});

  final Widget child;
  final OnlineSideEffectBarrier? barrier;

  @override
  State<InAppToastHost> createState() => _InAppToastHostState();
}

class _InAppToastHostState extends State<InAppToastHost>
    with SingleTickerProviderStateMixin {
  StreamSubscription<InAppNotificationEvent>? _sub;
  late final AnimationController _anim;
  InAppNotificationEvent? _event;
  String? Function()? _senderName;
  VoidCallback? _removeSenderCloseHook;
  Timer? _hideTimer;
  String? _lastDedupe;
  DateTime? _lastAt;
  final Map<String, DateTime> _seenNotificationIds = {};

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _sub = InAppNotificationBus.instance.stream.listen(_onEvent);
  }

  @override
  void dispose() {
    _forgetSender();
    _hideTimer?.cancel();
    _sub?.cancel();
    _anim.dispose();
    super.dispose();
  }

  void _forgetSender() {
    _removeSenderCloseHook?.call();
    _removeSenderCloseHook = null;
    _senderName = null;
  }

  void _onEvent(InAppNotificationEvent event) {
    if (event.type == '_session_reset' || event.type == '_dismiss') {
      if (event.type == '_session_reset') {
        _seenNotificationIds.clear();
        _lastDedupe = null;
        _lastAt = null;
      }
      if (event.type == '_session_reset' ||
          event.dismissedIds == null ||
          event.dismissedIds!.contains(_event?.payload?.notificationId)) {
        _hideTimer?.cancel();
        _forgetSender();
        _anim.stop();
        setState(() => _event = null);
      }
      return;
    }
    if (!(widget.barrier?.isOpen ?? true)) return;
    // Only events understood by the client can be routed from the banner.
    // Internal bus events and unknown payloads must never become visible.
    if (!PushPayload.knownTypes.contains(event.type)) return;

    final now = DateTime.now();
    final notificationId = event.payload?.notificationId;
    if (notificationId != null && notificationId.isNotEmpty) {
      _seenNotificationIds.removeWhere(
        (_, seenAt) => now.difference(seenAt) > const Duration(minutes: 1),
      );
      if (_seenNotificationIds.containsKey(notificationId)) return;
      _seenNotificationIds[notificationId] = now;
    } else {
      final key = '${event.type}|${event.title}|${event.body}';
      if (_lastDedupe == key &&
          _lastAt != null &&
          now.difference(_lastAt!) < const Duration(seconds: 2)) {
        return;
      }
      _lastDedupe = key;
    }
    _lastAt = now;

    _hideTimer?.cancel();
    _forgetSender();
    final needsSender =
        event.type == 'dm_message' && _genericDmTitle(event.title);
    setState(() => _event = event);
    _anim.forward(from: 0);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      _dismiss();
    });
    if (needsSender) unawaited(_resolveDmTitle(event));
  }

  Future<void> _resolveDmTitle(InAppNotificationEvent event) async {
    final payload = event.payload;
    if (payload == null ||
        payload.type != 'dm_message' ||
        (payload.notificationId ?? '').isEmpty ||
        (payload.chatId ?? '').isEmpty) return;
    final scope = AuthSessionScopeHost.maybeRead(context);
    final owner = scope?.capture();
    final caps = SessionCapabilitiesHost.maybeRead(context);
    final permit = caps?.capture(SessionCapability.networkRead);
    if (scope == null || owner == null || caps == null || permit == null)
      return;

    final client = Supabase.instance.client;
    final barrier = widget.barrier;
    bool ownerCurrent() =>
        mounted &&
        identical(widget.barrier, barrier) &&
        (barrier?.isOpen ?? true) &&
        identical(client, Supabase.instance.client) &&
        identical(scope, AuthSessionScopeHost.maybeRead(context)) &&
        identical(caps, SessionCapabilitiesHost.maybeRead(context)) &&
        scope.matchesSession(owner, client.auth.currentSession) &&
        caps.ownsFor(permit, owner, SessionCapability.networkRead);
    bool current() =>
        ownerCurrent() &&
        identical(_event, event) &&
        (_hideTimer?.isActive ?? false) &&
        !InAppNotificationBus.instance.wasDismissed(payload.notificationId) &&
        !ActiveChatTracker.instance.isActive(payload.chatId);

    Future<void> resolve() async {
      if (!current()) return;
      final row = await client
          .from('app_notifications')
          .select('id,recipient_id,event_type,title,data,read_at,deleted_at')
          .eq('id', payload.notificationId!)
          .eq('recipient_id', owner.userId)
          .maybeSingle();
      if (!current() ||
          row == null ||
          row['id'] != payload.notificationId ||
          row['recipient_id'] != owner.userId ||
          row['event_type'] != payload.type ||
          row['read_at'] != null ||
          row['deleted_at'] != null) return;
      final data = row['data'];
      if (data is! Map ||
          data['chat_id'] != payload.chatId ||
          (data['type'] != null && data['type'] != payload.type) ||
          (data['notification_id'] != null &&
              data['notification_id'] != row['id'])) return;
      final peer = data['peer_id'];
      if (peer is! String ||
          peer.trim().isEmpty ||
          peer == owner.userId ||
          data['author_id'] != peer ||
          (payload.peerId != null && payload.peerId != peer) ||
          (payload.raw['author_id'] != null &&
              payload.raw['author_id'] != peer) ||
          (payload.messageId != null &&
              data['message_id'] != null &&
              payload.messageId != data['message_id'])) return;

      final title = row['title'];
      final name = title is String && !_genericDmTitle(title)
          ? title.trim()
          : (await PushNavigation.resolvePeerProfile(peer)).name;
      if (current() && !_genericDmTitle(name)) {
        setState(() => _senderName = () => ownerCurrent() ? name : null);
        // The guarded host may remain mounted after its barrier closes.
        _removeSenderCloseHook = barrier?.onClose(() {
          scheduleMicrotask(() {
            if (mounted && identical(_event, event)) setState(_forgetSender);
          });
        });
      }
    }

    try {
      if (barrier == null) {
        await resolve();
      } else {
        await barrier.run(resolve);
      }
    } catch (_) {
      // Keep the neutral title if the original session cannot verify a sender.
    }
  }

  Future<bool> _dismiss() async {
    final dismissedEvent = _event;
    _hideTimer?.cancel();
    try {
      await _anim.reverse().orCancel;
    } on TickerCanceled {
      return false;
    }
    if (!mounted || !identical(_event, dismissedEvent)) return false;
    _forgetSender();
    setState(() => _event = null);
    return true;
  }

  Future<void> _open() async {
    final event = _event;
    final dismissed = await _dismiss();
    if (!dismissed || !mounted || event == null) return;
    final payload = event.payload;
    if (widget.barrier != null) {
      if (payload != null && widget.barrier!.isOpen) {
        await PushNotificationService.instance.openGuardedPayload(payload);
      }
      return;
    }
    if (payload != null) {
      await PushNavigation.handle(context, payload, force: true);
    } else {
      await showNotificationCenterSheet(context);
    }
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'dm_message':
        return Icons.chat_bubble_rounded;
      case 'team_message':
      case 'team_reply':
        return Icons.groups_rounded;
      case 'friend_request':
      case 'friend_accepted':
        return Icons.person_add_alt_1_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top;
    final event = _event;

    var title = event?.title ?? '';
    if (event?.type == 'dm_message' && _genericDmTitle(title)) {
      if (_senderName != null) {
        AuthSessionScopeHost.maybeOf(context);
        SessionCapabilitiesHost.maybeOf(context);
      }
      title = _senderName?.call() ?? _dmNotice;
    }
    return Stack(
      children: [
        widget.child,
        if (event != null)
          Positioned(
            left: 12,
            right: 12,
            top: top + 8,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -1.1),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: _anim,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              )),
              child: FadeTransition(
                opacity: _anim,
                child: Dismissible(
                  key: ValueKey(
                    '${event.type}_${event.title}_${event.body}_$_lastAt',
                  ),
                  direction: DismissDirection.up,
                  onDismissed: (_) {
                    _hideTimer?.cancel();
                    _forgetSender();
                    setState(() => _event = null);
                    _anim.value = 0;
                  },
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _open,
                      borderRadius: BorderRadius.circular(20),
                      child: Ink(
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: colors.outlineVariant),
                          boxShadow: [
                            BoxShadow(
                              color: colors.shadow.withValues(alpha: 0.16),
                              blurRadius: 22,
                              offset: const Offset(0, 10),
                            ),
                            BoxShadow(
                              color: colors.shadow.withValues(alpha: 0.06),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: colors.primaryContainer,
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Icon(
                                  _iconFor(event.type),
                                  color: colors.onPrimaryContainer,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                        color: colors.onSurface,
                                      ),
                                    ),
                                    if (event.body.trim().isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        event.body,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.2,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              TextButton(
                                onPressed: _open,
                                style: TextButton.styleFrom(
                                  foregroundColor: colors.primary,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  textStyle: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                                child: const Text('Открыть'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Parse jsonb `data` from app_notifications into [PushPayload].
PushPayload? pushPayloadFromNotificationData(dynamic raw) {
  if (raw == null) return null;
  if (raw is Map) {
    return PushPayload.tryParse(Map<String, dynamic>.from(raw));
  }
  return null;
}
