import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_filex/open_filex.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../common/friendly_empty_state.dart';
import '../models/chat_file.dart';
import '../models/message.dart';
import '../state/team_cubit.dart';
import '../widgets/file_card.dart';
import '../../../services/file_service.dart';
import '../widgets/fullscreen_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

enum _FilesSection { images, documents }

class FilesTab extends StatefulWidget {
  const FilesTab({super.key});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab>
    with AutomaticKeepAliveClientMixin<FilesTab> {
  final SupabaseClient _sb = Supabase.instance.client;
  FileService? _fileService; // ленивое, т.к. конфиг может отсутствовать в деве

  String? _chatId;
  RealtimeChannel? _rtFiles;

  _FilesSection _section = _FilesSection.images;
  final List<ChatFile> _files = [];
  bool _loading = true;
  bool _uploading = false;
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  FileService? _tryCreateFileService() {
    try {
      return FileService();
    } catch (_) {
      return null;
    }
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    final teamId = context.read<TeamCubit>().state.team.id;
    final chatId = await _getMainChatId(teamId);
    _chatId = chatId;
    await _loadFiles();
    _subscribeRealtime();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadFiles() async {
    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) return;
    try {
      final rows = await _sb
          .from('chat_files')
          .select('*')
          .eq('chat_id', chatId)
          .eq('is_deleted', false)
          .order('uploaded_at');
      final list = (rows as List)
          .map((e) => ChatFile.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      // Удаляем дубликаты по file_key или по имени, если ключ пуст
      final seen = <String>{};
      final deduped = <ChatFile>[];
      for (final f in list) {
        final key = (f.fileKey.isNotEmpty ? f.fileKey : 'name:${f.fileName}')
            .toLowerCase();
        if (seen.contains(key)) continue;
        seen.add(key);
        deduped.add(f);
      }
      _files
        ..clear()
        ..addAll(deduped);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[FilesTab] load error: $e');
    }
  }

  void _subscribeRealtime() {
    if (_chatId == null || _chatId!.isEmpty) return;
    try {
      _rtFiles?.unsubscribe();
    } catch (_) {}
    _rtFiles = _sb.channel('public:chat_files');
    final filter = PostgresChangeFilter(
      column: 'chat_id',
      type: PostgresChangeFilterType.eq,
      value: _chatId!,
    );
    _rtFiles!
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_files',
          filter: filter,
          callback: (_) => _loadFiles(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_files',
          filter: filter,
          callback: (_) => _loadFiles(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'chat_files',
          filter: filter,
          callback: (_) => _loadFiles(),
        );
    _rtFiles!.subscribe();
  }

  @override
  void dispose() {
    try {
      _rtFiles?.unsubscribe();
    } catch (_) {}
    super.dispose();
  }

  List<ChatFile> get _images =>
      _effectiveFiles().where((f) => f.isImage).toList().reversed.toList();

  List<ChatFile> _effectiveFiles([List<Message>? chat]) {
    final messages = chat ?? context.read<TeamCubit>().state.chat;
    return _mergeFiles(_files, _attachmentsFromMessages(messages));
  }

  List<ChatFile> _attachmentsFromMessages(List<Message> messages) {
    final result = <ChatFile>[];
    for (final message in messages) {
      for (final file in message.attachments ?? const <ChatFile>[]) {
        if (file.isDeleted) continue;
        if (file.fileUrl.isEmpty && file.fileKey.isEmpty) continue;
        result.add(file);
      }
    }
    return result;
  }

  List<ChatFile> _mergeFiles(
    Iterable<ChatFile> primary,
    Iterable<ChatFile> fromMessages,
  ) {
    final seen = <String>{};
    final merged = <ChatFile>[];

    String keyOf(ChatFile file) {
      final name = FileUiUtils.cleanFileName(file.fileName).toLowerCase();
      if (name.isNotEmpty && file.fileSize > 0) {
        return 'name:$name:size:${file.fileSize}';
      }
      if (file.fileKey.isNotEmpty) return 'key:${file.fileKey}'.toLowerCase();
      if (file.fileUrl.isNotEmpty) return 'url:${file.fileUrl}'.toLowerCase();
      return 'id:${file.id}'.toLowerCase();
    }

    void add(ChatFile file) {
      final key = keyOf(file);
      if (seen.contains(key)) return;
      seen.add(key);
      merged.add(file);
    }

    for (final file in primary) {
      add(file);
    }
    for (final file in fromMessages) {
      add(file);
    }

    return merged;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final chat = context.select((TeamCubit cubit) => cubit.state.chat);
    final effectiveFiles = _effectiveFiles(chat);
    final images =
        effectiveFiles.where((f) => f.isImage).toList().reversed.toList();
    final docs =
        effectiveFiles.where((f) => !f.isImage).toList().reversed.toList();
    final imagesCount = images.length;
    final docsCount = docs.length;

    return Stack(
      children: [
        Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    _buildSegment(
                      label: 'Фото',
                      count: imagesCount,
                      selected: _section == _FilesSection.images,
                      onTap: () =>
                          setState(() => _section = _FilesSection.images),
                    ),
                    const SizedBox(width: 8),
                    _buildSegment(
                      label: 'Файлы',
                      count: docsCount,
                      selected: _section == _FilesSection.documents,
                      onTap: () =>
                          setState(() => _section = _FilesSection.documents),
                    ),
                    const Spacer(),
                    if (_selecting) ...[
                      IconButton(
                        tooltip: 'Скопировать локально',
                        icon: const Icon(Icons.copy_all_outlined),
                        onPressed:
                            _selectedIds.isEmpty ? null : _copySelectedLocally,
                      ),
                      IconButton(
                        tooltip: 'Отправить выбранные в чат',
                        icon: const Icon(Icons.send_outlined),
                        onPressed: _selectedIds.isEmpty
                            ? null
                            : () async {
                                final selected = effectiveFiles
                                    .where((f) => _selectedIds.contains(f.id))
                                    .toList();
                                if (selected.isEmpty) return;
                                final teamId =
                                    context.read<TeamCubit>().state.team.id;
                                final messageId = await _sendMessageWithFiles(
                                    teamId,
                                    '📎 ${selected.first.fileName}${selected.length > 1 ? ' и ещё ${selected.length - 1}' : ''}',
                                    selected.map((e) => e.id).toList());
                                if (messageId.isNotEmpty && mounted) {
                                  await context
                                      .read<TeamCubit>()
                                      .refreshMessageById(messageId);
                                }
                                setState(() {
                                  _selecting = false;
                                  _selectedIds.clear();
                                });
                              },
                      ),
                      IconButton(
                        tooltip: 'Выйти из режима выбора',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _selecting = false;
                          _selectedIds.clear();
                        }),
                      ),
                    ] else ...[
                      IconButton(
                        tooltip: 'Выбрать',
                        icon: const Icon(Icons.checklist_rounded),
                        onPressed: () => setState(() => _selecting = true),
                      ),
                      IconButton(
                        tooltip: 'Загрузить',
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: _showUploadSheet,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: _loading && effectiveFiles.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : (_section == _FilesSection.images
                      ? _buildImagesGrid(images)
                      : _buildDocsList(docs)),
            ),
          ],
        ),
        if (_uploading)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: true,
              child: Container(
                color: Colors.black26,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSegment(
      {required String label,
      required int count,
      required bool selected,
      required VoidCallback onTap}) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    final bg = selected
        ? scheme.primary.withValues(alpha: 0.12)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.72);
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(22),
          boxShadow: selected
              ? [
                  BoxShadow(
                      color: color.withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 2))
                ]
              : [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2))
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: selected ? color : scheme.outline,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$count',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagesGrid(List<ChatFile> list) {
    if (list.isEmpty) {
      return const FriendlyEmptyState(
        lottieAsset: 'assets/lottie/empty_images_cat.json',
        fallbackIcon: Icons.photo_outlined,
        title: 'Пока нет изображений',
        subtitle: 'Загрузите фото — они появятся здесь.',
        animationHeight: 128,
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final f = list[i];
        return Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              if (_selecting) {
                _toggleSelected(f.id);
              } else {
                _openImageGallery(i);
              }
            },
            onLongPress: () {
              if (!_selecting) setState(() => _selecting = true);
              _toggleSelected(f.id);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: f.fileUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                  errorWidget: (_, __, ___) => ColoredBox(
                    color: Theme.of(context)
                        .colorScheme
                        .errorContainer
                        .withValues(alpha: 0.42),
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_selecting)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: _selectedIds.contains(f.id)
                          ? Theme.of(context).colorScheme.primary
                          : Colors.black45,
                      child: const Icon(Icons.check,
                          size: 16, color: Colors.white),
                    ),
                  ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.54),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      FileUiUtils.formatFileSize(f.fileSize),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDocsList(List<ChatFile> list) {
    if (list.isEmpty) {
      return _emptyState(
        'Пока нет файлов',
        icon: Icons.folder_open_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final f = list[i];
        final isSelected = _selectedIds.contains(f.id);
        return Stack(
          children: [
            AppFileCard(
              fileName: f.fileName,
              fileSize: f.fileSize,
              mimeType: f.fileType,
              compact: true,
              maxNameLines: 1,
              selected: isSelected,
              statusLabel: _formatDate(f.uploadedAt),
              onTap: () {
                if (_selecting) {
                  _toggleSelected(f.id);
                } else {
                  _openFilePreview(f);
                }
              },
            ),
            if (_selecting)
              Positioned(
                top: 8,
                right: 12,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.black45,
                  child: const Icon(Icons.check, size: 16, color: Colors.white),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _emptyState(String text, {IconData icon = Icons.folder_open}) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: cs.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) {
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}';
  }

  void _showUploadSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Загрузить изображение'),
              onTap: () async {
                Navigator.pop(context);
                await _pickAndUploadImage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Загрузить файл'),
              onTap: () async {
                Navigator.pop(context);
                await _pickAndUploadFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUploadImage() async {
    try {
      setState(() => _uploading = true);
      final service = _fileService ??= _tryCreateFileService();
      if (service == null) {
        _showError('Хранилище не настроено');
        return;
      }
      final file = await service.pickImage();
      if (file == null) return;
      await _uploadToStorageAndDb(file);
    } catch (e) {
      _showError('Ошибка загрузки: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickAndUploadFile() async {
    try {
      setState(() => _uploading = true);
      final service = _fileService ??= _tryCreateFileService();
      if (service == null) {
        _showError('Хранилище не настроено');
        return;
      }
      final file = await service.pickFile();
      if (file == null) return;
      await _uploadToStorageAndDb(file);
    } catch (e) {
      _showError('Ошибка загрузки: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _uploadToStorageAndDb(File file) async {
    if (_chatId == null || _chatId!.isEmpty) return;
    final user = _sb.auth.currentUser;
    if (user == null) {
      _showError('Не удалось определить пользователя');
      return;
    }
    final service = _fileService ??= _tryCreateFileService();
    if (service == null) {
      _showError('Хранилище не настроено');
      return;
    }
    // 1) Загружаем в хранилище
    final uploaded = await service.uploadFileToChat(
      file: file,
      chatId: _chatId!,
      messageId: '',
      uploadedBy: user.id,
    );
    // 2) Сохраняем запись в БД (message_id = null)
    await _saveChatFile(uploaded, user.id);
    // Обновим список сразу, не дожидаясь RT
    await _loadFiles();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '✅ Загружено: ${FileUiUtils.cleanFileName(uploaded.fileName)}')),
      );
    }
  }

  Future<void> _sendToChat(ChatFile f) async {
    try {
      final teamId = context.read<TeamCubit>().state.team.id;
      final name = FileUiUtils.cleanFileName(f.fileName);
      final messageId = await _sendMessageWithFiles(teamId, '📎 $name', [f.id]);
      if (messageId.isNotEmpty && mounted) {
        await context.read<TeamCubit>().refreshMessageById(messageId);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Отправлено в чат: $name')),
        );
      }
    } catch (e) {
      _showError('Не удалось отправить: $e');
    }
  }

  Future<void> _openOrDownload(ChatFile f) async {
    try {
      final service = _fileService ??= _tryCreateFileService();
      if (service != null) {
        final res = await service.downloadFile(
            fileKey: f.fileKey, fileName: f.fileName);
        if (res.success && res.file != null) {
          await OpenFilex.open(res.file!.path);
          return;
        }
      }
      // Фолбэк — открыть URL в браузере
      final uri = Uri.parse(f.fileUrl);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        _showError('Не удалось открыть файл');
      }
    } catch (e) {
      _showError('Ошибка открытия: $e');
    }
  }

  void _openImageGallery(int initialIndex) {
    final list = _images;
    final urls = list.map((e) => e.fileUrl).toList();
    final names = list.map((e) => e.fileName).toList();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullscreenImage(
            imageUrl: urls[initialIndex],
            fileName: names[initialIndex],
            galleryUrls: urls,
            galleryFileNames: names,
            galleryFileIds: list.map((e) => e.id).toList(),
            initialIndex: initialIndex),
      ),
    );
  }

  void _openFilePreview(ChatFile file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullscreenFileViewer(
          fileUrl: file.fileUrl,
          fileName: file.fileName,
          fileSize: file.fileSize,
          mimeType: file.fileType,
          sourceFileId: file.id,
        ),
      ),
    );
  }

  // ignore: unused_element
  void _showFileMenu(ChatFile f) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: Text(f.isImage ? 'Открыть изображение' : 'Открыть файл'),
              onTap: () {
                Navigator.pop(context);
                f.isImage
                    ? _openImageGallery(_images.indexWhere((x) => x.id == f.id))
                    : _openFilePreview(f);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Скачать'),
              onTap: () async {
                Navigator.pop(context);
                await _openOrDownload(f);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Скопировать локально'),
              onTap: () async {
                Navigator.pop(context);
                await _copyFilesLocally([f]);
              },
            ),
            ListTile(
              leading: const Icon(Icons.send_outlined),
              title: const Text('Отправить в чат'),
              onTap: () async {
                Navigator.pop(context);
                await _sendToChat(f);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  // --- Selection helpers ---
  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selecting = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  @override
  bool get wantKeepAlive => true;

  Future<String> _getMainChatId(String teamId) async {
    try {
      final response = await _sb
          .from('chats')
          .select('id')
          .eq('team_id', teamId)
          .eq('type', 'team_main')
          .limit(1)
          .single();
      return response['id'] as String;
    } catch (e) {
      for (final message in context.read<TeamCubit>().state.chat) {
        if (message.chatId.isNotEmpty) return message.chatId;
        for (final file in message.attachments ?? const <ChatFile>[]) {
          if (file.chatId.isNotEmpty) return file.chatId;
        }
      }
      return '';
    }
  }

  Future<String> _saveChatFile(ChatFile chatFile, String userId) async {
    final response = await _sb.rpc('save_chat_file', params: {
      'p_chat_id': chatFile.chatId,
      'p_file_name': chatFile.fileName,
      'p_file_key': chatFile.fileKey,
      'p_file_url': chatFile.fileUrl,
      'p_file_type': chatFile.fileType,
      'p_file_size': chatFile.fileSize,
      'p_uploaded_by': userId,
      'p_message_id':
          chatFile.messageId?.isEmpty == true ? null : chatFile.messageId,
    });
    return response.toString();
  }

  Future<String> _sendMessageWithFiles(
      String teamId, String text, List<String> fileIds) async {
    final messageType = fileIds.isNotEmpty ? 'file' : 'text';
    final response = await _sb.rpc(
      'send_chat_message_with_files',
      params: {
        'p_team_id': teamId,
        'p_text': text,
        'p_type': messageType,
        'p_file_ids': fileIds,
      },
    );
    return response.toString();
  }

  // --- Local copy helpers ---
  Future<void> _copySelectedLocally() async {
    final selected =
        _effectiveFiles().where((f) => _selectedIds.contains(f.id)).toList();
    await _copyFilesLocally(selected);
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  Future<void> _copyFilesLocally(List<ChatFile> files) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final f in files) {
        final name = f.fileName;
        final path = '${dir.path}/$name';
        // Пытаемся скачать байты через FileService, иначе по URL
        final service = _fileService ??= _tryCreateFileService();
        late final List<int> bytes;
        if (service != null && f.fileKey.isNotEmpty) {
          final res =
              await service.downloadFile(fileKey: f.fileKey, fileName: name);
          if (res.success && res.file != null) {
            bytes = await res.file!.readAsBytes();
          } else {
            final resp = await http.get(Uri.parse(f.fileUrl));
            bytes = resp.bodyBytes;
          }
        } else {
          final resp = await http.get(Uri.parse(f.fileUrl));
          bytes = resp.bodyBytes;
        }
        final out = File(path);
        await out.writeAsBytes(bytes, flush: true);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Скопировано в локальные файлы')));
      }
    } catch (e) {
      _showError('Не удалось скопировать: $e');
    }
  }
}
