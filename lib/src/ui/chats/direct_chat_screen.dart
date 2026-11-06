// FILE: lib/src/ui/chats/direct_chat_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';
import 'direct_chat_info_screen.dart';

class DirectChatScreen extends StatefulWidget {
  const DirectChatScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    this.peerAvatarUrl,
    this.initialChatId,
    this.cachedStore,
    this.cachedCapabilities,
    this.onlineBarrier,
    this.sessionIsCurrent,
    this.debugResolveProfile,
    this.debugChatBuilder,
  });

  final String peerId;
  final String peerName;
  final String? peerAvatarUrl;
  final String? initialChatId;
  final ProjectChatServerCache? cachedStore;
  final SessionCapabilities? cachedCapabilities;

  /// Optional route boundary. Both fields must be supplied for guarded use.
  final OnlineSideEffectBarrier? onlineBarrier;
  final bool Function()? sessionIsCurrent;
  @visibleForTesting
  final Future<({String name, String? avatar})> Function(String)?
      debugResolveProfile;
  @visibleForTesting
  final Widget Function(BuildContext, String)? debugChatBuilder;

  @override
  State<DirectChatScreen> createState() => _DirectChatScreenState();
}

class _DirectChatScreenState extends State<DirectChatScreen> {
  DmChatService? _service;
  int _serviceRevision = 0;
  bool get _wantsCached =>
      widget.cachedStore != null || widget.cachedCapabilities != null;
  late String _peerName;
  String? _peerAvatarUrl;

  bool get _needsPeerProfile =>
      isUnresolvedDmTitle(_peerName) || (_peerAvatarUrl ?? '').isEmpty;

  @override
  void initState() {
    super.initState();
    _peerName = normalizeDmTitle(widget.peerName);
    _peerAvatarUrl = widget.peerAvatarUrl;
    _createService();
    if (!_wantsCached && _needsPeerProfile) _loadPeerProfile();
  }

  void _createService() {
    _serviceRevision++;
    if (_wantsCached) {
      final cache = widget.cachedStore,
          caps = widget.cachedCapabilities,
          chat = widget.initialChatId;
      if (cache == null || caps == null || chat == null || chat.isEmpty) {
        _service = null;
        return;
      }
      try {
        _service = DmChatService.cachedOnly(
            peerId: widget.peerId,
            initialChatId: chat,
            capabilities: caps,
            cacheReader: (chatId, userId) async {
              final rows = await cache.read(chatId, caps);
              return rows == null
                  ? ChatCacheSnapshot.notFound
                  : ChatCacheSnapshot(found: true, messages: rows);
            });
      } catch (_) {
        _service = null;
      }
      return;
    }
    _service = DmChatService(
        peerId: widget.peerId, initialChatId: widget.initialChatId);
  }

  @override
  void didUpdateWidget(covariant DirectChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerId == widget.peerId &&
        oldWidget.initialChatId == widget.initialChatId &&
        identical(oldWidget.cachedStore, widget.cachedStore) &&
        identical(oldWidget.cachedCapabilities, widget.cachedCapabilities) &&
        identical(oldWidget.onlineBarrier, widget.onlineBarrier) &&
        identical(oldWidget.sessionIsCurrent, widget.sessionIsCurrent)) return;
    _service?.dispose();
    _peerName = normalizeDmTitle(widget.peerName);
    _peerAvatarUrl = widget.peerAvatarUrl;
    _createService();
    if (!_wantsCached && _needsPeerProfile) _loadPeerProfile();
  }

  @override
  void dispose() {
    _service?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = normalizeDmTitle(_peerName);
    final debugBuilder = widget.debugChatBuilder;
    if (kDebugMode && debugBuilder != null) return debugBuilder(context, title);
    final service = _service;
    if (service == null)
      return const Scaffold(
          body: Center(child: Text('Сохранённый чат недоступен.')));
    return UnifiedChatScreen(
      key: ValueKey(_serviceRevision),
      service: service,
      title: title,
      hideAvatars: true,
      peerAvatarUrl: _peerAvatarUrl,
      onlineBarrier: widget.onlineBarrier,
      sessionIsCurrent: widget.sessionIsCurrent,
      onOpenPeer: _wantsCached
          ? null
          : () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BlocProvider.value(
                    value: context.read<TeamCubit>(),
                    child: DirectChatInfoScreen(
                      service: service,
                      peerId: widget.peerId,
                      peerName: title,
                      peerAvatarUrl: _peerAvatarUrl,
                    ),
                  ),
                ),
              );
            },
    );
  }

  Future<void> _loadPeerProfile() async {
    if (_wantsCached) return;
    final revision = _serviceRevision;
    final peer = widget.peerId;
    final barrier = widget.onlineBarrier;
    final guard = widget.sessionIsCurrent;
    bool current() {
      try {
        return mounted &&
            !_wantsCached &&
            revision == _serviceRevision &&
            widget.peerId == peer &&
            identical(widget.onlineBarrier, barrier) &&
            identical(widget.sessionIsCurrent, guard) &&
            (barrier == null
                ? guard == null
                : guard != null && barrier.isOpen && guard());
      } catch (_) {
        return false;
      }
    }

    if (!current()) return;
    try {
      Future<({String name, String? avatar})> fetch() =>
          (kDebugMode ? widget.debugResolveProfile : null) != null
              ? widget.debugResolveProfile!(peer)
              : PushNavigation.resolvePeerProfile(peer);
      final profile =
          barrier == null ? await fetch() : await barrier.run(fetch);
      if (profile == null || !current()) return;
      final fullName = isUnresolvedDmTitle(profile.name) ? '' : profile.name;
      final avatar = (profile.avatar ?? '').trim();
      if (fullName.isEmpty && avatar.isEmpty) return;
      setState(() {
        if (fullName.isNotEmpty) _peerName = fullName;
        if (avatar.isNotEmpty) _peerAvatarUrl = avatar;
      });
    } catch (_) {
      // Profile may be unavailable — keep neutral "Пользователь".
    }
  }
}
