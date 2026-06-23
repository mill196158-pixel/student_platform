import 'dart:convert';
import 'dart:math' as math;
import 'dart:async'; // ← for Timer
import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:student_platform/src/ui/chats/core/i_chat_service.dart'
    show ChatMode;
import 'package:student_platform/src/ui/chats/forward/forward_picker.dart'
    show ForwardTarget;
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/widgets.dart'; // ChatMessageList
import 'package:student_platform/src/ui/learning/models/message.dart'; // модель сообщения
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';

class MyChatsScreen extends StatefulWidget {
  const MyChatsScreen({super.key, this.pickMode = false});
  final bool pickMode;
  @override
  State<MyChatsScreen> createState() => _MyChatsScreenState();
}

class _MyChatsScreenState extends State<MyChatsScreen> {
  final _repo = SupabaseLearningRepository();
  bool _loading = true;

  List<_ChatSummary> _all = [];
  List<_ChatSummary> _visible = [];
  String _query = '';

  RealtimeChannel? _channel; // общий канал с несколькими фильтрами
  Timer? _pollTimer; // ➜ NEW
  static const _pollEvery = Duration(seconds: 3); // ➜ NEW
  bool _pollInFlight = false; // ➜ NEW: защита от гонок

  bool _hydrated = false; // есть ли быстрый кеш на старте
  Timer? _searchDebounce;
  Timer? _filterDebounce; // ➜ NEW: дебаунс фильтра
  StreamSubscription? _sub; // ➜ NEW: на случай подписки

  // универсальный безопасный setState
  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  static const _cacheKey = 'my_chats_cache_v1';
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
    } catch (e) {
      debugPrint('[MyChatsScreen] mark read RPC error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _hydrateFromCache(); // мгновенно показываем старый список
    _load(); // параллельно тянем актуальные данные
    // ➜ NEW: запуск поллера сразу и мгновенный первый опрос
    _startPolling();
    // ignore: discarded_futures
    _pollOnce();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _channel?.unsubscribe();
    _searchDebounce?.cancel();
    _filterDebounce?.cancel();
    _sub?.cancel();
    _searchDebounce = null;
    _filterDebounce = null;
    _sub = null;
    super.dispose();
  }

  Future<void> _load() async {
    _safeSetState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user');
      String group = '';
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        group = (m['group_name'] ?? '') as String;
      }
      if (group.isEmpty) {
        setState(() {
          _all = [];
          _visible = [];
          _loading = false;
        });
        return;
      }

      // команды пользователя = наши чаты
      final teams = await _repo.loadTeams(group);

      // сводки по чатам (реальное lastMsg/lastTime из репозитория)
      final teamSummaries = await Future.wait(teams.map(_buildSummaryForTeam));

      // подкачиваем ЛС
      final dmSummaries = await _loadDms();

      // общий список
      final list = <_ChatSummary>[...teamSummaries, ...dmSummaries]
        ..sort(_compareChats);

      if (!mounted) return;
      _safeSetState(() {
        _all = list;
        _applyFilter();
        _loading = false;
      });
      _saveCache(_all); // сохранить кеш после загрузки

      // _subscribeRealtime(list); // realtime disabled
      _startPolling(); // ➜ NEW
      await _pollOnce(); // ➜ NEW: мгновенный опрос после наполнения списка
    } catch (_) {
      _safeSetState(() => _loading = false);
    }
  }

  int _compareChats(_ChatSummary a, _ChatSummary b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1; // закреплённые выше
    final aa = a.lastTime ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bb = b.lastTime ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bb.compareTo(aa); // новые выше
  }

  // ===== DM list loader =====
  Future<List<_ChatSummary>> _loadDms() async {
    try {
      final sb = Supabase.instance.client;
      final me = sb.auth.currentUser?.id;
      if (me == null || me.isEmpty) return const [];

      // Debug: show raw membership
      final test = await sb
          .from('chat_members')
          .select('chat_id, user_id')
          .eq('user_id', me);
      safeDebugLog(
          '[MyChatsScreen] DM memberships loaded user=${maskDebugId(me)} count=${(test as List? ?? const []).length}');

      final chatIds = (test as List? ?? const [])
          .map((r) => (r['chat_id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList();
      if (chatIds.isEmpty) return const [];

      // Fetch chats for these ids and keep only dm
      final chatsRes =
          await sb.from('chats').select('id,type').inFilter('id', chatIds);
      final dmIds = (chatsRes as List? ?? const [])
          .where((c) => ((c['type'] ?? '').toString() == 'dm'))
          .map((c) => (c['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      safeDebugLog('[MyChatsScreen] DM chat ids loaded count=${dmIds.length}');
      if (dmIds.isEmpty) return const [];

      final list = <_ChatSummary>[];
      for (final chatId in dmIds) {
        // DM peer profile via RPC
        String peerId = '';
        String title = 'Личный чат';
        String? avatarUrl;
        try {
          final prof = await sb
              .rpc('get_dm_peer_profile', params: {'p_chat_id': chatId});
          Map<String, dynamic>? row;
          if (prof is List && prof.isNotEmpty) {
            row = Map<String, dynamic>.from(prof.first as Map);
          } else if (prof is Map) {
            row = Map<String, dynamic>.from(prof);
          }
          if (row != null) {
            peerId = (row['peer_id'] ?? '').toString();
            final t = (row['title'] ?? '').toString().trim();
            if (t.isNotEmpty) title = t;
            final av = (row['avatar_url'] ?? '').toString().trim();
            if (av.isNotEmpty) avatarUrl = av;
          }
        } catch (_) {}

        if (peerId.isEmpty) {
          // без peerId нельзя открыть DirectChatScreen — скипаем
          continue;
        }

        // last message row
        DateTime? lastAt;
        String? lastMessageId;
        String? lastPreview;
        try {
          final res = await sb
              .rpc('get_last_message_row', params: {'p_chat_id': chatId});
          Map<String, dynamic>? row;
          if (res is List && res.isNotEmpty) {
            row = Map<String, dynamic>.from(res.first as Map);
          } else if (res is Map) {
            row = Map<String, dynamic>.from(res);
          }
          if (row != null) {
            lastMessageId = (row['id'] ?? '').toString();
            lastAt = DateTime.tryParse((row['created_at'] ?? '').toString());
            lastPreview = _buildPreviewFromRow(row);
          }
        } catch (_) {}

        // unread count
        int unread = 0;
        try {
          final res =
              await sb.rpc('get_unread_in_chat', params: {'p_chat_id': chatId});
          if (res is List && res.isNotEmpty) {
            final m = Map<String, dynamic>.from(res.first as Map);
            unread = (m['unread_count'] ?? 0) as int;
          } else if (res is Map) {
            final m = Map<String, dynamic>.from(res);
            unread = (m['unread_count'] ?? 0) as int;
          }
        } catch (_) {}

        list.add(_ChatSummary(
          team: Team(
              id: '',
              name: title.isEmpty ? 'Личный чат' : title,
              icon: '',
              teacher: '',
              groupCode: ''),
          title: title.isEmpty ? 'Личный чат' : title,
          subtitle: null,
          lastAuthor: null,
          lastMsgPreview: lastPreview ?? 'Сообщений пока нет',
          lastTime: lastAt,
          unread: unread,
          pinned: false,
          muted: false,
          chatId: chatId,
          lastMessageId:
              (lastMessageId?.isNotEmpty ?? false) ? lastMessageId : null,
          isDm: true,
          peerId: peerId,
          avatarUrl: avatarUrl,
        ));
      }

      safeDebugLog('[MyChatsScreen] DM summaries ready count=${list.length}');
      return list;
    } catch (e) {
      debugPrint('[DM] _loadDms error: $e');
      return const [];
    }
  }

  void _togglePinChat(_ChatSummary c) {
    setState(() {
      final idx = _all.indexWhere((e) => e.chatId == c.chatId);
      if (idx != -1) {
        _all[idx].pinned = !_all[idx].pinned;
        safeDebugLog(
            '[MyChatsScreen] togglePin chat=${maskDebugId(c.chatId)} pinned=${_all[idx].pinned}');
        _all.sort(_compareChats);
        _applyFilter();
      }
    });
  }

  // ===== realtime by chat_id (фильтры на уровне сервера) =====
  // ➜ NEW: polling instead of realtime
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollEvery, (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (_pollInFlight) return; // ➜ NEW: анти-дубль
    _pollInFlight = true; // ➜ NEW
    final ids = _all
        .map((e) => e.chatId)
        .where((id) => id != null && id!.isNotEmpty)
        .cast<String>()
        .toList();
    if (ids.isEmpty) {
      _pollInFlight = false;
      return;
    }

    final sb = Supabase.instance.client;
    final futures = <Future>[];

    for (final id in ids) {
      futures.add(sb
          .rpc('get_unread_in_chat', params: {'p_chat_id': id}).catchError((e) {
        safeDebugLog(
            '[poll] get_unread_in_chat failed chat=${maskDebugId(id)} error=${e.runtimeType}');
        return null;
      }).then((res) {
        int unread = 0;
        if (res is List && res.isNotEmpty) {
          final m = Map<String, dynamic>.from(res.first as Map);
          unread = (m['unread_count'] ?? 0) as int;
        } else if (res is Map) {
          final m = Map<String, dynamic>.from(res);
          unread = (m['unread_count'] ?? 0) as int;
        }
        final idx = _all.indexWhere((e) => e.chatId == id);
        if (idx != -1) _all[idx].unread = unread;
      }).catchError((_) {}));

      futures.add(sb.rpc('get_last_message_row',
          params: {'p_chat_id': id}).then((res) async {
        Map<String, dynamic>? row;
        if (res is List && res.isNotEmpty) {
          row = Map<String, dynamic>.from(res.first as Map);
        } else if (res is Map) {
          row = Map<String, dynamic>.from(res);
        }
        if (row == null) return;
        final lastId = (row['id'] ?? '').toString();
        final createdAt =
            DateTime.tryParse((row['created_at'] ?? '').toString());
        String authorName = '';
        final authorId = (row['author_id'] ?? '').toString();
        if (authorId.isNotEmpty) {
          try {
            final u = await sb
                .from('users')
                .select('name,surname')
                .eq('id', authorId)
                .maybeSingle();
            if (u != null && u is Map) {
              final name = (u['name'] ?? '').toString();
              final sur = (u['surname'] ?? '').toString();
              authorName =
                  [name, sur].where((s) => s.isNotEmpty).join(' ').trim();
            }
          } catch (_) {}
        }
        final idx = _all.indexWhere((e) => e.chatId == id);
        if (idx != -1) {
          final c = _all[idx];
          final isNewMessage =
              (lastId.isNotEmpty && lastId != (c.lastMessageId ?? ''));
          final isNewerTime = (c.lastTime == null ||
              (createdAt != null && createdAt.isAfter(c.lastTime!)));
          if (isNewMessage || isNewerTime) {
            c.lastMessageId = lastId;
            c.lastTime = createdAt ?? c.lastTime;
            safeDebugLog(
                '[poll/messages] updated chat=${maskDebugId(id)} message=${maskDebugId(lastId)}');
            c.lastMsgPreview = _buildPreviewFromRow(row);
            if (authorName.isNotEmpty) c.lastAuthor = authorName;
          }
        }
      }).catchError((e) {
        safeDebugLog(
            '[poll/messages] failed chat=${maskDebugId(id)} error=${e.runtimeType}');
      }));
    }

    await Future.wait(futures);

    if (!mounted) {
      _pollInFlight = false;
      return;
    }
    setState(() {
      _all.sort(_compareChats);
      _applyFilter();
    });
    _saveCache(_all);
    _pollInFlight = false; // ➜ NEW
  }

  // сводка для одной команды
  Future<_ChatSummary> _buildSummaryForTeam(Team t) async {
    final seed = _hash32(t.name);

    String? lastText;
    String? lastAuthor;
    DateTime? lastAt;
    String? chatId;
    String? lastMessageId; // ➜ NEW

    try {
      // chat id
      try {
        final res = await Supabase.instance.client
            .from('chats')
            .select('id')
            .eq('team_id', t.id)
            .eq('type', 'team_main')
            .limit(1)
            .maybeSingle();
        if (res != null && res is Map) {
          chatId = (res['id'] ?? '').toString();
        }
      } catch (_) {}

      // ➜ NEW: тянем только последний ряд и строим превью (через RPC, мимо RLS)
      if (chatId != null && chatId!.isNotEmpty) {
        final sb = Supabase.instance.client;
        final res = await sb.rpc('get_last_message_row',
            params: {'p_chat_id': chatId}).catchError((e) {
          safeDebugLog(
              '[summary/messages] failed chat=${maskDebugId(chatId)} error=${e.runtimeType}');
          return null;
        });
        Map<String, dynamic>? lastRow;
        if (res is List && res.isNotEmpty) {
          lastRow = Map<String, dynamic>.from(res.first as Map);
        } else if (res is Map) {
          lastRow = Map<String, dynamic>.from(res);
        }
        if (lastRow != null) {
          lastAt = DateTime.tryParse((lastRow['created_at'] ?? '').toString());
          lastText = _buildPreviewFromRow(lastRow);
          lastMessageId = (lastRow['id'] ?? '').toString();
          final authorId = (lastRow['author_id'] ?? '').toString();
          if (authorId.isNotEmpty) {
            try {
              final u = await sb
                  .from('users')
                  .select('name,surname')
                  .eq('id', authorId)
                  .maybeSingle();
              if (u != null && u is Map) {
                final name = (u['name'] ?? '').toString();
                final sur = (u['surname'] ?? '').toString();
                lastAuthor =
                    [name, sur].where((s) => s.isNotEmpty).join(' ').trim();
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    int unread = 0; // ➜ NEW
    try {
      if (chatId != null && chatId!.isNotEmpty) {
        final res = await Supabase.instance.client
            .rpc('get_unread_in_chat', params: {'p_chat_id': chatId});
        if (res is List && res.isNotEmpty) {
          final m = Map<String, dynamic>.from(res.first as Map);
          unread = (m['unread_count'] ?? 0) as int;
        } else if (res is Map) {
          final m = Map<String, dynamic>.from(res);
          unread = (m['unread_count'] ?? 0) as int;
        }
      }
    } catch (_) {}

    return _ChatSummary(
      team: t,
      title: t.name,
      subtitle: t.teacher.isNotEmpty
          ? t.teacher
          : (t.groupCode.isNotEmpty ? t.groupCode : null),
      lastAuthor: lastAuthor,
      lastMsgPreview: lastText ?? 'Сообщений пока нет',
      lastTime: lastAt,
      unread: unread,
      pinned: false,
      muted: false,
      chatId: chatId,
      lastMessageId: (lastMessageId != null && lastMessageId!.isNotEmpty)
          ? lastMessageId
          : null,
    );
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
        title: const Text('Чаты'),
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
                                      ),
                                    ),
                                  ),
                                );
                                if (c.chatId != null && c.chatId!.isNotEmpty) {
                                  await _refreshUnreadFor(c.chatId!);
                                }
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

                              // ➜ NEW: после возврата обновим unread для этого чата
                              String? chatId = c.chatId;
                              if (chatId == null || chatId.isEmpty) {
                                try {
                                  final res = await Supabase.instance.client
                                      .from('chats')
                                      .select('id')
                                      .eq('team_id', c.team.id)
                                      .eq('type', 'team_main')
                                      .limit(1)
                                      .maybeSingle();
                                  if (res != null && res is Map) {
                                    chatId = (res['id'] ?? '').toString();
                                    if (mounted) {
                                      _safeSetState(() {
                                        final idx = _all.indexWhere(
                                            (e) => e.team.id == c.team.id);
                                        if (idx != -1)
                                          _all[idx].chatId = chatId;
                                      });
                                    }
                                  }
                                } catch (_) {}
                              }
                              if (chatId != null && chatId.isNotEmpty) {
                                await _refreshUnreadFor(chatId);
                              }
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

              // ↓↓↓ ОЦЕНКА высоты КОНТЕКСТНОГО МЕНЮ (чёрная плашка)
              // чтобы под превью было место и ничего не «выпирало»
              const double kMenuEst = 260.0; // ~высота списка действий
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
                          setState(() {
                            final idx =
                                _all.indexWhere((e) => e.chatId == c.chatId);
                            if (idx != -1) _all[idx].muted = !_all[idx].muted;
                            _applyFilter();
                          });
                          Navigator.of(context).pop();
                        },
                        onMarkRead: () async {
                          if (c.chatId != null && c.chatId!.isNotEmpty) {
                            await _markChatReadServerSide(c.chatId!);
                            await _refreshUnreadFor(c.chatId!);
                          } else {
                            setState(() {
                              final idx = _all
                                  .indexWhere((e) => e.team.id == c.team.id);
                              if (idx != -1) _all[idx].unread = 0;
                              _applyFilter();
                            });
                          }
                          Navigator.of(context).pop();
                        },
                        onOpenChat: () {
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => TeamDetailsScreen(
                                team: c.team,
                                initialTabIndex: 1,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  // ЧЁРНОЕ всплывающее меню: ПОД превью и СДВИНУТО ВПРАВО
                  Positioned(
                    // ставим ровно под карточку
                    top: topOffset + previewH + kGapPreviewToMenu,
                    // правый край выравниваем по правому краю карточки
                    right: sideGap,
                    child: _PeekContextMenu(
                      pinned: c.pinned,
                      onReply: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TeamDetailsScreen(
                              team: c.team,
                              initialTabIndex: 1,
                            ),
                          ),
                        );
                      },
                      onCopy: () {
                        HapticFeedback.selectionClick();
                        debugPrint('[MyChatsScreen] preview: copy action');
                      },
                      onTogglePin: () {
                        _togglePinChat(c);
                        Navigator.of(context).pop();
                      },
                      onForward: () {
                        HapticFeedback.selectionClick();
                        debugPrint('[MyChatsScreen] preview: forward action');
                      },
                      onDelete: () {
                        HapticFeedback.mediumImpact();
                        debugPrint(
                            '[MyChatsScreen] preview: delete action (no-op)');
                      },
                      onSelect: () {
                        HapticFeedback.selectionClick();
                        debugPrint(
                            '[MyChatsScreen] preview: select action (no-op)');
                      },
                    ),
                  ),

                  // ❌ НИЖНЮЮ ПАНЕЛЬ ДЕЙСТВИЙ УБИРАЕМ — больше не нужна
                ],
              );
            },
          ),
        );
      },
    );
  }

  int _hash32(String s) =>
      s.codeUnits.fold<int>(0, (p, e) => (p * 31 + e) & 0xFFFFFFFF);

  // ➜ NEW: билдер превью по ряду messages
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
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_cacheKey);
      if (s == null || s.isEmpty) return;
      final raw = (jsonDecode(s) as List).cast<Map<String, dynamic>>();
      final list = raw.map(_summaryFromMap).toList()..sort(_compareChats);
      setState(() {
        _all = list;
        _applyFilter();
        _hydrated = true;
        _loading = false; // сразу показываем список, без скелетона
      });
    } catch (_) {}
  }

  Future<void> _saveCache(List<_ChatSummary> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = jsonEncode(list.map(_summaryToMap).toList());
      await prefs.setString(_cacheKey, data);
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
    return _ChatSummary(
      team: t,
      title: (m['title'] ?? '') as String,
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
      isDm: (m['isDm'] ?? false) as bool,
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
  final String title;
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
  final String? avatarUrl;

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
        (t.bodyMedium?.color ?? Colors.black).withOpacity(0.72);

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
                          color: onSurfaceVar,
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
                            color: onSurfaceVar,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      const SizedBox(height: 6),
                      if (data.unread > 0)
                        _UnreadBadge(count: data.unread)
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
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final txt = count > 999 ? '999+' : '$count';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
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

/// Всплывающее контекстное меню «как в чат tab / iMessage»
class _PeekContextMenu extends StatelessWidget {
  final bool pinned;
  final VoidCallback onReply;
  final VoidCallback onCopy;
  final VoidCallback onTogglePin;
  final VoidCallback onForward;
  final VoidCallback onDelete;
  final VoidCallback onSelect;

  const _PeekContextMenu({
    required this.pinned,
    required this.onReply,
    required this.onCopy,
    required this.onTogglePin,
    required this.onForward,
    required this.onDelete,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = Colors.black.withOpacity(0.92);
    final text = Colors.white.withOpacity(.95);
    final textMuted = Colors.white.withOpacity(.85);
    final divider = Colors.white.withOpacity(.12);

    Widget item(IconData icon, String label, VoidCallback onTap,
        {Color? color}) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color ?? textMuted),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color ?? text,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget sep() => Container(height: 1, color: divider);

    return IntrinsicWidth(
      stepWidth: 0,
      child: Material(
        color: bg,
        elevation: 18,
        shadowColor: Colors.black.withOpacity(.45),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            item(Icons.reply_rounded, 'Ответить', onReply),
            sep(),
            item(Icons.copy_rounded, 'Скопировать', onCopy),
            sep(),
            item(pinned ? Icons.push_pin : Icons.push_pin_outlined,
                pinned ? 'Открепить' : 'Закрепить', onTogglePin),
            sep(),
            item(Icons.forward_to_inbox_rounded, 'Переслать', onForward),
            sep(),
            item(Icons.delete_rounded, 'Удалить', onDelete,
                color: Colors.redAccent),
            sep(),
            item(Icons.check_rounded, 'Выбрать', onSelect),
          ],
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
      List<Message> msgs;

      if (widget.isDm && (widget.chatId?.isNotEmpty ?? false)) {
        // ===== DM: грузим сообщения напрямую по chat_id =====
        final sb = Supabase.instance.client;

        String rowPreview(Map m) {
          final body = (m['body'] ?? '').toString().trim();
          if (body.isNotEmpty) return body;
          final content = m['content'];
          if (content is String && content.isNotEmpty) {
            try {
              final decoded = jsonDecode(content);
              if (decoded is Map && decoded['text'] != null) {
                final t = decoded['text'].toString().trim();
                if (t.isNotEmpty) return t;
              }
            } catch (_) {
              return content.trim();
            }
          } else if (content is Map) {
            final t = (content['text'] ?? '').toString().trim();
            if (t.isNotEmpty) return t;
          }
          final msgType = (m['msg_type'] ?? '').toString();
          if (msgType == 'file' || msgType == 'image') return '📎 Вложение';
          return 'Сообщение';
        }

        Future<String> authorName(String authorId) async {
          try {
            final u = await sb
                .from('users')
                .select('name,surname,login')
                .eq('id', authorId)
                .maybeSingle();
            if (u != null && u is Map) {
              final name = (u['name'] ?? '').toString();
              final sur = (u['surname'] ?? '').toString();
              final full =
                  [name, sur].where((s) => s.isNotEmpty).join(' ').trim();
              if (full.isNotEmpty) return full;
              final login = (u['login'] ?? '').toString();
              if (login.isNotEmpty) return login;
            }
          } catch (_) {}
          return 'Пользователь';
        }

        final rows = await sb
            .from('messages')
            .select(
                'id, chat_id, author_id, created_at, body, content, msg_type')
            .eq('chat_id', widget.chatId!)
            .order('created_at', ascending: true)
            .limit(60);

        msgs = [];
        for (final r in (rows as List)) {
          final m = r as Map<String, dynamic>;
          final id = (m['id'] ?? '').toString();
          final chatId = (m['chat_id'] ?? '').toString();
          final aid = (m['author_id'] ?? '').toString();
          final at = DateTime.tryParse((m['created_at'] ?? '').toString()) ??
              DateTime.now();
          final text = rowPreview(m);
          final aname = await authorName(aid);

          msgs.add(Message(
            id: id,
            chatId: chatId,
            authorId: aid,
            authorLogin: '',
            authorName: aname,
            text: text,
            at: at,
          ));
        }
      } else {
        // ===== Группа: как было через репозиторий =====
        msgs = await _repo.loadChat(widget.team.id);
        msgs.sort((a, b) => a.at.compareTo(b.at));
      }

      // последние 30
      msgs.sort((a, b) => a.at.compareTo(b.at));
      final last = msgs.length > 30 ? msgs.sublist(msgs.length - 30) : msgs;

      // --- граница «Новые сообщения» ---
      DateTime? boundary;
      bool showBadge = false;

      String? chatId = widget.chatId;
      if (chatId == null || chatId.isEmpty) {
        // для групп получаем chatId по team_id
        try {
          final res = await Supabase.instance.client
              .from('chats')
              .select('id')
              .eq('team_id', widget.team.id)
              .eq('type', 'team_main')
              .limit(1)
              .maybeSingle();
          if (res != null && res is Map) {
            chatId = (res['id'] ?? '').toString();
          }
        } catch (_) {}
      }

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
