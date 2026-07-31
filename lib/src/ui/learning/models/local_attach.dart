enum LocalAttachUploadStatus {
  queued,
  uploading,
  uploaded,
  failed,
  canceled,
}

class LocalAttach {
  final String localId;
  final String path;
  final String name;
  final String mimeType;
  final int size;
  final bool isImage;
  final LocalAttachUploadStatus uploadStatus;
  final double progress;
  final String? errorMessage;
  final String? uploadedFileId; // ID файла после загрузки в БД

  LocalAttach({
    String? localId,
    required this.path,
    required String name,
    required this.mimeType,
    required this.size,
    required this.isImage,
    this.uploadStatus = LocalAttachUploadStatus.queued,
    this.progress = 0,
    this.errorMessage,
    this.uploadedFileId,
  })  : localId = localId ?? _newLocalId(),
        name = _baseName(name);

  bool get isQueued => uploadStatus == LocalAttachUploadStatus.queued;
  bool get isUploading => uploadStatus == LocalAttachUploadStatus.uploading;
  bool get isUploaded => uploadStatus == LocalAttachUploadStatus.uploaded;
  bool get isFailed => uploadStatus == LocalAttachUploadStatus.failed;
  bool get isCanceled => uploadStatus == LocalAttachUploadStatus.canceled;
  bool get canRetry => isFailed;
  bool get canCancel => isQueued || isUploading;

  LocalAttach copyWith({
    String? uploadedFileId,
    LocalAttachUploadStatus? uploadStatus,
    double? progress,
    String? errorMessage,
    bool clearError = false,
  }) {
    return LocalAttach(
      localId: localId,
      path: path,
      name: name,
      mimeType: mimeType,
      size: size,
      isImage: isImage,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      progress: progress ?? this.progress,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      uploadedFileId: uploadedFileId ?? this.uploadedFileId,
    );
  }

  static String _newLocalId() =>
      'local-${DateTime.now().microsecondsSinceEpoch}';

  static String _baseName(String value) {
    return value.split(RegExp(r'[\\/]')).last;
  }
}

// Удаляем дублирующую модель AttachedFile - она уже есть в composer.dart
