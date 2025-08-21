import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../services/file_service.dart';

class FileUploadSheet extends StatefulWidget {
  final String chatId;
  final Function(FileUploadResult) onFileUploaded;

  const FileUploadSheet({
    super.key,
    required this.chatId,
    required this.onFileUploaded,
  });

  @override
  State<FileUploadSheet> createState() => _FileUploadSheetState();
}

class _FileUploadSheetState extends State<FileUploadSheet> {
  final FileService _fileService = FileService();
  bool _isLoading = false;
  String? _uploadStatus;

  @override
  void dispose() {
    _fileService.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadFile(FileType type, {List<String>? allowedExtensions}) async {
    setState(() {
      _isLoading = true;
      _uploadStatus = 'Выбираем файл...';
    });

    try {
      final file = await _fileService.pickFile(
        type: type,
        allowedExtensions: allowedExtensions,
      );

      if (file == null) {
        setState(() {
          _isLoading = false;
          _uploadStatus = 'Файл не выбран';
        });
        return;
      }

      setState(() {
        _uploadStatus = 'Загружаем файл...';
      });

      final result = await _fileService.uploadFile(
        file: file,
        chatId: widget.chatId,
      );

      setState(() {
        _isLoading = false;
        if (result.success) {
          _uploadStatus = '✅ Файл загружен!';
          widget.onFileUploaded(result);
          Navigator.pop(context);
        } else {
          _uploadStatus = '❌ Ошибка: ${result.error}';
        }
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _uploadStatus = '❌ Ошибка: $e';
      });
    }
  }

  Future<void> _pickAndUploadImage(ImageSource source) async {
    setState(() {
      _isLoading = true;
      _uploadStatus = 'Выбираем изображение...';
    });

    try {
      final file = await _fileService.pickImage(source: source);

      if (file == null) {
        setState(() {
          _isLoading = false;
          _uploadStatus = 'Изображение не выбрано';
        });
        return;
      }

      setState(() {
        _uploadStatus = 'Загружаем изображение...';
      });

      final result = await _fileService.uploadFile(
        file: file,
        chatId: widget.chatId,
      );

      setState(() {
        _isLoading = false;
        if (result.success) {
          _uploadStatus = '✅ Изображение загружено!';
          widget.onFileUploaded(result);
          Navigator.pop(context);
        } else {
          _uploadStatus = '❌ Ошибка: ${result.error}';
        }
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _uploadStatus = '❌ Ошибка: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Выберите тип файла',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          
          // Документы
          _FileCategoryTile(
            icon: Icons.description,
            title: 'Документы',
            subtitle: 'PDF, Word, DWG, TXT',
            color: Colors.blue,
            onTap: () => _pickAndUploadFile(
              FileType.custom,
              allowedExtensions: ['pdf', 'doc', 'docx', 'dwg', 'txt'],
            ),
          ),
          
          const SizedBox(height: 8),
          
          // Изображения
          _FileCategoryTile(
            icon: Icons.image,
            title: 'Изображения',
            subtitle: 'JPG, PNG, GIF',
            color: Colors.green,
            onTap: () => _pickAndUploadImage(ImageSource.gallery),
          ),
          
          const SizedBox(height: 8),
          
          // Архивы
          _FileCategoryTile(
            icon: Icons.archive,
            title: 'Архивы',
            subtitle: 'ZIP, RAR',
            color: Colors.orange,
            onTap: () => _pickAndUploadFile(
              FileType.custom,
              allowedExtensions: ['zip', 'rar'],
            ),
          ),
          
          const SizedBox(height: 8),
          
          // Другие файлы
          _FileCategoryTile(
            icon: Icons.insert_drive_file,
            title: 'Другие файлы',
            subtitle: 'Любые типы',
            color: Colors.grey,
            onTap: () => _pickAndUploadFile(FileType.any),
          ),
          
          if (_isLoading) ...[
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
            const SizedBox(height: 8),
            Text(
              _uploadStatus ?? '',
              style: const TextStyle(fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
          
          const SizedBox(height: 16),
          
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
  }
}

class _FileCategoryTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _FileCategoryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: color),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

