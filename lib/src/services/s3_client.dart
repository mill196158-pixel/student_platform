import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:minio/minio.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';

/// Legacy direct S3/Yandex client.
///
/// Keep this internal to migration/cleanup paths only. Chat uploads must use
/// backend-issued presigned URLs via FileService/generate-upload-url.
class S3Client {
  final String accessKey;
  final String secretKey;
  final String bucketName;
  final String region;
  final String endpoint;
  late final Minio _minioClient;

  S3Client({
    required this.accessKey,
    required this.secretKey,
    required this.bucketName,
    required this.region,
    required this.endpoint,
  }) {
    // Инициализируем Minio клиент для Yandex Object Storage
    _minioClient = Minio(
      endPoint: endpoint,
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
    );
  }

  // Приводим поток к Stream<Uint8List>
  Stream<Uint8List> _asUint8Stream(File file) async* {
    await for (final chunk in file.openRead()) {
      yield Uint8List.fromList(chunk);
    }
  }

  // Загрузка файла с использованием Minio SDK
  Future<S3UploadResult> putObject({
    required String key,
    required Uint8List body,
    String? contentType,
  }) async {
    try {
      safeDebugLog(
          '[LegacyS3Client] putObject started key=${maskDebugId(key)} size=${body.length} contentType=${contentType ?? 'application/octet-stream'}');

      // Создаем временный файл для загрузки
      final tempFile = File(
          '${Directory.systemTemp.path}/temp_upload_${DateTime.now().millisecondsSinceEpoch}');
      await tempFile.writeAsBytes(body);

      // Загружаем файл через Minio (правильная сигнатура - только 3 аргумента)
      final fileSize = await tempFile.length();
      await _minioClient.putObject(
        bucketName,
        key,
        _asUint8Stream(tempFile),
      );

      // Удаляем временный файл
      await tempFile.delete();

      // Формируем URL для загруженного файла
      final fileUrl = 'https://$bucketName.$endpoint/$key';

      safeDebugLog(
          '[LegacyS3Client] putObject completed key=${maskDebugId(key)}');

      return S3UploadResult(
        success: true,
        fileKey: key,
        fileName: key.split('/').last,
        fileUrl: fileUrl,
        fileType: contentType ?? 'application/octet-stream',
        fileSize: fileSize,
      );
    } catch (e) {
      safeDebugLog(
          '[LegacyS3Client] putObject failed key=${maskDebugId(key)} error=${e.runtimeType}');
      return S3UploadResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Скачивание файла
  Future<S3DownloadResult> getObject({required String key}) async {
    try {
      safeDebugLog(
          '[LegacyS3Client] getObject started key=${maskDebugId(key)}');

      // Скачиваем файл через Minio
      final data = await _minioClient.getObject(bucketName, key);

      // Конвертируем Stream в Uint8List
      final bytes = <int>[];
      await for (final chunk in data) {
        bytes.addAll(chunk);
      }

      safeDebugLog(
          '[LegacyS3Client] getObject completed key=${maskDebugId(key)} size=${bytes.length}');

      return S3DownloadResult(
        success: true,
        data: Uint8List.fromList(bytes),
      );
    } catch (e) {
      safeDebugLog(
          '[LegacyS3Client] getObject failed key=${maskDebugId(key)} error=${e.runtimeType}');
      return S3DownloadResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Удаление файла
  Future<bool> deleteObject({required String key}) async {
    try {
      await _minioClient.removeObject(bucketName, key);
      return true;
    } catch (e) {
      safeDebugLog(
          '[LegacyS3Client] deleteObject failed key=${maskDebugId(key)} error=${e.runtimeType}');
      return false;
    }
  }

  // Тестовое подключение
  Future<bool> testConnection() async {
    try {
      safeDebugLog('[LegacyS3Client] testConnection started');

      // Проверяем существование бакета
      final bucketExists = await _minioClient.bucketExists(bucketName);
      if (!bucketExists) {
        safeDebugLog('[LegacyS3Client] testConnection bucket missing');
        return false;
      }
      safeDebugLog('[LegacyS3Client] testConnection bucket exists');

      // Пробуем загрузить тестовый файл
      final result = await putObject(
        key: 'test/connection-test.txt',
        body: Uint8List.fromList(
            utf8.encode('Test connection from ${DateTime.now()}')),
        contentType: 'text/plain',
      );

      if (result.success) {
        safeDebugLog('[LegacyS3Client] testConnection completed');
        return true;
      } else {
        safeDebugLog('[LegacyS3Client] testConnection upload probe failed');
        return false;
      }
    } catch (e) {
      safeDebugLog('[LegacyS3Client] testConnection failed: ${e.runtimeType}');
      return false;
    }
  }

  // Очистка ресурсов
  void dispose() {
    // Minio автоматически управляет ресурсами
  }
}

class S3UploadResult {
  final bool success;
  final String? fileKey;
  final String? fileName;
  final String? fileUrl;
  final String? fileType;
  final int? fileSize;
  final String? error;

  S3UploadResult({
    required this.success,
    this.fileKey,
    this.fileName,
    this.fileUrl,
    this.fileType,
    this.fileSize,
    this.error,
  });
}

class S3DownloadResult {
  final bool success;
  final Uint8List? data;
  final String? error;

  S3DownloadResult({
    required this.success,
    this.data,
    this.error,
  });
}
