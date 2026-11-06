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

class ChatAttachmentsController extends ChangeNotifier {
  final FileService fileService;
  final GlobalCache cache;
  final SupabaseClient supabase;

  final List<LocalAttach> pending = [];
  final Map<String, CancelToken> _cancelTokens = {};
  static const int maxFiles = 3;

  ChatAttachmentsController(this.fileService, this.cache, this.supabase);

  bool add(LocalAttach file) {
    if (pending.where((f)=>f.path!='__FG__').length >= maxFiles) {
      // мягко отказываем
      return false;
    }
    if (pending.any((f) => f.path == file.path)) {
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
    try {
      final row = await supabase.from('chat_files').select('file_key').eq('id',fileId).maybeSingle();
      if (row != null) await supabase.rpc('discard_unattached_chat_upload',params:{'p_key':row['file_key']});
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
