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

class TeamState {
  final Team team;
  final List<Message> chat;
  final List<FileItem> files;
  final List<Assignment> assignments;
  final bool loading;
  final int votes;
  final bool isStarosta;
  final Set<String> doneAssignmentIds;

  List<Assignment> get published => assignments.where((a) => a.published).toList();

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
    this.isStarosta = false, // по умолчанию НЕ староста
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
  TeamCubit(Team team) : repo = SupabaseLearningRepository(), super(TeamState(team: team));

  String? _myDisplayName;
  String? _myAvatarUrl;

  // realtime
  RealtimeChannel? _rtChat;
  RealtimeChannel? _rtAssignments;
  RealtimeChannel? _rtVotes;
  RealtimeChannel? _rtDone;

  Future<void> init() async {
    emit(state.copyWith(loading: true));

    // 1) грузим данные
    final chat = await repo.loadChat(state.team.id);
    final files = await repo.loadFiles(state.team.id);
    final ass = await repo.loadAssignments(state.team.id);

    // 2) роль пользователя в этой команде
    final star = await _fetchIsStarosta(state.team.id);

    // 3) сложим состояние
    emit(state.copyWith(
      loading: false,
      chat: chat,
      files: files,
      assignments: ass,
      doneAssignmentIds: ass.where((a) => a.completedByMe).map((a) => a.id).toSet(),
      isStarosta: star,
    ));

    // аккуратно дополним assignmentId/type там, где их нет
    await _hydrateAssignmentIdsInChat();

    // 4) подписки
    _subscribeToChat();
    _subscribeToAssignments();
  }

  // ----- роль старосты для текущего пользователя по team_members -----
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
    if (_myDisplayName != null && _myDisplayName!.isNotEmpty) return _myDisplayName!;
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
          final full = [(mm['name'] ?? '').toString(), (mm['surname'] ?? '').toString()]
              .where((s) => s.isNotEmpty)
              .join(' ')
              .trim();
          if (full.isNotEmpty) return _myDisplayName = full;
        }
      }
    } catch (_) {}
    return _myDisplayName = 'Я';
  }

  Future<String?> _getMyAvatarUrl() async {
    if (_myAvatarUrl != null && _myAvatarUrl!.isNotEmpty) return _myAvatarUrl;
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

  Future<void> sendMessage(
    String author,
    String text, {
    String? authorName,
    String? imagePath,
    String? replyToId,
    MessageType type = MessageType.text,
    String? assignmentId,
  }) async {
    final t = text.trim();
    if (t.isEmpty && imagePath == null && type == MessageType.text) return;

    final currentUid = Supabase.instance.client.auth.currentUser?.id ?? '';

    // оптимистично добавим локально
    final local = Message(
      id: '${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(999)}',
      chatId: '',
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
    );
    final optimistic = [...state.chat, local];
    emit(state.copyWith(chat: optimistic));

    // отправим на сервер и перезагрузим чат с сервера (чтобы вычистить локальные «призраки»)
    final ok = await repo.saveChat(state.team.id, optimistic);
    if (ok) {
      final fresh = await repo.loadChat(state.team.id);
      if (fresh.isNotEmpty) {
        emit(state.copyWith(chat: fresh));
      }
    }

    // аккуратно дополним assignmentId/type, если надо
    await _hydrateAssignmentIdsInChat();
  }

  void removeMessage(String id) {
    final idx = state.chat.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    final updated = List<Message>.from(state.chat)..removeAt(idx);
    emit(state.copyWith(chat: updated));
    repo.saveChat(state.team.id, updated);
  }

  Future<void> _subscribeToChat() async {
    final sb = Supabase.instance.client;
    try {
      final rows = await sb
          .from('chats')
          .select('id')
          .eq('team_id', state.team.id)
          .eq('type', 'team_main')
          .limit(1);
      if (rows is! List || rows.isEmpty) return;
      final chatId = (rows.first['id'] ?? '').toString();
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

      _rtChat!
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'messages',
            filter: filter,
            callback: (_) async {
              final fresh = await repo.loadChat(state.team.id);
              emit(state.copyWith(chat: fresh));
              await _hydrateAssignmentIdsInChat();
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'messages',
            filter: filter,
            callback: (_) async {
              final fresh = await repo.loadChat(state.team.id);
              emit(state.copyWith(chat: fresh));
              await _hydrateAssignmentIdsInChat();
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'messages',
            filter: filter,
            callback: (_) async {
              final fresh = await repo.loadChat(state.team.id);
              emit(state.copyWith(chat: fresh));
              await _hydrateAssignmentIdsInChat();
            },
          );

      await _rtChat!.subscribe();
    } catch (_) {
      // тихо
    }
  }

  // --------------------------- ЗАДАНИЯ (server) ---------------------------

  Future<void> proposeAssignment({
    required String title,
    required String description,
    String? link,
    String? due,
    List<Map<String, String>> attachments = const [],
  }) async {
    // 1) создаём черновик на сервере
    final res = await Supabase.instance.client.rpc('propose_assignment', params: {
      'p_team_id': state.team.id,
      'p_title': title.trim(),
      'p_description': description.trim(),
      'p_link': (link ?? '').trim(),
      'p_due': (due ?? '').trim(),
      'p_attachments': attachments,
    });
    final createdId = (res ?? '').toString();

    // 2) сообщение в чат (draft)
    await sendMessage(
      'system',
      'Черновик задания: ${title.trim()}',
      type: MessageType.assignmentDraft,
      assignmentId: createdId.isNotEmpty ? createdId : null,
    );

    // 3) актуализируем список
    await _reloadAssignments();
  }

  Future<void> voteForPending() async {
    final a = state.pending;
    if (a == null) return;

    final res = await Supabase.instance.client.rpc('vote_assignment', params: {
      'p_assignment_id': a.id,
    });

    // если опубликовалось — поменяем тип пузыря
    try {
      final map = Map<String, dynamic>.from(res as Map);
      final published = map['published'] == true;
      if (published) {
        await _markDraftBubblePublished(a.id);
      }
    } catch (_) {}

    await _reloadAssignments();
  }

  Future<void> publishPendingManually() async {
    final a = state.pending;
    if (a == null) return;

    await Supabase.instance.client.rpc('publish_assignment', params: {
      'p_assignment_id': a.id,
    });

    await _markDraftBubblePublished(a.id);
    await _reloadAssignments();
  }

  void markAssignmentDone({required String assignmentId, required bool done}) {
    final set = {...state.doneAssignmentIds};
    if (done) {
      set.add(assignmentId);
    } else {
      set.remove(assignmentId);
    }
    emit(state.copyWith(doneAssignmentIds: set));
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
    emit(state.copyWith(
      assignments: ass,
      doneAssignmentIds: ass.where((a) => a.completedByMe).map((a) => a.id).toSet(),
    ));
    await _hydrateAssignmentIdsInChat();
  }

  Future<void> _markDraftBubblePublished(String assignmentId) async {
    final chat = [...state.chat];
    for (int i = chat.length - 1; i >= 0; i--) {
      final m = chat[i];
      if (m.assignmentId == assignmentId && m.type == MessageType.assignmentDraft) {
        chat[i] = m.copyWith(type: MessageType.assignmentPublished);
        break;
      }
    }
    await repo.saveChat(state.team.id, chat); // локальный кэш
    emit(state.copyWith(chat: chat));
  }

  // Только дописываем assignmentId/type к уже существующим сообщениям. Ничего НЕ вставляем.
  Future<void> _hydrateAssignmentIdsInChat() async {
    if (state.chat.isEmpty) return;

    bool changed = false;
    final chat = [...state.chat];

    for (int i = 0; i < chat.length; i++) {
      final m = chat[i];
      final isAssType = m.type == MessageType.assignmentDraft || m.type == MessageType.assignmentPublished;
      final looksLikeDraft = m.text.trimLeft().toLowerCase().startsWith('черновик задания:');

      if ((m.assignmentId == null || m.assignmentId!.isEmpty) && (isAssType || looksLikeDraft)) {
        // пробуем найти по заголовку
        final title = _extractTitle(m.text);
        Assignment? a;
        if (title != null) {
          final same = state.assignments.where((x) => x.title.trim() == title.trim()).toList();
          if (same.isNotEmpty) {
            a = isAssType && m.type == MessageType.assignmentDraft
                ? same.lastWhere((x) => !x.published, orElse: () => same.last)
                : same.last;
          }
        }
        if (a != null) {
          final newType = (isAssType ? m.type : MessageType.assignmentDraft);
          chat[i] = m.copyWith(assignmentId: a.id, type: newType);
          changed = true;
        }
      }
    }

    if (changed) {
      emit(state.copyWith(chat: chat));
      // не шлём это на сервер; только локальный кэш
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'learning_chat_${state.team.id}',
        jsonEncode(chat.map((e) => e.toJson()).toList()),
      );
    }
  }

  String? _extractTitle(String text) {
    final t = text.trim();
    final low = t.toLowerCase();
    if (low.startsWith('черновик задания:')) {
      return t.substring('Черновик задания:'.length).trim();
    }
    if (low.startsWith('опубликовано задание:')) {
      return t.substring('Опубликовано задание:'.length).trim();
    }
    return null;
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

    // assignment_done — свои отметки «выполнено»
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
      await _rtAssignments?.unsubscribe();
      await _rtVotes?.unsubscribe();
      await _rtDone?.unsubscribe();
    } catch (_) {}
    return super.close();
  }
}
