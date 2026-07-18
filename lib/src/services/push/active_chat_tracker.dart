/// Tracks the currently opened chat so foreground pushes for that chat
/// can be suppressed (Realtime already updates the open conversation).
class ActiveChatTracker {
  ActiveChatTracker._();
  static final ActiveChatTracker instance = ActiveChatTracker._();

  String? _chatId;

  String? get chatId => _chatId;

  void enter(String? chatId) {
    final id = chatId?.trim();
    _chatId = (id == null || id.isEmpty) ? null : id;
  }

  void leave(String? chatId) {
    final id = chatId?.trim();
    if (id == null || id.isEmpty) return;
    if (_chatId == id) _chatId = null;
  }

  bool isActive(String? chatId) {
    final id = chatId?.trim();
    if (id == null || id.isEmpty) return false;
    return _chatId == id;
  }
}
