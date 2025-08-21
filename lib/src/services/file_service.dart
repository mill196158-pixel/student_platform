import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart' as picker;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import '../config/yandex_storage_config.dart';
import 's3_client.dart';
import '../ui/learning/models/chat_file.dart';

class FileService {
  late final S3Client _s3Client;
  final ImagePicker _imagePicker = ImagePicker();

  FileService() {
    if (YandexStorageConfig.isConfigured) {
      _s3Client = S3Client(
        accessKey: YandexStorageConfig.accessKey,
        secretKey: YandexStorageConfig.secretKey,
        bucketName: YandexStorageConfig.bucketName,
        region: YandexStorageConfig.region,
        endpoint: YandexStorageConfig.endpoint,
      );
    } else {
      throw Exception('Yandex Storage не настроен! Заполните данные в YandexStorageConfig');
    }
  }

  // Тест подключения
  Future<TestResult> testConnection() async {
    try {
      final success = await _s3Client.testConnection();
      return TestResult(
        success: success,
        error: success ? null : 'Не удалось подключиться к Яндекс Storage',
      );
    } catch (e) {
      return TestResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Загрузка тестового файла
  Future<FileUploadResult> uploadTestFile() async {
    try {
      // Создаем тестовый файл в памяти
      final testContent = 'Тестовый файл от ${DateTime.now().toString()}\n'
          'Этот файл был создан для проверки подключения к Яндекс Object Storage.\n'
          'Время создания: ${DateTime.now().toIso8601String()}';
      
      final testBytes = testContent.codeUnits;
      final testFileName = 'test_connection_${DateTime.now().millisecondsSinceEpoch}.txt';
      final testFileKey = 'test/$testFileName';
      
      final result = await _s3Client.putObject(
        key: testFileKey,
        body: Uint8List.fromList(testBytes),
        contentType: 'text/plain',
      );

      if (result.success) {
        return FileUploadResult(
          success: true,
          fileKey: result.fileKey!,
          fileName: testFileName,
          fileUrl: result.fileUrl!,
          fileType: 'documents',
          fileSize: testBytes.length,
        );
      } else {
        return FileUploadResult(
          success: false,
          error: result.error,
        );
      }
    } catch (e) {
      return FileUploadResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Загрузка файла в чат (создает запись в chat_files)
  Future<ChatFile> uploadFileToChat({
    required File file,
    required String chatId,
    required String messageId,
    required String uploadedBy,
    String? customFileName,
  }) async {
    try {
      final fileName = customFileName ?? file.path.split('/').last;
      final fileType = _getFileType(fileName);
      final fileKey = _generateFileKey(fileName, chatId, fileType);
      
      final bytes = await file.readAsBytes();
      
      final result = await _s3Client.putObject(
        key: fileKey,
        body: bytes,
        contentType: _getContentType(fileName),
      );

      if (result.success) {
        return ChatFile(
          id: '', // Будет заполнено на сервере
          chatId: chatId,
          messageId: messageId,
          fileName: fileName,
          fileKey: result.fileKey!,
          fileUrl: result.fileUrl!,
          fileType: _getContentType(fileName),
          fileSize: bytes.length,
          uploadedBy: uploadedBy,
          uploadedAt: DateTime.now(),
        );
      } else {
        throw Exception(result.error ?? 'Неизвестная ошибка загрузки файла');
      }
    } catch (e) {
      throw Exception('Ошибка загрузки файла: $e');
    }
  }

  // Загрузка файла (старый метод для совместимости)
  Future<FileUploadResult> uploadFile({
    required File file,
    required String chatId,
    String? customFileName,
  }) async {
    try {
      final fileName = customFileName ?? file.path.split('/').last;
      final fileType = _getFileType(fileName);
      final fileKey = _generateFileKey(fileName, chatId, fileType);
      
      final bytes = await file.readAsBytes();
      
      final result = await _s3Client.putObject(
        key: fileKey,
        body: bytes,
        contentType: _getContentType(fileName),
      );

      if (result.success) {
        return FileUploadResult(
          success: true,
          fileKey: result.fileKey!,
          fileName: fileName,
          fileUrl: result.fileUrl!,
          fileType: fileType,
          fileSize: bytes.length,
        );
      } else {
        return FileUploadResult(
          success: false,
          error: result.error,
        );
      }
    } catch (e) {
      return FileUploadResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Выбор файла
  Future<File?> pickFile({
    picker.FileType type = picker.FileType.any,
    List<String>? allowedExtensions,
  }) async {
    try {
      final result = await picker.FilePicker.platform.pickFiles(
        type: type,
        allowedExtensions: allowedExtensions,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = File(result.files.first.path!);
        return file;
      }
      return null;
    } catch (e) {
      print('Ошибка выбора файла: $e');
      return null;
    }
  }

  // Выбор изображения
  Future<File?> pickImage({ImageSource source = ImageSource.gallery}) async {
    try {
      final XFile? image = await _imagePicker.pickImage(source: source);
      if (image != null) {
        return File(image.path);
      }
      return null;
    } catch (e) {
      print('Ошибка выбора изображения: $e');
      return null;
    }
  }

  // Вспомогательные методы
  String _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return 'documents';
      case 'doc':
      case 'docx':
        return 'documents';
      case 'dwg':
        return 'documents';
      case 'txt':
        return 'documents';
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return 'images';
      case 'zip':
      case 'rar':
        return 'archives';
      default:
        return 'other';
    }
  }

  String _getContentType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'dwg':
        return 'application/acad';
      case 'txt':
        return 'text/plain';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'zip':
        return 'application/zip';
      case 'rar':
        return 'application/x-rar-compressed';
      default:
        return 'application/octet-stream';
    }
  }

  String _generateFileKey(String fileName, String chatId, String fileType) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = fileName.split('.').last;
    // Структура: chats/{chatId}/{fileType}/{timestamp}.{ext}
    // Например: chats/123e4567-e89b-12d3-a456-426614174000/images/1703123456789.jpg
    return 'chats/$chatId/$fileType/$timestamp.$ext';
  }

  void dispose() {
    _s3Client.dispose();
  }
}

class FileUploadResult {
  final bool success;
  final String? fileKey;
  final String? fileName;
  final String? fileUrl;
  final String? fileType;
  final int? fileSize;
  final String? error;

  FileUploadResult({
    required this.success,
    this.fileKey,
    this.fileName,
    this.fileUrl,
    this.fileType,
    this.fileSize,
    this.error,
  });
}

class TestResult {
  final bool success;
  final String? error;

  TestResult({
    required this.success,
    this.error,
  });
}
