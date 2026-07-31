import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart' as picker;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';
import '../ui/learning/models/chat_file.dart';

typedef UploadProgressCallback = void Function(int sentBytes, int totalBytes);

class FileService {
  final SupabaseClient _supabase;
  final Dio _dio;
  final bool _ownsDio;
  final ImagePicker _imagePicker = ImagePicker();

  FileService({
    SupabaseClient? supabase,
    Dio? dio,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _dio = dio ?? Dio(),
        _ownsDio = dio == null;

  // Тест подключения
  Future<TestResult> testConnection() async {
    if (_supabase.auth.currentSession == null) {
      return TestResult(
        success: false,
        error: 'Нужно войти в аккаунт для загрузки файлов',
      );
    }

    return TestResult(success: true);
  }

  // Загрузка тестового файла
  Future<FileUploadResult> uploadTestFile() async {
    return FileUploadResult(
      success: false,
      error:
          'Тестовая загрузка требует реальный chatId. Используйте загрузку из чата.',
    );
  }

  // Загрузка файла в чат (создает запись в chat_files)
  Future<ChatFile> uploadFileToChat({
    required File file,
    required String chatId,
    required String messageId,
    required String uploadedBy,
    String? customFileName,
    UploadProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      final fileName = _fileNameFromPath(customFileName ?? file.path);
      final contentType = _getContentType(fileName);
      final bytes = await file.readAsBytes();

      final upload = await _createPresignedUpload(
        chatId: chatId,
        fileName: fileName,
        contentType: contentType,
        fileSize: bytes.length,
      );
      await _putToPresignedUrl(
        upload,
        bytes,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

      return ChatFile(
        id: '', // Будет заполнено на сервере
        chatId: chatId,
        messageId: messageId,
        fileName: fileName,
        fileKey: upload.fileKey,
        fileUrl: upload.fileUrl,
        fileType: contentType,
        fileSize: bytes.length,
        uploadedBy: uploadedBy,
        uploadedAt: DateTime.now(),
      );
    } catch (e) {
      throw Exception('Ошибка загрузки файла: ${_friendlyUploadError(e)}');
    }
  }

  // Загрузка файла (старый метод для совместимости)
  Future<FileUploadResult> uploadFile({
    required File file,
    required String chatId,
    String? customFileName,
    UploadProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      final fileName = _fileNameFromPath(customFileName ?? file.path);
      final contentType = _getContentType(fileName);
      final bytes = await file.readAsBytes();

      final upload = await _createPresignedUpload(
        chatId: chatId,
        fileName: fileName,
        contentType: contentType,
        fileSize: bytes.length,
      );
      await _putToPresignedUrl(
        upload,
        bytes,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

      return FileUploadResult(
        success: true,
        fileKey: upload.fileKey,
        fileName: fileName,
        fileUrl: upload.fileUrl,
        fileType: contentType,
        fileSize: bytes.length,
      );
    } catch (e) {
      return FileUploadResult(
        success: false,
        error: _friendlyUploadError(e),
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
      safeDebugLog('[FileService] pickFile failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<List<File>> pickFiles({
    picker.FileType type = picker.FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = true,
  }) async {
    try {
      final result = await picker.FilePicker.platform.pickFiles(
        type: type,
        allowedExtensions: allowedExtensions,
        allowMultiple: allowMultiple,
      );

      if (result == null || result.files.isEmpty) return const [];
      return result.files
          .map((file) => file.path)
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .map(File.new)
          .toList(growable: false);
    } catch (e) {
      safeDebugLog('[FileService] pickFiles failed: ${e.runtimeType}');
      return const [];
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
      safeDebugLog('[FileService] pickImage failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<List<File>> pickImages() async {
    try {
      final images = await _imagePicker.pickMultiImage();
      return images
          .map((image) => image.path)
          .where((path) => path.isNotEmpty)
          .map(File.new)
          .toList(growable: false);
    } catch (e) {
      safeDebugLog('[FileService] pickImages failed: ${e.runtimeType}');
      return const [];
    }
  }

  // Вспомогательные методы
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

  Future<_PresignedUpload> _createPresignedUpload({
    required String chatId,
    required String fileName,
    required String contentType,
    required int fileSize,
  }) async {
    final session = _supabase.auth.currentSession;
    if (session == null) {
      throw Exception('Нужно войти в аккаунт для загрузки файлов');
    }

    try {
      final response = await _supabase.functions.invoke(
        'generate-upload-url',
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
        },
        body: {
          'chatId': chatId,
          'fileName': fileName,
          'contentType': contentType,
          'fileSize': fileSize,
          'scope': 'chat',
        },
      );

      final data = response.data;
      if (data is! Map) {
        throw Exception('Некорректный ответ сервера загрузки');
      }

      final uploadUrl = data['uploadUrl']?.toString() ?? '';
      final fileKey = data['fileKey']?.toString() ?? '';
      final fileUrl = data['fileUrl']?.toString() ?? '';
      final headers = _stringMap(data['headers']);

      if (uploadUrl.isEmpty || fileKey.isEmpty || fileUrl.isEmpty) {
        throw Exception('Сервер загрузки вернул неполные данные');
      }

      return _PresignedUpload(
        uploadUrl: uploadUrl,
        fileKey: fileKey,
        fileUrl: fileUrl,
        headers: headers,
      );
    } on FunctionException catch (e) {
      throw Exception(_functionErrorMessage(e));
    }
  }

  Future<void> _putToPresignedUrl(
    _PresignedUpload upload,
    Uint8List bytes, {
    UploadProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      await _dio.put<dynamic>(
        upload.uploadUrl,
        data: bytes,
        cancelToken: cancelToken,
        options: Options(
          headers: upload.headers,
          responseType: ResponseType.plain,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
        onSendProgress: onProgress,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('Загрузка отменена');
      }
      final status = e.response?.statusCode;
      final suffix = status == null ? '' : ' (код $status)';
      throw Exception('Не удалось загрузить файл в хранилище$suffix');
    }
  }

  Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};

    return value.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  String _fileNameFromPath(String path) {
    return path.split(RegExp(r'[\\/]')).last;
  }

  String _functionErrorMessage(FunctionException error) {
    final details = error.details;
    final serverMessage = details is Map ? details['error']?.toString() : null;

    if (serverMessage != null && serverMessage.isNotEmpty) {
      return 'Не удалось получить ссылку для загрузки: $serverMessage';
    }

    if (error.status == 401) {
      return 'Сессия истекла. Войдите заново и повторите загрузку.';
    }

    if (error.status == 403) {
      return 'Нет доступа к этому чату для загрузки файла.';
    }

    return 'Не удалось получить ссылку для загрузки (код ${error.status})';
  }

  String _friendlyUploadError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.isEmpty ? 'Неизвестная ошибка загрузки файла' : text;
  }

  // Скачивание файла
  Future<FileDownloadResult> downloadFile({
    required String fileKey,
    required String fileName,
  }) async {
    return FileDownloadResult(
      success: false,
      error: 'Прямое скачивание по Yandex fileKey отключено в Flutter-клиенте',
    );
  }

  void dispose() {
    if (_ownsDio) {
      _dio.close();
    }
  }
}

class _PresignedUpload {
  final String uploadUrl;
  final String fileKey;
  final String fileUrl;
  final Map<String, String> headers;

  const _PresignedUpload({
    required this.uploadUrl,
    required this.fileKey,
    required this.fileUrl,
    required this.headers,
  });
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

class FileDownloadResult {
  final bool success;
  final File? file;
  final String? fileName;
  final String? error;

  FileDownloadResult({
    required this.success,
    this.file,
    this.fileName,
    this.error,
  });
}
