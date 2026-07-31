import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../utils/chat_copied_file_cache.dart';
import 'file_card.dart';

Future<File> _downloadRemoteFileToCache({
  required String url,
  required String fileName,
}) async {
  final cleanName = FileUiUtils.cleanFileName(fileName);
  final digest = crypto.sha1.convert(utf8.encode(url)).toString();
  final dir = await getApplicationCacheDirectory();
  final filesDir = Directory('${dir.path}${Platform.pathSeparator}chat_files');
  if (!await filesDir.exists()) {
    await filesDir.create(recursive: true);
  }

  final path = '${filesDir.path}${Platform.pathSeparator}${digest}_$cleanName';
  final cached = File(path);
  if (await cached.exists() && await cached.length() > 0) {
    return cached;
  }

  final resp = await http.get(Uri.parse(url));
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}');
  }
  await cached.writeAsBytes(resp.bodyBytes, flush: true);
  return cached;
}

FileFormat _clipboardFormatForFile(String fileName, String? mimeType) {
  final name = FileUiUtils.cleanFileName(fileName).toLowerCase();
  final mime = (mimeType ?? '').toLowerCase();
  bool ext(String value) => name.endsWith('.$value');

  if (mime.contains('png') || ext('png')) return Formats.png;
  if (mime.contains('jpeg') ||
      mime.contains('jpg') ||
      ext('jpg') ||
      ext('jpeg')) {
    return Formats.jpeg;
  }
  if (mime.contains('gif') || ext('gif')) return Formats.gif;
  if (mime.contains('webp') || ext('webp')) return Formats.webp;
  if (mime.contains('bmp') || ext('bmp')) return Formats.bmp;
  if (mime.contains('svg') || ext('svg')) return Formats.svg;
  if (mime.contains('heic') || ext('heic')) return Formats.heic;
  if (mime.contains('heif') || ext('heif')) return Formats.heif;

  if (mime.contains('pdf') || ext('pdf')) return Formats.pdf;
  if (mime.contains('msword') || ext('doc')) return Formats.doc;
  if (mime.contains('wordprocessingml') || ext('docx')) return Formats.docx;
  if (mime.contains('spreadsheetml') || ext('xlsx')) return Formats.xlsx;
  if (mime.contains('vnd.ms-excel') || ext('xls')) return Formats.xls;
  if (mime.contains('presentationml') || ext('pptx')) return Formats.pptx;
  if (mime.contains('vnd.ms-powerpoint') || ext('ppt')) return Formats.ppt;
  if (mime.contains('csv') || ext('csv')) return Formats.csv;
  if (mime.contains('markdown') || ext('md')) return Formats.md;
  if (mime.startsWith('text/') || ext('txt')) return Formats.plainTextFile;

  if (mime.contains('zip') || ext('zip')) return Formats.zip;
  if (mime.contains('rar') || ext('rar')) return Formats.rar;
  if (mime.contains('7z') || ext('7z')) return Formats.sevenZip;
  if (mime.contains('tar') || ext('tar')) return Formats.tar;
  if (mime.contains('gzip') || ext('gz')) return Formats.gzip;

  final fallbackMime = mime.isNotEmpty ? mime : 'application/octet-stream';
  return SimpleFileFormat(mimeTypes: [fallbackMime]);
}

({FileFormat format, String extension, String mimeType}) _clipboardImageFormat(
  List<int> bytes,
) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return (format: Formats.png, extension: 'png', mimeType: 'image/png');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return (format: Formats.jpeg, extension: 'jpg', mimeType: 'image/jpeg');
  }
  if (bytes.length >= 6) {
    final header = latin1.decode(bytes.take(6).toList(), allowInvalid: true);
    if (header == 'GIF87a' || header == 'GIF89a') {
      return (format: Formats.gif, extension: 'gif', mimeType: 'image/gif');
    }
  }
  if (bytes.length >= 12) {
    final riff = latin1.decode(bytes.sublist(0, 4), allowInvalid: true);
    final webp = latin1.decode(bytes.sublist(8, 12), allowInvalid: true);
    if (riff == 'RIFF' && webp == 'WEBP') {
      return (format: Formats.webp, extension: 'webp', mimeType: 'image/webp');
    }
  }
  return (format: Formats.png, extension: 'png', mimeType: 'image/png');
}

String _ensureExtension(String fileName, String extension) {
  final clean = FileUiUtils.cleanFileName(fileName);
  if (clean.toLowerCase().endsWith('.$extension')) return clean;
  return '$clean.$extension';
}

Future<({String name, String mimeType, bool isImage})>
    _writeFileBytesToClipboard({
  required File file,
  required String fileName,
  String? mimeType,
}) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) {
    throw UnsupportedError('Буфер обмена недоступен на этой платформе');
  }

  final bytes = await file.readAsBytes();
  final lowerMime = (mimeType ?? '').toLowerCase();
  final imageFormat = lowerMime == 'image/*' || lowerMime.startsWith('image/');
  final formatInfo = imageFormat ? _clipboardImageFormat(bytes) : null;
  final effectiveName = formatInfo == null
      ? FileUiUtils.cleanFileName(fileName)
      : _ensureExtension(fileName, formatInfo.extension);
  final effectiveMimeType = formatInfo?.mimeType ??
      ((mimeType ?? '').isNotEmpty && mimeType != 'image/*'
          ? mimeType!
          : 'application/octet-stream');
  final format =
      formatInfo?.format ?? _clipboardFormatForFile(effectiveName, mimeType);

  final item = DataWriterItem(suggestedName: effectiveName);
  item.add(format(Uint8List.fromList(bytes)));
  await clipboard.write([item]);
  return (
    name: effectiveName,
    mimeType: effectiveMimeType,
    isImage: effectiveMimeType.startsWith('image/'),
  );
}

void _showShortCopiedSnack(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      const SnackBar(
        content: Text('Скопировано'),
        duration: Duration(milliseconds: 650),
        behavior: SnackBarBehavior.floating,
      ),
    );
}

class FullscreenImage extends StatefulWidget {
  final String imageUrl;
  final String? fileName;
  final String? sourceFileId;
  final List<String>? galleryUrls;
  final List<String>? galleryFileNames;
  final List<String>? galleryFileIds;
  final int initialIndex;

  const FullscreenImage({
    super.key,
    required this.imageUrl,
    this.fileName,
    this.sourceFileId,
    this.galleryUrls,
    this.galleryFileNames,
    this.galleryFileIds,
    this.initialIndex = 0,
  });

  @override
  State<FullscreenImage> createState() => _FullscreenImageState();
}

class _FullscreenImageState extends State<FullscreenImage> {
  late final bool _isGallery;
  late final PageController _pageController;
  late int _currentIndex;
  double _dragDy = 0;

  @override
  void initState() {
    super.initState();
    _isGallery = (widget.galleryUrls != null && widget.galleryUrls!.isNotEmpty);
    final maxIndex = _isGallery ? widget.galleryUrls!.length - 1 : 0;
    _currentIndex = widget.initialIndex.clamp(0, maxIndex).toInt();
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  String get _currentUrl =>
      _isGallery ? widget.galleryUrls![_currentIndex] : widget.imageUrl;

  String? get _currentFileId {
    if (_isGallery) {
      final ids = widget.galleryFileIds;
      if (ids != null && _currentIndex < ids.length) {
        final id = ids[_currentIndex].trim();
        if (id.isNotEmpty) return id;
      }
      return null;
    }
    final id = widget.sourceFileId?.trim();
    return (id == null || id.isEmpty) ? null : id;
  }

  String get _currentName {
    if (_isGallery) {
      final names = widget.galleryFileNames;
      if (names != null && _currentIndex < names.length) {
        final clean = FileUiUtils.cleanFileName(names[_currentIndex]);
        if (clean.isNotEmpty) return clean;
      }
      return 'Изображение';
    }
    final name = widget.fileName;
    if (name != null && name.isNotEmpty) {
      return FileUiUtils.cleanFileName(name);
    }
    return 'Изображение';
  }

  String get _title {
    if (!_isGallery) return _currentName;
    return '${_currentIndex + 1}/${widget.galleryUrls!.length}  $_currentName';
  }

  Future<void> _openCurrentExternally() async {
    try {
      final file = await _downloadRemoteFileToCache(
        url: _currentUrl,
        fileName: _currentName,
      );
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть файл: ${res.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть файл: $e')),
        );
      }
    }
  }

  Future<void> _shareCurrent() async {
    try {
      final file = await _downloadRemoteFileToCache(
        url: _currentUrl,
        fileName: _currentName,
      );
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, name: _currentName)]),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось поделиться файлом: $e')),
      );
    }
  }

  Future<void> _copyCurrentFileToClipboard() async {
    try {
      final file = await _downloadRemoteFileToCache(
        url: _currentUrl,
        fileName: _currentName,
      );
      final meta = await _writeFileBytesToClipboard(
        file: file,
        fileName: _currentName,
        mimeType: 'image/*',
      );
      ChatCopiedFileCache.remember(
        path: file.path,
        name: meta.name,
        mimeType: meta.mimeType,
        isImage: meta.isImage,
        fileId: _currentFileId,
      );
      if (mounted) _showShortCopiedSnack(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось скопировать файл: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
        canPop: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black.withValues(alpha: 0.72),
            elevation: 0,
            leading: IconButton(
              tooltip: 'Закрыть',
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
            actions: [
              IconButton(
                tooltip: 'Открыть',
                icon:
                    const Icon(Icons.open_in_new_rounded, color: Colors.white),
                onPressed: _openCurrentExternally,
              ),
            ],
          ),
          body: GestureDetector(
            onVerticalDragUpdate: (details) {
              _dragDy += details.delta.dy;
            },
            onVerticalDragEnd: (details) {
              // Закрываем по лёгкому свайпу вверх или вниз,
              // но только если был реальный жест (смещение > 40)
              if (_dragDy.abs() > 40 ||
                  ((details.primaryVelocity ?? 0).abs()) > 300) {
                Navigator.pop(context);
              }
              _dragDy = 0;
            },
            child: _isGallery ? _buildGallery() : _buildSingle(),
          ),
          bottomNavigationBar: _ViewerActionBar(
            actions: [
              _ViewerAction(
                icon: Icons.open_in_new_rounded,
                label: 'Открыть',
                onTap: _openCurrentExternally,
              ),
              _ViewerAction(
                icon: Icons.ios_share_rounded,
                label: 'Поделиться',
                onTap: _shareCurrent,
              ),
              _ViewerAction(
                icon: Icons.copy_rounded,
                label: 'Копировать',
                onTap: _copyCurrentFileToClipboard,
              ),
            ],
          ),
        ));
  }

  Widget _buildSingle() {
    return Center(
      child: InteractiveViewer(
        minScale: 0.7,
        maxScale: 4,
        child: Image.network(
          _currentUrl,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          },
          errorBuilder: (context, error, stackTrace) => const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white,
                  size: 48,
                ),
                SizedBox(height: 16),
                Text(
                  'Не удалось открыть изображение',
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGallery() {
    final urls = widget.galleryUrls!;
    return PhotoViewGestureDetectorScope(
      axis: Axis.vertical,
      child: PhotoViewGallery.builder(
        pageController: _pageController,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        itemCount: urls.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        builder: (context, index) {
          final url = urls[index];
          return PhotoViewGalleryPageOptions(
            imageProvider: NetworkImage(url),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 2,
          );
        },
        loadingBuilder: (context, event) => const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      ),
    );
  }
}

class FullscreenFileViewer extends StatefulWidget {
  final String fileUrl;
  final String fileName;
  final int fileSize;
  final String? mimeType;
  final String? sourceFileId;

  const FullscreenFileViewer({
    super.key,
    required this.fileUrl,
    required this.fileName,
    required this.fileSize,
    this.mimeType,
    this.sourceFileId,
  });

  @override
  State<FullscreenFileViewer> createState() => _FullscreenFileViewerState();
}

class _FullscreenFileViewerState extends State<FullscreenFileViewer> {
  bool _opening = false;
  late final Future<File> _cachedFileFuture;

  @override
  void initState() {
    super.initState();
    _cachedFileFuture = _ensureCachedFile();
  }

  String get _fileName => FileUiUtils.cleanFileName(widget.fileName);
  bool get _isPdf {
    final name = _fileName.toLowerCase();
    final mime = (widget.mimeType ?? '').toLowerCase();
    return mime.contains('pdf') || name.endsWith('.pdf');
  }

  Future<void> _downloadAndOpen() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final file = await _cachedFileFuture;
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть файл: ${res.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть файл')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<File> _ensureCachedFile() {
    return _downloadRemoteFileToCache(
      url: widget.fileUrl,
      fileName: _fileName,
    );
  }

  Future<void> _shareCachedFile() async {
    try {
      final file = await _cachedFileFuture;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, name: _fileName)]),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось поделиться файлом: $e')),
      );
    }
  }

  Future<void> _copyCachedFileToClipboard() async {
    try {
      final file = await _cachedFileFuture;
      final meta = await _writeFileBytesToClipboard(
        file: file,
        fileName: _fileName,
        mimeType: widget.mimeType,
      );
      ChatCopiedFileCache.remember(
        path: file.path,
        name: meta.name,
        mimeType: meta.mimeType,
        isImage: meta.isImage,
        fileId: widget.sourceFileId,
      );
      if (mounted) _showShortCopiedSnack(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось скопировать файл: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0F),
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: .72),
        elevation: 0,
        leading: IconButton(
          tooltip: 'Закрыть',
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          _fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            tooltip: 'Открыть файл',
            icon: const Icon(Icons.open_in_new_rounded, color: Colors.white),
            onPressed: _opening ? null : _downloadAndOpen,
          ),
        ],
      ),
      body: _isPdf ? _buildPdfPreview() : _buildFileActionCard(theme, scheme),
      bottomNavigationBar: _ViewerActionBar(
        actions: [
          _ViewerAction(
            icon: Icons.open_in_new_rounded,
            label: _opening ? 'Открываем' : 'Открыть',
            onTap: _opening ? null : _downloadAndOpen,
          ),
          _ViewerAction(
            icon: Icons.ios_share_rounded,
            label: 'Поделиться',
            onTap: _shareCachedFile,
          ),
          _ViewerAction(
            icon: Icons.copy_rounded,
            label: 'Копировать',
            onTap: _copyCachedFileToClipboard,
          ),
        ],
      ),
    );
  }

  Widget _buildPdfPreview() {
    return FutureBuilder<File>(
      future: _cachedFileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return _buildFileActionCard(
              Theme.of(context), Theme.of(context).colorScheme);
        }
        return PdfDocumentViewBuilder.file(
          snapshot.data!.path,
          loadingBuilder: (context) => const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
          errorBuilder: (context, error, stackTrace) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Не удалось открыть PDF: $error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
          builder: (context, document) {
            if (document == null) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.white),
              );
            }
            return PdfViewer.file(snapshot.data!.path);
          },
        );
      },
    );
  }

  Widget _buildFileActionCard(ThemeData theme, ColorScheme scheme) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .24),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppFileCard(
                    fileName: _fileName,
                    fileSize: widget.fileSize,
                    mimeType: widget.mimeType,
                    compact: true,
                    maxNameLines: 2,
                    trailing: _opening
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.insert_drive_file_outlined,
                            color: scheme.onSurfaceVariant,
                          ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _opening ? null : _downloadAndOpen,
                      icon: _opening
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.open_in_new_rounded),
                      label: Text(_opening ? 'Открываем...' : 'Открыть файл'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerAction {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ViewerAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class _ViewerActionBar extends StatelessWidget {
  final List<_ViewerAction> actions;

  const _ViewerActionBar({required this.actions});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .78),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: .10)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: actions
              .map(
                (action) => Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: action.onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            action.icon,
                            color: action.onTap == null
                                ? Colors.white38
                                : Colors.white,
                            size: 20,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            action.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: action.onTap == null
                                  ? Colors.white38
                                  : Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}
