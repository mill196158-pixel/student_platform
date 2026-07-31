// FILE: lib/src/ui/chats/core/i_chat_service.dart
import 'dart:async';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';

enum ChatMode { team, dm }

abstract class IChatService {
  ChatMode get mode;
  bool get supportsAssignments; // для DM => false
  bool get supportsNotes; // “заметки” — для DM => false

  String get currentUserId;

  /// Подтверждает/создаёт chatId и возвращает его
  Future<String> ensureChatId();

  /// Текущий chatId (после ensureChatId)
  String? get chatId;

  /// Стрим актуального списка сообщений (по убыванию времени как в вашем ChatMessageList)
  Stream<List<Message>> watchMessages();

  /// Snapshot-first load state (empty list can still be [ChatMessagesLoadPhase.ready]).
  Stream<ChatMessagesViewState> watchMessagesState();

  /// Latest view state without waiting for the next stream event.
  ChatMessagesViewState get messagesViewState;

  /// Retry after [ChatMessagesLoadPhase.error] when no snapshot exists.
  Future<void> retryLoadMessages();

  /// Снимок текущего списка (удобно для быстрых операций)
  List<Message> get currentMessages;

  /// Загрузить более старые сообщения перед указанным сообщением.
  Future<List<Message>> loadOlderMessages(
      {required Message before, int limit = 50});

  /// Метаданные непрочитанных (например, first_unread_id, count)
  Future<Map<String, dynamic>> getUnreadMeta();

  /// Отметить прочитанным по последний сообщению (как в mark_read)
  Future<void> markRead(String lastMessageId);

  /// Отправка текста с опцией ответа и списком id загруженных файлов
  Future<String> sendText(String text,
      {String? replyToId, List<String>? fileIds});

  /// Триггернуть реакцию (тоггл)
  Future<void> toggleReaction(String messageId, String emoji);

  /// Пин/анпин
  Future<void> pinMessage(String messageId, bool pin);

  /// Удалить (мягко)
  Future<void> deleteMessage(String messageId);

  /// Редактировать собственное текстовое сообщение
  Future<Message> editOwnMessage(String messageId, String text);

  /// Загрузка локального файла в сторадж/БД -> вернуть chat_files.id
  Future<String> upload(LocalAttach local);

  /// Получить файл по id (для предпросмотра/кэша)
  Future<ChatFile?> getFile(String fileId);
}
