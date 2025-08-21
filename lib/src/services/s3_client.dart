import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:minio/minio.dart';

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
      print('🔍 Загружаем файл в Yandex Storage через Minio...');
      print('📍 Key: $key');
      print('📦 Bucket: $bucketName');
      print('📏 Size: ${body.length} bytes');
      print('📄 Content-Type: ${contentType ?? 'application/octet-stream'}');

      // Создаем временный файл для загрузки
      final tempFile = File('${Directory.systemTemp.path}/temp_upload_${DateTime.now().millisecondsSinceEpoch}');
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

      print('✅ Файл успешно загружен!');
      print('🔗 URL: $fileUrl');

      return S3UploadResult(
        success: true,
        fileKey: key,
        fileName: key.split('/').last,
        fileUrl: fileUrl,
        fileType: contentType ?? 'application/octet-stream',
        fileSize: fileSize,
      );
    } catch (e) {
      print('❌ Ошибка загрузки файла: $e');
      return S3UploadResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  // Тестовое подключение
  Future<bool> testConnection() async {
    try {
      print('🔍 Тестируем подключение к Yandex Storage через Minio...');
      print('📍 Endpoint: $endpoint');
      print('📦 Bucket: $bucketName');
      print('🌍 Region: $region');
      print('🔑 Access Key: ${accessKey.substring(0, 8)}...');

      // Проверяем существование бакета
      final bucketExists = await _minioClient.bucketExists(bucketName);
      if (!bucketExists) {
        print('❌ Бакет $bucketName не найден!');
        return false;
      }
      print('✅ Бакет $bucketName найден!');

      // Пробуем загрузить тестовый файл
      final result = await putObject(
        key: 'test/connection-test.txt',
        body: Uint8List.fromList(utf8.encode('Test connection from ${DateTime.now()}')),
        contentType: 'text/plain',
      );

      if (result.success) {
        print('✅ Подключение и загрузка успешно!');
        return true;
      } else {
        print('❌ Ошибка подключения: ${result.error}');
        return false;
      }
    } catch (e) {
      print('💥 Исключение при подключении: $e');
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
