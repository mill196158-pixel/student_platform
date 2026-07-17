// FILE: lib/src/ui/chats/core/team_chat_service.dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/services/file_service.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_repository.dart';
import 'i_chat_service.dart';

class TeamChatService implements IChatService {
  final BuildContext context;
  final ChatRepository _repo;
  String? _chatId;

  TeamChatService(this.context)
      : _repo = ChatRepository(
          supabase: Supabase.instance.client,
          fileService: FileService(),
        );

  @override
  ChatMode get mode => ChatMode.team;

  @override
  bool get supportsAssignments => true;

  @override
  bool get supportsNotes => true; // для команды — да (у вас так)

  @override
  String get currentUserId =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  String? get chatId => _chatId;

  @override
  Future<String> ensureChatId() async {
    if (_chatId != null && _chatId!.isNotEmpty) return _chatId!;
    final teamId = context.read<TeamCubit>().state.team.id;
    _chatId = await _repo.getMainChatId(teamId);
    return _chatId!;
  }

  @override
  Stream<List<Message>> watchMessages() =>
      context.read<TeamCubit>().stream.map((s) => s.chat);

  @override
  List<Message> get currentMessages => context.read<TeamCubit>().state.chat;

  @override
  Future<List<Message>> loadOlderMessages(
          {required Message before, int limit = 50}) =>
      context.read<TeamCubit>().loadOlderMessages(limit: limit);

  @override
  Future<Map<String, dynamic>> getUnreadMeta() async {
    final cid = await ensureChatId();
    return await _repo.getUnreadInChat(cid);
  }

  @override
  Future<void> markRead(String lastMessageId) async {
    final cid = await ensureChatId();
    await _repo.markRead(chatId: cid, messageId: lastMessageId);
  }

  @override
  Future<String> sendText(String text,
      {String? replyToId, List<String>? fileIds}) async {
    // Если есть файлы — используем вашу RPC
    final teamId = context.read<TeamCubit>().state.team.id;
    if ((fileIds?.isNotEmpty ?? false)) {
      return await _repo.sendMessageWithFiles(teamId, text, fileIds!);
    }
    // Иначе — используем текущую отправку через TeamCubit
    return await context
            .read<TeamCubit>()
            .sendMessage('me', text, replyToId: replyToId) ??
        '';
  }

  @override
  Future<void> toggleReaction(String messageId, String emoji) =>
      _repo.toggleReaction(messageId, emoji);

  @override
  Future<void> pinMessage(String messageId, bool pin) =>
      context.read<TeamCubit>().pinMessage(messageId, pin);

  @override
  Future<void> deleteMessage(String messageId) =>
      context.read<TeamCubit>().removeMessage(messageId);

  @override
  Future<Message> editOwnMessage(String messageId, String text) async {
    final updated =
        await context.read<TeamCubit>().editOwnMessage(messageId, text);
    if (updated == null) {
      throw Exception('edit_failed');
    }
    return updated;
  }

  @override
  Future<String> upload(LocalAttach local) async {
    // Ваша загрузка уже инкапсулирована в ChatAttachmentsController + FileService,
    // но для совместимости дадим простой путь через repo.saveChatFile, если нужен:
    // Здесь можно оставить заглушку: фронту достаточно вернуть chat_file.id.
    // Для реальной сборки — используйте ваш уже готовый путь из ChatTab.
    throw UnimplementedError('Use existing attachments pipeline in ChatTab');
  }

  @override
  Future<ChatFile?> getFile(String fileId) async {
    final r = await Supabase.instance.client
        .from('chat_files')
        .select('*')
        .eq('id', fileId)
        .maybeSingle();
    if (r == null) return null;
    return ChatFile.fromJson(r);
  }
}
