// lib/src/ui/learning/state/team_cubit.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/models/file_item.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_memory_cache.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';

class TeamState {
  final Team team;
  final List<Message> chat;
  final List<FileItem> files;
  final List<Assignment> assignments;
  final bool loading;
  final int votes;
  final bool isStarosta;
  final Set<String> doneAssignmentIds;

  List<Assignment> get published =>
      assignments.where((a) => a.published).toList();

  Assignment? get pending {
    for (int i = assignments.length - 1; i >= 0; i--) {
      if (!assignments[i].published) return assignments[i];
    }
    return null;
  }

  bool get hasPending => pending != null;

  const TeamState({
    required this.team,
    this.chat = const [],
    this.files = const [],
    this.assignments = const [],
    this.loading = false,
    this.votes = 0,
    this.isStarosta = false,
    this.doneAssignmentIds = const {},
  });

  TeamState copyWith({
    Team? team,
    List<Message>? chat,
    List<FileItem>? files,
    List<Assignment>? assignments,
    bool? loading,
    int? votes,
    bool? isStarosta,
    Set<String>? doneAssignmentIds,
  }) =>
      TeamState(
        team: team ?? this.team,
        chat: chat ?? this.chat,
        files: files ?? this.files,
        assignments: assignments ?? this.assignments,
        loading: loading ?? this.loading,
        votes: votes ?? this.votes,
        isStarosta: isStarosta ?? this.isStarosta,
        doneAssignmentIds: doneAssignmentIds ?? this.doneAssignmentIds,
      );
}

class TeamCubit extends Cubit<TeamState> {
  final LearningRepository repo;
  static final Map<String, List<Message>> _messagesByTeamId = {};
  static final Map<String, List<Assignment>> _assignmentsByTeamId = {};

  TeamCubit(Team team)
      : repo = SupabaseLearningRepository(),
        super(TeamState(
          team: team,
          chat: List<Message>.unmodifiable(
              _messagesByTeamId[team.id] ?? const <Message>[]),
          assignments: List<Assignment>.unmodifiable(
              _assignmentsByTeamId[team.id] ?? const <Assignment>[]),
          doneAssignmentIds: (_assignmentsByTeamId[team.id] ?? const [])
              .where((a) => a.completedByMe)
              .map((a) => a.id)
              .toSet(),
        ));

  String? _myDisplayName;
  String? _myAvatarUrl;
  String? _mainChatId;

  // realtime
  RealtimeChannel? _rtChat;
  RealtimeChannel? _rtAssignments;
  RealtimeChannel? _rtReactions;
  RealtimeChannel? _rtVotes;
  RealtimeChannel? _rtDone;

  // ----------- INIT -----------
  Future<void> init() async {
    if (state.chat.isEmpty) {
      final persistedByTeam = await _loadPersistedTeamChatSnapshot();
      if (persistedByTeam.isNotEmpty) {
        _rememberTeamChat(persistedByTeam);
        emit(state.copyWith(
          loading: false,
          chat: persistedByTeam,
        ));
        unawaited(_hydrateChatAuthorIdentities());
      } else {
        emit(state.copyWith(loading: true));
      }
    }
    if (state.assignments.isEmpty) {
      final persistedAssignments = await _loadPersistedAssignmentsSnapshot();
      if (persistedAssignments.isNotEmpty) {
        _rememberAssignments(persistedAssignments);
        emit(state.copyWith(
          assignments: persistedAssignments,
          doneAssignmentIds: persistedAssignments
              .where((a) => a.completedByMe)
              .map((a) => a.id)
              .toSet(),
        ));
      }
    }
    final chatId = await _resolveMainChatId();
    if (chatId != null && ChatMessageMemoryCache.has(chatId)) {
      final cached = ChatMessageMemoryCache.snapshot(chatId);
      _rememberTeamChat(cached);
      emit(state.copyWith(
        loading: false,
        chat: cached,
      ));
      unawaited(_hydrateChatAuthorIdentities());
    } else if (chatId != null) {
      final persisted = await _loadPersistedChatSnapshot(chatId);
      if (persisted.isNotEmpty) {
        final cached = ChatMessageMemoryCache.replace(chatId, persisted);
        _rememberTeamChat(cached);
        emit(state.copyWith(
          loading: false,
          chat: cached,
        ));
        unawaited(_hydrateChatAuthorIdentities());
      }
    }

    final chat = await repo.loadChat(state.team.id);
    final files = await repo.loadFiles(state.team.id);
    final ass = await repo.loadAssignments(state.team.id);
    final star = await _fetchIsStarosta(state.team.id);
    final mergedChat = chatId == null
        ? _dedupeAndSort(chat)
        : ChatMessageMemoryCache.merge(chatId, chat);
    if (chatId != null) {
      unawaited(_persistChatSnapshot(chatId, mergedChat));
    }
    _rememberTeamChat(mergedChat);
    _rememberAssignments(ass);
    unawaited(_persistAssignmentsSnapshot(ass));

    emit(state.copyWith(
      loading: false,
      chat: mergedChat,
      files: files,
      assignments: ass,
      doneAssignmentIds:
          ass.where((a) => a.completedByMe).map((a) => a.id).toSet(),
      isStarosta: star,
    ));
    unawaited(_hydrateChatAuthorIdentities());

    await _hydrateAssignmentIdsInChat();

    _subscribeToChat();
    _subscribeToAssignments();
  }

  void _rememberAssignments(Iterable<Assignment> assignments) {
    final stable = assignments.where((a) => a.id.isNotEmpty).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (stable.isEmpty) return;
    _assignmentsByTeamId[state.team.id] = List<Assignment>.unmodifiable(stable);
  }

  void _rememberTeamChat(Iterable<Message> messages) {
    final stable = _dedupeAndSort(messages).where((m) => !m.isLocal).toList();
    if (stable.isEmpty) return;
    final tail =
        stable.length > 120 ? stable.sublist(stable.length - 120) : stable;
    _messagesByTeamId[state.team.id] = List<Message>.unmodifiable(tail);
  }

  Future<void> _hydrateChatAuthorIdentities() async {
    final chat = state.chat;
    if (chat.isEmpty) return;

    final authorIds = chat
        .where((message) {
          if (message.authorId.isEmpty || message.isSystem) return false;
          final name = message.authorName.trim();
          final avatar = message.authorAvatarUrl?.trim() ?? '';
          return name.isEmpty || name == 'Студент' || avatar.isEmpty;
        })
        .map((message) => message.authorId)
        .toSet()
        .toList();
    if (authorIds.isEmpty) return;

    try {
      // Прямое чтение public.users по чужим id заблокировано RLS (виден только
      // собственный ряд), поэтому профили берём через SECURITY DEFINER RPC
      // get_user_profile, который обходит RLS.
      final client = Supabase.instance.client;
      final byId = <String, Map<String, dynamic>>{};
      for (final authorId in authorIds) {
        try {
          final res =
              await client.rpc('get_user_profile', params: {'p_id': authorId});
          Map<String, dynamic>? map;
          if (res is List && res.isNotEmpty) {
            map = Map<String, dynamic>.from(res.first as Map);
          } else if (res is Map) {
            map = Map<String, dynamic>.from(res);
          }
          if (map != null) byId[authorId] = map;
        } catch (_) {}
      }
      if (byId.isEmpty || isClosed) return;

      var changed = false;
      final updated = state.chat.map((message) {
        final user = byId[message.authorId];
        if (user == null) return message;

        final name = [
          (user['name'] ?? '').toString(),
          (user['surname'] ?? '').toString(),
        ].where((part) => part.trim().isNotEmpty).join(' ').trim();
        final login = (user['login'] ?? '').toString().trim();
        final avatar = (user['avatar_url'] ?? '').toString().trim();

        final currentName = message.authorName.trim();
        final nextName =
            name.isNotEmpty ? name : (login.isNotEmpty ? login : currentName);
        final nextAvatar = avatar.isNotEmpty ? avatar : message.authorAvatarUrl;
        final nextLogin = login.isNotEmpty ? login : message.authorLogin;

        if (nextName == message.authorName &&
            nextAvatar == message.authorAvatarUrl &&
            nextLogin == message.authorLogin) {
          return message;
        }

        changed = true;
        return message.copyWith(
          authorLogin: nextLogin,
          authorName: nextName,
          authorAvatarUrl: nextAvatar,
        );
      }).toList();

      if (!changed || isClosed) return;
      emit(state.copyWith(chat: _mergeCachedChat(updated)));
    } catch (e) {
      safeDebugLog('[TeamCubit] hydrate authors failed: ${e.runtimeType}');
    }
  }

  Future<String?> _resolveMainChatId() async {
    if (_mainChatId != null && _mainChatId!.isNotEmpty) return _mainChatId;
    try {
      final rows = await Supabase.instance.client
          .from('chats')
          .select('id')
          .eq('team_id', state.team.id)
          .eq('type', 'team_main')
          .limit(1);
      if (rows.isEmpty) return null;

      final chatId = (rows.first['id'] ?? '').toString();
      if (chatId.isEmpty) return null;

      _mainChatId = chatId;
      return chatId;
    } catch (_) {
      return null;
    }
  }

  List<Message> _mergeCachedChat(List<Message> messages) {
    final chatId = _mainChatId;
    if (chatId == null || chatId.isEmpty) {
      final sorted = _dedupeAndSort(messages);
      _rememberTeamChat(sorted);
      return sorted;
    }
    final merged = ChatMessageMemoryCache.merge(chatId, messages);
    _rememberTeamChat(merged);
    unawaited(_persistChatSnapshot(chatId, merged));
    return merged;
  }

  String _chatSnapshotKey(String chatId) => 'chat_snapshot_v1_$chatId';
  String get _teamChatSnapshotKey => 'team_chat_snapshot_v1_${state.team.id}';
  String get _assignmentsSnapshotKey =>
      'team_assignment_snapshot_v1_${state.team.id}';

  Future<List<Message>> _loadPersistedTeamChatSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_teamChatSnapshotKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => Message.fromJson(Map<String, dynamic>.from(item)))
          .where((message) => message.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Assignment>> _loadPersistedAssignmentsSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_assignmentsSnapshotKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => Assignment.fromJson(Map<String, dynamic>.from(item)))
          .where((assignment) => assignment.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Message>> _loadPersistedChatSnapshot(String chatId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_chatSnapshotKey(chatId));
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => Message.fromJson(Map<String, dynamic>.from(item)))
          .where((message) => message.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistChatSnapshot(
    String chatId,
    Iterable<Message> messages,
  ) async {
    try {
      final stable = messages
          .where((message) => !message.isLocal && message.id.isNotEmpty)
          .toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      final tail =
          stable.length > 120 ? stable.sublist(stable.length - 120) : stable;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _chatSnapshotKey(chatId),
        jsonEncode(tail.map((message) => message.toJson()).toList()),
      );
      await prefs.setString(
        _teamChatSnapshotKey,
        jsonEncode(tail.map((message) => message.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _persistAssignmentsSnapshot(
    Iterable<Assignment> assignments,
  ) async {
    try {
      final stable = assignments.where((a) => a.id.isNotEmpty).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _assignmentsSnapshotKey,
        jsonEncode(stable.map((assignment) => assignment.toJson()).toList()),
      );
    } catch (_) {}
  }

  List<Message> _reconcileCachedMessage(
    Message serverMessage, {
    String? clientId,
  }) {
    final chatId = _mainChatId;
    if (chatId == null || chatId.isEmpty) {
      final updated = List<Message>.from(state.chat)
        ..removeWhere((message) {
          if (!message.isLocal) return false;
          if (clientId != null && clientId.isNotEmpty) {
            return message.clientId == clientId || message.id == clientId;
          }
          return _isLikelySameLocalMessage(message, serverMessage);
        })
        ..add(
            serverMessage.copyWith(deliveryStatus: MessageDeliveryStatus.sent));
      return _dedupeAndSort(updated);
    }
    return ChatMessageMemoryCache.reconcileUpsert(
      chatId,
      serverMessage,
      clientId: clientId,
    );
  }

  List<Message> _removeCachedMessage(String messageId) {
    final chatId = _mainChatId;
    if (chatId == null || chatId.isEmpty) {
      return state.chat.where((m) => m.id != messageId).toList();
    }
    return ChatMessageMemoryCache.remove(chatId, messageId);
  }

  List<Message> _dedupeAndSort(Iterable<Message> messages) {
    final byId = <String, Message>{};
    for (final message in messages) {
      if (message.id.isEmpty) continue;
      byId[message.id] = message;
    }
    final list = byId.values.toList()
      ..sort((a, b) {
        final byTime = a.at.compareTo(b.at);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    return list;
  }

  bool _isLikelySameLocalMessage(Message local, Message server) {
    if (!local.isLocal || server.isLocal) return false;
    if (local.authorId.isNotEmpty &&
        server.authorId.isNotEmpty &&
        local.authorId != server.authorId) {
      return false;
    }
    if (local.text.trim() != server.text.trim()) return false;
    if ((local.replyToId ?? '') != (server.replyToId ?? '')) return false;
    if (local.type != server.type) return false;
    if ((local.fileId ?? '') != (server.fileId ?? '')) return false;
    return local.at.difference(server.at).abs() <= const Duration(seconds: 30);
  }

  void _markLocalMessageFailed(String clientId) {
    final updated = state.chat.map((message) {
      if (message.clientId == clientId || message.id == clientId) {
        return message.copyWith(deliveryStatus: MessageDeliveryStatus.failed);
      }
      return message;
    }).toList();
    emit(state.copyWith(chat: _mergeCachedChat(updated)));
  }

  Future<void> refreshMessageById(String messageId) async {
    if (messageId.isEmpty) return;

    final message = await repo.loadMessageById(state.team.id, messageId);
    if (message == null) return;

    emit(state.copyWith(chat: _reconcileCachedMessage(message)));
    await _hydrateAssignmentIdsInChat();
  }

  // ----- роль старосты -----
  Future<bool> _fetchIsStarosta(String teamId) async {
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) return false;
    try {
      final row = await sb
          .from('team_members')
          .select('role')
          .eq('team_id', teamId)
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return false;
      final role = (row['role'] ?? '').toString();
      return ['starosta', 'teacher', 'admin', 'owner'].contains(role);
    } catch (_) {
      return false;
    }
  }

  // ----------------------------- Профиль (имя/аватар) -----------------------------
  Future<String> _getMyDisplayName() async {
    if (_myDisplayName != null && _myDisplayName!.isNotEmpty) {
      return _myDisplayName!;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user');
      if (raw != null && raw.isNotEmpty) {
        final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final first = (m['name'] ?? '').toString();
        final last = (m['surname'] ?? '').toString();
        final full = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
        if (full.isNotEmpty) return _myDisplayName = full;
      }
    } catch (_) {}
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null && uid.isNotEmpty) {
        final row = await Supabase.instance.client
            .from('users')
            .select('name, surname')
            .eq('id', uid)
            .maybeSingle();
        if (row != null) {
          final mm = Map<String, dynamic>.from(row as Map);
          final full = [
            (mm['name'] ?? '').toString(),
            (mm['surname'] ?? '').toString()
          ].where((s) => s.isNotEmpty).join(' ').trim();
          if (full.isNotEmpty) return _myDisplayName = full;
        }
      }
    } catch (_) {}
    return _myDisplayName = 'Я';
  }

  Future<String?> _getMyAvatarUrl() async {
    if (_myAvatarUrl != null && _myAvatarUrl!.isNotEmpty) {
      return _myAvatarUrl;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user');
      if (raw != null && raw.isNotEmpty) {
        final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final url = (m['avatar_url'] ?? m['avatarUrl'] ?? '').toString();
        if (url.isNotEmpty) return _myAvatarUrl = url;
      }
    } catch (_) {}
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null && uid.isNotEmpty) {
        final row = await Supabase.instance.client
            .from('users')
            .select('avatar_url')
            .eq('id', uid)
            .maybeSingle();
        if (row != null) {
          final mm = Map<String, dynamic>.from(row as Map);
          final url = (mm['avatar_url'] ?? '').toString();
          if (url.isNotEmpty) return _myAvatarUrl = url;
        }
      }
    } catch (_) {}
    return _myAvatarUrl;
  }

  // ----------------------------- ЧАТ -----------------------------
  Future<String?> sendMessage(
    String author,
    String text, {
    String? authorName,
    String? imagePath,
    String? replyToId,
    MessageType type = MessageType.text,
    String? assignmentId,
    String? fileId,
  }) async {
    final t = text.trim();
    if (t.isEmpty && imagePath == null && type == MessageType.text) return null;

    final currentUid = Supabase.instance.client.auth.currentUser?.id ?? '';

    // оптимистично
    final clientId =
        'local_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999)}';
    final local = Message(
      id: clientId,
      chatId: _mainChatId ?? '',
      authorId: currentUid,
      authorLogin: '',
      authorName: authorName ?? await _getMyDisplayName(),
      text: t,
      at: DateTime.now(),
      authorAvatarUrl: await _getMyAvatarUrl(),
      imagePath: imagePath,
      replyToId: replyToId,
      type: type,
      assignmentId: assignmentId,
      fileId: fileId,
      clientId: clientId,
      deliveryStatus: MessageDeliveryStatus.sending,
    );
    final optimistic = _mergeCachedChat([...state.chat, local]);
    emit(state.copyWith(chat: optimistic));

    try {
      final messageId = await repo.saveChat(state.team.id, [local]);
      if (messageId == null || messageId.isEmpty) {
        _markLocalMessageFailed(clientId);
        return null;
      }

      final serverMessage =
          await repo.loadMessageById(state.team.id, messageId);
      if (serverMessage != null) {
        emit(state.copyWith(
          chat: _reconcileCachedMessage(serverMessage, clientId: clientId),
        ));
      }
      await _hydrateAssignmentIdsInChat();
      return messageId;
    } catch (e) {
      _markLocalMessageFailed(clientId);
      safeDebugLog('[TeamCubit] sendMessage failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> retryFailedTextMessage(Message message) async {
    if (!message.isFailed || message.type != MessageType.text) return;
    final text = message.text.trim();
    if (text.isEmpty) return;

    // Drop the stale local bubble before retrying so a successful retry cannot
    // leave both the failed local row and the server row in the list.
    emit(state.copyWith(chat: _removeCachedMessage(message.id)));
    await sendMessage(
      'me',
      text,
      replyToId: message.replyToId,
      type: MessageType.text,
    );
  }

  Future<void> removeMessage(String id) async {
    final idx = state.chat.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    final previous = state.chat;

    // Оптимистично удаляем локально
    final updated = _removeCachedMessage(id);
    emit(state.copyWith(chat: updated));

    // Удаляем с сервера
    final success = await repo.deleteMessage(id);
    if (!success) {
      // Если не удалось удалить с сервера, возвращаем сообщение обратно
      emit(state.copyWith(chat: _mergeCachedChat(previous)));
      safeDebugLog(
          '[TeamCubit] delete message failed message=${maskDebugId(id)}');
      return;
    }
    // Перечитываем чат, чтобы зафиксировать удаление сервером (устойчиво к рейсам/RT)
    try {
      final fresh = await repo.loadChat(state.team.id);
      if (fresh.isNotEmpty) emit(state.copyWith(chat: _mergeCachedChat(fresh)));
    } catch (_) {}
  }

  Future<List<Message>> loadOlderMessages({int limit = 50}) async {
    if (state.chat.isEmpty) return [];
    final oldest = state.chat.reduce((a, b) => a.at.isBefore(b.at) ? a : b);
    final older =
        await repo.loadOlderMessages(state.team.id, oldest, limit: limit);
    if (older.isEmpty) return [];

    final existingIds = state.chat.map((m) => m.id).toSet();
    final uniqueOlder = older.where((m) => existingIds.add(m.id)).toList();
    if (uniqueOlder.isEmpty) return [];

    final merged = _mergeCachedChat([...uniqueOlder, ...state.chat]);
    emit(state.copyWith(chat: merged));
    return uniqueOlder;
  }

  // Toggle server-side pin for a message with optimistic UI
  Future<void> pinMessage(String id, bool pinned) async {
    final idx = state.chat.indexWhere((m) => m.id == id);
    if (idx == -1) return;

    // optimistic
    final updated = List<Message>.from(state.chat);
    updated[idx] = updated[idx].copyWith(isPinned: pinned);
    emit(state.copyWith(chat: _mergeCachedChat(updated)));

    final ok = await repo.pinMessage(id, pinned);
    if (!ok) {
      // revert if failed
      final reverted = List<Message>.from(updated);
      reverted[idx] = reverted[idx].copyWith(isPinned: !pinned);
      emit(state.copyWith(chat: _mergeCachedChat(reverted)));
    }
    // realtime UPDATE will also refresh list shortly
  }

  String _messageIdFromPayload(PostgresChangePayload payload,
      {bool old = false}) {
    final record = old ? payload.oldRecord : payload.newRecord;
    return (record['id'] ?? '').toString();
  }

  Future<void> _onRealtimeMessageInsert(PostgresChangePayload payload) async {
    final id = _messageIdFromPayload(payload);
    if (id.isEmpty || state.chat.any((m) => m.id == id)) return;

    final message = await repo.loadMessageById(state.team.id, id);
    if (message == null) return;

    emit(state.copyWith(chat: _reconcileCachedMessage(message)));
    await _hydrateAssignmentIdsInChat();
  }

  Future<void> _onRealtimeMessageUpdate(PostgresChangePayload payload) async {
    final id = _messageIdFromPayload(payload);
    if (id.isEmpty) return;

    final idx = state.chat.indexWhere((m) => m.id == id);
    if (idx == -1) return;

    final message = await repo.loadMessageById(state.team.id, id);
    if (message == null) return;

    final updated = List<Message>.from(state.chat);
    updated[idx] = message;
    emit(state.copyWith(chat: _mergeCachedChat(updated)));
    await _hydrateAssignmentIdsInChat();
  }

  Future<void> _onRealtimeMessageDelete(PostgresChangePayload payload) async {
    final id = _messageIdFromPayload(payload, old: true);
    if (id.isEmpty) return;

    final updated = _removeCachedMessage(id);
    if (updated.length == state.chat.length) return;

    emit(state.copyWith(chat: updated));
    await _hydrateAssignmentIdsInChat();
  }

  Future<void> _subscribeToChat() async {
    final sb = Supabase.instance.client;
    try {
      final chatId = await _resolveMainChatId();
      if (chatId == null) return;
      if (chatId.isEmpty) return;

      try {
        await _rtChat?.unsubscribe();
      } catch (_) {}
      _rtChat = sb.channel('public:messages');

      final filter = PostgresChangeFilter(
        column: 'chat_id',
        type: PostgresChangeFilterType.eq,
        value: chatId,
      );

      safeDebugLog('[TeamCubit] RT subscribe chat=${maskDebugId(chatId)}');

      _rtChat!
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'messages',
            filter: filter,
            callback: (payload) async {
              safeDebugLog('[TeamCubit] RT messages INSERT');
              await _onRealtimeMessageInsert(payload);
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'messages',
            filter: filter,
            callback: (payload) async {
              safeDebugLog('[TeamCubit] RT messages UPDATE');
              await _onRealtimeMessageUpdate(payload);
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'messages',
            filter: filter,
            callback: (payload) async {
              safeDebugLog('[TeamCubit] RT messages DELETE');
              await _onRealtimeMessageDelete(payload);
            },
          );

      await _rtChat!.subscribe();
      // subscribe to reactions table for lightweight updates
      try {
        await _rtReactions?.unsubscribe();
      } catch (_) {}
      _rtReactions = sb.channel('public:message_reactions');
      _rtReactions!
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'message_reactions',
            callback: (payload) async {
              try {
                final newRec = payload.newRecord as Map<String, dynamic>?;
                final mid = newRec?['message_id']?.toString();
                if (mid != null && mid.isNotEmpty) {
                  final res = await repo.loadReactionsForMessage(mid);
                  final counts = Map<String, int>.from(res['counts'] ?? {});
                  final userReactions =
                      (res['userReactions'] as List? ?? const [])
                          .map((emoji) => emoji.toString())
                          .toList();
                  final chat = [...state.chat];
                  final idx = chat.indexWhere((m) => m.id == mid);
                  if (idx != -1) {
                    chat[idx] = chat[idx].copyWith(
                      reactions: counts,
                      userReactions: userReactions,
                    );
                    emit(state.copyWith(chat: _mergeCachedChat(chat)));
                  }
                }
              } catch (_) {}
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'message_reactions',
            callback: (payload) async {
              try {
                final oldRec = payload.oldRecord as Map<String, dynamic>?;
                final mid = oldRec?['message_id']?.toString();
                if (mid != null && mid.isNotEmpty) {
                  final res = await repo.loadReactionsForMessage(mid);
                  final counts = Map<String, int>.from(res['counts'] ?? {});
                  final userReactions =
                      (res['userReactions'] as List? ?? const [])
                          .map((emoji) => emoji.toString())
                          .toList();
                  final chat = [...state.chat];
                  final idx = chat.indexWhere((m) => m.id == mid);
                  if (idx != -1) {
                    chat[idx] = chat[idx].copyWith(
                      reactions: counts,
                      userReactions: userReactions,
                    );
                    emit(state.copyWith(chat: _mergeCachedChat(chat)));
                  }
                }
              } catch (_) {}
            },
          );

      await _rtReactions!.subscribe();
    } catch (_) {
      // тихо
    }
  }

  // --------------------------- ЗАДАНИЯ ---------------------------
  Future<void> proposeAssignment({
    required String title,
    required String description,
    String? link,
    String? due,
    List<Map<String, String>> attachments = const [],
  }) async {
    // RPC creates the assignment and its message-row card atomically.
    final res =
        await Supabase.instance.client.rpc('propose_assignment', params: {
      'p_team_id': state.team.id,
      'p_title': title.trim(),
      'p_description': description.trim(),
      'p_link': (link ?? '').trim(),
      'p_due': (due ?? '').trim(),
      'p_attachments': attachments,
    });

    final creation = _parseAssignmentCreationResult(res);
    if (creation.assignmentId.isEmpty || creation.messageId.isEmpty) {
      throw StateError('assignment_creation_missing_server_ids');
    }
    safeDebugLog(
        '[TeamCubit] proposeAssignment created assignment=${maskDebugId(creation.assignmentId)} message=${maskDebugId(creation.messageId)} type=${creation.msgType}');

    // Re-read both slices so the assignment bubble appears even if realtime is slow.
    await _reloadAssignments();
    await _reloadChatFromServer(preferMessageId: creation.messageId);
  }

  ({String assignmentId, String messageId, String msgType, String status})
      _parseAssignmentCreationResult(dynamic res) {
    if (res is Map) {
      final data = Map<String, dynamic>.from(res);
      return (
        assignmentId:
            (data['assignment_id'] ?? data['assignmentId'] ?? '').toString(),
        messageId: (data['message_id'] ?? data['messageId'] ?? '').toString(),
        msgType: (data['msg_type'] ?? data['msgType'] ?? '').toString(),
        status: (data['status'] ?? '').toString(),
      );
    }

    // Legacy RPC returned only assignment id. Treat it as incomplete for chat
    // persistence so UI does not show a fake assignment bubble.
    return (
      assignmentId: (res ?? '').toString(),
      messageId: '',
      msgType: '',
      status: '',
    );
  }

  Future<void> voteForPending() async {
    final a = state.pending;
    if (a == null) return;
    await _voteAssignment(a.id);
  }

  // 👇 новая публичная прокладка
  Future<void> voteFor(String assignmentId) async {
    await _voteAssignment(assignmentId);
  }

  Future<void> _voteAssignment(String assignmentId) async {
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) return;

    try {
      final res = await sb.rpc('vote_assignment', params: {
        'p_assignment_id': assignmentId,
      });
      await _reloadAssignments();
      await _reloadChatFromServer();
      safeDebugLog(
          '[TeamCubit] vote RPC OK assignment=${maskDebugId(assignmentId)} user=${maskDebugId(uid)} resultType=${res.runtimeType}');
    } catch (e) {
      safeDebugLog(
          '[TeamCubit] vote failed assignment=${maskDebugId(assignmentId)} error=${e.runtimeType}');
    }
  }

  Future<void> publishPendingManually() async {
    final a = state.pending;
    if (a == null) return;
    await publishAssignment(a.id);
  }

  Future<void> publishAssignment(String assignmentId) async {
    await Supabase.instance.client.rpc('publish_assignment', params: {
      'p_assignment_id': assignmentId,
    });

    await _markDraftBubblePublished(assignmentId);
    await _reloadAssignments();
    await _reloadChatFromServer();
  }

  Future<void> markAssignmentDone({
    required String assignmentId,
    required bool done,
  }) async {
    await Supabase.instance.client.rpc('set_assignment_done', params: {
      'p_assignment_id': assignmentId,
      'p_done': done,
    });
    await _reloadAssignments();
  }

  bool isAssignmentDone(String id) => state.doneAssignmentIds.contains(id);

  Future<void> toggleCompleted(String id) async {
    final nowDone = !isAssignmentDone(id);
    await Supabase.instance.client.rpc('set_assignment_done', params: {
      'p_assignment_id': id,
      'p_done': nowDone,
    });
    await _reloadAssignments();
  }

  Future<void> updateAssignment(
    String id, {
    String? title,
    String? description,
    String? link,
    String? due,
    List<Map<String, String>>? attachments,
  }) async {
    await Supabase.instance.client.rpc('update_assignment', params: {
      'p_assignment_id': id,
      'p_title': (title ?? ''),
      'p_description': (description ?? ''),
      'p_link': (link ?? ''),
      'p_due': (due ?? ''),
      'p_attachments': attachments ?? const [],
    });
    await _reloadAssignments();
  }

  Future<void> removeAssignment(String id) async {
    await Supabase.instance.client.rpc('remove_assignment', params: {
      'p_assignment_id': id,
    });
    await _reloadAssignments();
  }

  // ---------------------- ВНУТРЕННЕЕ ----------------------
  Future<void> _reloadAssignments() async {
    final ass = await repo.loadAssignments(state.team.id);
    _rememberAssignments(ass);
    unawaited(_persistAssignmentsSnapshot(ass));
    emit(state.copyWith(
      assignments: ass,
      doneAssignmentIds:
          ass.where((a) => a.completedByMe).map((a) => a.id).toSet(),
    ));
    await _hydrateAssignmentIdsInChat();
    safeDebugLog('[TeamCubit] assignments reloaded count=${ass.length}');
  }

  Future<void> _reloadChatFromServer({String? preferMessageId}) async {
    try {
      final fresh = await repo.loadChat(state.team.id);
      var merged = _mergeCachedChat(fresh);
      if (preferMessageId != null &&
          preferMessageId.isNotEmpty &&
          !merged.any((message) => message.id == preferMessageId)) {
        final message =
            await repo.loadMessageById(state.team.id, preferMessageId);
        if (message != null) {
          merged = _mergeCachedChat([...merged, message]);
        }
      }
      emit(state.copyWith(chat: merged));
      await _hydrateAssignmentIdsInChat();
    } catch (e) {
      safeDebugLog('[TeamCubit] chat reload failed: ${e.runtimeType}');
    }
  }

  Future<void> _markDraftBubblePublished(String assignmentId) async {
    final chat = [...state.chat];
    for (int i = chat.length - 1; i >= 0; i--) {
      final m = chat[i];
      if (m.assignmentId == assignmentId &&
          m.type == MessageType.assignmentDraft) {
        chat[i] = m.copyWith(type: MessageType.assignmentPublished);
        break;
      }
    }
    emit(state.copyWith(chat: _mergeCachedChat(chat)));
  }

  // Only reconcile assignment message type from server-backed assignment state.
  // Never invent assignmentId by title; new assignment bubbles must come from
  // messages.assignment_id returned by Supabase.
  Future<void> _hydrateAssignmentIdsInChat() async {
    if (state.chat.isEmpty) return;

    bool changed = false;
    final chat = [...state.chat];

    for (int i = 0; i < chat.length; i++) {
      final m = chat[i];
      final isAssType = m.type == MessageType.assignmentDraft ||
          m.type == MessageType.assignmentPublished;
      if ((m.assignmentId ?? '').isNotEmpty && isAssType) {
        final byId = state.assignments.where((x) => x.id == m.assignmentId);
        if (byId.isNotEmpty &&
            byId.first.published &&
            m.type == MessageType.assignmentDraft) {
          chat[i] = m.copyWith(type: MessageType.assignmentPublished);
          changed = true;
          continue;
        }
      }
    }

    if (changed) {
      emit(state.copyWith(chat: _mergeCachedChat(chat)));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'learning_chat_${state.team.id}',
        jsonEncode(chat.map((e) => e.toJson()).toList()),
      );
    }
  }

  void _subscribeToAssignments() {
    final sb = Supabase.instance.client;

    // assignments (insert/update/delete)
    try {
      _rtAssignments?.unsubscribe();
    } catch (_) {}
    _rtAssignments = sb.channel('public:assignments');
    _rtAssignments!
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'assignments',
          filter: PostgresChangeFilter(
            column: 'team_id',
            type: PostgresChangeFilterType.eq,
            value: state.team.id,
          ),
          callback: (_) => _reloadAssignments(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'assignments',
          filter: PostgresChangeFilter(
            column: 'team_id',
            type: PostgresChangeFilterType.eq,
            value: state.team.id,
          ),
          callback: (_) => _reloadAssignments(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'assignments',
          filter: PostgresChangeFilter(
            column: 'team_id',
            type: PostgresChangeFilterType.eq,
            value: state.team.id,
          ),
          callback: (_) => _reloadAssignments(),
        );

    // assignment_votes
    try {
      _rtVotes?.unsubscribe();
    } catch (_) {}
    _rtVotes = sb.channel('public:assignment_votes');
    _rtVotes!
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'assignment_votes',
          callback: (_) => _reloadAssignments(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'assignment_votes',
          callback: (_) => _reloadAssignments(),
        );

    // assignment_done
    try {
      _rtDone?.unsubscribe();
    } catch (_) {}
    _rtDone = sb.channel('public:assignment_done');
    _rtDone!
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'assignment_done',
          callback: (_) => _reloadAssignments(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'assignment_done',
          callback: (_) => _reloadAssignments(),
        );

    _rtAssignments!.subscribe();
    _rtVotes!.subscribe();
    _rtDone!.subscribe();
  }

  // --------------------------- ФАЙЛЫ ---------------------------
  Future<void> setFiles(List<FileItem> files) async {
    await repo.saveFiles(state.team.id, files);
    emit(state.copyWith(files: files));
  }

  @override
  Future<void> close() async {
    try {
      await _rtChat?.unsubscribe();
      await _rtReactions?.unsubscribe();
      await _rtAssignments?.unsubscribe();
      await _rtVotes?.unsubscribe();
      await _rtDone?.unsubscribe();
    } catch (_) {}
    return super.close();
  }
}
