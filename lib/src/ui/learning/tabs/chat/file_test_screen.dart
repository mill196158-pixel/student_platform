import 'dart:io';
import 'package:flutter/material.dart';
import '../../../../services/file_service.dart';

class FileTestScreen extends StatefulWidget {
  const FileTestScreen({super.key});

  @override
  State<FileTestScreen> createState() => _FileTestScreenState();
}

class _FileTestScreenState extends State<FileTestScreen> {
  final FileService _fileService = FileService();
  bool _isLoading = false;
  String _status = 'Готов к тестированию';
  String? _lastError;

  @override
  void dispose() {
    _fileService.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() {
      _isLoading = true;
      _status = 'Тестируем подключение...';
      _lastError = null;
    });

    try {
      final result = await _fileService.testConnection();
      
      setState(() {
        _isLoading = false;
        if (result.success) {
          _status = '✅ Подключение успешно!';
        } else {
          _status = '❌ Ошибка подключения';
          _lastError = result.error ?? 'Не удалось подключиться к Yandex Storage';
        }
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _status = '❌ Ошибка подключения';
        _lastError = e.toString();
      });
    }
  }

  Future<void> _uploadTestFile() async {
    setState(() {
      _isLoading = true;
      _status = 'Выбираем файл...';
      _lastError = null;
    });

    try {
      final file = await _fileService.pickFile();
      
      if (file == null) {
        setState(() {
          _isLoading = false;
          _status = 'Файл не выбран';
        });
        return;
      }

      setState(() {
        _status = 'Загружаем файл...';
      });

      final result = await _fileService.uploadFile(
        file: file,
        chatId: 'test-chat-${DateTime.now().millisecondsSinceEpoch}',
      );

      setState(() {
        _isLoading = false;
        if (result.success) {
          _status = '✅ Файл загружен успешно!\nКлюч: ${result.fileKey}\nURL: ${result.fileUrl}';
        } else {
          _status = '❌ Ошибка загрузки';
          _lastError = result.error;
        }
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _status = '❌ Ошибка загрузки';
        _lastError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Тест файлового сервиса'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Статус:',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      style: const TextStyle(fontSize: 16),
                    ),
                    if (_lastError != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          border: Border.all(color: Colors.red.shade200),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Ошибка: $_lastError',
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _testConnection,
              icon: const Icon(Icons.wifi),
              label: const Text('Тест подключения'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _uploadTestFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Загрузить тестовый файл'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(16),
              ),
            ),
            if (_isLoading) ...[
              const SizedBox(height: 16),
              const Center(
                child: CircularProgressIndicator(),
              ),
            ],
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                border: Border.all(color: Colors.orange.shade200),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '📋 Что нужно сделать:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '1. Заполнить данные Yandex Storage в файле:\n   lib/src/config/yandex_storage_config.dart\n\n'
                    '2. Запустить тест подключения\n\n'
                    '3. Если подключение работает - протестировать загрузку файла\n\n'
                    '4. После успешных тестов - интегрировать в чат',
                    style: TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
