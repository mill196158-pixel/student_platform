import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';

/// A file confirmed by the last scoped source-message snapshot, not a claim
/// that its server-side status can be checked while offline.
class ScopedForwardFile {
  ScopedForwardFile(this.file, this._current);
  final ChatFile file;
  final bool Function() _current;
  bool get isCurrent {
    try { return _current(); } catch (_) { return false; }
  }
}

class ScopedForwardFileResolver {
  const ScopedForwardFileResolver({required this.store, required this.capabilities});
  final ProjectChatServerCache store;
  final SessionCapabilities capabilities;

  Future<ScopedForwardFile?> resolve({required String chatId, required String messageId,
      required String fileId, required String url}) async {
    if ([chatId, messageId, fileId, url].any((s) => s.isEmpty || s.length > 4096)) return null;
    try {
      final owner = store.scope.capture();
      final permit = capabilities.capture(SessionCapability.cachedRead);
      final revision = ProjectChatServerCache.snapshotChanges.value;
      if (owner == null || permit == null || !capabilities.owns(permit, owner)) return null;
      bool current() => !ProjectChatServerCache.snapshotMutationInProgress &&
          ProjectChatServerCache.snapshotChanges.value == revision &&
          capabilities.mode == SessionCapabilityMode.cacheOnly &&
          store.scope.isCurrent(owner) && capabilities.permits(permit, SessionCapability.cachedRead);
      if (!current()) return null;
      final messages = await store.read(chatId, capabilities);
      if (!current() || messages == null) return null;
      final source = messages.where((m) => m.chatId == chatId && m.id == messageId).toList();
      if (source.length != 1) return null;
      final files = source.single.attachments ?? const <ChatFile>[];
      final ids = files.where((f) => f.id == fileId).toList();
      final urls = files.where((f) => f.fileUrl == url).toList();
      if (ids.length != 1 || urls.length != 1 || !identical(ids.single, urls.single)) return null;
      final file = ids.single;
      if (file.chatId != chatId || file.messageId != messageId ||
          !file.deletionVerified || file.isDeleted || !current()) return null;
      return ScopedForwardFile(file, current);
    } catch (_) { return null; }
  }
}
