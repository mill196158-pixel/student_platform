import 'dart:async';
import 'dart:convert';
import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';

class MyFriendsScreen extends StatefulWidget {
  const MyFriendsScreen({super.key});
  @override
  State<MyFriendsScreen> createState() => _MyFriendsScreenState();
}

class _MyFriendsScreenState extends State<MyFriendsScreen> {
  final _sb = Supabase.instance.client;

  bool _loading = true;
  bool _hydrated = false;

  // Друзья (теперь из таблицы friends)
  List<_Friend> _friends = [];
  List<_Friend> _visible = [];
  List<_Friend> _classmates = [];
  bool _classmatesLoadFailed = false;
  _FriendsTab _activeTab = _FriendsTab.friends;

  // Входящие заявки
  List<_Friend> _requests = [];
  final Set<String> _pendingReq = {}; // in-flight действия над заявкой

  // Поиск
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  Timer? _debounce;
  bool _searching = false;
  List<_Friend> _remote = [];

  // Realtime
  RealtimeChannel? _usersCh;
  RealtimeChannel? _frReqCh;
  RealtimeChannel? _friendsChA;
  RealtimeChannel? _friendsChB;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _usersCh?.unsubscribe();
    _frReqCh?.unsubscribe();
    _friendsChA?.unsubscribe();
    _friendsChB?.unsubscribe();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final uid = _sb.auth.currentUser?.id;
      if (uid == null) {
        setState(() {
          _loading = false;
          _hydrated = true;
          _friends = [];
          _visible = [];
          _requests = [];
        });
        return;
      }

      await Future.wait([
        _loadFriends(),
        _loadClassmates(),
        _reloadRequestsOnly(),
      ]);

      _subscribeRealtime(uid);

      setState(() {
        _applyFilter();
        if (_friends.isEmpty && _classmates.isNotEmpty) {
          _activeTab = _FriendsTab.classmates;
        }
        _loading = false;
        _hydrated = true;
      });
    } catch (e) {
      debugPrint('[Friends] load error: $e');
      setState(() {
        _loading = false;
        _hydrated = true;
      });
    }
  }

  // ---------- ДРУЗЬЯ ----------

  Future<void> _loadFriends() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) {
      setState(() => _friends = []);
      return;
    }

    try {
      final res = await _sb.rpc('get_my_friends_bulk');
      final rows = res is List
          ? res.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : const <Map<String, dynamic>>[];

      final list = rows.map(_friendFromMap).toList()
        ..sort((a, b) => a.surname.compareTo(b.surname));

      setState(() {
        _friends = list;
        if (_query.trim().length < 2 || _remote.isEmpty) {
          _applyFilter();
        }
      });
    } catch (e) {
      debugPrint('[Friends] get_my_friends_bulk error: $e');
      setState(() => _friends = []);
    }
  }

  void _subscribeRealtime(String uid) {
    // Входящие заявки
    _frReqCh?.unsubscribe();
    _frReqCh = _sb
        .channel('public:friend_requests:to:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friend_requests',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'to_id', value: uid),
          callback: (_) => _reloadRequestsOnly(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friend_requests',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'to_id', value: uid),
          callback: (_) => _reloadRequestsOnly(),
        )
        .subscribe();

    // Друзья: два фильтра (user_id=я) и (friend_id=я)
    _friendsChA?.unsubscribe();
    _friendsChA = _sb
        .channel('public:friends:a:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'user_id', value: uid),
          callback: (_) => _loadFriends(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'user_id', value: uid),
          callback: (_) => _loadFriends(),
        )
        .subscribe();

    _friendsChB?.unsubscribe();
    _friendsChB = _sb
        .channel('public:friends:b:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'friend_id',
              value: uid),
          callback: (_) => _loadFriends(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'friend_id',
              value: uid),
          callback: (_) => _loadFriends(),
        )
        .subscribe();
  }

  Future<void> _loadClassmates() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) {
      setState(() => _classmates = []);
      return;
    }

    try {
      final rpcRows = await _loadClassmateRowsFromRpc();
      if (rpcRows.isNotEmpty) {
        setState(() {
          _classmates = rpcRows.map(_friendFromMap).toList();
          _classmatesLoadFailed = false;
        });
        return;
      }

      Map<String, dynamic>? me;
      try {
        final res = await _sb.rpc('get_my_profile');
        if (res is Map) {
          me = Map<String, dynamic>.from(res);
        } else if (res is List && res.isNotEmpty) {
          me = Map<String, dynamic>.from(res.first as Map);
        }
      } catch (_) {}

      me ??= await _sb
          .from('users')
          .select('id, group_name, primary_group_id')
          .eq('id', uid)
          .maybeSingle();

      var groupId = (me?['primary_group_id'] ?? '').toString();
      final groupName = (me?['group_name'] ?? '').toString().trim();

      if (groupId.isEmpty) {
        groupId = await _loadMyActiveGroupId(uid);
      }

      if (groupId.isEmpty && groupName.isEmpty) {
        setState(() {
          _classmates = [];
          _classmatesLoadFailed = false;
        });
        return;
      }

      List<Map<String, dynamic>> rows = const [];
      if (groupId.isNotEmpty) {
        rows = await _loadClassmateRowsByGroupId(groupId, uid);
      }

      if (rows.isEmpty && groupName.isNotEmpty) {
        rows = await _loadClassmateRowsByGroupName(groupName, uid);
      }

      final list = <_Friend>[];
      for (final r in rows) {
        list.add(_friendFromMap(r));
      }

      setState(() {
        _classmates = list;
        _classmatesLoadFailed = false;
      });
    } catch (e) {
      debugPrint('[Friends] load classmates error: $e');
      setState(() {
        _classmates = [];
        _classmatesLoadFailed = true;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _loadClassmateRowsFromRpc() async {
    try {
      final res = await _sb.rpc('get_my_classmates');
      if (res is! List) return const [];
      return res.map((row) => Map<String, dynamic>.from(row as Map)).toList();
    } catch (e) {
      debugPrint('[Friends] get_my_classmates RPC unavailable: $e');
      return const [];
    }
  }

  Future<String> _loadMyActiveGroupId(String uid) async {
    try {
      final row = await _sb
          .from('student_enrollments')
          .select('group_id, started_at, created_at')
          .eq('user_id', uid)
          .eq('status', 'active')
          .filter('ended_at', 'is', null)
          .order('started_at', ascending: false)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      return (row?['group_id'] ?? '').toString();
    } catch (_) {}

    try {
      final rows = await _sb
          .from('student_enrollments')
          .select('group_id')
          .eq('user_id', uid)
          .limit(1);
      if (rows is List && rows.isNotEmpty) {
        return (rows.first['group_id'] ?? '').toString();
      }
    } catch (_) {}

    return '';
  }

  Future<List<Map<String, dynamic>>> _loadClassmateRowsByGroupId(
    String groupId,
    String uid,
  ) async {
    try {
      var enrollments = await _sb
          .from('student_enrollments')
          .select('user_id')
          .eq('group_id', groupId)
          .eq('status', 'active')
          .filter('ended_at', 'is', null)
          .limit(150);

      if (enrollments is List && enrollments.isEmpty) {
        enrollments = await _sb
            .from('student_enrollments')
            .select('user_id')
            .eq('group_id', groupId)
            .limit(150);
      }

      final ids = <String>{
        for (final row in (enrollments as List))
          (row['user_id'] ?? '').toString(),
      }..removeWhere((id) => id.isEmpty || id == uid);

      if (ids.isEmpty) return const [];

      final users = await _sb
          .from('users')
          .select(
              'id, name, surname, avatar_url, status, university, city, group_name, primary_group_id')
          .inFilter('id', ids.toList())
          .order('surname', ascending: true);

      return (users as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
    } catch (e) {
      debugPrint('[Friends] load classmates by enrollment error: $e');
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _loadClassmateRowsByGroupName(
    String groupName,
    String uid,
  ) async {
    try {
      final users = await _sb
          .from('users')
          .select(
              'id, name, surname, avatar_url, status, university, city, group_name, primary_group_id')
          .eq('group_name', groupName)
          .neq('id', uid)
          .order('surname', ascending: true)
          .limit(150);

      return (users as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
    } catch (e) {
      debugPrint('[Friends] load classmates by group_name error: $e');
      return const [];
    }
  }

  _Friend _friendFromMap(Map<String, dynamic> u) {
    return _Friend(
      id: (u['id'] ?? '').toString(),
      name: (u['name'] ?? '').toString(),
      surname: (u['surname'] ?? '').toString(),
      avatarUrl: (u['avatar_url'] ?? '').toString(),
      status: (u['status'] ?? '').toString(),
      university: (u['university'] ?? '').toString(),
      city: (u['city'] ?? '').toString(),
      groupName: (u['group_name'] ?? '').toString(),
    );
  }

  // ---------- ЗАЯВКИ ----------

  Future<void> _reloadRequestsOnly() async {
    try {
      final uid = _sb.auth.currentUser?.id;
      if (uid == null) {
        setState(() => _requests = const []);
        return;
      }

      final res = await _sb.rpc('get_my_incoming_friend_requests');
      final rows = res is List
          ? res.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : const <Map<String, dynamic>>[];

      setState(() => _requests = rows.map(_friendFromMap).toList());
    } catch (e) {
      debugPrint('[Friends] get_my_incoming_friend_requests error: $e');
      setState(() => _requests = const []);
    }
  }

  Future<void> _acceptRequest(_Friend f) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return;
    if (_pendingReq.contains(f.id)) return;
    setState(() => _pendingReq.add(f.id));
    try {
      await _sb.rpc(
        'accept_friend_request',
        params: {'p_user_id': f.id},
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Заявка принята')));
      }
    } catch (e) {
      debugPrint('[Friends] accept error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось принять заявку')),
        );
      }
    } finally {
      await Future.wait([_reloadRequestsOnly(), _loadFriends()]);
      if (mounted) {
        setState(() {
          _pendingReq.remove(f.id);
          if (_query.trim().length < 2) _visible = List.of(_friends);
        });
      }
    }
  }

  Future<void> _declineRequest(_Friend f) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return;
    if (_pendingReq.contains(f.id)) return;
    setState(() => _pendingReq.add(f.id));
    try {
      await _sb.rpc(
        'decline_friend_request',
        params: {'p_user_id': f.id},
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Заявка отклонена')));
      }
    } catch (e) {
      debugPrint('[Friends] decline error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось отклонить заявку')),
        );
      }
    } finally {
      await _reloadRequestsOnly();
      await _loadFriends();
      if (mounted) setState(() => _pendingReq.remove(f.id));
    }
  }

  // ---------- ПОИСК ----------

  void _applyFilter() {
    if (_query.trim().isEmpty) {
      _visible = List.of(_friends);
    } else {
      final q = _query.toLowerCase();
      _visible = _friends
          .where((f) => ('${f.name} ${f.surname}'.toLowerCase().contains(q)))
          .toList();
    }
  }

  void _onSearchChanged(String s) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      final q = s.trim();
      setState(() => _query = q);

      if (q.length < 2) {
        setState(() {
          _remote = [];
          _applyFilter();
        });
        return;
      }

      await _searchRemote(q);
    });
  }

  Future<void> _searchRemote(String q) async {
    setState(() => _searching = true);

    final me = _sb.auth.currentUser?.id;
    String myGroup = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      final userJson = prefs.getString('user');
      if (userJson != null) {
        final meMap = jsonDecode(userJson) as Map<String, dynamic>;
        myGroup = (meMap['group_name'] ?? '').toString();
      }
    } catch (_) {}

    try {
      final res = await _sb.rpc('search_users_global', params: {'p_q': q});
      List<Map<String, dynamic>> rows;
      if (res is List) {
        rows = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else {
        rows = const [];
      }

      if (rows.isEmpty) {
        final safe = q
            .replaceAll('%', '')
            .replaceAll('*', '')
            .replaceAll(',', ' ')
            .trim();
        final pattern = '*${Uri.encodeComponent(safe)}*';
        try {
          rows = await _sb
              .from('users')
              .select(
                  'id, name, surname, avatar_url, status, university, group_name')
              .or('name.ilike.$pattern,surname.ilike.$pattern')
              .limit(50);
        } catch (_) {
          rows = const [];
        }

        if (rows.isEmpty && myGroup.isNotEmpty) {
          try {
            rows = await _sb
                .from('users')
                .select(
                    'id, name, surname, avatar_url, status, university, group_name')
                .eq('group_name', myGroup)
                .or('name.ilike.$pattern,surname.ilike.$pattern')
                .limit(50);
          } catch (_) {}
        }
      }

      final found = <_Friend>[];
      for (final r in rows) {
        final id = (r['id'] ?? '').toString();
        if (id.isEmpty || id == me) continue;
        found.add(_Friend(
          id: id,
          name: (r['name'] ?? '').toString(),
          surname: (r['surname'] ?? '').toString(),
          avatarUrl: (r['avatar_url'] ?? '').toString(),
          status: (r['status'] ?? '').toString(),
          university: (r['university'] ?? '').toString(),
          city: (r['city'] ?? '').toString(),
          groupName: (r['group_name'] ?? '').toString(),
        ));
      }

      found.sort((a, b) {
        final aSame = a.groupName == myGroup ? 0 : 1;
        final bSame = b.groupName == myGroup ? 0 : 1;
        final cmpGroup = aSame.compareTo(bSame);
        if (cmpGroup != 0) return cmpGroup;
        return a.surname.compareTo(b.surname);
      });

      setState(() {
        _remote = found;
        _visible = found.isNotEmpty ? List.of(found) : List.of(_friends);
        _searching = false;
      });
    } catch (e) {
      debugPrint('[Friends] remote search error: $e');
      setState(() {
        _searching = false;
        _remote = [];
        _applyFilter();
      });
    }
  }

  // ---------- UI ----------

  void _openFriendProfile(_Friend f) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FriendProfileScreen(userId: f.id)),
    );

    if (!mounted) return;

    await _loadFriends();
    await _loadClassmates();
    await _reloadRequestsOnly();

    if (_query.trim().length < 2) {
      setState(() => _visible = List.of(_friends));
    }
  }

  void _startChat(_Friend f) async {
    HapticFeedback.lightImpact();
    if (f.id.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: context.read<TeamCubit>(),
          child: DirectChatScreen(
            peerId: f.id,
            peerName: [f.name, f.surname]
                .where((s) => s.trim().isNotEmpty)
                .join(' ')
                .trim(),
            peerAvatarUrl: f.avatarUrl.isNotEmpty ? f.avatarUrl : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searchingMode = _query.length >= 2;

    final children = <Widget>[
      // Поиск
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
        child: Material(
          elevation: 1.5,
          shadowColor: Colors.black12,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 38,
            child: TextField(
              key: const ValueKey('friends_search_field'),
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: theme.colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: 'Поиск',
                hintStyle: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(.6)),
                prefixIcon: Icon(Icons.search,
                    size: 20,
                    color: theme.colorScheme.onSurface.withOpacity(.9)),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                filled: true,
                fillColor: theme.colorScheme.surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
        ),
      ),

      // Заявки — в строчку (как список, не карусель)
      if (!searchingMode && _requests.isNotEmpty) ...[
        const SizedBox(height: 10),
        _SectionHeader(title: 'Заявки в друзья'),
        const SizedBox(height: 6),
        ..._requests.map((f) => _RequestRow(
              data: f,
              busy: _pendingReq.contains(f.id),
              onOpen: () => _openFriendProfile(f),
              onAccept: () => _acceptRequest(f),
              onDecline: () => _declineRequest(f),
            )),
        const SizedBox(height: 8),
        const _ThinDivider(),
      ],

      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
              child: _SectionHeader(
                  title: searchingMode ? 'Результаты' : 'Мои друзья')),
          if (_searching) ...[
            const SizedBox(width: 8),
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
          ],
        ],
      ),

      if (!searchingMode) ...[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _FriendsTabSwitch(
            active: _activeTab,
            onChanged: (tab) => setState(() => _activeTab = tab),
          ),
        ),
      ],

      if (_searching)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
    ];

    if (_loading && !_hydrated) {
      return Scaffold(
        appBar: AppBar(centerTitle: true, title: const Text('Друзья')),
        body: const _SkeletonList(),
      );
    }

    // Список друзей (в строчку, как чаты)
    final list = searchingMode
        ? _visible
        : (_activeTab == _FriendsTab.friends ? _friends : _classmates);
    for (var i = 0; i < list.length; i++) {
      final f = list[i];
      children.add(_FriendRow(
        data: f,
        onTap: () => _openFriendProfile(f),
        onChat: () => _startChat(f),
      ));
      children.add(const _ThinDivider());
    }

    if (!searchingMode && !_searching && list.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: Text(
            _activeTab == _FriendsTab.friends
                ? 'Друзей пока нет'
                : (_classmatesLoadFailed
                    ? 'Не удалось загрузить одногруппников'
                    : 'Одногруппники не найдены'),
            style: const TextStyle(color: Colors.black54),
          ),
        ),
      ));
    }

    if (searchingMode && !_searching && list.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
            child: Text('Ничего не найдено',
                style: TextStyle(color: Colors.black54))),
      ));
    }

    return Scaffold(
      appBar: AppBar(centerTitle: true, title: const Text('Друзья')),
      body: Theme(
        data: theme.copyWith(
            textTheme: theme.textTheme.apply(
                bodyColor: theme.colorScheme.onSurface,
                displayColor: theme.colorScheme.onSurface)),
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            key: const PageStorageKey('friends_list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
                left: 8,
                right: 8,
                top: 4,
                bottom: MediaQuery.of(context).padding.bottom + 12),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// ----- Виджеты -----

enum _FriendsTab {
  friends,
  classmates,
}

class _FriendsTabSwitch extends StatelessWidget {
  final _FriendsTab active;
  final ValueChanged<_FriendsTab> onChanged;

  const _FriendsTabSwitch({
    required this.active,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget item(_FriendsTab tab, String label) {
      final selected = active == tab;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onChanged(tab),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  selected ? cs.primary.withOpacity(.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: selected ? cs.primary : Colors.black87,
                  ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(.45),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          item(_FriendsTab.friends, 'Друзья'),
          item(_FriendsTab.classmates, 'Одногруппники'),
        ],
      ),
    );
  }
}

class _Friend {
  final String id;
  final String name;
  final String surname;
  final String avatarUrl;
  final String status;
  final String university;
  final String city;
  final String groupName;

  const _Friend({
    required this.id,
    required this.name,
    required this.surname,
    required this.avatarUrl,
    required this.status,
    required this.university,
    required this.city,
    required this.groupName,
  });

  String get fullName =>
      [name, surname].where((e) => e.trim().isNotEmpty).join(' ').trim();

  _Friend copyWith({String? avatarUrl, String? status}) => _Friend(
        id: id,
        name: name,
        surname: surname,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        status: status ?? this.status,
        university: university,
        city: city,
        groupName: groupName,
      );
}

class _FriendRow extends StatelessWidget {
  final _Friend data;
  final VoidCallback onTap;
  final VoidCallback onChat;

  const _FriendRow(
      {required this.data, required this.onTap, required this.onChat});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final subtitle = [
      if (data.university.isNotEmpty) data.university,
      if (data.groupName.isNotEmpty) 'группа ${data.groupName}',
    ].join(', ');

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            _BubbleAvatar(label: data.fullName, imageUrl: data.avatarUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700, height: 1.1)),
                  const SizedBox(height: 2),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(color: Colors.black54)),
                  if (data.status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(data.status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: Colors.black45)),
                    ),
                ],
              ),
            ),
            Row(
              children: [
                IconButton(
                    icon: const Icon(Icons.chat_bubble_outline),
                    tooltip: 'Написать',
                    onPressed: onChat),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  final _Friend data;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _RequestRow({
    required this.data,
    required this.busy,
    required this.onOpen,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final subtitle = [
      if (data.university.isNotEmpty) data.university,
      if (data.groupName.isNotEmpty) 'группа ${data.groupName}',
    ].join(', ');

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            _BubbleAvatar(label: data.fullName, imageUrl: data.avatarUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700, height: 1.1)),
                  const SizedBox(height: 2),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(color: Colors.black54)),
                ],
              ),
            ),
            SizedBox(
              height: 36,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GIconChip(
                    onTap: busy ? null : onAccept,
                    busy: busy,
                    icon: Icons.check,
                    gradient: _gradPurple,
                    fg: Colors.black87,
                    tooltip: 'Принять',
                  ),
                  const SizedBox(width: 8),
                  _GIconChip(
                    onTap: busy ? null : onDecline,
                    busy: busy,
                    icon: Icons.close,
                    gradient: _gradGrey,
                    fg: Colors.black87,
                    tooltip: 'Отклонить',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GIconChip extends StatelessWidget {
  final VoidCallback? onTap;
  final bool busy;
  final IconData icon;
  final List<Color> gradient;
  final Color fg;
  final String tooltip;

  const _GIconChip({
    required this.onTap,
    required this.busy,
    required this.icon,
    required this.gradient,
    required this.fg,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        gradient: LinearGradient(
            colors: gradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
        borderRadius: radius,
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))
        ],
      ),
      child: Center(
        child: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, size: 18, color: fg),
      ),
    );

    return Opacity(
      opacity: (onTap == null) ? .6 : 1,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: radius,
          onTap: (onTap == null) ? null : onTap,
          child: child,
        ),
      ),
    );
  }
}

// NOTE: _GActionButton был заменён на более компактный _GIconChip

const _gradPurple = [Color(0xFFD1C4E9), Color(0xFFB39DDB)];
const _gradGrey = [Color(0xFFE0E0E0), Color(0xFFCFD8DC)];

/// Пузырёк-аватар в стиле чатов (градиент + вложенный круг с инициалами/фото)
class _BubbleAvatar extends StatelessWidget {
  final String label;
  final String imageUrl;
  const _BubbleAvatar({required this.label, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final colors = _gradientFromString(label);
    final ch = (label.trim().isNotEmpty ? label.trim().characters.first : '•')
        .toUpperCase();

    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
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
                offset: const Offset(0, 2))
          ],
        ),
        alignment: Alignment.center,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: imageUrl.isNotEmpty
              ? Image.network(imageUrl,
                  width: 44, height: 44, fit: BoxFit.cover)
              : Text(ch,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 18)),
        ),
      ),
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

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? actionText;
  final VoidCallback? onAction;
  const _SectionHeader({required this.title, this.actionText, this.onAction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          if (actionText != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero),
              child: Text(actionText!,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

class _ThinDivider extends StatelessWidget {
  const _ThinDivider();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 72, right: 12),
      child: Divider(
          height: 0,
          thickness: .6,
          color: Theme.of(context).dividerColor.withOpacity(.28)),
    );
  }
}

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: 10,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemBuilder: (ctx, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(26))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 12, width: 140, color: Colors.black12),
                  const SizedBox(height: 8),
                  Container(height: 10, width: 220, color: Colors.black12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
