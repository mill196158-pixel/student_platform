import 'dart:async';

import 'package:flutter/material.dart';

import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';

/// Floating iOS-style in-app banner (not a bottom SnackBar over the tab bar).
class InAppToastHost extends StatefulWidget {
  const InAppToastHost({super.key, required this.child});

  final Widget child;

  @override
  State<InAppToastHost> createState() => _InAppToastHostState();
}

class _InAppToastHostState extends State<InAppToastHost>
    with SingleTickerProviderStateMixin {
  StreamSubscription<InAppNotificationEvent>? _sub;
  late final AnimationController _anim;
  InAppNotificationEvent? _event;
  Timer? _hideTimer;
  String? _lastDedupe;
  DateTime? _lastAt;

  static const _lavender = Color(0xFF7C63D8);

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
    _hideTimer?.cancel();
    _sub?.cancel();
    _anim.dispose();
    super.dispose();
  }

  void _onEvent(InAppNotificationEvent event) {
    final show = event.isChatMessage ||
        event.type == 'friend_request' ||
        event.type == 'friend_accept';
    if (!show) return;

    final key = '${event.type}|${event.title}|${event.body}';
    final now = DateTime.now();
    if (_lastDedupe == key &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastDedupe = key;
    _lastAt = now;

    _hideTimer?.cancel();
    setState(() => _event = event);
    _anim.forward(from: 0);
    _hideTimer = Timer(const Duration(seconds: 4), _dismiss);
  }

  Future<void> _dismiss() async {
    _hideTimer?.cancel();
    await _anim.reverse();
    if (!mounted) return;
    setState(() => _event = null);
  }

  Future<void> _open() async {
    final event = _event;
    await _dismiss();
    if (!mounted || event == null) return;
    final payload = event.payload;
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
      case 'friend_accept':
        return Icons.person_add_alt_1_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final event = _event;

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
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFE8E4F0)),
                          boxShadow: [
                            BoxShadow(
                              color: _lavender.withValues(alpha: 0.22),
                              blurRadius: 22,
                              offset: const Offset(0, 10),
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
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
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFFDCD0FA),
                                      Color(0xFFC9B8F3),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Icon(
                                  _iconFor(event.type),
                                  color: _lavender,
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
                                      event.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                        color: Color(0xFF1C1B1F),
                                      ),
                                    ),
                                    if (event.body.trim().isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        event.body,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          height: 1.2,
                                          color: Color(0xFF6B6578),
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
                                  foregroundColor: _lavender,
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
