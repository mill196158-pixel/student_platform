import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/chats/data/blocks_api.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';

/// Гостевой профиль пользователя.
/// Показывает: аватар, ФИО, вуз, группу, статус.
/// Метрики: Рейтинг (пока "—"), Друзья (кол-во).
/// Главное действие: "Добавить в друзья" / "У вас в друзьях!" / "Заявка отправлена".
///
/// Зависимости по БД (все безопасно через try/catch):
/// - public.users (id, name, surname, avatar_url, status, university, group_name)
/// - friend_requests (from_id, to_id, created_at) — опционально
/// - friends (user_id, friend_id, created_at) — опционально
///
/// Навигация: FriendProfileScreen(userId: '...')

class FriendProfileScreen extends StatefulWidget {
  final String userId;
  const FriendProfileScreen({super.key, required this.userId});

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  final _sb = Supabase.instance.client;

  Map<String, dynamic>? _guest; // данные пользователя
  String? _myId;

  bool _loading = true;
  bool _error = false;

  // друзья гостя для списка
  List<_MiniUser> _friends = [];

  // состояние дружбы со мной
  _FriendshipState _state = _FriendshipState.unknown;
  bool _friendActionBusy = false;

  // блокировка (отдельно от дружбы)
  bool _iBlocked = false;
  bool _blockActionBusy = false;

  // прокрутка и якорь «Друзья»
  final ScrollController _scroll = ScrollController();
  final _friendsKey = GlobalKey();
  RealtimeChannel? _friendsChannel;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _friendsChannel?.unsubscribe();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      // кто я
      _myId = _sb.auth.currentUser?.id;
      if (_myId == null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final userJson = prefs.getString('user');
          if (userJson != null) {
            final me = jsonDecode(userJson) as Map<String, dynamic>;
            _myId = (me['id'] ?? '').toString();
          }
        } catch (_) {}
      }

      // гость — через SECURITY DEFINER RPC, обходящий RLS
      final res =
          await _sb.rpc('get_user_profile', params: {'p_id': widget.userId});
      Map<String, dynamic>? g;
      if (res is List) {
        if (res.isNotEmpty) g = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        g = Map<String, dynamic>.from(res);
      }

      if (g == null) {
        setState(() {
          _loading = false;
          _error = true;
        });
        return;
      }

      _guest = g;
      await Future.wait([
        _loadFriendshipStateSafe(),
        _loadGuestFriendsSafe(),
        _loadBlockStateSafe(),
      ]);

      setState(() {
        _loading = false;
        _error = false;
      });
      _subscribeFriendsRealtime();
    } catch (_) {
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  void _subscribeFriendsRealtime() {
    _friendsChannel?.unsubscribe();
    final other = widget.userId;

    _friendsChannel = _sb
        .channel('public:friends:for:$other')
        // INSERT: когда у гостя появляется новый друг
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: other,
          ),
          callback: (_) async => _onFriendsChangedRealtime(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'friend_id',
            value: other,
          ),
          callback: (_) async => _onFriendsChangedRealtime(),
        )
        // DELETE: когда у гостя удаляют друга
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: other,
          ),
          callback: (_) async => _onFriendsChangedRealtime(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'friend_id',
            value: other,
          ),
          callback: (_) async => _onFriendsChangedRealtime(),
        )
        .subscribe();
  }

  Future<void> _onFriendsChangedRealtime() async {
    await _loadFriendshipStateSafe();
    await _loadGuestFriendsSafe();
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await _bootstrap();
  }

  // --- FRIENDSHIP STATE ---

  Future<void> _loadFriendshipStateSafe() async {
    try {
      await _loadFriendshipState();
    } catch (_) {
      // если таблиц нет — просто покажем состояние как "unknown" → кнопка "Добавить в друзья"
      if (mounted) setState(() => _state = _FriendshipState.none);
    }
  }

  Future<void> _loadFriendshipState() async {
    final me = _myId;
    final other = widget.userId;
    if (me == null || me.isEmpty || other.isEmpty) {
      _state = _FriendshipState.none;
      return;
    }

    // 1) уже друзья? (таблица friends может не существовать)
    try {
      final fr = await _sb
          .from('friends')
          .select('user_id, friend_id')
          .or('and(user_id.eq.$me,friend_id.eq.$other),and(user_id.eq.$other,friend_id.eq.$me)')
          .limit(1);
      if (fr is List && fr.isNotEmpty) {
        _state = _FriendshipState.friends;
        return;
      }
    } catch (_) {
      // таблицы нет — идём дальше
    }

    // 2) исходящая заявка?
    try {
      final out = await _sb
          .from('friend_requests')
          .select('from_id')
          .eq('from_id', me)
          .eq('to_id', other)
          .limit(1);
      if (out is List && out.isNotEmpty) {
        _state = _FriendshipState.requestSent;
        return;
      }
    } catch (_) {}

    // 3) входящая заявка?
    try {
      final inc = await _sb
          .from('friend_requests')
          .select('from_id')
          .eq('from_id', other)
          .eq('to_id', me)
          .limit(1);
      if (inc is List && inc.isNotEmpty) {
        _state = _FriendshipState.requestIncoming;
        return;
      }
    } catch (_) {}

    _state = _FriendshipState.none;
  }

  bool _beginFriendAction() {
    if (_friendActionBusy) return false;
    if (mounted) {
      setState(() => _friendActionBusy = true);
    } else {
      _friendActionBusy = true;
    }
    return true;
  }

  void _endFriendAction() {
    if (mounted) {
      setState(() => _friendActionBusy = false);
    } else {
      _friendActionBusy = false;
    }
  }

  void _showFriendActionError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _sendFriendRequest() async {
    final me = _myId;
    final other = widget.userId;
    if (me == null || me.isEmpty || me == other) return;
    if (!_beginFriendAction()) return;

    try {
      await _loadFriendshipState();
      if (_state != _FriendshipState.none) {
        if (mounted) setState(() {});
        return;
      }
      await _sb.rpc(
        'send_friend_request',
        params: {'p_user_id': other},
      );
      await _onFriendsChangedRealtime();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _state == _FriendshipState.friends
                ? 'Теперь вы друзья'
                : 'Заявка отправлена',
          ),
        ),
      );
    } catch (e) {
      debugPrint('[FriendProfile] send request error: $e');
      _showFriendActionError('Не удалось отправить заявку');
    } finally {
      _endFriendAction();
    }
  }

  Future<void> _acceptFriendRequest() async {
    final me = _myId;
    final other = widget.userId;
    if (me == null || me.isEmpty || other.isEmpty) return;
    if (!_beginFriendAction()) return;

    try {
      await _sb.rpc(
        'accept_friend_request',
        params: {'p_user_id': other},
      );

      // локально обновим состояние и список + прокрутим к секции
      await _onFriendsChangedRealtime();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Теперь вы друзья')));

      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _friendsKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOut);
        }
      });
    } catch (e) {
      debugPrint('[FriendProfile] accept request error: $e');
      _showFriendActionError('Не удалось принять заявку');
    } finally {
      _endFriendAction();
    }
  }

  Future<void> _removeFriend() async {
    final me = _myId;
    final other = widget.userId;
    if (me == null || me.isEmpty || other.isEmpty) return;
    if (!_beginFriendAction()) return;

    try {
      await _sb.rpc(
        'remove_friend',
        params: {'p_user_id': other},
      );

      await _onFriendsChangedRealtime();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Удалено из друзей')));
    } catch (e) {
      debugPrint('[FriendProfile] remove friend error: $e');
      _showFriendActionError('Не удалось удалить');
    } finally {
      _endFriendAction();
    }
  }

  Future<void> _cancelFriendRequest() async {
    final me = _myId;
    final other = widget.userId;
    if (me == null || me.isEmpty || other.isEmpty) return;
    if (!_beginFriendAction()) return;

    try {
      await _sb.rpc(
        'cancel_friend_request',
        params: {'p_user_id': other},
      );
      await _onFriendsChangedRealtime();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Заявка отменена')));
    } catch (e) {
      debugPrint('[FriendProfile] cancel request error: $e');
      _showFriendActionError('Не удалось отменить заявку');
    } finally {
      _endFriendAction();
    }
  }

  Future<void> _declineIncomingRequest() async {
    final me = _myId;
    final other = widget.userId;
    if (me == null || me.isEmpty || other.isEmpty) return;
    if (!_beginFriendAction()) return;

    try {
      await _sb.rpc(
        'decline_friend_request',
        params: {'p_user_id': other},
      );
      await _onFriendsChangedRealtime();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Заявка отклонена')));
    } catch (e) {
      debugPrint('[FriendProfile] decline request error: $e');
      _showFriendActionError('Не удалось отклонить заявку');
    } finally {
      _endFriendAction();
    }
  }

  Future<void> _loadBlockStateSafe() async {
    final me = _myId;
    if (me == null || me.isEmpty || me == widget.userId) {
      _iBlocked = false;
      return;
    }
    try {
      final rel = await BlocksApi.getBlockRelationship(widget.userId);
      _iBlocked = rel.iBlocked;
    } catch (e) {
      debugPrint('[FriendProfile] get_block_relationship error: $e');
      _iBlocked = false;
    }
  }

  Future<void> _confirmAndBlock() async {
    if (_blockActionBusy || _myId == null || _myId == widget.userId) return;
    final g = _guest;
    final displayName = g == null ? '' : _fullName(g['name'], g['surname']);
    final titleName = displayName.isEmpty ? 'пользователя' : displayName;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        final text = Theme.of(ctx).textTheme;
        return AlertDialog(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(
            'Заблокировать $titleName?',
            style: text.titleMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            'Вы больше не сможете обмениваться личными сообщениями. '
            'В общих чатах его сообщения будут скрыты.',
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'Отмена',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Заблокировать'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;

    setState(() => _blockActionBusy = true);
    try {
      await BlocksApi.blockUser(widget.userId);
      if (!mounted) return;
      setState(() => _iBlocked = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Пользователь заблокирован')),
      );
    } catch (e) {
      debugPrint('[FriendProfile] block_user error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            BlocksApi.shortErrorMessage(e,
                fallback: 'Не удалось заблокировать'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _blockActionBusy = false);
    }
  }

  Future<void> _unblockUser() async {
    if (_blockActionBusy || _myId == null || _myId == widget.userId) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        final text = Theme.of(ctx).textTheme;
        return AlertDialog(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(
            'Разблокировать пользователя?',
            style: text.titleMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            'Вы снова сможете обмениваться личными сообщениями.',
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'Отмена',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Разблокировать'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;

    setState(() => _blockActionBusy = true);
    try {
      await BlocksApi.unblockUser(widget.userId);
      if (!mounted) return;
      setState(() => _iBlocked = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Пользователь разблокирован')),
      );
    } catch (e) {
      debugPrint('[FriendProfile] unblock_user error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            BlocksApi.shortErrorMessage(
              e,
              fallback: 'Не удалось разблокировать',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _blockActionBusy = false);
    }
  }

  Future<void> _openDirectChat() async {
    final me = _myId;
    if (me == null || me.isEmpty || me == widget.userId) return;

    final g = _guest;
    if (g == null) return;

    final peerName = _fullName(g['name'], g['surname']);
    final avatar = (g['avatar_url'] ?? '').toString();
    Widget screen = DirectChatScreen(
      peerId: widget.userId,
      peerName: peerName.isEmpty ? 'Личный чат' : peerName,
      peerAvatarUrl: avatar.isEmpty ? null : avatar,
    );

    try {
      screen = BlocProvider.value(
        value: context.read<TeamCubit>(),
        child: screen,
      );
    } catch (_) {
      // DirectChatScreen сам использует ensure_dm_chat; TeamCubit нужен только для экрана медиа по тапу на заголовок.
    }

    try {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => screen));
    } catch (e) {
      debugPrint('[FriendProfile] open DM error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            BlocksApi.isDmBlockedError(e)
                ? 'Личные сообщения недоступны'
                : BlocksApi.shortErrorMessage(
                    e,
                    fallback: 'Не удалось открыть чат',
                  ),
          ),
        ),
      );
    }
  }

  // --- GUEST FRIENDS LIST (или fallback на одногруппников) ---

  Future<void> _loadGuestFriendsSafe() async {
    try {
      await _loadGuestFriends();
    } catch (_) {
      _friends = [];
    }
  }

  Future<void> _loadGuestFriends() async {
    // ожидаем таблицу friends с полями (user_id, friend_id)
    final other = widget.userId;

    final pairs = await _sb
        .from('friends')
        .select('user_id, friend_id')
        .or('user_id.eq.$other,friend_id.eq.$other')
        .limit(200);

    final ids = <String>{};
    for (final r in pairs) {
      final a = (r['user_id'] ?? '').toString();
      final b = (r['friend_id'] ?? '').toString();
      if (a == other && b.isNotEmpty) ids.add(b);
      if (b == other && a.isNotEmpty) ids.add(a);
    }
    if (ids.isEmpty) {
      _friends = [];
      return;
    }

    final users = await _sb
        .from('users')
        .select('id, name, surname, avatar_url, university, group_name')
        .inFilter('id', ids.toList())
        .order('surname', ascending: true);

    _friends = users.map<_MiniUser>((r) {
      return _MiniUser(
        id: (r['id'] ?? '').toString(),
        name: (r['name'] ?? '').toString(),
        surname: (r['surname'] ?? '').toString(),
        avatarUrl: (r['avatar_url'] ?? '').toString(),
        university: (r['university'] ?? '').toString(),
        groupName: (r['group_name'] ?? '').toString(),
      );
    }).toList();
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Stack(
          children: [
            const Center(child: CircularProgressIndicator()),
            PositionedDirectional(
              start: 4,
              top: media.padding.top + 4,
              child: const _TopBackButton(),
            ),
          ],
        ),
      );
    }
    if (_error || _guest == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Stack(
          children: [
            Center(
              child: Text(
                'Пользователь не найден',
                style: TextStyle(color: colorScheme.onSurface),
              ),
            ),
            PositionedDirectional(
              start: 4,
              top: media.padding.top + 4,
              child: const _TopBackButton(),
            ),
          ],
        ),
      );
    }

    final g = _guest!;
    final fullName = _fullName(g['name'], g['surname']);
    final avatar = (g['avatar_url'] ?? '').toString();
    final university = (g['university'] ?? '').toString();
    final group = (g['group_name'] ?? '').toString();
    final status = (g['status'] ?? '').toString();

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                16,
                media.padding.top + 50,
                16,
                24 + media.padding.bottom,
              ),
              children: [
                _Header(
                  fullName: fullName.isEmpty ? 'Без имени' : fullName,
                  university: university,
                  groupName: group,
                  status: status,
                  avatarUrl: avatar.isEmpty ? null : avatar,
                ),
                const SizedBox(height: 15),

                // Главное действие: дружба
                if (_myId != null && _myId != widget.userId)
                  _FriendAction(
                    state: _state,
                    onAdd: _sendFriendRequest,
                    onAccept: _acceptFriendRequest,
                    onRemove: _removeFriend,
                    onCancelRequest: _cancelFriendRequest,
                    onDecline: _declineIncomingRequest,
                  ),
                if (_myId != null && _myId != widget.userId) ...[
                  const SizedBox(height: 10),
                  _GActionLarge(
                    onTap: _openDirectChat,
                    gradient: _gradBlue,
                    icon: Icons.chat_bubble_outline,
                    text: 'Сообщение',
                  ),
                ],

                const SizedBox(height: 12),

                // Метрики (рейтинг пока "—")
                _MetricsRowGuest(
                  rating: '—',
                  friends: '${_friends.length}',
                ),

                const SizedBox(height: 15),
                Padding(
                  key: _friendsKey,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Друзья',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),

                const SizedBox(height: 10),
                _ProfileListSection(
                  users: _friends,
                  emptyText: 'Друзья не найдены',
                  onOpenUser: (id) {
                    if (id == widget.userId) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => FriendProfileScreen(userId: id),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          PositionedDirectional(
            start: 4,
            top: media.padding.top + 4,
            child: const _TopBackButton(),
          ),
          if (_myId != null && _myId != widget.userId)
            PositionedDirectional(
              end: 4,
              top: media.padding.top + 4,
              child: _ProfileActionsMenu(
                iBlocked: _iBlocked,
                busy: _blockActionBusy,
                onBlock: _confirmAndBlock,
                onUnblock: _unblockUser,
              ),
            ),
        ],
      ),
    );
  }

  String _fullName(dynamic name, dynamic surname) {
    final first = (name ?? '').toString().trim();
    final last = (surname ?? '').toString().trim();
    return [first, last].where((e) => e.isNotEmpty).join(' ');
  }
}

// ---- UI pieces ----

class _TopBackButton extends StatelessWidget {
  const _TopBackButton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => Navigator.maybePop(context),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.arrow_back_rounded,
            color: scheme.onSurface,
            size: 24,
          ),
        ),
      ),
    );
  }
}

class _ProfileActionsMenu extends StatelessWidget {
  const _ProfileActionsMenu({
    required this.iBlocked,
    required this.busy,
    required this.onBlock,
    required this.onUnblock,
  });

  final bool iBlocked;
  final bool busy;
  final VoidCallback onBlock;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: PopupMenuButton<String>(
        enabled: !busy,
        tooltip: 'Действия',
        padding: EdgeInsets.zero,
        offset: const Offset(0, 4),
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        onSelected: (value) {
          if (busy) return;
          if (value == 'block') onBlock();
          if (value == 'unblock') onUnblock();
        },
        itemBuilder: (context) {
          if (iBlocked) {
            return [
              PopupMenuItem<String>(
                value: 'unblock',
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_open_outlined,
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Разблокировать',
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ];
          }
          return [
            PopupMenuItem<String>(
              value: 'block',
              child: Row(
                children: [
                  Icon(
                    Icons.block_outlined,
                    size: 20,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Заблокировать',
                    style: TextStyle(
                      color: scheme.error,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ];
        },
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.more_vert_rounded,
            color: scheme.onSurface,
            size: 24,
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String fullName;
  final String university;
  final String groupName;
  final String status;
  final String? avatarUrl;

  const _Header({
    required this.fullName,
    required this.university,
    required this.groupName,
    required this.status,
    required this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final text = theme.textTheme;

    ImageProvider? avatarProvider;
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      avatarProvider = NetworkImage(avatarUrl!);
    }

    return Column(
      children: [
        CircleAvatar(
          radius: 44,
          backgroundColor: colorScheme.secondaryContainer,
          backgroundImage: avatarProvider,
          child: avatarProvider == null
              ? Icon(
                  Icons.person,
                  size: 44,
                  color: colorScheme.onSecondaryContainer,
                )
              : null,
        ),
        const SizedBox(height: 10),
        Text(
          fullName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: text.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          [
            if (university.isNotEmpty) university,
            if (groupName.isNotEmpty) 'группа $groupName',
          ].where((e) => e.isNotEmpty).join(', '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 7),
        Text(
          status.isEmpty ? 'Статус не указан' : status,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.bodyLarge?.copyWith(color: colorScheme.onSurface),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _FriendAction extends StatelessWidget {
  final _FriendshipState state;
  final VoidCallback onAdd;
  final VoidCallback onAccept;
  final VoidCallback? onRemove;
  final VoidCallback? onCancelRequest;
  final VoidCallback? onDecline;

  const _FriendAction({
    required this.state,
    required this.onAdd,
    required this.onAccept,
    this.onRemove,
    this.onCancelRequest,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case _FriendshipState.friends:
        return Row(
          children: [
            Expanded(
              child: _GActionLarge(
                onTap: null,
                gradient: _gradPurple,
                icon: Icons.check_circle,
                text: 'В друзьях',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _GActionLarge(
                onTap: onRemove,
                gradient: _gradGrey,
                icon: Icons.person_remove,
                text: 'Удалить',
              ),
            ),
          ],
        );

      case _FriendshipState.requestSent:
        return Row(
          children: [
            Expanded(
              child: _GActionLarge(
                onTap: null,
                gradient: _gradBlue,
                icon: Icons.hourglass_top,
                text: 'Заявка отправлена',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _GActionLarge(
                onTap: onCancelRequest,
                gradient: _gradGrey,
                icon: Icons.close,
                text: 'Отменить',
              ),
            ),
          ],
        );

      case _FriendshipState.requestIncoming:
        return Row(
          children: [
            Expanded(
              child: _GActionLarge(
                onTap: onAccept,
                gradient: _gradPurple,
                icon: Icons.check,
                text: 'Принять',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _GActionLarge(
                onTap: onDecline,
                gradient: _gradGrey,
                icon: Icons.close,
                text: 'Отклонить',
              ),
            ),
          ],
        );

      case _FriendshipState.none:
      case _FriendshipState.unknown:
      default:
        return Row(
          children: [
            Expanded(
              child: _GActionLarge(
                onTap: onAdd,
                gradient: _gradPurple,
                icon: Icons.person_add_alt_1,
                text: 'Добавить',
              ),
            ),
          ],
        );
    }
  }
}

class _MetricsRowGuest extends StatelessWidget {
  final String rating;
  final String friends;

  const _MetricsRowGuest({
    required this.rating,
    required this.friends,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bg = Color.alphaBlend(
      colorScheme.primary.withAlpha(20),
      colorScheme.surface,
    );

    Widget cell({
      required IconData icon,
      required String label,
      required String value,
    }) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: colorScheme.onSurface),
              const SizedBox(height: 8),
              Text(
                value,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          cell(icon: Icons.grade_outlined, label: 'Рейтинг', value: rating),
          const SizedBox(width: 12),
          cell(icon: Icons.group_outlined, label: 'Друзья', value: friends),
        ],
      ),
    );
  }
}

class _ProfileListSection extends StatelessWidget {
  final List<_MiniUser> users;
  final String emptyText;
  final ValueChanged<String> onOpenUser;

  const _ProfileListSection({
    required this.users,
    required this.emptyText,
    required this.onOpenUser,
  });

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) {
      return _Empty(text: emptyText);
    }

    return Column(
      children: List.generate(users.length, (i) {
        final user = users[i];
        return Column(
          children: [
            _FriendRow(
              data: user,
              onTap: () => onOpenUser(user.id),
            ),
            if (i != users.length - 1) const _ThinDivider(),
          ],
        );
      }),
    );
  }
}

class _FriendRow extends StatelessWidget {
  final _MiniUser data;
  final VoidCallback onTap;

  const _FriendRow({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final subtitle = [
      if (data.university.isNotEmpty) data.university,
      if (data.groupName.isNotEmpty) data.groupName,
    ].join(', ');

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            _Avatar(url: data.avatarUrl, name: data.fullName),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.fullName,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _ThinDivider extends StatelessWidget {
  const _ThinDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 74, right: 8),
      child: Divider(height: 1),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22),
      alignment: Alignment.center,
      child: Text(
        text,
        style: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String url;
  final String name;
  final double size;
  const _Avatar({required this.url, required this.name, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final initials = _initials(name);
    if (url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size / 2),
        child: Image.network(url, width: size, height: size, fit: BoxFit.cover),
      );
    }
    final color = _seedColor(name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size / 2),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withOpacity(.9), color.withOpacity(.6)],
        ),
      ),
      child: Text(
        initials,
        style: TextStyle(
            fontWeight: FontWeight.w800,
            color: Colors.white,
            fontSize: size * 0.38,
            letterSpacing: .2),
      ),
    );
  }

  static String _initials(String s) {
    final parts =
        s.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return '👤';
    final a = parts[0].characters.first.toUpperCase();
    final b = parts.length > 1 ? parts[1].characters.first.toUpperCase() : '';
    return '$a$b';
  }

  static Color _seedColor(String key) {
    var h = 0;
    for (final r in key.runes) {
      h = (h * 31 + r) & 0xFFFFFFFF;
    }
    final base = 0xFF6C63FF;
    final mix = (base & 0x00FFFFFF) ^ (h & 0x00FFFFFF);
    return Color(0xFF000000 | mix).withOpacity(1);
  }
}

class _MiniUser {
  final String id;
  final String name;
  final String surname;
  final String avatarUrl;
  final String university;
  final String groupName;
  const _MiniUser({
    required this.id,
    required this.name,
    required this.surname,
    required this.avatarUrl,
    required this.university,
    required this.groupName,
  });
  String get fullName =>
      [name, surname].where((e) => e.trim().isNotEmpty).join(' ').trim();
}

enum _FriendshipState {
  unknown,
  none,
  requestSent,
  requestIncoming,
  friends,
}

// Градиенты в фирменной мягкой гамме
const _gradPurple = [
  Color(0xFFEDE7F6),
  Color(0xFFD1C4E9)
]; // добавить/в друзьях
const _gradGrey = [Color(0xFFF5F5F5), Color(0xFFE0E0E0)]; // убрать/отменить
const _gradBlue = [Color(0xFFE3F2FD), Color(0xFFBBDEFB)]; // заявка отправлена

/// Универсальная большая «чип-кнопка» с градиентом
class _GActionLarge extends StatelessWidget {
  final VoidCallback? onTap;
  final List<Color> gradient;
  final IconData icon;
  final String text;
  const _GActionLarge({
    required this.onTap,
    required this.gradient,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fg = colorScheme.onSurface;
    final radius = BorderRadius.circular(16);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: gradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: colorScheme.shadow.withAlpha(28),
                blurRadius: 4,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Row(
            children: [
              Icon(icon, color: fg, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
