/// Tracks the currently opened chat so foreground pushes for that chat
/// can be suppressed (Realtime already updates the open conversation).
class ActiveChatTracker {
  ActiveChatTracker._();
  static final ActiveChatTracker instance = ActiveChatTracker._();

  String? _chatId;
  String? _teamId;
  bool Function()? _isCurrentRoute;
  int _messageListDepth = 0;

  String? get chatId => _chatId;
  bool get isViewingMessages => _chatId != null || _messageListDepth > 0;

  void enterMessageList() {
    _messageListDepth += 1;
  }

  void leaveMessageList() {
    if (_messageListDepth > 0) _messageListDepth -= 1;
  }

  void enter(String? chatId, {String? teamId, bool Function()? isCurrentRoute}) {
    _teamId = teamId;
    _isCurrentRoute = isCurrentRoute;
    final id = chatId?.trim();
    _chatId = (id == null || id.isEmpty) ? null : id;
  }

  void leave(String? chatId) {
    final id = chatId?.trim();
    if (id == null || id.isEmpty) return;
    if (_chatId == id) {
      _chatId = null;
      _teamId = null;
      _isCurrentRoute = null;
    }
  }

  bool isCurrentTeamChat(String? teamId, String? chatId) =>
      _teamId != null &&
      (teamId == null || teamId == _teamId) &&
      (chatId == null || chatId == _chatId) &&
      (teamId != null || chatId != null) &&
      (_isCurrentRoute?.call() ?? false);

  bool isActive(String? chatId) {
    final id = chatId?.trim();
    if (id == null || id.isEmpty) return false;
    return _chatId == id;
  }
}
