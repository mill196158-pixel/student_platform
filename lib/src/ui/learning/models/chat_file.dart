import 'package:flutter/material.dart';

enum ChatFileType { document, image, other }

class ChatFile {
  final String id;
  final String chatId;
  final String?
      messageId; // ID сообщения, к которому прикреплен файл (может быть null)
  final String fileName; // Оригинальное имя файла
  final String fileKey; // Ключ в Yandex Storage (путь)
  final String fileUrl; // URL для скачивания
  final String fileType; // MIME тип
  final int fileSize; // Размер в байтах
  final String uploadedBy; // ID пользователя, загрузившего файл
  final DateTime uploadedAt; // Время загрузки
  final bool isDeleted; // Флаг удаления

  const ChatFile({
    required this.id,
    required this.chatId,
    required this.messageId,
    required this.fileName,
    required this.fileKey,
    required this.fileUrl,
    required this.fileType,
    required this.fileSize,
    required this.uploadedBy,
    required this.uploadedAt,
    this.isDeleted = false,
  });

  // Определяем тип файла по MIME типу
  ChatFileType get type {
    if (fileType.startsWith('image/')) return ChatFileType.image;
    if (fileType.startsWith('application/') ||
        fileType.startsWith('text/') ||
        fileType.contains('pdf') ||
        fileType.contains('word') ||
        fileType.contains('excel') ||
        fileType.contains('powerpoint')) {
      return ChatFileType.document;
    }
    return ChatFileType.other;
  }

  // Проверяем, является ли файл изображением
  bool get isImage => fileType.startsWith('image/');

  // Проверяем, является ли файл документом
  bool get isDocument {
    return fileType.startsWith('application/') &&
        (fileName.toLowerCase().endsWith('.pdf') ||
            fileName.toLowerCase().endsWith('.doc') ||
            fileName.toLowerCase().endsWith('.docx') ||
            fileName.toLowerCase().endsWith('.txt') ||
            fileName.toLowerCase().endsWith('.dwg'));
  }

  // Получаем иконку для файла
  IconData get fileIcon {
    if (isImage) return Icons.image;
    if (fileName.toLowerCase().endsWith('.pdf')) return Icons.picture_as_pdf;
    if (fileName.toLowerCase().endsWith('.doc') ||
        fileName.toLowerCase().endsWith('.docx')) return Icons.description;
    if (fileName.toLowerCase().endsWith('.dwg')) return Icons.architecture;
    if (fileName.toLowerCase().endsWith('.txt')) return Icons.text_snippet;
    return Icons.attach_file;
  }

  // Получаем иконку для файла
  String get icon {
    switch (type) {
      case ChatFileType.image:
        return '🖼️';
      case ChatFileType.document:
        if (fileType.contains('pdf')) return '📄';
        if (fileType.contains('word')) return '📝';
        if (fileType.contains('excel')) return '📊';
        if (fileType.contains('powerpoint')) return '📈';
        if (fileType.contains('text')) return '📄';
        return '📎';
      case ChatFileType.other:
        return '📎';
    }
  }

  // Форматируем размер файла
  String get formattedSize {
    if (fileSize < 1024) return '$fileSize Б';
    if (fileSize < 1024 * 1024)
      return '${(fileSize / 1024).toStringAsFixed(1)} КБ';
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'chat_id': chatId,
        'message_id': messageId ?? '',
        'file_name': fileName,
        'file_key': fileKey,
        'file_url': fileUrl,
        'file_type': fileType,
        'file_size': fileSize,
        'uploaded_by': uploadedBy,
        'uploaded_at': uploadedAt.toIso8601String(),
        'is_deleted': isDeleted,
      };

  factory ChatFile.fromJson(Map<String, dynamic> j) => ChatFile(
        id: (j['id'] ?? '').toString(),
        chatId: (j['chat_id'] ?? '').toString(),
        messageId: j['message_id']?.toString(),
        fileName: (j['file_name'] ?? '').toString(),
        fileKey: (j['file_key'] ?? '').toString(),
        fileUrl: (j['file_url'] ?? '').toString(),
        fileType: (j['file_type'] ?? 'application/octet-stream').toString(),
        fileSize: _asInt(j['file_size']),
        uploadedBy: (j['uploaded_by'] ?? '').toString(),
        uploadedAt: DateTime.tryParse((j['uploaded_at'] ?? '').toString()) ??
            DateTime.now(),
        isDeleted: _asBool(j['is_deleted']),
      );

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString()) ?? 0;
  }

  static bool _asBool(dynamic value) {
    if (value is bool) return value;
    return value?.toString().toLowerCase() == 'true';
  }

  ChatFile copyWith({
    String? id,
    String? chatId,
    String? messageId,
    String? fileName,
    String? fileKey,
    String? fileUrl,
    String? fileType,
    int? fileSize,
    String? uploadedBy,
    DateTime? uploadedAt,
    bool? isDeleted,
  }) {
    return ChatFile(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      messageId: messageId ?? this.messageId,
      fileName: fileName ?? this.fileName,
      fileKey: fileKey ?? this.fileKey,
      fileUrl: fileUrl ?? this.fileUrl,
      fileType: fileType ?? this.fileType,
      fileSize: fileSize ?? this.fileSize,
      uploadedBy: uploadedBy ?? this.uploadedBy,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
