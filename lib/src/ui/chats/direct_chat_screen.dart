// FILE: lib/src/ui/chats/direct_chat_screen.dart
import 'package:flutter/material.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
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
  });

  final String peerId;
  final String peerName;
  final String? peerAvatarUrl;
  final String? initialChatId;
  final ProjectChatServerCache? cachedStore;
  final SessionCapabilities? cachedCapabilities;

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
        identical(oldWidget.cachedCapabilities, widget.cachedCapabilities))
      return;
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
    try {
      final profile = await PushNavigation.resolvePeerProfile(widget.peerId);
      if (!mounted || _wantsCached || revision != _serviceRevision) return;
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
