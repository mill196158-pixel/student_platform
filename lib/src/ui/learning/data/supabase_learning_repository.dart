// lib/src/ui/learning/data/supabase_learning_repository.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/file_item.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart'; // ДОБАВЛЕНО!
import 'package:student_platform/src/utils/safe_debug_log.dart';

class SupabaseLearningRepository implements LearningRepository {
  final SupabaseClient _sb = Supabase.instance.client;

  static const _kTeamsCache = 'learning_teams_cache';
  static const _kHiddenIds = 'learning_hidden_team_ids';
  static const _kViewMode = 'learning_view_mode';
  static const _chatPrefix = 'learning_chat_';
  static const _filesPrefix = 'learning_files_';
  static const _assignPrefix = 'learning_assign_';

  final Map<String, String> _chatIdByTeam =
      {}; // teamId -> chatId (type='team_main')

  // -------------------- Команды --------------------

  @override
  Future<List<Team>> loadTeams(String groupCode) async {
    try {
      debugPrint('[loadTeams] calling get_my_teams');
      final res = await _sb.rpc('get_my_teams');
      final baseList = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .map(_mapRowToTeam)
          .toList();
      final list = await _hydrateTeamsAcademicFields(baseList);
      await saveTeams(list);
      return list;
    } catch (e, st) {
      debugPrint('[loadTeams] error: $e\n$st');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kTeamsCache);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List)
          .map((e) => Team.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
  }

  Team _mapRowToTeam(Map<String, dynamic> m) {
    return Team(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      teacher: (m['teacher'] ?? '').toString(),
      groupCode: (m['group_name'] ?? '').toString(),
      icon: (m['icon'] ?? '').toString(),
      unread: 0,
      pollApproved: false,
      subjectOfferingId:
          _nullableString(m['subject_offering_id'] ?? m['subjectOfferingId']),
      groupId: _nullableString(m['group_id'] ?? m['groupId']),
      subjectId: _nullableString(m['subject_id'] ?? m['subjectId']),
      academicYearId:
          _nullableString(m['academic_year_id'] ?? m['academicYearId']),
      academicTermId:
          _nullableString(m['academic_term_id'] ?? m['academicTermId']),
      semesterNumber: _nullableInt(m['semester_number'] ?? m['semesterNumber']),
    );
  }

  Future<List<Team>> _hydrateTeamsAcademicFields(List<Team> teams) async {
    final ids =
        teams.map((team) => team.id).where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return teams;

    try {
      final rows = await _sb
          .from('teams')
          .select(
            'id,group_id,subject_id,subject_offering_id,academic_year_id,academic_term_id,semester_number',
          )
          .inFilter('id', ids);
      final byId = <String, Map<String, dynamic>>{};
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = (row['id'] ?? '').toString();
        if (id.isNotEmpty) byId[id] = row;
      }

      return teams.map((team) {
        final row = byId[team.id];
        if (row == null) return team;
        return team.copyWith(
          subjectOfferingId: _nullableString(row['subject_offering_id']),
          groupId: _nullableString(row['group_id']),
          subjectId: _nullableString(row['subject_id']),
          academicYearId: _nullableString(row['academic_year_id']),
          academicTermId: _nullableString(row['academic_term_id']),
          semesterNumber: _nullableInt(row['semester_number']),
        );
      }).toList();
    } catch (e) {
      safeDebugLog('[loadTeams] academic hydrate failed: ${e.runtimeType}');
      return teams;
    }
  }

  @override
  Future<void> saveTeams(List<Team> teams) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kTeamsCache,
      jsonEncode(teams.map((e) => e.toJson()).toList()),
    );
  }

  @override
  Future<String> joinByInviteCode(String code) async {
    debugPrint('[joinByInviteCode] code=$code');
    final res =
        await _sb.rpc('join_team_by_code', params: {'p_code': code.trim()});
    final teamId = res?.toString() ?? '';
    return teamId;
  }

  // -------------------- Чат --------------------

  MessageType _typeFromServer(String? s) {
    switch (s) {
      case 'assignmentDraft':
        return MessageType.assignmentDraft;
      case 'assignmentPublished':
        return MessageType.assignmentPublished;
      case 'file':
        return MessageType.file;
      default:
        return MessageType.text;
    }
  }

  String _typeToServer(Message m) {
    switch (m.type) {
      case MessageType.assignmentDraft:
        return 'assignmentDraft';
      case MessageType.assignmentPublished:
        return 'assignmentPublished';
      case MessageType.file:
        return 'file';
      default:
        return 'text';
    }
  }

  Future<String?> _currentLogin() async {
    final user = _sb.auth.currentUser;
    if (user == null) return null;
    try {
      final rows =
          await _sb.from('users').select('login').eq('id', user.id).limit(1);
      if (rows.isNotEmpty) {
        final m = Map<String, dynamic>.from(rows.first as Map);
        final login = (m['login'] ?? '').toString();
        return login.isEmpty ? null : login;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getTeamMainChatId(String teamId) async {
    if (_chatIdByTeam.containsKey(teamId)) return _chatIdByTeam[teamId];
    final rows = await _sb
        .from('chats')
        .select('id')
        .eq('team_id', teamId)
        .eq('type', 'team_main')
        .limit(1);
    if (rows.isNotEmpty) {
      final id = (rows.first['id'] ?? '').toString();
      _chatIdByTeam[teamId] = id;
      return id;
    }
    return null;
  }

  /// Public API to fetch main chat id for a team (type='team_main').
  /// Returns empty string if not found.
  Future<String> getMainChatId(String teamId) async {
    final id = await _getTeamMainChatId(teamId);
    return id ?? '';
  }

  String? _firstAttachmentUrl(dynamic value) {
    try {
      if (value == null) return null;
      if (value is String && value.isNotEmpty) return value;
      if (value is List && value.isNotEmpty) {
        final first = Map<String, dynamic>.from(value.first as Map);
        return (first['url'] ?? first['path'] ?? '').toString();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  List<ChatFile> _parseAttachments(dynamic value) {
    final attachments = <ChatFile>[];
    if (value == null) return attachments;

    safeDebugLog('[loadChat] attachments type=${value.runtimeType}');

    try {
      List<dynamic> attachmentsList;

      if (value is String) {
        // Если attachments пришло как JSON строка
        if (value.isEmpty || value == '[]') return attachments;
        final decoded = jsonDecode(value);
        attachmentsList = decoded is List ? decoded : [];
      } else if (value is List) {
        attachmentsList = value;
      } else {
        safeDebugLog(
            '[loadChat] unknown attachments type=${value.runtimeType}');
        return attachments;
      }

      for (final it in attachmentsList) {
        if (it is Map<String, dynamic>) {
          attachments.add(ChatFile(
            id: (it['id'] ?? '').toString(),
            chatId: (it['chatId'] ?? it['chat_id'] ?? '').toString(),
            messageId: (it['messageId'] ?? it['message_id'] ?? '').toString(),
            fileName: (it['fileName'] ?? it['file_name'] ?? it['name'] ?? '')
                .toString(),
            fileKey: (it['fileKey'] ?? it['file_key'] ?? '').toString(),
            fileUrl:
                (it['fileUrl'] ?? it['file_url'] ?? it['url'] ?? '').toString(),
            fileType: (it['fileType'] ?? it['file_type'] ?? it['type'] ?? '')
                .toString(),
            fileSize: _asInt(it['fileSize'] ?? it['file_size'] ?? it['size']),
            uploadedBy:
                (it['uploadedBy'] ?? it['uploaded_by'] ?? '').toString(),
            uploadedAt: DateTime.tryParse((it['uploadedAt'] ??
                        it['uploaded_at'] ??
                        it['created_at'] ??
                        '')
                    .toString()) ??
                DateTime.now(),
          ));
        }
      }
    } catch (e) {
      safeDebugLog('[loadChat] attachments parse failed: ${e.runtimeType}');
    }

    return attachments;
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString()) ?? 0;
  }

  int? _nullableInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  String? _nullableString(dynamic value) {
    final text = (value ?? '').toString();
    return text.isEmpty ? null : text;
  }

  DateTime? _nullableDate(dynamic value) {
    final text = (value ?? '').toString();
    return text.isEmpty ? null : DateTime.tryParse(text);
  }

  Future<void> _saveChatLocal(String teamId, List<Message> messages) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(messages.map((e) => e.toJson()).toList());
    await prefs.setString('$_chatPrefix$teamId', raw);
  }

  Future<List<Message>> _loadChatLocal(String teamId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_chatPrefix$teamId');
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List)
        .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Message _mapMessageRow(
    Map<String, dynamic> m, {
    required String chatId,
    required String currentUserId,
  }) {
    final authorId = (m['author_id']?.toString() ?? '');
    final amI = currentUserId.isNotEmpty && authorId == currentUserId;
    final authorName = (m['author_name'] ?? '').toString().trim();
    final authorLogin = (m['author_login'] ?? '').toString().trim();

    return Message(
      id: (m['id'] ?? '').toString(),
      chatId: (m['chat_id'] ?? chatId).toString(),
      authorId: authorId,
      authorLogin: authorLogin.isNotEmpty ? authorLogin : 'system',
      authorName: authorName.isNotEmpty
          ? authorName
          : (authorLogin.isNotEmpty ? authorLogin : (amI ? 'Вы' : 'Студент')),
      text: (m['text'] ?? m['content'] ?? m['body'] ?? '').toString(),
      at: DateTime.tryParse((m['at'] ?? m['created_at'] ?? '').toString()) ??
          DateTime.now(),
      imagePath: _firstAttachmentUrl(m['image_path'] ?? m['attachments']),
      replyToId: m['reply_to_id']?.toString(),
      type: _typeFromServer((m['type'] ?? m['msg_type'])?.toString()),
      assignmentId: (m['assignment_id'] ?? m['assignmentId'])?.toString(),
      fileId: (m['file_id'] ?? m['fileId'])?.toString(),
      authorAvatarUrl: (m['author_avatar_url'] ?? m['avatar_url'])?.toString(),
      attachments: _parseAttachments(m['attachments']),
      isPinned: (m['is_pinned'] ?? false) == true,
      reactions: (m['reactions'] is Map)
          ? Map<String, int>.from(m['reactions'] as Map)
          : (m['reactions'] is String && (m['reactions'] as String).isNotEmpty
              ? Map<String, int>.from(
                  jsonDecode(m['reactions'] as String) as Map)
              : null),
      userReactions: (m['user_reactions'] is List)
          ? (m['user_reactions'] as List).map((e) => e.toString()).toList()
          : null,
    );
  }

  Future<List<ChatFile>> _loadChatFilesForMessage(String messageId) async {
    final rows =
        await _sb.from('chat_files').select('*').eq('message_id', messageId);
    return (rows as List)
        .map((e) => ChatFile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<List<Message>> loadChat(String teamId) async {
    try {
      final me = _sb.auth.currentUser;

      // Основной путь: SECURITY DEFINER RPC, который джойнит имя/логин/аватар
      // автора на сервере в обход RLS. Прямое чтение public.users клиентом
      // запрещено политиками (виден только собственный ряд id = auth.uid()),
      // из-за чего у чужих сообщений имя не подтягивалось и падало в «Студент».
      final rpcRows = await _sb.rpc('get_chat_messages_for_team', params: {
        'p_team_id': teamId,
        'p_limit': 200,
      });

      final list = <Message>[];
      for (final row in rpcRows as List) {
        final data = Map<String, dynamic>.from(row as Map);
        final id = (data['id'] ?? '').toString();
        if (id.isEmpty) continue;

        final attachments = await _loadChatFilesForMessage(id);
        if (attachments.isNotEmpty) {
          data['attachments'] = attachments.map((e) => e.toJson()).toList();
        }

        list.add(_mapMessageRow(
          data,
          chatId: (data['chat_id'] ?? '').toString(),
          currentUserId: me?.id ?? '',
        ));
      }

      list.sort((a, b) => a.at.compareTo(b.at));

      // Всегда синхронизируем локальный кэш с серверным ответом,
      // даже если список пуст — это важно, чтобы удалённое последнее
      // сообщение не «воскресало» из локального кэша.
      await _saveChatLocal(teamId, list);
      return list;
    } catch (e, st) {
      debugPrint('[loadChat] rpc failed, fallback to direct tables: $e\n$st');
      return _loadChatViaTables(teamId);
    }
  }

  /// Fallback-путь загрузки чата напрямую из таблиц (используется, если RPC
  /// `get_chat_messages_for_team` недоступен). Имена чужих авторов здесь могут
  /// не резолвиться из-за RLS на public.users — тогда сработает заглушка.
  Future<List<Message>> _loadChatViaTables(String teamId) async {
    try {
      final me = _sb.auth.currentUser;
      final chatId = await _getTeamMainChatId(teamId);
      if (chatId == null || chatId.isEmpty) {
        await _saveChatLocal(teamId, const []);
        return const [];
      }

      safeDebugLog(
          '[loadChat] team=${maskDebugId(teamId)} chat=${maskDebugId(chatId)}');

      // Последние 50 сообщений (DESC), затем ASC для UI: старые сверху, новые снизу.
      final rows = await _sb
          .from('messages')
          .select('*')
          .eq('chat_id', chatId)
          .order('created_at', ascending: false)
          .limit(50);

      final list = <Message>[];
      for (final row in rows as List) {
        final data = Map<String, dynamic>.from(row as Map);
        final id = (data['id'] ?? '').toString();
        if (id.isEmpty) continue;

        final attachments = await _loadChatFilesForMessage(id);
        if (attachments.isNotEmpty) {
          data['attachments'] = attachments.map((e) => e.toJson()).toList();
        }

        await _applyAuthorIdentity(data, (data['author_id'] ?? '').toString());

        list.add(_mapMessageRow(
          data,
          chatId: chatId,
          currentUserId: me?.id ?? '',
        ));
      }

      list.sort((a, b) => a.at.compareTo(b.at));

      await _saveChatLocal(teamId, list);
      return list;
    } catch (e, st) {
      debugPrint('[loadChat] error: $e\n$st');
      return _loadChatLocal(teamId);
    }
  }

  /// Заполняет `author_login`/`author_name`/`author_avatar_url` в [data].
  /// Сначала пытается прочитать public.users напрямую (работает только для
  /// собственного ряда из-за RLS), а при отсутствии данных использует
  /// SECURITY DEFINER RPC `get_user_profile`, который обходит RLS.
  Future<void> _applyAuthorIdentity(
    Map<String, dynamic> data,
    String authorId,
  ) async {
    if (authorId.isEmpty) return;

    try {
      final user = await _sb
          .from('users')
          .select('login,name,surname,avatar_url')
          .eq('id', authorId)
          .maybeSingle();
      if (user != null) {
        final u = Map<String, dynamic>.from(user as Map);
        final name = [
          (u['name'] ?? '').toString(),
          (u['surname'] ?? '').toString(),
        ].where((s) => s.trim().isNotEmpty).join(' ').trim();
        data['author_login'] = (u['login'] ?? '').toString();
        data['author_name'] =
            name.isNotEmpty ? name : (u['login'] ?? '').toString();
        data['author_avatar_url'] = (u['avatar_url'] ?? '').toString();
        return;
      }
    } catch (_) {}

    // RLS скрыл чужой ряд — берём профиль через RPC в обход RLS.
    try {
      final res = await _sb.rpc('get_user_profile', params: {'p_id': authorId});
      Map<String, dynamic>? u;
      if (res is List && res.isNotEmpty) {
        u = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        u = Map<String, dynamic>.from(res);
      }
      if (u == null) return;

      final name = [
        (u['name'] ?? '').toString(),
        (u['surname'] ?? '').toString(),
      ].where((s) => s.trim().isNotEmpty).join(' ').trim();
      if (name.isNotEmpty) data['author_name'] = name;
      final avatar = (u['avatar_url'] ?? '').toString();
      if (avatar.isNotEmpty) data['author_avatar_url'] = avatar;
    } catch (_) {}
  }

  @override
  Future<Message?> loadMessageById(String teamId, String messageId) async {
    try {
      final chatId = await _getTeamMainChatId(teamId);
      if (chatId == null || chatId.isEmpty || messageId.isEmpty) return null;

      final row = await _sb
          .from('messages')
          .select('*')
          .eq('id', messageId)
          .eq('chat_id', chatId)
          .maybeSingle();
      if (row == null) return null;

      final data = Map<String, dynamic>.from(row as Map);
      final attachments = await _loadChatFilesForMessage(messageId);
      if (attachments.isNotEmpty) {
        data['attachments'] = attachments.map((e) => e.toJson()).toList();
      }

      await _applyAuthorIdentity(data, (data['author_id'] ?? '').toString());

      return _mapMessageRow(
        data,
        chatId: chatId,
        currentUserId: _sb.auth.currentUser?.id ?? '',
      );
    } catch (e, st) {
      debugPrint('[loadMessageById] error: $e\n$st');
      return null;
    }
  }

  @override
  Future<List<Message>> loadOlderMessages(String teamId, Message before,
      {int limit = 50}) async {
    try {
      final chatId = await _getTeamMainChatId(teamId);
      if (chatId == null || chatId.isEmpty) return [];

      final rows = await _sb
          .from('messages')
          .select('*')
          .eq('chat_id', chatId)
          .lte('created_at', before.at.toUtc().toIso8601String())
          .order('created_at', ascending: false)
          .limit(limit + 1);

      final older = <Message>[];
      for (final row in rows as List) {
        final data = Map<String, dynamic>.from(row as Map);
        final id = (data['id'] ?? '').toString();
        if (id.isEmpty || id == before.id) continue;

        final attachments = await _loadChatFilesForMessage(id);
        if (attachments.isNotEmpty) {
          data['attachments'] = attachments.map((e) => e.toJson()).toList();
        }

        await _applyAuthorIdentity(data, (data['author_id'] ?? '').toString());

        older.add(_mapMessageRow(
          data,
          chatId: chatId,
          currentUserId: _sb.auth.currentUser?.id ?? '',
        ));
      }

      older.sort((a, b) => a.at.compareTo(b.at));
      return older.take(limit).toList();
    } catch (e, st) {
      debugPrint('[loadOlderMessages] error: $e\n$st');
      return [];
    }
  }

  @override
  Future<String?> saveChat(String teamId, List<Message> messages) async {
    if (messages.isEmpty) return null;

    final last = messages.last;
    final String typeStr = _typeToServer(last);
    final String? replyTo =
        (last.replyToId?.isNotEmpty ?? false) ? last.replyToId : null;
    final String? attachment =
        (last.imagePath?.isNotEmpty ?? false) ? last.imagePath : null;

    safeDebugLog(
        '[saveChat] team=${maskDebugId(teamId)} type=$typeStr replyTo=${maskDebugId(replyTo)} hasAttachment=${attachment != null}');

    String? messageId;

    try {
      final result = await _sb.rpc('send_chat_message', params: {
        'p_team_id': teamId,
        'p_text': last.text,
        'p_type': typeStr,
        'p_reply_to': replyTo,
        'p_attachment_url': attachment,
        'p_assignment_id': last.assignmentId,
        'p_file_id': last.fileId,
      });
      messageId = result?.toString();
    } catch (e, st) {
      debugPrint('[saveChat] send_chat_message error: $e\n$st');
      try {
        final login = await _currentLogin();
        if (login != null && login.isNotEmpty) {
          final result = await _sb.rpc('send_chat_message_for_login', params: {
            'p_team_id': teamId,
            'p_login': login,
            'p_text': last.text,
            'p_type': typeStr,
            'p_reply_to': replyTo,
            'p_attachment_url': attachment,
            'p_assignment_id': last.assignmentId,
            'p_file_id': last.fileId,
          });
          messageId = result?.toString();
        }
      } catch (e2, st2) {
        debugPrint('[saveChat] send_chat_message_for_login error: $e2\n$st2');
      }
    }

    await _saveChatLocal(teamId, messages);
    return messageId;
  }

  @override
  Future<Map<String, dynamic>> loadReactionsForMessage(String messageId) async {
    try {
      final rows = await _sb
          .from('message_reactions')
          .select('emoji,user_id')
          .eq('message_id', messageId) as List<dynamic>?;

      final counts = <String, int>{};
      final userReacts = <String>[];
      final uid = _sb.auth.currentUser?.id;
      if (rows != null) {
        for (final r in rows) {
          final map = Map<String, dynamic>.from(r as Map);
          final emoji = (map['emoji'] ?? '').toString();
          counts[emoji] = (counts[emoji] ?? 0) + 1;
          if (uid != null && uid.isNotEmpty && (map['user_id'] ?? '') == uid) {
            userReacts.add(emoji);
          }
        }
      }
      return {'counts': counts, 'userReactions': userReacts};
    } catch (e) {
      safeDebugLog(
          '[SupabaseLearningRepository] loadReactionsForMessage failed message=${maskDebugId(messageId)} error=${e.runtimeType}');
      return {'counts': <String, int>{}, 'userReactions': <String>[]};
    }
  }

  @override
  Future<bool> deleteMessage(String messageId) async {
    try {
      safeDebugLog('[deleteMessage] message=${maskDebugId(messageId)}');

      // Вместо удаления файлов — отвязываем их от сообщения (message_id = null),
      // чтобы файлы оставались доступны во вкладке "Файлы".
      await _sb
          .from('chat_files')
          .update({'message_id': null}).eq('message_id', messageId);

      debugPrint('[deleteMessage] связанные файлы отвязаны (message_id=null)');

      // Затем удаляем само сообщение
      await _sb.from('messages').delete().eq('id', messageId);

      debugPrint('[deleteMessage] сообщение успешно удалено');
      return true;
    } catch (e, st) {
      debugPrint('[deleteMessage] error: $e\n$st');
      return false;
    }
  }

  @override
  Future<bool> pinMessage(String messageId, bool pinned) async {
    try {
      safeDebugLog(
          '[pinMessage] message=${maskDebugId(messageId)} pinned=$pinned');
      await _sb.rpc('pin_message', params: {
        'p_message_id': messageId,
        'p_pinned': pinned,
      });
      return true;
    } catch (e, st) {
      debugPrint('[pinMessage] error: $e\n$st');
      return false;
    }
  }

  // ---------------------- Файлы ----------------------

  @override
  Future<List<FileItem>> loadFiles(String teamId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_filesPrefix$teamId');
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List)
        .map((e) => FileItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<void> saveFiles(String teamId, List<FileItem> files) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(files.map((e) => e.toJson()).toList());
    await prefs.setString('$_filesPrefix$teamId', raw);
  }

  // ---------------------- Задания ----------------------

  Assignment _mapAssignmentRow(Map<String, dynamic> m) {
    final attachments = <Map<String, String>>[];
    try {
      final raw = m['attachments'];
      if (raw is List) {
        for (final it in raw) {
          final mm = Map<String, dynamic>.from(it as Map);
          attachments.add({
            'name': (mm['name'] ?? '').toString(),
            'path': (mm['path'] ?? mm['url'] ?? '').toString(),
          });
        }
      }
    } catch (_) {}

    final status = _nullableString(m['status']);
    final publishedAt = _nullableDate(m['published_at']);
    final dueAt = _nullableDate(m['due_at']);

    return Assignment(
      id: (m['id'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      link: (m['link'] ?? '').toString().isEmpty
          ? null
          : (m['link'] ?? '').toString(),
      due: (m['due'] ?? m['due_text'] ?? '').toString().isEmpty
          ? null
          : (m['due'] ?? m['due_text']).toString(),
      dueAt: dueAt,
      attachments: attachments,
      published: (m['published'] ?? false) == true ||
          publishedAt != null ||
          status == 'published',
      votes: _asInt(m['votes'] ?? m['votes_count']),
      completedByMe: (m['completed_by_me'] ?? false) as bool,
      createdBy: (m['created_by'] ?? '').toString(),
      createdAt: DateTime.tryParse((m['created_at'] ?? '').toString()) ??
          DateTime.now(),
      status: status,
      publishedAt: publishedAt,
      subjectOfferingId: _nullableString(m['subject_offering_id']),
      groupId: _nullableString(m['group_id']),
      subjectId: _nullableString(m['subject_id']),
      academicYearId: _nullableString(m['academic_year_id']),
      academicTermId: _nullableString(m['academic_term_id']),
      semesterNumber: _nullableInt(m['semester_number']),
    );
  }

  @override
  Future<List<Assignment>> loadAssignments(String teamId) async {
    try {
      final res =
          await _sb.rpc('get_team_assignments', params: {'p_team_id': teamId});
      final list = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .map(_mapAssignmentRow)
          .toList();

      // кэш для оффлайна
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_assignPrefix$teamId',
          jsonEncode(list.map((e) => e.toJson()).toList()));
      return list;
    } catch (e, st) {
      debugPrint('[loadAssignments] error: $e\n$st');
      // оффлайн-кэш
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_assignPrefix$teamId');
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List)
          .map((e) => Assignment.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
  }

  @override
  Future<void> saveAssignments(String teamId, List<Assignment> items) async {
    // Истина — на сервере (через RPC в Cubit), здесь только локальный кэш для оффлайна
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString('$_assignPrefix$teamId', raw);
  }

  // ---------------------- Настройки ----------------------

  @override
  Future<Set<String>> loadHiddenTeamIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kHiddenIds);
    if (raw == null || raw.isEmpty) return {};
    return Set<String>.from((jsonDecode(raw) as List).map((e) => e.toString()));
  }

  @override
  Future<void> saveHiddenTeamIds(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHiddenIds, jsonEncode(ids.toList()));
  }

  @override
  Future<String?> loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kViewMode);
  }

  @override
  Future<void> saveViewMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kViewMode, mode);
  }
}
