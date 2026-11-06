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
import '../../../../../core/auth_session_scope.dart';
import '../../../../../core/session_capabilities.dart';
import '../../../../../core/qa_rotation_receipt.dart';

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

  Session? _ownerSession;
  late final String? _ownerBinding;
  int _ownerGeneration = 0;
  bool _scopeRevoked = false;
  bool _uncertainOldOperations = false;
  bool get sessionInterrupted => _attachmentScopeQa && !_scopeCurrent();
  bool _disposed = false;
  final AuthSessionScope? authScope;
  final SessionCapabilities? capabilities;
  final QaRotationReceipt? rotationReceipt;
  AuthOperationScope? _originalOwner;
  final Set<Future<void>> _activeOperations = {};
  final Map<String, LocalAttach> _ownedEntries = {};
  final Map<String, (String, String?)> _ownedTargets = {};
  final Set<String> _dispatchedEntries = {};
  CapabilityPermit? _reboundPermit;

  ChatAttachmentsController(this.fileService, this.cache, this.supabase,
      {this.authScope, this.capabilities, this.rotationReceipt}) {
    _ownerSession = _attachmentScopeQa ? supabase.auth.currentSession : null;
    // This also installs the existing session observer before capturing epoch.
    _ownerBinding = _attachmentScopeQa ? ChatFileAccess.currentSessionBinding : null;
    _ownerGeneration = ChatFileAccess.generation;
    if (_attachmentScopeQa && authScope != null && capabilities != null && rotationReceipt != null) {
      _originalOwner = authScope!.capture();
      _reboundPermit = capabilities!.capture(SessionCapability.mutation);
      authScope!.addListener(_onAuthChanged);
      capabilities!.addListener(_onAuthChanged);
    }
  }

  Future<T> _track<T>(Future<T> Function() work) async {
    final done = Completer<void>();
    _activeOperations.add(done.future);
    try { return await work(); } finally {
      _activeOperations.remove(done.future);
      done.complete();
    }
  }

  Future<void> _releaseTemp(String path) => _attachmentScopeQa
      ? _track(() => ChatFileAccess.releaseForwardTemp(path))
      : ChatFileAccess.releaseForwardTemp(path);

  void _onAuthChanged() {
    if (_disposed || _scopeCurrent()) return;
    for (final token in _cancelTokens.values) { token.cancel('session changed'); }
    var changed = false;
    for (var i = 0; i < pending.length; i++) {
      final old = pending[i];
      if (old.isUploading && identical(_ownedEntries[old.localId], old)) {
        final next = old.copyWith(uploadStatus: LocalAttachUploadStatus.failed,
            errorMessage: 'Сессия обновилась. Повторите загрузку.');
        pending[i] = next;
        _ownedEntries[old.localId] = next;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  bool _scopeCurrent() {
    if (!_attachmentScopeQa) return true;
    if (_disposed) return false;
    if (_scopeRevoked) return false;
    var valid = false;
    try {
      final owner = _ownerSession;
      valid = owner != null && _ownerBinding != null &&
          identical(Supabase.instance.client, supabase) &&
          identical(supabase.auth.currentSession, owner) &&
          ChatFileAccess.userId == owner.user.id &&
          ChatFileAccess.currentSessionBinding == _ownerBinding &&
          ChatFileAccess.generation == _ownerGeneration &&
          ((authScope == null || capabilities == null || rotationReceipt == null) ||
              (_reboundPermit != null &&
               capabilities!.permits(_reboundPermit!, SessionCapability.mutation)));
    } catch (_) {
      valid = false;
    }
    if (!valid) {
      _scopeRevoked = true;
      if (_activeOperations.isNotEmpty) _uncertainOldOperations = true;
    }
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

  /// Only an explicit user retry can resume an in-memory item after a
  /// policy-verified same-session rotation. A receipt does not replace drain.
  Future<bool> _resumeForExplicitRetry(LocalAttach file, String chatId, String? teamId) async {
    final scope = authScope, caps = capabilities, receipt = rotationReceipt;
    final oldOwner = _originalOwner, oldSession = _ownerSession;
    if (_disposed || _uncertainOldOperations || scope == null || caps == null || receipt == null ||
        oldOwner == null || oldSession == null || _ownerBinding == null ||
        _dispatchedEntries.contains(file.localId) ||
        _ownedTargets[file.localId] != (chatId, teamId)) return false;
    final entry = _findPending(file.localId);
    if (entry == null || !entry.isFailed ||
        !identical(_ownedEntries[file.localId], entry)) return false;
    // Do not silently carry old server results or ownerless restored items.
    // They remain intact and require a separate reviewed recovery path.
    if (pending.any((item) => item.path != '__FG__' &&
        (!identical(_ownedEntries[item.localId], item) ||
         item.uploadedFileId != null))) return false;
    final currentSession = supabase.auth.currentSession;
    final currentOwner = scope.capture();
    final permit = caps.capture(SessionCapability.mutation);
    bool valid() {
      try {
        return !_disposed && currentSession != null && currentOwner != null &&
            permit != null && identical(Supabase.instance.client, supabase) &&
            identical(supabase.auth.currentSession, currentSession) &&
            currentSession.user.id == oldSession.user.id &&
            ChatFileAccess.userId == oldSession.user.id &&
            ChatFileAccess.currentSessionBinding == _ownerBinding &&
            ChatFileAccess.generation == _ownerGeneration &&
            scope.isCurrent(currentOwner) &&
            scope.matchesSession(currentOwner, currentSession) &&
            caps.permits(permit, SessionCapability.mutation) &&
            receipt.permitsResume(oldOwner, scope, caps) &&
            !_dispatchedEntries.contains(file.localId) &&
            _ownedTargets[file.localId] == (chatId, teamId) &&
            !pending.any((item) => item.path != '__FG__' &&
              (!identical(_ownedEntries[item.localId], item) || item.uploadedFileId != null)) &&
            identical(_ownedEntries[file.localId], entry) &&
            identical(_findPending(file.localId), entry);
      } catch (_) { return false; }
    }
    if (!valid()) return false;
    for (final token in _cancelTokens.values) { token.cancel('session changed'); }
    final elapsed = Stopwatch()..start();
    try {
      while (_activeOperations.isNotEmpty) {
        final remaining = const Duration(seconds: 10) - elapsed.elapsed;
        if (remaining <= Duration.zero) return false;
        await Future.wait(_activeOperations.toList()).timeout(remaining);
        if (!valid()) return false;
      }
    } catch (_) { return false; }
    if (!valid()) return false;
    _ownerSession = currentSession;
    _originalOwner = currentOwner;
    _reboundPermit = permit;
    _scopeRevoked = false;
    return true;
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
    final added = file.copyWith(
      uploadStatus: status,
      progress: status == LocalAttachUploadStatus.uploaded ? 1 : file.progress,
      clearError: true,
    );
    pending.add(added);
    if (_attachmentScopeQa) _ownedEntries[file.localId] = added;
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
      _ownedEntries.remove(removed.localId);
      _ownedTargets.remove(removed.localId);
      _dispatchedEntries.remove(removed.localId);
      unawaited(_releaseTemp(removed.path));
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
    unawaited(_releaseTemp(pending[index].path));
    _ownedEntries.remove(file.localId);
    _ownedTargets.remove(file.localId);
    _dispatchedEntries.remove(file.localId);
    pending.removeAt(index);
    notifyListeners();
  }

  Future<void> retry(
    LocalAttach file, {
    String? teamId,
    required String chatId,
    String? messageId,
    bool Function()? canDispatch,
  }) async {
    bool allowed() {
      try { return canDispatch?.call() ?? true; } catch (_) { return false; }
    }
    if (!allowed()) return;
    if (!_scopeCurrent()) {
      if (!_attachmentScopeQa || !await _resumeForExplicitRetry(file, chatId, teamId)) return;
    }
    if (!allowed()) return;
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
      canDispatch: canDispatch,
    );
  }

  /// The original target is memory-only and exists only for entries added by
  /// this controller. Never infer it from an ownerless restored draft.
  String? ownedTargetForRetry(LocalAttach file) {
    if (!_attachmentScopeQa) return null;
    final entry = _findPending(file.localId);
    if (entry == null || !identical(_ownedEntries[file.localId], entry)) return null;
    return _ownedTargets[file.localId]?.$1;
  }

  Future<void> upload(
    LocalAttach file, {
    String? teamId,
    required String chatId,
    String? messageId,
    bool Function()? canDispatch,
  }) async {
    if (!_attachmentScopeQa) {
      await _uploadLegacy(file, teamId: teamId, chatId: chatId, messageId: messageId);
      return;
    }
    await _track(() => _uploadScoped(file, teamId: teamId, chatId: chatId, messageId: messageId, canDispatch: canDispatch));
  }

  Future<void> _uploadScoped(LocalAttach file, {
    String? teamId,
    required String chatId,
    String? messageId,
    bool Function()? canDispatch,
  }) async {
    bool allowed() {
      try { return canDispatch?.call() ?? true; } catch (_) { return false; }
    }
    if (!_scopeCurrent() || !allowed()) return;
    final existingIndex = pending.indexWhere((f) => f.localId == file.localId);
    if (existingIndex == -1) return;
    final source = pending[existingIndex];
    if (source.path != file.path || source.name != file.name ||
        source.mimeType != file.mimeType || source.size != file.size ||
        source.isImage != file.isImage ||
        source.preserveOriginal != file.preserveOriginal) return;
    if (identical(_ownedEntries[file.localId], source)) {
      final previousTarget = _ownedTargets[file.localId];
      if (previousTarget != null && previousTarget != (chatId, teamId)) return;
      _ownedTargets[file.localId] = (chatId, teamId);
    }
    final operationSession = supabase.auth.currentSession;
    final operationOwner = ChatFileAccess.userId;
    final operationEpoch = ChatFileAccess.generation;
    bool sameOperationSession() => allowed() && operationSession != null && operationOwner != null &&
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
        onDispatch: () => _dispatchedEntries.add(file.localId),
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
        final next = pending[index].copyWith(
          uploadedFileId: savedId,
          uploadStatus: LocalAttachUploadStatus.uploaded,
          progress: 1,
          clearError: true,
        );
        if (identical(_ownedEntries[file.localId], pending[index])) {
          _ownedEntries[file.localId] = next;
        }
        pending[index] = next;
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
    if (_attachmentScopeQa) {
      await _track(() => _deleteUploadedScoped(fileId));
      return;
    }
    await _deleteUploadedScoped(fileId);
  }

  Future<void> _deleteUploadedScoped(String fileId) async {
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
      _ownedEntries.remove(file.localId);
      _ownedTargets.remove(file.localId);
      unawaited(_releaseTemp(file.path));
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
      _ownedEntries.remove(file.localId);
      _ownedTargets.remove(file.localId);
      unawaited(_releaseTemp(file.path));
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
    if (_attachmentScopeQa && identical(_ownedEntries[localId], pending[index])) {
      _ownedEntries[localId] = file;
    }
    pending[index] = file;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_attachmentScopeQa && authScope != null && capabilities != null && rotationReceipt != null) {
      authScope!.removeListener(_onAuthChanged);
      capabilities!.removeListener(_onAuthChanged);
      for (final token in _cancelTokens.values) { token.cancel('controller disposed'); }
    }
    super.dispose();
  }
}
