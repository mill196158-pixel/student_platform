import 'dart:convert';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/services/push/active_chat_tracker.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/ui/chats/archive_screen.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';
import 'package:student_platform/src/ui/chats/core/i_chat_service.dart'
    show ChatMode;
import 'package:student_platform/src/ui/chats/forward/forward_picker.dart'
    show ForwardTarget;
import 'package:student_platform/src/ui/chats/data/chat_archive_api.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/chats/data/chat_summaries_cache.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/widgets.dart'; // ChatMessageList
import 'package:student_platform/src/ui/learning/models/message.dart'; // модель сообщения
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';

class MyChatsScreen extends StatefulWidget {
  const MyChatsScreen({super.key, this.pickMode = false});
  final bool pickMode;
  @override
  State<MyChatsScreen> createState() => _MyChatsScreenState();
}

class _MyChatsScreenState extends State<MyChatsScreen>
    with WidgetsBindingObserver {
  bool _loading = true;

  List<_ChatSummary> _all = [];
  List<_ChatSummary> _visible = [];
  String _query = '';

  RealtimeChannel? _channel; // один общий канал для списка чатов
  Timer? _reloadDebounce;
  static const _reloadDebounceEvery = Duration(milliseconds: 300);
  bool _summariesInFlight = false;
  bool _summariesQueued = false;
  Completer<void>? _summariesReloadCompleter;

  bool _hydrated = false; // есть ли быстрый кеш на старте
  Timer? _searchDebounce;
  Timer? _filterDebounce; // ➜ NEW: дебаунс фильтра
  StreamSubscription? _sub; // ➜ NEW: на случай подписки

  // универсальный безопасный setState
  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  String get _currentUserId =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

  Future<void> _markChatReadServerSide(String chatId) async {
    // ➜ NEW
    try {
      final sb = Supabase.instance.client;
      final last = await sb
          .from('messages')
          .select('id')
          .eq('chat_id', chatId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final lastId =
          (last != null && last is Map) ? (last['id'] as String?) : null;
      await sb.rpc('mark_chat_read', params: {
        'p_chat_id': chatId,
        if (lastId != null && lastId.isNotEmpty) 'p_message_id': lastId,
      });
      await AppNotificationsApi(client: sb).markReadForChat(chatId);
    } catch (e) {
      debugPrint('[MyChatsScreen] mark read RPC error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    ActiveChatTracker.instance.enterMessageList();
    WidgetsBinding.instance.addObserver(this);
    final raw = ChatSummariesCache.readSync(_currentUserId);
    if (raw != null) {
      _applyCachedRaw(raw, notify: false);
    }
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (!_hydrated) {
      await _hydrateFromCache();
    }
    await _load();
  }

  @override
  void dispose() {
    ActiveChatTracker.instance.leaveMessageList();
    WidgetsBinding.instance.removeObserver(this);
    _reloadDebounce?.cancel();
    _reloadDebounce = null;
    _channel?.unsubscribe();
    _channel = null;
    _searchDebounce?.cancel();
    _filterDebounce?.cancel();
    _sub?.cancel();
    _searchDebounce = null;
    _filterDebounce = null;
    _sub = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_reloadSummariesFromRpc());
    }
  }

  Future<void> _load() async {
    if (!_hydrated) {
      _safeSetState(() => _loading = true);
    }
    _summariesInFlight = true;
    try {
      final sb = Supabase.instance.client;
      final me = sb.auth.currentUser?.id;
      if (me == null || me.isEmpty) {
        _safeSetState(() {
          _all = [];
          _visible = [];
          _hydrated = true;
          _loading = false;
        });
        return;
      }

      final res = await sb.rpc('get_my_chat_summaries');
      final rows = (res as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // Локальный кеш — быстрый старт; pin/mute с сервера — источник истины.
      // settings_exists=false → один раз перенести старые локальные pin/mute.
      final localStateByKey = <String, _ChatSummary>{
        for (final item in _all) _summaryIdentity(item): item,
      };
      final list = <_ChatSummary>[];
      final toMigrate = <Map<String, dynamic>>[];

      for (final row in rows) {
        final item = _summaryFromRpcRow(row);
        if (item.isDm && (item.peerId == null || item.peerId!.isEmpty)) {
          continue;
        }

        final settingsExists = row['settings_exists'] == true;
        if (!settingsExists) {
          final local = localStateByKey[_summaryIdentity(item)];
          if (local != null) {
            item.pinned = local.pinned;
            item.muted = local.muted;
          }
          final chatId = item.chatId;
          if (chatId != null && chatId.isNotEmpty) {
            toMigrate.add({
              'user_id': me,
              'chat_id': chatId,
              'is_pinned': item.pinned,
              'is_muted': item.muted,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            });
          }
        }
        list.add(item);
      }

      if (toMigrate.isNotEmpty) {
        await sb.from('chat_user_settings').upsert(
              toMigrate,
              onConflict: 'user_id,chat_id',
            );
      }

      list.sort(_compareChats);

      if (!mounted) return;
      _safeSetState(() {
        _all = list;
        _applyFilter();
        _hydrated = true;
        _loading = false;
      });
      await _saveCache(_all);
      unawaited(_hydrateUnresolvedDmTitles());

      _subscribeChatsRealtime();
    } catch (_) {
      _safeSetState(() => _loading = false);
    } finally {
      _summariesInFlight = false;
      if (_summariesQueued) {
        _summariesQueued = false;
        unawaited(_reloadSummariesFromRpc());
      }
    }
  }

  int _compareChats(_ChatSummary a, _ChatSummary b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1; // закреплённые выше
    final aa = a.lastTime ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bb = b.lastTime ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bb.compareTo(aa); // новые выше
  }

  _ChatSummary _summaryFromRpcRow(Map<String, dynamic> row) {
    final chatType = (row['chat_type'] ?? '').toString();
    final isDm = chatType == 'dm';
    final teamId = (row['team_id'] ?? '').toString();
    final teamName = (row['team_name'] ?? '').toString();
    final teamIcon = (row['team_icon'] ?? '').toString();
    final teamTeacher = (row['team_teacher'] ?? '').toString();
    final teamGroupName = (row['team_group_name'] ?? '').toString();
    final teamKind = (row['team_kind'] ?? 'subject').toString();
    final isGroupSpace = !isDm && teamKind == 'group_space';
    final titleRaw = (row['title'] ?? '').toString().trim();
    final peerId = (row['peer_id'] ?? '').toString();
    final avatarRaw = (row['avatar_url'] ?? '').toString().trim();
    final chatId = (row['chat_id'] ?? '').toString();
    final lastMessageId = (row['last_message_id'] ?? '').toString();
    final lastAt = DateTime.tryParse((row['last_message_at'] ?? '').toString());
    final lastAuthorName = (row['last_author_name'] ?? '').toString().trim();
    final unread = (row['unread_count'] as num?)?.toInt() ?? 0;
    final hasLastMessage = lastMessageId.isNotEmpty;
    final preview = hasLastMessage
        ? _buildPreviewFromRow({
            'body': row['body'],
            'content': row['content'],
            'msg_type': row['msg_type'],
          })
        : 'Сообщений пока нет';

    final title = isDm
        ? normalizeDmTitle(titleRaw)
        : (titleRaw.isNotEmpty
            ? titleRaw
            : (teamName.isNotEmpty ? teamName : 'Чат'));

    return _ChatSummary(
      team: Team(
        id: isDm ? '' : teamId,
        name: isDm ? title : (teamName.isNotEmpty ? teamName : title),
        icon: isGroupSpace
            ? (teamIcon.isNotEmpty ? teamIcon : 'groups')
            : teamIcon,
        teacher: teamTeacher,
        groupCode: teamGroupName,
      ),
      title: title,
      subtitle: isDm
          ? null
          : (isGroupSpace
              ? 'Группа'
              : (teamTeacher.isNotEmpty
                  ? teamTeacher
                  : (teamGroupName.isNotEmpty ? teamGroupName : null))),
      lastAuthor: lastAuthorName.isNotEmpty ? lastAuthorName : null,
      lastMsgPreview: preview,
      lastTime: lastAt,
      unread: unread,
      pinned: row['is_pinned'] == true,
      muted: row['is_muted'] == true,
      chatId: chatId.isNotEmpty ? chatId : null,
      lastMessageId: hasLastMessage ? lastMessageId : null,
      isDm: isDm,
      peerId: peerId.isNotEmpty ? peerId : null,
      avatarUrl: avatarRaw.isNotEmpty ? avatarRaw : null,
    );
  }

  /// Resolve peer names for DMs still showing a neutral/legacy placeholder.
  Future<void> _hydrateUnresolvedDmTitles() async {
    final need = <_ChatSummary>[];
    for (final c in _all) {
      if (!c.isDm) continue;
      final peerId = c.peerId;
      if (peerId == null || peerId.isEmpty) continue;
      if (isUnresolvedDmTitle(c.title) || (c.avatarUrl ?? '').isEmpty) {
        need.add(c);
      }
    }
    if (need.isEmpty) return;

    try {
      // Direct `users` SELECT is RLS-blocked for peers; resolve via RPC.
      var changed = false;
      for (final c in need) {
        final profile = await PushNavigation.resolvePeerProfile(c.peerId!);
        final fullName =
            isUnresolvedDmTitle(profile.name) ? '' : profile.name.trim();
        final avatar = (profile.avatar ?? '').trim();
        if (fullName.isNotEmpty && isUnresolvedDmTitle(c.title)) {
          c.title = fullName;
          changed = true;
        }
        if (avatar.isNotEmpty && (c.avatarUrl ?? '').isEmpty) {
          c.avatarUrl = avatar;
          changed = true;
        }
      }
      if (!changed || !mounted) return;
      _safeSetState(_applyFilter);
      _saveCache(_all);
    } catch (_) {
      // Keep neutral fallback; header/open path also hydrates by peerId.
    }
  }

  Future<void> _togglePinChat(_ChatSummary c) async {
    final idx =
        _all.indexWhere((e) => _summaryIdentity(e) == _summaryIdentity(c));
    if (idx == -1) return;

    final prev = _all[idx].pinned;
    final next = !prev;
    _safeSetState(() {
      _all[idx].pinned = next;
      safeDebugLog(
          '[MyChatsScreen] togglePin chat=${maskDebugId(c.chatId)} pinned=$next');
      _all.sort(_compareChats);
      _applyFilter();
    });
    await _saveCache(_all);

    final chatId = c.chatId;
    if (chatId == null || chatId.isEmpty)
      return; // без chatId — только локально

    final ok = await _updateChatUserPinned(chatId: chatId, isPinned: next);
    if (ok || !mounted) return;

    _safeSetState(() {
      final i =
          _all.indexWhere((e) => _summaryIdentity(e) == _summaryIdentity(c));
      if (i == -1) return;
      _all[i].pinned = prev;
      _all.sort(_compareChats);
      _applyFilter();
    });
    await _saveCache(_all);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Не удалось закрепить')),
    );
  }

  Future<void> _toggleMuteChat(_ChatSummary c) async {
    final idx =
        _all.indexWhere((e) => _summaryIdentity(e) == _summaryIdentity(c));
    if (idx == -1) return;

    final prev = _all[idx].muted;
    final next = !prev;
    _safeSetState(() {
      _all[idx].muted = next;
      safeDebugLog(
          '[MyChatsScreen] toggleMute chat=${maskDebugId(c.chatId)} muted=$next');
      _applyFilter();
    });
    await _saveCache(_all);

    final chatId = c.chatId;
    if (chatId == null || chatId.isEmpty)
      return; // без chatId — только локально

    final ok = await _updateChatUserMuted(chatId: chatId, isMuted: next);
    if (ok || !mounted) return;

    _safeSetState(() {
      final i =
          _all.indexWhere((e) => _summaryIdentity(e) == _summaryIdentity(c));
      if (i == -1) return;
      _all[i].muted = prev;
      _applyFilter();
    });
    await _saveCache(_all);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Не удалось изменить звук')),
    );
  }

  Future<bool> _updateChatUserPinned({
    required String chatId,
    required bool isPinned,
  }) async {
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (me == null || me.isEmpty) return false;
    try {
      final rows = await Supabase.instance.client
          .from('chat_user_settings')
          .update({
            'is_pinned': isPinned,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('user_id', me)
          .eq('chat_id', chatId)
          .select('chat_id');
      return rows.isNotEmpty;
    } catch (e) {
      debugPrint('[MyChatsScreen] update chat_user_settings pin error: $e');
      return false;
    }
  }

  Future<bool> _updateChatUserMuted({
    required String chatId,
    required bool isMuted,
  }) async {
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (me == null || me.isEmpty) return false;
    try {
      final rows = await Supabase.instance.client
          .from('chat_user_settings')
          .update({
            'is_muted': isMuted,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('user_id', me)
          .eq('chat_id', chatId)
          .select('chat_id');
      return rows.isNotEmpty;
    } catch (e) {
      debugPrint('[MyChatsScreen] update chat_user_settings mute error: $e');
      return false;
    }
  }

  Future<void> _archivePersonalChat(_ChatSummary c) async {
    final chatId = c.chatId;
    if (chatId == null || chatId.isEmpty || !c.isDm) return;
    try {
      await ChatArchiveApi.setPersonalChatArchived(
        chatId: chatId,
        archived: true,
      );
      if (!mounted) return;
      _safeSetState(() {
        _all.removeWhere((e) => e.chatId == chatId);
        _applyFilter();
      });
      await _saveCache(_all);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить в архив')),
      );
    }
  }

  Future<void> _hidePersonalChat(_ChatSummary c) async {
    final chatId = c.chatId;
    if (chatId == null || chatId.isEmpty || !c.isDm) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить переписку у себя?'),
        content: const Text(
          'Переписка исчезнет только у вас. Если собеседник напишет снова, диалог появится в сообщениях.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ChatArchiveApi.hidePersonalChatForMe(chatId: chatId);
      if (!mounted) return;
      _safeSetState(() {
        _all.removeWhere((e) => e.chatId == chatId);
        _applyFilter();
      });
      await _saveCache(_all);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить переписку')),
      );
    }
  }

  void _scheduleSummariesReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(_reloadDebounceEvery, () {
      unawaited(_reloadSummariesFromRpc());
    });
  }

  Future<void> _reloadSummariesFromRpc() async {
    if (_summariesInFlight) {
      _summariesQueued = true;
      return _summariesReloadCompleter?.future ?? Future<void>.value();
    }
    _summariesInFlight = true;
    final completer = Completer<void>();
    _summariesReloadCompleter = completer;
    try {
      do {
        _summariesQueued = false;
        final sb = Supabase.instance.client;
        if (sb.auth.currentUser == null) break;

        final res = await sb.rpc('get_my_chat_summaries');
        final list = (res as List? ?? const [])
            .map((e) => _summaryFromRpcRow(Map<String, dynamic>.from(e as Map)))
            .where((c) => !c.isDm || (c.peerId?.isNotEmpty ?? false))
            .toList()
          ..sort(_compareChats);

        if (!mounted) break;
        _safeSetState(() {
          _all = list;
          _applyFilter();
        });
        await _saveCache(_all);
      } while (_summariesQueued && mounted);
    } catch (e) {
      safeDebugLog(
          '[realtime] get_my_chat_summaries failed error=${e.runtimeType}');
    } finally {
      final needsAnother = _summariesQueued && mounted;
      _summariesQueued = false;
      _summariesInFlight = false;
      if (!completer.isCompleted) completer.complete();
      if (identical(_summariesReloadCompleter, completer)) {
        _summariesReloadCompleter = null;
      }
      if (needsAnother) {
        unawaited(_reloadSummariesFromRpc());
      }
    }
  }

  Future<void> _refreshAfterReturningFromChat() async {
    _reloadDebounce?.cancel();
    _reloadDebounce = null;
    await _reloadSummariesFromRpc();
  }

  void _subscribeChatsRealtime() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) return;
    if (_channel != null) return;

    void onChange(PostgresChangePayload _) => _scheduleSummariesReload();

    final userFilter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'user_id',
      value: uid,
    );

    _channel = Supabase.instance.client
        .channel('public:my_chats:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_reads',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_reads',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'chat_reads',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_user_settings',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_user_settings',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'chat_user_settings',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_members',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_members',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'chat_members',
          filter: userFilter,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chats',
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chats',
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'chats',
          callback: onChange,
        )
        .subscribe();
  }

  String _summaryIdentity(_ChatSummary c) {
    final chatId = c.chatId;
    if (chatId != null && chatId.isNotEmpty) return 'chat:$chatId';
    if (c.isDm && (c.peerId ?? '').isNotEmpty) return 'dm:${c.peerId}';
    if (c.team.id.isNotEmpty) return 'team:${c.team.id}';
    return 'title:${c.title}';
  }

  Future<void> _openChat(_ChatSummary c) async {
    Navigator.of(context).pop();
    if (c.isDm && (c.peerId?.isNotEmpty ?? false)) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BlocProvider.value(
            value: context.read<TeamCubit>(),
            child: DirectChatScreen(
              peerId: c.peerId!,
              peerName: c.title,
              peerAvatarUrl: c.avatarUrl,
              initialChatId: c.chatId,
            ),
          ),
        ),
      );
      await _refreshAfterReturningFromChat();
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeamDetailsScreen(
          team: c.team,
          initialTabIndex: 1,
        ),
      ),
    );
    await _refreshAfterReturningFromChat();
  }

  Future<void> _markChatRead(_ChatSummary c) async {
    final chatId = c.chatId;
    Navigator.of(context).pop();
    setState(() {
      final idx =
          _all.indexWhere((e) => _summaryIdentity(e) == _summaryIdentity(c));
      if (idx != -1) _all[idx].unread = 0;
      _applyFilter();
    });
    await _saveCache(_all);
    if (chatId != null && chatId.isNotEmpty) {
      await _markChatReadServerSide(chatId);
      await _refreshUnreadFor(chatId);
    }
  }

  void _applyFilter() {
    if (!mounted) return;
    _safeSetState(() {
      if (_query.isEmpty) {
        _visible = List.of(_all);
      } else {
        final q = _query.toLowerCase();
        _visible = _all.where((c) {
          return c.title.toLowerCase().contains(q) ||
              (c.subtitle ?? '').toLowerCase().contains(q) ||
              (c.lastAuthor ?? '').toLowerCase().contains(q) ||
              (c.lastMsgPreview ?? '').toLowerCase().contains(q);
        }).toList();
      }
      safeDebugLog(
          '[MyChatsScreen] filter applied hasQuery=${_query.isNotEmpty} visible=${_visible.length} all=${_all.length}');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final searchFill =
        isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F4);
    final dividerOpacity = isDark ? .24 : .35;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Сообщения'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'archive') {
                unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BlocProvider.value(
                        value: context.read<TeamCubit>(),
                        child: const ArchiveScreen(),
                      ),
                    ),
                  ),
                );
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem<String>(
                value: 'archive',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.archive_outlined),
                  title: Text('Архив'),
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // компактный поиск
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: SizedBox(
              height: 38,
              child: TextField(
                onChanged: (s) {
                  _searchDebounce?.cancel();
                  _searchDebounce =
                      Timer(const Duration(milliseconds: 160), () {
                    if (!mounted) return;
                    _safeSetState(() {
                      _query = s.trim();
                      _applyFilter();
                    });
                  });
                },
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Поиск',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  filled: true,
                  fillColor: searchFill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),

          // список — только «между» разделители (без верхнего)
          Expanded(
            child: (_loading && !_hydrated)
                ? const _SkeletonList()
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      key: const PageStorageKey('chats_list'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                        left: 6,
                        right: 6,
                        top: 4,
                        bottom: MediaQuery.of(context).padding.bottom + 12,
                      ),
                      itemCount: _visible.length,
                      separatorBuilder: (ctx, i) =>
                          _ThinDivider(opacity: dividerOpacity),
                      itemBuilder: (ctx, i) {
                        final c = _visible[i];
                        return KeyedSubtree(
                          key: ValueKey(c.chatId ?? c.title),
                          child: _ChatRow(
                            data: c,
                            onTap: () async {
                              debugPrint(
                                  '[MyChatsScreen] onTap -> \'${c.title}\'');
                              if (widget.pickMode) {
                                try {
                                  if (c.isDm &&
                                      (c.peerId?.isNotEmpty ?? false)) {
                                    final realId =
                                        await DmApi.getOrCreateChatId(
                                            peerId: c.peerId!);
                                    // ignore: use_build_context_synchronously
                                    Navigator.pop(
                                        context,
                                        ForwardTarget(
                                          chatId: realId,
                                          title: c.title,
                                          mode: ChatMode.dm,
                                          avatarUrl: c.avatarUrl,
                                          open: (ctx) async {
                                            await Navigator.of(ctx)
                                                .push(MaterialPageRoute(
                                              builder: (_) =>
                                                  BlocProvider.value(
                                                value: ctx.read<TeamCubit>(),
                                                child: DirectChatScreen(
                                                  peerId: c.peerId!,
                                                  peerName: c.title,
                                                  peerAvatarUrl: c.avatarUrl,
                                                  initialChatId: realId,
                                                ),
                                              ),
                                            ));
                                          },
                                        ));
                                  } else {
                                    String? chatId = c.chatId;
                                    if (chatId == null || chatId.isEmpty) {
                                      try {
                                        final res = await Supabase
                                            .instance.client
                                            .from('chats')
                                            .select('id')
                                            .eq('team_id', c.team.id)
                                            .eq('type', 'team_main')
                                            .limit(1)
                                            .maybeSingle();
                                        if (res != null && res is Map) {
                                          chatId = (res['id'] ?? '').toString();
                                        }
                                      } catch (_) {}
                                    }
                                    // ignore: use_build_context_synchronously
                                    Navigator.pop(
                                        context,
                                        ForwardTarget(
                                          chatId: chatId ?? '',
                                          title: c.title,
                                          mode: ChatMode.team,
                                          avatarUrl: c.avatarUrl,
                                          open: (ctx) async {
                                            await Navigator.of(ctx)
                                                .push(MaterialPageRoute(
                                              builder: (_) => TeamDetailsScreen(
                                                  team: c.team,
                                                  initialTabIndex: 1),
                                            ));
                                          },
                                        ));
                                  }
                                } catch (_) {}
                                return;
                              }
                              if (c.isDm && (c.peerId?.isNotEmpty ?? false)) {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => BlocProvider.value(
                                      value: context.read<TeamCubit>(),
                                      child: DirectChatScreen(
                                        peerId: c.peerId!,
                                        peerName: c.title,
                                        peerAvatarUrl: c.avatarUrl,
                                        initialChatId: c.chatId,
                                      ),
                                    ),
                                  ),
                                );
                                await _refreshAfterReturningFromChat();
                                return;
                              }

                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => TeamDetailsScreen(
                                    team: c.team,
                                    initialTabIndex: 1,
                                  ),
                                ),
                              );
                              await _refreshAfterReturningFromChat();
                            },
                            onLongPressStart: (details) {
                              safeDebugLog(
                                  '[MyChatsScreen] onLongPress chat=${maskDebugId(c.chatId)}');
                              HapticFeedback.mediumImpact();
                              _showPeek(c,
                                  pressPosition: details.globalPosition);
                            },
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _showPeek(_ChatSummary c, {Offset? pressPosition}) {
    debugPrint('[MyChatsScreen] _showPeek: ${c.title}');

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'peek',
      barrierColor: Colors.black.withValues(alpha: 0.24),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (_, anim, __, ___) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return Opacity(
          opacity: curved.value,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxW = constraints.maxWidth;
              final maxH = constraints.maxHeight;
              final previewW = maxW > 560 ? 520.0 : maxW * 0.94; // как и было
              final mq = MediaQuery.of(context);
              final safeTop = mq.padding.top;
              final safeBottom = mq.padding.bottom;
              // одинаковый зазор сверху и по бокам
              final sideGap = (maxW - previewW) / 2.0;
              final topOffset = safeTop + sideGap;

              final menuItems = c.isDm ? 6 : 4;
              final double kMenuEst = _peekMenuItemHeight * menuItems;
              const double kGapPreviewToMenu = 10.0;

              // итог: оставляем место под меню + нижнюю безопасную зону
              final double previewH = math.max(
                220.0,
                math.min(
                  maxH * 0.58,
                  maxH -
                      topOffset -
                      (kMenuEst + kGapPreviewToMenu + safeBottom + 8),
                ),
              );

              return Stack(
                children: [
                  // карточка предпросмотра
                  Positioned(
                    top: topOffset,
                    left: sideGap,
                    width: previewW,
                    height: previewH,
                    child: Transform.scale(
                      scale: 0.95 + 0.05 * curved.value,
                      child: _ChatPeekSheet(
                        width: previewW,
                        height: previewH,
                        team: c.team,
                        chatId: c.chatId, // DM: реальный chatId
                        isDm: c.isDm,
                        pinned: c.pinned,
                        muted: c.muted,
                        onTogglePin: () {
                          _togglePinChat(c);
                          Navigator.of(context).pop();
                        },
                        onToggleMute: () {
                          _toggleMuteChat(c);
                          Navigator.of(context).pop();
                        },
                        onMarkRead: () async => _markChatRead(c),
                        onOpenChat: () => _openChat(c),
                      ),
                    ),
                  ),

                  Positioned(
                    top: topOffset + previewH + kGapPreviewToMenu,
                    right: sideGap,
                    child: _PeekContextMenu(
                      pinned: c.pinned,
                      muted: c.muted,
                      hasUnread: c.unread > 0,
                      isDm: c.isDm,
                      onOpen: () => _openChat(c),
                      onTogglePin: () {
                        _togglePinChat(c);
                        Navigator.of(context).pop();
                      },
                      onToggleMute: () {
                        _toggleMuteChat(c);
                        Navigator.of(context).pop();
                      },
                      onMarkRead: () => _markChatRead(c),
                      onArchive: c.isDm
                          ? () {
                              Navigator.of(context).pop();
                              unawaited(_archivePersonalChat(c));
                            }
                          : null,
                      onHideForMe: c.isDm
                          ? () {
                              Navigator.of(context).pop();
                              unawaited(_hidePersonalChat(c));
                            }
                          : null,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  // билдер превью по ряду messages / RPC summary
  String _buildPreviewFromRow(Map row) {
    String? fgPreviewFromText(String s) {
      final idx = s.indexOf('__FG__:');
      if (idx < 0) return null;
      final payload = s.substring(idx + '__FG__:'.length).trim();
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map && decoded['items'] is List) {
          final n = (decoded['items'] as List).length;
          return n > 1 ? 'Пересланные сообщения ($n)' : 'Пересланное сообщение';
        }
      } catch (_) {}
      return 'Пересланные сообщения';
    }

    // 1) сначала пробуем body (явный текст)
    final body = (row['body'] ?? '').toString().trim();
    if (body.isNotEmpty) {
      final fg = fgPreviewFromText(body);
      return fg ?? body;
    }

    // 2) если нет body — пробуем content (вдруг там JSON или строка)
    final dynamic rawContent = row['content'];
    if (rawContent is String && rawContent.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawContent);
        if (decoded is Map && decoded['text'] != null) {
          final txt = decoded['text'].toString().trim();
          if (txt.isNotEmpty) {
            final fg = fgPreviewFromText(txt);
            return fg ?? txt;
          }
        }
      } catch (_) {
        // не JSON → вернуть строку как есть (но без FG-маркера)
        final s = rawContent.trim();
        if (s.isNotEmpty) {
          final fg = fgPreviewFromText(s);
          return fg ?? s;
        }
      }
    } else if (rawContent is Map) {
      final txt = (rawContent['text'] ?? '').toString().trim();
      if (txt.isNotEmpty) {
        final fg = fgPreviewFromText(txt);
        return fg ?? txt;
      }
    }

    // 3) вложения по типу сообщения
    final msgType = (row['msg_type'] ?? '').toString();
    if (msgType == 'file' || msgType == 'image') {
      return '📎 Вложение';
    }

    // 4) fallback
    return 'Сообщение';
  }

  Future<void> _hydrateFromCache() async {
    try {
      final s = await ChatSummariesCache.read(_currentUserId);
      if (s == null || s.isEmpty) return;
      if (!mounted) return;
      _applyCachedRaw(s, notify: true);
      unawaited(_hydrateUnresolvedDmTitles());
    } catch (_) {}
  }

  void _applyCachedRaw(String rawJson, {required bool notify}) {
    final raw = (jsonDecode(rawJson) as List).cast<Map<String, dynamic>>();
    final list = raw.map(_summaryFromMap).toList()..sort(_compareChats);
    void apply() {
      _all = list;
      final query = _query.toLowerCase();
      _visible = query.isEmpty
          ? List<_ChatSummary>.of(list)
          : list.where((c) {
              return c.title.toLowerCase().contains(query) ||
                  (c.subtitle ?? '').toLowerCase().contains(query) ||
                  (c.lastAuthor ?? '').toLowerCase().contains(query) ||
                  (c.lastMsgPreview ?? '').toLowerCase().contains(query);
            }).toList();
      _hydrated = true;
      _loading = false;
    }

    if (notify) {
      _safeSetState(apply);
    } else {
      apply();
    }
  }

  Future<void> _saveCache(List<_ChatSummary> list) async {
    try {
      final data = jsonEncode(list.map(_summaryToMap).toList());
      await ChatSummariesCache.write(_currentUserId, data);
    } catch (_) {}
  }

  Map<String, dynamic> _summaryToMap(_ChatSummary c) => {
        'team': {
          'id': c.team.id,
          'name': c.team.name,
          'teacher': c.team.teacher,
          'groupCode': c.team.groupCode,
          'icon': c.team.icon,
        },
        'title': c.title,
        'subtitle': c.subtitle,
        'lastAuthor': c.lastAuthor,
        'lastMsgPreview': c.lastMsgPreview,
        'lastTime': c.lastTime?.toIso8601String(),
        'unread': c.unread,
        'pinned': c.pinned,
        'muted': c.muted,
        'chatId': c.chatId,
        'lastMessageId': c.lastMessageId,
        'isDm': c.isDm,
        'peerId': c.peerId,
        'avatarUrl': c.avatarUrl,
      };

  _ChatSummary _summaryFromMap(Map<String, dynamic> m) {
    final tm = (m['team'] as Map<String, dynamic>);
    final t = Team(
      id: tm['id'] as String,
      name: tm['name'] as String,
      icon: (tm['icon'] ?? '') as String,
      teacher: (tm['teacher'] ?? '') as String,
      groupCode: (tm['groupCode'] ?? '') as String,
    );
    final isDm = (m['isDm'] ?? false) as bool;
    final titleRaw = (m['title'] ?? '') as String;
    return _ChatSummary(
      team: t,
      title: isDm ? normalizeDmTitle(titleRaw) : titleRaw,
      subtitle: m['subtitle'] as String?,
      lastAuthor: m['lastAuthor'] as String?,
      lastMsgPreview: m['lastMsgPreview'] as String?,
      lastTime: m['lastTime'] != null
          ? DateTime.tryParse(m['lastTime'] as String)
          : null,
      unread: (m['unread'] ?? 0) as int,
      pinned: (m['pinned'] ?? false) as bool,
      muted: (m['muted'] ?? false) as bool,
      chatId: m['chatId'] as String?,
      lastMessageId: m['lastMessageId'] as String?,
      isDm: isDm,
      peerId: m['peerId'] as String?,
      avatarUrl: m['avatarUrl'] as String?,
    );
  }

  // ➜ NEW: обновить unread для одного чата по RPC и переложить в список + кэш
  Future<void> _refreshUnreadFor(String chatId) async {
    try {
      final res = await Supabase.instance.client
          .rpc('get_unread_in_chat', params: {'p_chat_id': chatId});

      int unread = 0;
      if (res is List && res.isNotEmpty) {
        final m = Map<String, dynamic>.from(res.first as Map);
        unread = (m['unread_count'] ?? 0) as int;
      } else if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        unread = (m['unread_count'] ?? 0) as int;
      }

      if (!mounted) return;
      setState(() {
        final idx = _all.indexWhere((e) => e.chatId == chatId);
        if (idx != -1) {
          _all[idx].unread = unread;
          _all.sort(_compareChats);
          _applyFilter();
        }
      });
      _saveCache(_all);
    } catch (_) {/* тихо */}
  }
}

class _ChatSummary {
  final Team team;
  String title;
  final String? subtitle;
  String? lastAuthor; // ← отдельная строка «кто написал»
  String? lastMsgPreview; // ← отдельная строка «сообщение»
  DateTime? lastTime;
  int unread;
  bool pinned;
  bool muted;
  String? chatId;
  // ➜ NEW: последний message id для точного обновления превью
  String? lastMessageId;
  // ➜ NEW: DM meta
  final bool isDm;
  final String? peerId;
  String? avatarUrl;

  _ChatSummary({
    required this.team,
    required this.title,
    this.subtitle,
    this.lastAuthor,
    this.lastMsgPreview,
    this.lastTime,
    this.unread = 0,
    this.pinned = false,
    this.muted = false,
    this.chatId,
    this.lastMessageId,
    this.isDm = false,
    this.peerId,
    this.avatarUrl,
  });
}

class _ChatRow extends StatelessWidget {
  final _ChatSummary data;
  final VoidCallback onTap;
  final GestureLongPressStartCallback? onLongPressStart;

  const _ChatRow({
    required this.data,
    required this.onTap,
    this.onLongPressStart,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final onSurface = theme.colorScheme.onSurface;
    final onSurfaceVar =
        (t.bodyMedium?.color ?? Colors.black).withValues(alpha: 0.72);
    final unread = data.unread > 0;
    final muted = data.muted;
    final accent = Theme.of(context).colorScheme.primary;

    final time = data.lastTime != null ? _formatTime(data.lastTime!) : '';

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onLongPressStart: onLongPressStart,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                _BubbleAvatar(
                    label: data.title,
                    muted: data.muted,
                    avatarUrl: data.avatarUrl),
                const SizedBox(width: 12),

                // центр: 3 строки (заголовок / автор / сообщение)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1) Название
                      Text(
                        data.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleMedium?.copyWith(
                          color: onSurface,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.1,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // 2) Автор (или подпись чата, если автора нет)
                      Text(
                        (data.lastAuthor?.isNotEmpty ?? false)
                            ? data.lastAuthor!
                            : (data.subtitle ?? ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(
                          color: onSurfaceVar,
                          fontWeight: FontWeight.w600,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // 3) Превью сообщения
                      Text(
                        data.lastMsgPreview ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(
                          color: unread && !muted ? onSurface : onSurfaceVar,
                          fontWeight: unread && !muted ? FontWeight.w700 : null,
                          height: 1.05,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // справа: время + бейдж
                SizedBox(
                  width: 56,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (time.isNotEmpty)
                        Text(
                          time,
                          style: t.labelSmall?.copyWith(
                            color: unread && !muted ? accent : onSurfaceVar,
                            fontWeight: unread && !muted
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                      const SizedBox(height: 6),
                      if (data.unread > 0)
                        _UnreadBadge(count: data.unread, muted: data.muted)
                      else if (data.pinned)
                        Icon(Icons.push_pin, size: 16, color: onSurfaceVar),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$dd.$mo';
  }
}

class _ThinDivider extends StatelessWidget {
  final double opacity;
  const _ThinDivider({this.opacity = .35});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).dividerColor.withOpacity(opacity);
    return Padding(
      padding: const EdgeInsets.only(left: 72, right: 14), // отступ под аватар
      child: Divider(height: 0, thickness: 0.6, color: c),
    );
  }
}

class _BubbleAvatar extends StatelessWidget {
  final String label;
  final bool muted;
  final String? avatarUrl;
  const _BubbleAvatar(
      {required this.label, required this.muted, this.avatarUrl});

  @override
  Widget build(BuildContext context) {
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: 26,
            backgroundImage: NetworkImage(avatarUrl!),
            backgroundColor: Colors.transparent,
          ),
          if (muted)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    shape: BoxShape.circle),
                child: const Icon(Icons.volume_off_rounded, size: 16),
              ),
            ),
        ],
      );
    }

    final ch = (label.trim().isNotEmpty ? label.trim().characters.first : '•')
        .toUpperCase();
    final colors = _gradientFromString(label);
    final surface = Theme.of(context).colorScheme.surface;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          alignment: Alignment.center,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.06),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              ch,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
          ),
        ),
        if (muted)
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: surface, shape: BoxShape.circle),
              child: const Icon(Icons.volume_off_rounded, size: 16),
            ),
          ),
      ],
    );
  }

  List<Color> _gradientFromString(String s) {
    final h = s.codeUnits.fold<int>(0, (p, e) => (p * 31 + e) & 0xFFFFFFFF);
    final c1 = HSVColor.fromAHSV(1, (h % 360).toDouble(), .62, .92).toColor();
    final c2 =
        HSVColor.fromAHSV(1, ((h >> 4) % 360).toDouble(), .62, .78).toColor();
    return [c1, c2];
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  final bool muted;
  const _UnreadBadge({required this.count, required this.muted});

  @override
  Widget build(BuildContext context) {
    final txt = count > 999 ? '999+' : '$count';
    final color = muted
        ? Theme.of(context).colorScheme.outline.withValues(alpha: 0.65)
        : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        txt,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
    );
  }
}

class _PeekCard extends StatelessWidget {
  final _ChatSummary data;
  final VoidCallback onOpen;
  const _PeekCard({required this.data, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final onSurfaceVar =
        (t.bodyMedium?.color ?? Colors.black).withOpacity(0.72);
    final time = data.lastTime != null ? _formatTime(data.lastTime!) : '';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 14,
        shadowColor: Colors.black.withOpacity(.3),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _BubbleAvatar(label: data.title, muted: data.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          data.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          data.lastAuthor ?? data.subtitle ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: onSurfaceVar),
                        ),
                      ],
                    ),
                  ),
                  if (time.isNotEmpty)
                    Text(
                      time,
                      style: t.labelSmall?.copyWith(
                        color: onSurfaceVar,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  data.lastMsgPreview ?? 'Сообщений пока нет',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Закрыть'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: onOpen,
                      child: const Text('Открыть чат'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$dd.$mo';
  }
}

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();
  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: 10,
      separatorBuilder: (_, __) => const _ThinDivider(),
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.06),
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 12, color: Colors.black.withOpacity(.05)),
                  const SizedBox(height: 6),
                  Container(height: 12, color: Colors.black.withOpacity(.04)),
                  const SizedBox(height: 6),
                  Container(height: 12, color: Colors.black.withOpacity(.04)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Нижняя плашка действий — визуально как меню в чате (иконки + подписи)
class _PeekActionsBar extends StatelessWidget {
  final bool pinned;
  final bool muted;
  final double safeBottom;
  final VoidCallback onPin;
  final VoidCallback onMute;
  final VoidCallback onMarkRead;
  final VoidCallback onOpen;

  const _PeekActionsBar({
    required this.pinned,
    required this.muted,
    required this.safeBottom,
    required this.onPin,
    required this.onMute,
    required this.onMarkRead,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 14,
      shadowColor: Colors.black.withOpacity(.25),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56, maxHeight: 86),
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, 10, 8, 10 + safeBottom),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ActionTile(
                icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
                label: pinned ? 'Открепить' : 'Закрепить',
                onTap: onPin,
              ),
              _ActionTile(
                icon:
                    muted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                label: muted ? 'Со звуком' : 'Без звука',
                onTap: onMute,
              ),
              _ActionTile(
                icon: Icons.mark_email_read_outlined,
                label: 'Прочитано',
                onTap: onMarkRead,
              ),
              _ActionTile(
                icon: Icons.open_in_new_rounded,
                label: 'Открыть чат',
                onTap: onOpen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionTile(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurfaceVar =
        (theme.textTheme.bodyMedium?.color ?? Colors.black).withOpacity(.78);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: onSurfaceVar),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

const double _peekMenuItemHeight = 42.0;

class _PeekMenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _PeekMenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
}

/// Всплывающее контекстное меню превью чата — тем же стилем, что меню сообщений.
class _PeekContextMenu extends StatefulWidget {
  final bool pinned;
  final bool muted;
  final bool hasUnread;
  final bool isDm;
  final VoidCallback onOpen;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleMute;
  final VoidCallback onMarkRead;
  final VoidCallback? onArchive;
  final VoidCallback? onHideForMe;

  const _PeekContextMenu({
    required this.pinned,
    required this.muted,
    required this.hasUnread,
    this.isDm = false,
    required this.onOpen,
    required this.onTogglePin,
    required this.onToggleMute,
    required this.onMarkRead,
    this.onArchive,
    this.onHideForMe,
  });

  @override
  State<_PeekContextMenu> createState() => _PeekContextMenuState();
}

class _PeekContextMenuState extends State<_PeekContextMenu> {
  late List<GlobalKey> _itemKeys;
  int? _selectedIndex;
  bool _pointerActive = false;

  List<_PeekMenuAction> get _actions {
    final items = <_PeekMenuAction>[
      _PeekMenuAction(
        icon: Icons.open_in_new_rounded,
        label: 'Открыть чат',
        onTap: widget.onOpen,
      ),
      _PeekMenuAction(
        icon: widget.pinned ? Icons.push_pin : Icons.push_pin_outlined,
        label: widget.pinned ? 'Открепить' : 'Закрепить',
        onTap: widget.onTogglePin,
      ),
      _PeekMenuAction(
        icon: widget.muted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        label: widget.muted ? 'Со звуком' : 'Без звука',
        onTap: widget.onToggleMute,
      ),
      _PeekMenuAction(
        icon: Icons.mark_chat_read_outlined,
        label: widget.hasUnread ? 'Прочитано' : 'Обновить прочитано',
        onTap: widget.onMarkRead,
      ),
    ];
    if (widget.isDm && widget.onArchive != null) {
      items.add(
        _PeekMenuAction(
          icon: Icons.archive_outlined,
          label: 'В архив',
          onTap: widget.onArchive!,
        ),
      );
    }
    if (widget.isDm && widget.onHideForMe != null) {
      items.add(
        _PeekMenuAction(
          icon: Icons.delete_outline,
          label: 'Удалить у себя',
          onTap: widget.onHideForMe!,
          danger: true,
        ),
      );
    }
    return items;
  }

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(_actions.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant _PeekContextMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pinned != widget.pinned ||
        oldWidget.muted != widget.muted ||
        oldWidget.hasUnread != widget.hasUnread ||
        oldWidget.isDm != widget.isDm) {
      _itemKeys = List.generate(_actions.length, (_) => GlobalKey());
      _selectedIndex = null;
    }
  }

  void _selectIndex(int? nextIndex, {bool haptic = true}) {
    if (nextIndex == _selectedIndex) return;
    setState(() => _selectedIndex = nextIndex);
    if (haptic && nextIndex != null) {
      HapticFeedback.selectionClick();
    }
  }

  void _selectAtPosition(Offset globalPosition, {bool haptic = true}) {
    _selectIndex(_hitTest(globalPosition), haptic: haptic);
  }

  void _activateSelected([int? explicitIndex]) {
    final index = explicitIndex ?? _selectedIndex;
    final actions = _actions;
    if (index == null || index < 0 || index >= actions.length) return;
    actions[index].onTap();
  }

  int? _hitTest(Offset globalPosition) {
    Rect? menuBounds;
    final rowRects = <Rect>[];

    for (final key in _itemKeys) {
      final context = key.currentContext;
      final renderObject = context?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;
      final topLeft = renderObject.localToGlobal(Offset.zero);
      final rect = topLeft & renderObject.size;
      rowRects.add(rect);
      menuBounds = menuBounds == null ? rect : menuBounds.expandToInclude(rect);
    }

    for (var i = 0; i < rowRects.length; i++) {
      if (rowRects[i].contains(globalPosition)) return i;
    }

    final bounds = menuBounds;
    if (bounds == null) return null;

    const horizontalSlop = 140.0;
    if (globalPosition.dx < bounds.left - horizontalSlop ||
        globalPosition.dx > bounds.right + horizontalSlop) {
      return null;
    }

    for (var i = 0; i < rowRects.length; i++) {
      final row = rowRects[i];
      if (globalPosition.dy >= row.top && globalPosition.dy <= row.bottom) {
        return i;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final actions = _actions;
    final selectedIndex = _selectedIndex;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? const Color(0xFF1D1D1F) : Colors.white;
    final highlightColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.07);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 188, maxWidth: 240),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _pointerActive = true;
          _selectAtPosition(event.position, haptic: false);
        },
        onPointerMove: (event) {
          if (!_pointerActive) return;
          _selectAtPosition(event.position);
        },
        onPointerUp: (event) {
          if (!_pointerActive) return;
          final index = _hitTest(event.position);
          _selectIndex(index, haptic: false);
          _pointerActive = false;
          _activateSelected(index);
        },
        onPointerCancel: (_) {
          _pointerActive = false;
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: actions.length * _peekMenuItemHeight,
              child: Stack(
                children: [
                  if (selectedIndex != null)
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 130),
                      curve: Curves.easeOutCubic,
                      left: 5,
                      right: 5,
                      top: selectedIndex * _peekMenuItemHeight + 4,
                      height: _peekMenuItemHeight - 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: highlightColor,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < actions.length; i++)
                        _PeekMenuItemTile(
                          key: _itemKeys[i],
                          action: actions[i],
                          selected: selectedIndex == i,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PeekMenuItemTile extends StatelessWidget {
  final _PeekMenuAction action;
  final bool selected;

  const _PeekMenuItemTile({
    super.key,
    required this.action,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = action.danger
        ? Colors.redAccent
        : (isDark ? Colors.white : Colors.black87);
    final fontWeight = selected ? FontWeight.w700 : FontWeight.w500;

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        height: _peekMenuItemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(action.icon, color: color, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: fontWeight,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Содержимое карточки предпросмотра: лента последних сообщений без шапки и без поля ввода.
/// Рисуется теми же «бабблами», что и в чате (ChatMessageList), взаимодействия отключены.
class _ChatPeekSheet extends StatefulWidget {
  final double width;
  final double height;
  final Team team;
  final String? chatId; // DM: реальный chatId
  final bool isDm; // признак ЛС
  final bool pinned;
  final bool muted;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleMute;
  final VoidCallback onMarkRead;
  final VoidCallback onOpenChat;

  const _ChatPeekSheet({
    required this.width,
    required this.height,
    required this.team,
    this.chatId,
    this.isDm = false,
    required this.pinned,
    required this.muted,
    required this.onTogglePin,
    required this.onToggleMute,
    required this.onMarkRead,
    required this.onOpenChat,
  });

  @override
  State<_ChatPeekSheet> createState() => _ChatPeekSheetState();
}

class _ChatPeekSheetState extends State<_ChatPeekSheet> {
  final _repo = SupabaseLearningRepository();
  final _scroll = ScrollController();
  final ChatSearchController _search = ChatSearchController();
  List<Message> _messages = const [];
  bool _loading = true;
  // Граница «видел до» и флаг показа чипа «Новые сообщения» — фиксируем на момент открытия превью
  DateTime? _entrySeenAt;
  bool _showEntryNewBadge = false;

  Future<String?> _resolveChatId() async {
    final id = widget.chatId;
    if (id != null && id.isNotEmpty) return id;
    try {
      final res = await Supabase.instance.client
          .from('chats')
          .select('id')
          .eq('team_id', widget.team.id)
          .eq('type', 'team_main')
          .limit(1)
          .maybeSingle();
      if (res != null && res is Map) {
        final chatId = (res['id'] ?? '').toString();
        if (chatId.isNotEmpty) return chatId;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _hydrateFromSharedCache(String? chatId) async {
    if (chatId == null || chatId.isEmpty) return;
    final snap = await ChatMessageCacheStore.read(chatId);
    if (!snap.found || !mounted) return;
    final messages = snap.messages;
    setState(() {
      _messages = messages.length > 30
          ? messages.sublist(messages.length - 30)
          : messages;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 1), _jumpToBottom);
    });
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;

    // Для reverse-списка «низ» = minScrollExtent, иначе — maxScrollExtent
    final bool isReversed = pos.axisDirection == AxisDirection.up ||
        pos.axisDirection == AxisDirection.left;

    final double target =
        isReversed ? pos.minScrollExtent : pos.maxScrollExtent;

    _scroll.jumpTo(target);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final chatId = await _resolveChatId();
      await _hydrateFromSharedCache(chatId);

      List<Message> msgs;
      if (widget.isDm && (chatId?.isNotEmpty ?? false)) {
        final result = await DmApi.syncLatest(chatId: chatId!, limit: 30);
        msgs = result.ok
            ? result.messages
            : ChatMessageCacheStore.messagesSync(chatId);
      } else {
        msgs = await _repo.loadChat(widget.team.id);
        msgs.sort((a, b) => a.at.compareTo(b.at));
        if (chatId != null && chatId.isNotEmpty) {
          await ChatMessageCacheStore.applyLatestServerPage(
            chatId: chatId,
            serverPage: msgs,
            pageLimit: 30,
          );
        }
      }

      msgs.sort((a, b) => a.at.compareTo(b.at));
      final last = msgs.length > 30 ? msgs.sublist(msgs.length - 30) : msgs;

      DateTime? boundary;
      bool showBadge = false;

      if (chatId != null && chatId.isNotEmpty) {
        try {
          final unreadRes = await Supabase.instance.client
              .rpc('get_unread_in_chat', params: {'p_chat_id': chatId});

          int unreadCount = 0;
          String? firstUnreadId;

          if (unreadRes is List && unreadRes.isNotEmpty) {
            final m = Map<String, dynamic>.from(unreadRes.first as Map);
            unreadCount = (m['unread_count'] ?? 0) as int;
            firstUnreadId = (m['first_unread_id'] ?? '')?.toString();
          } else if (unreadRes is Map) {
            final m = Map<String, dynamic>.from(unreadRes);
            unreadCount = (m['unread_count'] ?? 0) as int;
            firstUnreadId = (m['first_unread_id'] ?? '')?.toString();
          }

          showBadge = unreadCount > 0;

          if (showBadge &&
              (firstUnreadId != null && firstUnreadId.isNotEmpty)) {
            final idx = last.indexWhere((m) => m.id == firstUnreadId);
            if (idx != -1) {
              boundary = last[idx]
                  .at
                  .toUtc()
                  .subtract(const Duration(microseconds: 1));
            }
          }
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _messages = last;
        _loading = false;
        _entrySeenAt = boundary;
        _showEntryNewBadge = showBadge;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 1), _jumpToBottom);
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 14,
        shadowColor: Colors.black.withOpacity(.3),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onOpenChat();
          },
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: _loading
                ? const _SkeletonList()
                : AbsorbPointer(
                    absorbing:
                        true, // взаимодействия внутри списка по-прежнему отключены
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                      child: MediaQuery(
                        // В превью карточке считаем ширину бабблов от ширины карточки,
                        // а не всего экрана, чтобы исключить горизонтальный overflow
                        data: MediaQuery.of(context).copyWith(
                          size: Size(widget.width - 40,
                              MediaQuery.of(context).size.height),
                        ),
                        child: ChatMessageList(
                          messages: _messages,
                          controller: _scroll,
                          messageKeys: <String, GlobalKey>{},
                          boundaryKeys: <String, GlobalKey>{},
                          search: _search,
                          currentUserId:
                              Supabase.instance.client.auth.currentUser?.id,
                          entrySeenAt: _entrySeenAt,
                          showEntryNewBadge: _showEntryNewBadge,
                          onReply: (_) {},
                          onLongPress: (_, __, ___, ____, _____, ______) {},
                          onReplyTap: (_) {},
                          onReact: (_, __) {},
                          selectingMessages: false,
                          selectedMessageIds: const <String>{},
                          onToggleSelect: (_) {},
                          hideSenderIdentity: widget.isDm,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
