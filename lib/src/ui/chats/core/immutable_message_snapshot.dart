import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

/// A pre-existing in-memory snapshot may be used while a later history
/// eviction settles, but it never grants access after capability revocation.
class ScopedImmutableMessageSnapshot {
  ScopedImmutableMessageSnapshot._(this._capabilities, this._permit,
      this._sourceCurrent, this._messages);
  final SessionCapabilities _capabilities;
  final CapabilityPermit _permit;
  final bool Function() _sourceCurrent;
  final List<Message> _messages;
  bool _invalidated = false;

  static ScopedImmutableMessageSnapshot? capture({
    required SessionCapabilities capabilities,
    required bool Function() sourceCurrent,
    required Iterable<Message> alreadyLoaded,
  }) {
    try {
      if (historyEvictionInProgress || !sourceCurrent()) return null;
      final permit = capabilities.capture(SessionCapability.cachedRead);
      if (permit == null) return null;
      final snapshot = immutableMessageSnapshot(alreadyLoaded);
      if (historyEvictionInProgress || !sourceCurrent() ||
          !capabilities.permits(permit, SessionCapability.cachedRead)) return null;
      return ScopedImmutableMessageSnapshot._(capabilities, permit, sourceCurrent, snapshot);
    } catch (_) {
      return null;
    }
  }

  List<Message>? get readable {
    if (_invalidated) return null;
    try {
      if (_sourceCurrent() && _capabilities.permits(_permit, SessionCapability.cachedRead)) {
        return _messages;
      }
    } catch (_) {
      // Unknown validity is a permanent invalidation of this captured view.
    }
    _invalidated = true;
    return null;
  }
}

/// Detaches every mutable collection used by a Message. The returned messages
/// remain subject to the caller's live account/capability checks.
List<Message> immutableMessageSnapshot(Iterable<Message> messages) =>
    List<Message>.unmodifiable(messages.map(_detachMessage));

Message _detachMessage(Message message) {
  final forward = message.forward;
  return message.copyWith(
    attachments: message.attachments == null
        ? null : List.unmodifiable(message.attachments!),
    reactions: message.reactions == null
        ? null : Map.unmodifiable(message.reactions!),
    userReactions: message.userReactions == null
        ? null : List.unmodifiable(message.userReactions!),
    outboundFileIds: List.unmodifiable(message.outboundFileIds),
    forward: forward == null ? null : ForwardPayloadModel(
      fromChatId: forward.fromChatId,
      fromChatTitle: forward.fromChatTitle,
      items: List.unmodifiable(forward.items.map((item) => ForwardItemModel(
        id: item.id,
        authorId: item.authorId,
        authorName: item.authorName,
        at: item.at,
        text: item.text,
        attachments: List.unmodifiable(item.attachments),
      ))),
    ),
  );
}
