import 'package:student_platform/src/ui/learning/models/message.dart';

/// Explicit message-list load phase. Never infer loading from [messages].isEmpty.
enum ChatMessagesLoadPhase {
  /// No local snapshot yet (memory/prefs).
  noSnapshot,

  /// Cache and/or server read succeeded (including empty list).
  ready,

  /// Quiet background sync; UI must keep showing the last ready snapshot.
  refreshing,

  /// Network/server failure. Show cache if present; otherwise error UI.
  error,
}

/// Persistent/memory envelope for one chat owned by one auth user.
class ChatCacheSnapshot {
  const ChatCacheSnapshot({
    required this.found,
    required this.messages,
    this.savedAt,
    this.lastSyncedAt,
    this.oldestLoadedAt,
    this.hasMoreBefore = false,
    this.clearedAt,
  });

  /// `true` even when [messages] is empty — empty chat is a valid cache hit.
  final bool found;
  final List<Message> messages;
  final DateTime? savedAt;
  final DateTime? lastSyncedAt;
  final DateTime? oldestLoadedAt;
  final bool hasMoreBefore;
  final DateTime? clearedAt;

  static const ChatCacheSnapshot notFound = ChatCacheSnapshot(
    found: false,
    messages: <Message>[],
  );

  bool get hasSnapshot => found;

  ChatCacheSnapshot copyWith({
    bool? found,
    List<Message>? messages,
    DateTime? savedAt,
    DateTime? lastSyncedAt,
    DateTime? oldestLoadedAt,
    bool? hasMoreBefore,
    DateTime? clearedAt,
    bool clearClearedAt = false,
  }) {
    return ChatCacheSnapshot(
      found: found ?? this.found,
      messages: messages ?? this.messages,
      savedAt: savedAt ?? this.savedAt,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      oldestLoadedAt: oldestLoadedAt ?? this.oldestLoadedAt,
      hasMoreBefore: hasMoreBefore ?? this.hasMoreBefore,
      clearedAt: clearClearedAt ? clearedAt : (clearedAt ?? this.clearedAt),
    );
  }
}

/// UI-facing state for a chat message list.
class ChatMessagesViewState {
  const ChatMessagesViewState({
    required this.phase,
    required this.messages,
    this.hasSnapshot = false,
    this.hasMoreBefore = false,
    this.error,
  });

  final ChatMessagesLoadPhase phase;
  final List<Message> messages;
  final bool hasSnapshot;
  final bool hasMoreBefore;
  final Object? error;

  static const ChatMessagesViewState initial = ChatMessagesViewState(
    phase: ChatMessagesLoadPhase.noSnapshot,
    messages: <Message>[],
  );

  bool get isInitialLoading =>
      phase == ChatMessagesLoadPhase.noSnapshot && !hasSnapshot;

  bool get showError =>
      phase == ChatMessagesLoadPhase.error && !hasSnapshot && messages.isEmpty;

  bool get isRefreshing => phase == ChatMessagesLoadPhase.refreshing;

  ChatMessagesViewState copyWith({
    ChatMessagesLoadPhase? phase,
    List<Message>? messages,
    bool? hasSnapshot,
    bool? hasMoreBefore,
    Object? error,
    bool clearError = false,
  }) {
    return ChatMessagesViewState(
      phase: phase ?? this.phase,
      messages: messages ?? this.messages,
      hasSnapshot: hasSnapshot ?? this.hasSnapshot,
      hasMoreBefore: hasMoreBefore ?? this.hasMoreBefore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
