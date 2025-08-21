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

class SupabaseLearningRepository implements LearningRepository {
  final SupabaseClient _sb = Supabase.instance.client;

  static const _kTeamsCache = 'learning_teams_cache';
  static const _kHiddenIds = 'learning_hidden_team_ids';
  static const _kViewMode = 'learning_view_mode';
  static const _chatPrefix = 'learning_chat_';
  static const _filesPrefix = 'learning_files_';
  static const _assignPrefix = 'learning_assign_';

  final Map<String, String> _chatIdByTeam = {}; // teamId -> chatId (type='team_main')

  // -------------------- Команды --------------------

  @override
  Future<List<Team>> loadTeams(String groupCode) async {
    try {
      debugPrint('[loadTeams] calling get_my_teams');
      final res = await _sb.rpc('get_my_teams');
      final list = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .map(_mapRowToTeam)
          .toList();
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
    );
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
    final res = await _sb.rpc('join_team_by_code', params: {'p_code': code.trim()});
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
      final rows = await _sb.from('users').select('login').eq('id', user.id).limit(1);
      if (rows is List && rows.isNotEmpty) {
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
    if (rows is List && rows.isNotEmpty) {
      final id = (rows.first['id'] ?? '').toString();
      _chatIdByTeam[teamId] = id;
      return id;
    }
    return null;
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

  @override
  Future<List<Message>> loadChat(String teamId) async {
    try {
      final me = _sb.auth.currentUser;
      final chatId = await _getTeamMainChatId(teamId);

      debugPrint('[loadChat] teamId=$teamId, chatId=$chatId');
      final res = await _sb.rpc('get_chat_messages_for_team', params: {
        'p_team_id': teamId,
        'p_limit': 400,
      });

      final list = (res as List).map<Message>((e) {
        final m = Map<String, dynamic>.from(e as Map);
        final authorId = (m['author_id']?.toString() ?? '');
        final amI = (me != null && authorId.isNotEmpty && authorId == me.id);

        return Message(
          id: (m['id'] ?? '').toString(),
          chatId: chatId ?? '',
          authorId: authorId,
          authorLogin: (m['author_login'] ?? 'system').toString(),
          authorName: (m['author_name'] ?? (amI ? 'Вы' : 'Студент')).toString(),
          text: (m['text'] ?? m['content'] ?? '').toString(),
          at: DateTime.tryParse((m['at'] ?? m['created_at'] ?? '').toString()) ?? DateTime.now(),
          imagePath: _firstAttachmentUrl(m['image_path'] ?? m['attachments']),
          replyToId: m['reply_to_id']?.toString(),
          type: _typeFromServer(m['type']?.toString()),
          assignmentId: m['assignment_id']?.toString(),
          fileId: m['file_id']?.toString(),
          authorAvatarUrl: (m['author_avatar_url'] ?? m['avatar_url'])?.toString(),
        );
      }).toList();

      if (list.isEmpty) {
        debugPrint('[loadChat] пустой список, возвращаем локальный кэш');
        return _loadChatLocal(teamId);
      }

      await _saveChatLocal(teamId, list);
      return list;
    } catch (e, st) {
      debugPrint('[loadChat] error: $e\n$st');
      return _loadChatLocal(teamId);
    }
  }

  @override
  Future<String?> saveChat(String teamId, List<Message> messages) async {
    if (messages.isEmpty) return null;

    final last = messages.last;
    final String typeStr = _typeToServer(last);
    final String? replyTo = (last.replyToId?.isNotEmpty ?? false) ? last.replyToId : null;
    final String? attachment = (last.imagePath?.isNotEmpty ?? false) ? last.imagePath : null;

    debugPrint('[saveChat] "${last.text}" teamId=$teamId type=$typeStr replyTo=$replyTo attach=$attachment');

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

    return Assignment(
      id: (m['id'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      link: (m['link'] ?? '').toString().isEmpty ? null : (m['link'] ?? '').toString(),
      due: (m['due'] ?? m['due_text'] ?? '').toString().isEmpty ? null : (m['due'] ?? m['due_text']).toString(),
      attachments: attachments,
      published: (m['published'] ?? (m['published_at'] != null)) == true,
      votes: (m['votes'] ?? 0) as int,
      completedByMe: (m['completed_by_me'] ?? false) as bool,
      createdBy: (m['created_by'] ?? '').toString(),
      createdAt: DateTime.tryParse((m['created_at'] ?? '').toString()) ?? DateTime.now(),
    );
  }

  @override
  Future<List<Assignment>> loadAssignments(String teamId) async {
    try {
      final res = await _sb.rpc('get_team_assignments', params: {'p_team_id': teamId});
      final list = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .map(_mapAssignmentRow)
          .toList();

      // кэш для оффлайна
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_assignPrefix$teamId', jsonEncode(list.map((e) => e.toJson()).toList()));
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
