import '../../../../../services/chat_file_access.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';
import 'dart:io';
import '../../../../../services/file_service.dart';
import '../../../global_cache.dart';
import '../../../models/local_attach.dart';

// The exact-session fence remains experimental until safe token refresh rebind
// is proven. Default builds retain their previous attachment-session behavior.
const _attachmentScopeQa = bool.fromEnvironment('CHAT_ATTACHMENT_SESSION_FENCE_QA');

class ChatAttachmentsController extends ChangeNotifier {
  final FileService fileService;
  final GlobalCache cache;
  final SupabaseClient supabase;

  final List<LocalAttach> pending = [];
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, (CancelToken, LocalAttach)> _operationEntries = {};
  static const int maxFiles = 3;

  late final Session? _ownerSession;
  late final String? _ownerBinding;
  late final int _ownerGeneration;
  bool _scopeRevoked = false;

  ChatAttachmentsController(this.fileService, this.cache, this.supabase) {
    _ownerSession = _attachmentScopeQa ? supabase.auth.currentSession : null;
    // This also installs the existing session observer before capturing epoch.
    _ownerBinding = _attachmentScopeQa ? ChatFileAccess.currentSessionBinding : null;
    _ownerGeneration = ChatFileAccess.generation;
  }

  bool _scopeCurrent() {
    if (!_attachmentScopeQa) return true;
    if (_scopeRevoked) return false;
    var valid = false;
    try {
      final owner = _ownerSession;
      valid = owner != null && _ownerBinding != null &&
          identical(Supabase.instance.client, supabase) &&
          identical(supabase.auth.currentSession, owner) &&
          ChatFileAccess.userId == owner.user.id &&
          ChatFileAccess.currentSessionBinding == _ownerBinding &&
          ChatFileAccess.generation == _ownerGeneration;
    } catch (_) {
      valid = false;
    }
    if (!valid) _scopeRevoked = true;
    return valid;
  }

  bool _sameAttachment(LocalAttach source, CancelToken token) {
    if (!_scopeCurrent() || token.isCancelled ||
        !identical(_cancelTokens[source.localId], token)) return false;
    if (!_attachmentScopeQa) return true;
    final current = _findPending(source.localId);
    final operation = _operationEntries[source.localId];
    return current != null && operation != null &&
        identical(operation.$1, token) && identical(operation.$2, current) &&
        !current.isCanceled &&
        current.path == source.path && current.name == source.name &&
        current.mimeType == source.mimeType && current.size == source.size &&
        current.isImage == source.isImage &&
        current.preserveOriginal == source.preserveOriginal;
  }

  bool add(LocalAttach file) {
    if (!_scopeCurrent()) return false;
    if (pending.where((f)=>f.path!='__FG__').length >= maxFiles) {
      // мягко отказываем
      return false;
    }
    if (pending.any((f) => f.path == file.path ||
        (_attachmentScopeQa && f.localId == file.localId))) {
      // исключаем дубли
      return false;
    }

    final status = (file.uploadedFileId?.isNotEmpty ?? false)
        ? LocalAttachUploadStatus.uploaded
        : LocalAttachUploadStatus.queued;
    pending.add(file.copyWith(
      uploadStatus: status,
      progress: status == LocalAttachUploadStatus.uploaded ? 1 : file.progress,
      clearError: true,
    ));
    notifyListeners();
    return true;
  }

  void remove(LocalAttach file) {
    if (!_scopeCurrent()) {
      _cancelTokens.remove(file.localId)?.cancel('session changed');
      return;
    }
    final index = pending.indexWhere((f) => f.localId == file.localId);
    if (index != -1) {
      final removed = pending.removeAt(index);
      unawaited(ChatFileAccess.releaseForwardTemp(removed.path));
      _cancelTokens.remove(removed.localId)?.cancel('attachment removed');
      if (removed.uploadedFileId != null) {
        deleteUploaded(removed.uploadedFileId!);
      }
      notifyListeners();
    }
  }

  void cancel(LocalAttach file) {
    if (!_scopeCurrent()) {
      _cancelTokens.remove(file.localId)?.cancel('session changed');
      return;
    }
    final index = pending.indexWhere((f) => f.localId == file.localId);
    if (index == -1) return;

    pending[index] = pending[index].copyWith(
      uploadStatus: LocalAttachUploadStatus.canceled,
      progress: 0,
      clearError: true,
    );
    final uploadedId = pending[index].uploadedFileId;
    if (uploadedId != null) unawaited(deleteUploaded(uploadedId));
    _cancelTokens.remove(file.localId)?.cancel('attachment canceled');
    unawaited(ChatFileAccess.releaseForwardTemp(pending[index].path));
    pending.removeAt(index);
    notifyListeners();
  }

  Future<void> retry(
    LocalAttach file, {
    String? teamId,
    required String chatId,
    String? messageId,
  }) async {
    if (!_scopeCurrent()) return;
    final index = pending.indexWhere((f) => f.localId == file.localId);
    if (index == -1) return;
    await upload(
      pending[index].copyWith(
        uploadStatus: LocalAttachUploadStatus.queued,
        progress: 0,
        clearError: true,
      ),
      teamId: teamId,
      chatId: chatId,
      messageId: messageId,
    );
  }

  Future<void> upload(
    LocalAttach file, {
    String? teamId,
    required String chatId,
    String? messageId,
  }) async {
    if (!_attachmentScopeQa) {
      await _uploadLegacy(file, teamId: teamId, chatId: chatId, messageId: messageId);
      return;
    }
    if (!_scopeCurrent()) return;
    final existingIndex = pending.indexWhere((f) => f.localId == file.localId);
    if (existingIndex == -1) return;
    final source = pending[existingIndex];
    if (source.path != file.path || source.name != file.name ||
        source.mimeType != file.mimeType || source.size != file.size ||
        source.isImage != file.isImage ||
        source.preserveOriginal != file.preserveOriginal) return;
    final operationSession = supabase.auth.currentSession;
    final operationOwner = ChatFileAccess.userId;
    final operationEpoch = ChatFileAccess.generation;
    bool sameOperationSession() => operationSession != null && operationOwner != null &&
        operationOwner == ChatFileAccess.userId && operationEpoch == ChatFileAccess.generation;
    if (!sameOperationSession()) return;
    final uploadToken = CancelToken();
    _cancelTokens[file.localId]?.cancel('attachment retry');
    _cancelTokens[file.localId] = uploadToken;
    final uploading = source.copyWith(
      uploadStatus: LocalAttachUploadStatus.uploading,
      progress: 0,
      clearError: true,
    );
    _operationEntries[file.localId] = (uploadToken, uploading);
    _replacePending(file.localId, uploading);

    try {
      if (!sameOperationSession() || !_sameAttachment(source, uploadToken)) return;
      if (source.path.isEmpty) {
        throw Exception('File path is empty');
      }

      // Загружаем в Object Storage и получаем метаданные
      final uploadedChatFile = await fileService.uploadFileToChat(
        file: File(source.path),
        chatId: chatId,
        messageId: messageId ?? '',
        uploadedBy: operationSession!.user.id,
        customFileName: source.name,
        preserveOriginal: source.preserveOriginal,
        cancelToken: uploadToken,
        isCurrent: _attachmentScopeQa
            ? () => sameOperationSession() && _sameAttachment(source, uploadToken)
            : null,
        onProgress: (sent, total) {
          if (total <= 0 || !_sameAttachment(source, uploadToken)) return;
          final progress = (sent / total).clamp(0.0, 1.0);
          final current = _findPending(file.localId);
          if (current == null || current.isCanceled) return;
          final next = current.copyWith(
            uploadStatus: LocalAttachUploadStatus.uploading,
            progress: progress,
            clearError: true,
          );
          _operationEntries[file.localId] = (uploadToken, next);
          _replacePending(file.localId, next);
        },
      );

      if (!sameOperationSession() || !_scopeCurrent()) return;
      final current = _findPending(file.localId);
      if (current == null || current.isCanceled || uploadToken.isCancelled) {
        await supabase.rpc('discard_unattached_chat_upload',params:{'p_key':uploadedChatFile.fileKey});
        return;
      }
      if (!_sameAttachment(source, uploadToken)) return;

      // Сохраняем запись в БД и получаем её ID
      final savedId = await _saveChatFileToDatabase(
        chatId: chatId,
        fileName: uploadedChatFile.fileName,
        fileKey: uploadedChatFile.fileKey,
        fileUrl: uploadedChatFile.fileUrl,
        fileType: uploadedChatFile.fileType,
        fileSize: uploadedChatFile.fileSize,
        uploadedBy: operationSession.user.id,
        messageId: messageId,
      );
      if (!sameOperationSession() || !_sameAttachment(source, uploadToken)) return;
      await cache.cacheFile(savedId, uploadedChatFile.copyWith(id: savedId));
      if (!sameOperationSession() || !_scopeCurrent()) return;

      // Обновляем файл в списке, если не был удалён во время загрузки
      final index = pending.indexWhere((f) => f.localId == file.localId);
      if (index != -1 && _sameAttachment(source, uploadToken)) {
        pending[index] = pending[index].copyWith(
          uploadedFileId: savedId,
          uploadStatus: LocalAttachUploadStatus.uploaded,
          progress: 1,
          clearError: true,
        );
        notifyListeners();
      } else if (index == -1 && _scopeCurrent()) {
        await deleteUploaded(savedId);
      }
    } catch (e) {
      if (!_sameAttachment(source, uploadToken)) {
        return;
      }
      final current = _findPending(file.localId);
      if (current != null && !current.isCanceled) {
        _replacePending(
          file.localId,
          current.copyWith(
            uploadStatus: LocalAttachUploadStatus.failed,
            errorMessage: 'Не удалось загрузить',
          ),
        );
      }
      safeDebugLog('[ChatAttachments] upload failed: ${e.runtimeType}');
    } finally {
      if (identical(_cancelTokens[file.localId], uploadToken)) {
        _cancelTokens.remove(file.localId);
      }
      if (identical(_operationEntries[file.localId]?.$1, uploadToken)) {
        _operationEntries.remove(file.localId);
      }
    }
  }

  Future<void> _uploadLegacy(
    LocalAttach file, {
    String? teamId,
    required String chatId,
    String? messageId,
  }) async {
    final existingIndex = pending.indexWhere((f) => f.localId == file.localId);
    if (existingIndex == -1) return;

    final owner=ChatFileAccess.userId, epoch=ChatFileAccess.generation;
    bool sameSession()=>owner!=null && owner==ChatFileAccess.userId && epoch==ChatFileAccess.generation;
    if(!sameSession()) return;
    final uploadToken = CancelToken();
    _cancelTokens[file.localId]?.cancel('attachment retry');
    _cancelTokens[file.localId] = uploadToken;
    _replacePending(
      file.localId,
      pending[existingIndex].copyWith(
        uploadStatus: LocalAttachUploadStatus.uploading,
        progress: 0,
        clearError: true,
      ),
    );

    try {
      if (file.path.isEmpty) {
        throw Exception('File path is empty');
      }

      // Загружаем в Object Storage и получаем метаданные
      final uploadedChatFile = await fileService.uploadFileToChat(
        file: File(file.path),
        chatId: chatId,
        messageId: messageId ?? '',
        uploadedBy: supabase.auth.currentUser!.id,
        customFileName: file.name,
        preserveOriginal: file.preserveOriginal,
        cancelToken: uploadToken,
        onProgress: (sent, total) {
          if (total <= 0) return;
          final progress = (sent / total).clamp(0.0, 1.0);
          final current = _findPending(file.localId);
          if (current == null || current.isCanceled) return;
          _replacePending(
            file.localId,
            current.copyWith(
              uploadStatus: LocalAttachUploadStatus.uploading,
              progress: progress,
              clearError: true,
            ),
          );
        },
      );

      if(!sameSession()) return;
      final current = _findPending(file.localId);
      if (current == null || current.isCanceled || uploadToken.isCancelled) {
        await supabase.rpc('discard_unattached_chat_upload',params:{'p_key':uploadedChatFile.fileKey});
        return;
      }

      // Сохраняем запись в БД и получаем её ID
      final savedId = await _saveChatFileToDatabase(
        chatId: chatId,
        fileName: uploadedChatFile.fileName,
        fileKey: uploadedChatFile.fileKey,
        fileUrl: uploadedChatFile.fileUrl,
        fileType: uploadedChatFile.fileType,
        fileSize: uploadedChatFile.fileSize,
        uploadedBy: supabase.auth.currentUser!.id,
        messageId: messageId,
      );
      if(!sameSession()) return;
      await cache.cacheFile(savedId, uploadedChatFile.copyWith(id: savedId));

      // Обновляем файл в списке, если не был удалён во время загрузки
      final index = pending.indexWhere((f) => f.localId == file.localId);
      if (index != -1) {
        pending[index] = pending[index].copyWith(
          uploadedFileId: savedId,
          uploadStatus: LocalAttachUploadStatus.uploaded,
          progress: 1,
          clearError: true,
        );
        notifyListeners();
      } else {
        await deleteUploaded(savedId);
      }
    } catch (e) {
      if (uploadToken.isCancelled) {
        return;
      }
      final current = _findPending(file.localId);
      if (current != null && !current.isCanceled) {
        _replacePending(
          file.localId,
          current.copyWith(
            uploadStatus: LocalAttachUploadStatus.failed,
            errorMessage: 'Не удалось загрузить',
          ),
        );
      }
      safeDebugLog('[ChatAttachments] upload failed: ${e.runtimeType}');
    } finally {
      if (identical(_cancelTokens[file.localId], uploadToken)) {
        _cancelTokens.remove(file.localId);
      }
    }
  }

  Future<void> deleteUploaded(String fileId) async {
    if (!_scopeCurrent()) return;
    try {
      final row = await supabase.from('chat_files').select('file_key').eq('id',fileId).maybeSingle();
      if (_scopeCurrent() && row != null) await supabase.rpc('discard_unattached_chat_upload',params:{'p_key':row['file_key']});
    } catch (e) {
      safeDebugLog('[ChatAttachments] deleteUploaded failed: ${e.runtimeType}');
    }
  }

  Future<String> _saveChatFileToDatabase({
    required String chatId,
    required String fileName,
    required String fileKey,
    required String fileUrl,
    required String fileType,
    required int fileSize,
    required String uploadedBy,
    String? messageId,
  }) async {
    final response = await supabase.rpc('save_chat_file', params: {
      'p_chat_id': chatId,
      'p_file_name': fileName,
      'p_file_key': fileKey,
      'p_file_url': fileUrl,
      'p_file_type': fileType,
      'p_file_size': fileSize,
      'p_uploaded_by': uploadedBy,
      'p_message_id':
          (messageId == null || messageId.isEmpty) ? null : messageId,
    });
    return response.toString();
  }

  /// Forget only attachments confirmed as sent. The server owns those files
  /// now; unlike cancellation this must never discard uploaded objects.
  void forgetConfirmedSent(bool Function(LocalAttach) matches) {
    if (!_scopeCurrent()) return;
    final removed = pending.where(matches).toList(growable: false);
    if (removed.isEmpty) return;
    pending.removeWhere(matches);
    for (final file in removed) {
      _cancelTokens.remove(file.localId)?.cancel('attachment already sent');
      unawaited(ChatFileAccess.releaseForwardTemp(file.path));
    }
    notifyListeners();
  }

  void clear() {
    if (!_scopeCurrent()) {
      for (final token in _cancelTokens.values) { token.cancel('session changed'); }
      _cancelTokens.clear();
      return;
    }
    for (final file in pending) {
      unawaited(ChatFileAccess.releaseForwardTemp(file.path));
      _cancelTokens.remove(file.localId)?.cancel('attachments cleared');
      if (file.uploadedFileId != null) {
        deleteUploaded(file.uploadedFileId!);
      }
    }
    pending.clear();
    notifyListeners();
  }

  List<LocalAttach> getPendingFiles() => List.from(pending);

  bool get hasActiveUploads => pending.any(
        (file) => file.path != '__FG__' && (file.isQueued || file.isUploading),
      );

  bool get hasFailedUploads => pending.any(
        (file) => file.path != '__FG__' && file.isFailed,
      );

  bool get allUploadsReady => pending
      .where((file) => file.path != '__FG__')
      .every((file) => file.isUploaded && file.uploadedFileId != null);

  LocalAttach? _findPending(String localId) {
    for (final file in pending) {
      if (file.localId == localId) return file;
    }
    return null;
  }

  void _replacePending(String localId, LocalAttach file) {
    final index = pending.indexWhere((f) => f.localId == localId);
    if (index == -1) return;
    pending[index] = file;
    notifyListeners();
  }
}
