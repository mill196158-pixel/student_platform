import 'dart:convert';

import '../../learning/models/local_attach.dart';
import '../../learning/models/message.dart';
import '../core/forward_payload.dart';

/// Snapshot used to avoid clearing attachments added or changed during send.
class ForwardAttachmentSnapshot {
  ForwardAttachmentSnapshot(List<LocalAttach> files)
      : _ids = files.map((f) => f.localId).toList(growable: false),
        _state = files
            .map((f) => (f.localId, f.uploadedFileId, f.uploadStatus))
            .toList(growable: false);
  final List<String> _ids;
  final List<(String, String?, LocalAttachUploadStatus)> _state;
  bool sameFiles(List<LocalAttach> files) =>
      files.length == _ids.length &&
      List.generate(files.length, (i) => files[i].localId == _ids[i])
          .every((value) => value);
  bool containsUnchanged(LocalAttach file) =>
      _state.contains((file.localId, file.uploadedFileId, file.uploadStatus));
  bool sameState(List<LocalAttach> files) =>
      sameFiles(files) &&
      List.generate(
          files.length,
          (i) =>
              (
                files[i].localId,
                files[i].uploadedFileId,
                files[i].uploadStatus
              ) ==
              _state[i]).every((value) => value);
}

/// A confirmed send consumes its old forward, but only clears composer fields
/// that still match the values actually sent.
({bool clearText, bool clearReply}) confirmedForwardCleanup({
  required String sentText,
  required String currentText,
  required String? sentReplyId,
  required String? currentReplyId,
}) =>
    (
      clearText: sentText == currentText,
      clearReply: sentReplyId == currentReplyId
    );

/// Refuse to send a prepared forward unless every captured local attachment
/// still exists, completed upload, and every prepared forward ID is present.
/// No composer or queue state is changed on refusal.
Future<bool> sendPreparedForwardIfComplete({
  required List<LocalAttach> requiredFiles,
  required List<LocalAttach> currentFiles,
  required Iterable<String> stagedFileIds,
  required Set<String> expectedForwardFileIds,
  required Future<void> Function(List<String>) send,
  required bool Function() isCurrent,
}) async {
  if (!isCurrent()) return false;
  final ids = <String>{};
  for (final id in stagedFileIds) {
    if (id.trim().isEmpty) return false;
    ids.add(id);
  }
  for (final required in requiredFiles) {
    final matches =
        currentFiles.where((item) => item.localId == required.localId);
    if (matches.length != 1) return false;
    final file = matches.single;
    final id = file.uploadedFileId;
    if (!file.isUploaded || id == null || id.trim().isEmpty) return false;
    ids.add(id);
  }
  if (!ids.containsAll(expectedForwardFileIds)) return false;
  if (!isCurrent()) return false;
  await send(ids.toList(growable: false));
  return true;
}

/// Returns null rather than silently dropping a selected message or file.
List<Message>? completeForwardSelection(
    List<String> selectedIds, List<Message> messages) {
  if (selectedIds.isEmpty ||
      selectedIds.any((id) => id.trim().isEmpty) ||
      selectedIds.toSet().length != selectedIds.length) return null;
  final selected =
      messages.where((message) => selectedIds.contains(message.id)).toList();
  if (selected.length != selectedIds.length ||
      selected.map((message) => message.id).toSet().length !=
          selectedIds.length) return null;
  for (final message in selected) {
    if (ForwardPayload.isForwardText(message.text)) {
      final nested = ForwardPayload.tryParse(message.text);
      if (nested == null ||
          !forwardSourceReferencesComplete(nested, const [])) {
        return null;
      }
    }
    final attachments = message.attachments ?? const [];
    final referencedIds = <String>{
      if ((message.fileId ?? '').trim().isNotEmpty) message.fileId!.trim(),
      for (final id in message.outboundFileIds)
        if (id.trim().isNotEmpty) id.trim(),
    };
    final attachedIds = attachments.map((file) => file.id.trim()).toSet();
    if ((message.type == MessageType.file && attachments.isEmpty) ||
        !attachedIds.containsAll(referencedIds)) return null;
    for (final attachment in attachments) {
      if (attachment.id.trim().isEmpty ||
          attachment.fileUrl.trim().isEmpty ||
          attachment.isDeleted) return null;
    }
  }
  selected.sort((a, b) => a.at.compareTo(b.at));
  return selected;
}

/// Freezes every message field that is copied into the forward payload.
/// A same-ID replacement while an asynchronous chat lookup runs must not
/// send stale text or stale attachment metadata.
class ForwardSelectionSnapshot {
  ForwardSelectionSnapshot(List<Message> selected)
      : _selectedIds =
            selected.map((message) => message.id).toList(growable: false),
        _signatures = {
          for (final message in selected) message.id: _signature(message)
        };

  final List<String> _selectedIds;
  final Map<String, String> _signatures;

  static String _signature(Message message) => jsonEncode([
        message.id,
        message.chatId,
        message.authorId,
        message.authorName,
        message.authorAvatarUrl,
        message.at.toIso8601String(),
        message.text,
        message.type.name,
        message.fileId,
        message.outboundFileIds,
        for (final file in message.attachments ?? const [])
          [
            file.id,
            file.fileUrl,
            file.fileName,
            file.fileType,
            file.fileSize,
            file.isDeleted
          ],
      ]);

  bool matches(List<Message> current) {
    final selected = completeForwardSelection(_selectedIds, current);
    return selected != null &&
        selected.length == _signatures.length &&
        selected
            .every((message) => _signatures[message.id] == _signature(message));
  }
}

/// IDs received from a handoff must map to a URL-bearing payload reference;
/// otherwise preparation could silently turn an attachment into plain text.
bool forwardSourceReferencesComplete(
    ForwardPayload payload, List<String> fileIds) {
  try {
    bool validNested(ForwardPayload value, int depth) {
      if (depth > 8) return false;
      for (final item in value.items) {
        if (!ForwardPayload.isForwardText(item.text)) continue;
        final nested = ForwardPayload.tryParse(item.text);
        if (nested == null || !validNested(nested, depth + 1)) return false;
      }
      return true;
    }

    if (!validNested(payload, 0)) return false;
    final refs = payload.allFiles();
    if (refs.any((ref) => ref.url.trim().isEmpty)) return false;
    final byId = {
      for (final ref in refs)
        if (ref.id != null && ref.id!.trim().isNotEmpty) ref.id!.trim()
    };
    return fileIds
        .every((id) => id.trim().isNotEmpty && byId.contains(id.trim()));
  } catch (_) {
    return false;
  }
}
