import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../models/chat_file.dart';
import '../../widgets/fullscreen_image.dart';

class FileMessageBubble extends StatelessWidget {
  final ChatFile file;
  final bool isMe;
  final String time;
  final VoidCallback? onLongPress;

  const FileMessageBubble({
    super.key,
    required this.file,
    required this.isMe,
    required this.time,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    // Отладочная информация убрана для чистоты
    
    return GestureDetector(
      onLongPress: onLongPress,
      onTap: () => _handleFileTap(context),
      child: Container(
        margin: EdgeInsets.only(
          left: isMe ? 50 : 12,
          right: isMe ? 12 : 50,
          bottom: 4,
        ),
        child: Row(
          mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isMe) ...[
              CircleAvatar(
                radius: 16,
                backgroundColor: theme.colorScheme.primary.withOpacity(0.2),
                child: Text(
                  file.uploadedBy.isNotEmpty ? file.uploadedBy[0].toUpperCase() : '?',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            
            Flexible(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isMe 
                    ? theme.colorScheme.primary.withOpacity(0.22)
                    : theme.colorScheme.surfaceContainerHighest,
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Предварительный просмотр для изображений
                    if (file.isImage) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: file.fileUrl,
                          width: 200,
                          height: 150,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            width: 200,
                            height: 150,
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: CircularProgressIndicator(),
                            ),
                          ),
                          errorWidget: (context, url, error) => Container(
                            width: 200,
                            height: 150,
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: Icon(Icons.error, color: Colors.grey),
                            ),
                          ),
                        ),
                      ),
                    ] else ...[
                      // Файл как гиперссылка
                      InkWell(
                        onTap: () => _handleFileTap(context),
                        borderRadius: BorderRadius.circular(8),
                        child: _buildFileCard(theme),
                      ),
                    ],
                    
                    const SizedBox(height: 8),
                    
                    // Информация о файле и время
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 14,
                          color: Colors.black54,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          file.formattedSize,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          file.fileType.split('/').last.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.black54,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          time,
                          style: TextStyle(
                            color: Colors.black54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            
            // Время теперь внутри пузыря
          ],
        ),
      ),
    );
  }

  Widget _buildFileCard(ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          file.icon,
          style: const TextStyle(fontSize: 24),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            file.fileName,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Future<Uint8List?> _loadImagePreview() async {
    try {
      final response = await http.get(Uri.parse(file.fileUrl));
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      print('Ошибка загрузки превью: $e');
    }
    return null;
  }

  Future<void> _handleFileTap(BuildContext context) async {
    if (file.isImage) {
      // Показываем изображение в полноэкранном режиме
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FullscreenImage(
            imageUrl: file.fileUrl,
            fileName: file.fileName,
          ),
        ),
      );
    } else {
      // Скачиваем и открываем документ
      await _downloadAndOpenFile(context);
    }
  }

  void _showImageFullScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            title: Text(
              file.fileName,
              style: const TextStyle(color: Colors.white),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.download, color: Colors.white),
                onPressed: () => _downloadFile(context),
              ),
            ],
          ),
          body: Center(
            child: FutureBuilder<Uint8List?>(
              future: _loadImagePreview(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const CircularProgressIndicator(color: Colors.white);
                }
                
                if (snapshot.hasData && snapshot.data != null) {
                  return InteractiveViewer(
                    child: Image.memory(
                      snapshot.data!,
                      fit: BoxFit.contain,
                    ),
                  );
                }
                
                return const Text(
                  'Не удалось загрузить изображение',
                  style: TextStyle(color: Colors.white),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _downloadAndOpenFile(BuildContext context) async {
    try {
      // Показываем индикатор загрузки
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Загружаем файл...'),
            ],
          ),
        ),
      );

      // Скачиваем файл (file - это ChatFile модель)
      final response = await http.get(Uri.parse(file.fileUrl));
      if (response.statusCode != 200) {
        throw Exception('Ошибка загрузки файла');
      }

      // Сохраняем во временную папку
      final tempDir = await getTemporaryDirectory();
      final filePath = '${tempDir.path}/${file.fileName}';
      final localFile = File(filePath); // localFile - это dart:io.File
      await localFile.writeAsBytes(response.bodyBytes);

      Navigator.pop(context); // Закрываем диалог загрузки

      // Открываем файл
      final result = await OpenFilex.open(filePath);
      if (result.type != ResultType.done) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Не удалось открыть файл: ${result.message}'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }

    } catch (e) {
      Navigator.pop(context); // Закрываем диалог загрузки
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка при работе с файлом: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _downloadFile(BuildContext context) async {
    try {
      final url = Uri.parse(file.fileUrl);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Не удалось скачать файл: ${file.fileName}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка при скачивании файла: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
