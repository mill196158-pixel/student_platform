import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

/// A previously confirmed author from the same project and offline session.
/// The caller must check [isCurrent] again when rendering the name.
class ScopedForwardAuthor {
  ScopedForwardAuthor._(this.name, this._current);
  final String name;
  final bool Function() _current;
  bool get isCurrent {
    try {
      return _current();
    } catch (_) {
      return false;
    }
  }
}

class ScopedForwardAuthorResolver {
  const ScopedForwardAuthorResolver(
      {required this.store, required this.capabilities});
  final ProjectChatServerCache store;
  final SessionCapabilities capabilities;

  Future<ScopedForwardAuthor?> resolve(
      {required String sourceChatId,
      required String messageId,
      required String authorId}) async {
    if (sourceChatId.trim().isEmpty ||
        messageId.trim().isEmpty ||
        authorId.trim().isEmpty ||
        sourceChatId.length > 256 ||
        messageId.length > 256 ||
        authorId.length > 256) return null;
    try {
      final AuthOperationScope? owner = store.scope.capture();
      final permit = capabilities.capture(SessionCapability.cachedRead);
      if (owner == null || permit == null || !capabilities.owns(permit, owner))
        return null;
      bool current() =>
          capabilities.mode == SessionCapabilityMode.cacheOnly &&
          store.scope.isCurrent(owner) &&
          capabilities.permits(permit, SessionCapability.cachedRead);
      if (!current()) return null;
      final messages = await store.read(sourceChatId, capabilities);
      if (!current() || messages == null) return null;
      final matches = messages
          .where((m) => m.chatId == sourceChatId && m.id == messageId)
          .toList();
      if (matches.length != 1 ||
          matches.single.authorId != authorId ||
          matches.single.authorNameVerified != true ||
          matches.single.authorName.trim().isEmpty) return null;
      return current()
          ? ScopedForwardAuthor._(matches.single.authorName, current)
          : null;
    } catch (_) {
      return null;
    }
  }
}
