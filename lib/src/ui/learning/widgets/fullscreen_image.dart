import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:photo_view/photo_view.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../utils/chat_copied_file_cache.dart';
import 'file_card.dart';

int _viewerTempSequence = 0;
final _viewerWriteVersions = <String, int>{};
final _viewerPublishQueues = <String, Future<void>>{};
@visibleForTesting
int debugGalleryDrains = 0;

@visibleForTesting
Future<File> writeViewerFileAtomically(File destination, List<int> bytes,
    {Future<void> Function()? beforePublish,
    bool Function()? canPublish}) async {
  final path = destination.absolute.path;
  final version = _viewerTempSequence++;
  _viewerWriteVersions[path] = version;
  final temporary =
      File('${destination.path}.tmp.$pid.${_viewerTempSequence++}');
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    if (beforePublish != null) await beforePublish();
    final previous = _viewerPublishQueues[path];
    final done = Completer<void>();
    _viewerPublishQueues[path] = done.future;
    try {
      if (previous != null) await previous;
      if (_viewerWriteVersions[path] != version ||
          !(canPublish?.call() ?? true)) throw StateError('Запись устарела.');
      return await temporary.rename(destination.path);
    } finally {
      done.complete();
      if (identical(_viewerPublishQueues[path], done.future)) {
        _viewerPublishQueues.remove(path);
      }
    }
  } finally {
    if (await temporary.exists()) await temporary.delete();
    if (_viewerWriteVersions[path] == version)
      _viewerWriteVersions.remove(path);
  }
}

Future<File> _downloadRemoteFileToCache({
  required String url,
  required String fileName,
  required _ViewerAccessTicket access,
  bool Function()? sourceCurrent,
}) async {
  void check() {
    if (!access.isCurrent(url) || !(sourceCurrent?.call() ?? true))
      throw StateError('Доступ к вложению изменился.');
  }

  check();
  final cleanName = FileUiUtils.cleanFileName(fileName);
  await ChatFileAccess.authorize(url);
  check();
  final digest =
      crypto.sha1.convert(utf8.encode('${access.user}:$url')).toString();
  final dir = await getApplicationCacheDirectory();
  check();
  final filesDir = Directory('${dir.path}${Platform.pathSeparator}chat_files');
  if (!await filesDir.exists()) {
    await filesDir.create(recursive: true);
  }
  check();

  final path = '${filesDir.path}${Platform.pathSeparator}${digest}_$cleanName';
  final cached = File(path);
  if (await cached.exists() && await cached.length() > 0) {
    check();
    return cached;
  }

  final bytes = await ChatFileAccess.readBytes(url);
  check();
  final file = await writeViewerFileAtomically(cached, bytes,
      canPublish: () => access.isCurrent(url) && (sourceCurrent?.call() ?? true));
  check();
  return file;
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
  required bool Function() isCurrent,
  String? mimeType,
}) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) {
    throw UnsupportedError('Буфер обмена недоступен на этой платформе');
  }

  if (!isCurrent()) throw StateError('Доступ к вложению изменился.');
  final bytes = await file.readAsBytes();
  if (!isCurrent()) throw StateError('Доступ к вложению изменился.');
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
  if (!isCurrent()) throw StateError('Доступ к вложению изменился.');
  await clipboard.write([item]);
  if (!isCurrent()) throw StateError('Доступ к вложению изменился.');
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

/// Gives transparent pixels a readable surface without changing source bytes.
/// Kept inside the zoom transform so the surface follows the image.
class FullscreenImageSurface extends StatelessWidget {
  const FullscreenImageSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.white,
        child: child,
      );
}

class _ViewerAccessTicket {
  _ViewerAccessTicket()
      : session = ChatFileAccess.currentSessionBinding,
        user = ChatFileAccess.userId,
        epoch = ChatFileAccess.generation;
  final String? session;
  final String? user;
  final int epoch;
  bool isCurrent(String url) => ChatFileAccess.isViewerCurrent(url,
      user: user, epoch: epoch, sessionBinding: session);
}

class _RevokedMedia extends StatelessWidget {
  const _RevokedMedia();
  @override
  Widget build(BuildContext context) => const Center(
      child:
          Text('Вложение недоступно', style: TextStyle(color: Colors.white)));
}

class _FullscreenImageState extends State<FullscreenImage> {
  late final bool _isGallery;
  late final PageController _pageController;
  late final List<AuthorizedFileImageProvider> _providers;
  late int _currentIndex;
  double _dragDy = 0;
  late final _ViewerAccessTicket _access;

  @override
  void initState() {
    super.initState();
    _access = _ViewerAccessTicket();
    ChatFileAccess.accessChanges.addListener(_accessChanged);
    _isGallery = (widget.galleryUrls != null && widget.galleryUrls!.isNotEmpty);
    _providers = [
      for (final url in (_isGallery ? widget.galleryUrls! : [widget.imageUrl]))
        AuthorizedFileImageProvider(url)
    ];
    final maxIndex = _isGallery ? widget.galleryUrls!.length - 1 : 0;
    _currentIndex = widget.initialIndex.clamp(0, maxIndex).toInt();
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    ChatFileAccess.accessChanges.removeListener(_accessChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _accessChanged() {
    if (mounted) setState(() {});
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
    final url = _currentUrl;
    if (!_access.isCurrent(url)) return;
    try {
      final file = await _downloadRemoteFileToCache(
        url: url,
        fileName: _currentName,
        access: _access,
      );
      if (!mounted || _currentUrl != url || !_access.isCurrent(url)) return;
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
    final url = _currentUrl;
    if (!_access.isCurrent(url)) return;
    try {
      final file = await _downloadRemoteFileToCache(
        url: url,
        fileName: _currentName,
        access: _access,
      );
      if (!mounted || _currentUrl != url || !_access.isCurrent(url)) return;
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
    final url = _currentUrl;
    final index = _currentIndex;
    final name = _currentName;
    final fileId = _currentFileId;
    bool current() =>
        mounted &&
        _currentIndex == index &&
        _currentUrl == url &&
        _access.isCurrent(url);
    if (!current()) return;
    try {
      final file = await _downloadRemoteFileToCache(
        url: url,
        fileName: name,
        access: _access,
      );
      if (!current()) return;
      final meta = await _writeFileBytesToClipboard(
        file: file,
        fileName: name,
        mimeType: 'image/*',
        isCurrent: current,
      );
      if (!current()) return;
      ChatCopiedFileCache.remember(
        path: file.path,
        name: meta.name,
        mimeType: meta.mimeType,
        isImage: meta.isImage,
        fileId: fileId,
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
    final allowed = _access.isCurrent(_currentUrl);
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
                onPressed: allowed ? _openCurrentExternally : null,
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
            child: _isGallery
                ? _buildGallery()
                : Stack(children: [
                    Offstage(offstage: !allowed, child: _buildSingle()),
                    if (!allowed) const _RevokedMedia()
                  ]),
          ),
          bottomNavigationBar: _ViewerActionBar(
            actions: [
              _ViewerAction(
                icon: Icons.open_in_new_rounded,
                label: 'Открыть',
                onTap: allowed ? _openCurrentExternally : null,
              ),
              _ViewerAction(
                icon: Icons.ios_share_rounded,
                label: 'Поделиться',
                onTap: allowed ? _shareCurrent : null,
              ),
              _ViewerAction(
                icon: Icons.copy_rounded,
                label: 'Копировать',
                onTap: allowed ? _copyCurrentFileToClipboard : null,
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
        child: Image(
          image: _providers.first,
          fit: BoxFit.contain,
          frameBuilder: (context, child, frame, synchronous) =>
              synchronous || frame != null
                  ? FullscreenImageSurface(child: child)
                  : child,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return const Center(
              child: ProductLoadingIndicator.page(color: Colors.white),
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
      child: PhotoViewGestureDetectorScope(
        axis: Axis.horizontal,
        child: PageView.builder(
          controller: _pageController,
          itemCount: urls.length,
          onPageChanged: (i) => setState(() => _currentIndex = i),
          itemBuilder: (context, index) {
            final permitted = _access.isCurrent(urls[index]);
            return Stack(children: [
              Offstage(
                  offstage: !permitted,
                  child: GalleryImageSurface(provider: _providers[index])),
              if (!permitted) const _RevokedMedia(),
            ]);
          },
        ),
      ),
    );
  }
}

/// Resolves the image size so the white backing follows the zoomed image.
class GalleryImageSurface extends StatefulWidget {
  const GalleryImageSurface({super.key, required this.provider});
  final ImageProvider provider;

  @override
  State<GalleryImageSurface> createState() => _GalleryImageSurfaceState();
}

class _GalleryImageSurfaceState extends State<GalleryImageSurface> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _imageInfo;
  bool _error = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant GalleryImageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      _unsubscribe();
      _error = false;
      _subscribe();
    }
  }

  void _subscribe() {
    final stream =
        widget.provider.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) return;
    _unsubscribe();
    _stream = stream;
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, synchronous) {
      if (!mounted || !identical(_listener, listener)) {
        info.dispose();
        return;
      }
      final previous = _imageInfo;
      if (synchronous) {
        _imageInfo = info;
        _error = false;
      } else {
        setState(() {
          _imageInfo = info;
          _error = false;
        });
      }
      previous?.dispose();
    }, onError: (Object _, StackTrace? __) {
      if (!mounted || !identical(_listener, listener)) return;
      if (_imageInfo == null) setState(() => _error = true);
    });
    _listener = listener;
    stream.addListener(listener);
  }

  void _unsubscribe() {
    final listener = _listener;
    final stream = _stream;
    if (listener != null && stream != null && _imageInfo == null) {
      // A revoked viewer can detach while its image future is still failing.
      // The provider API has no cancellation. Keep an independent listener
      // until the request settles, without retaining the disposed widget.
      late final ImageStreamListener drain;
      var finished = false;
      void finish() {
        if (finished) return;
        finished = true;
        debugGalleryDrains--;
        stream.removeListener(drain);
      }

      drain = ImageStreamListener((info, _) {
        info.dispose();
        finish();
      }, onError: (Object _, StackTrace? __) => finish());
      debugGalleryDrains++;
      stream.addListener(drain);
    }
    if (listener != null) stream?.removeListener(listener);
    _stream = null;
    _listener = null;
    _imageInfo?.dispose();
    _imageInfo = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error)
      return const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.white));
    final info = _imageInfo;
    if (info == null)
      return const Center(
          child: ProductLoadingIndicator.page(color: Colors.white));
    final size =
        Size(info.image.width / info.scale, info.image.height / info.scale);
    return ClipRect(
        child: PhotoView.customChild(
      childSize: size,
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 2,
      child: FullscreenImageSurface(
          child:
              RawImage(image: info.image, scale: info.scale, fit: BoxFit.fill)),
    ));
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
  Future<File>? _namedExport;
  late Future<File> _previewFileFuture;
  late _ViewerAccessTicket _access;
  late Object? _previewClient;
  int _sourceRevision = 0;

  @override
  void initState() {
    super.initState();
    ChatFileAccess.accessChanges.addListener(_accessChanged);
    _resetSource();
  }

  void _resetSource() {
    final revision = ++_sourceRevision;
    _access = _ViewerAccessTicket();
    _previewClient = ChatFileAccess.currentClientIdentity;
    _namedExport = null;
    _opening = false;
    // Keep named exports for share, clipboard and external viewers. A PDF
    // preview can use an already authorized local copy without exporting it.
    _previewFileFuture = _isPdf ? _ensurePdfPreview(revision) : _ensureCachedFile();
    unawaited(_previewFileFuture.then<void>((_) {},
        onError: (Object _, StackTrace __) {}));
  }

  @override
  void didUpdateWidget(covariant FullscreenFileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fileUrl != widget.fileUrl ||
        oldWidget.fileName != widget.fileName ||
        oldWidget.mimeType != widget.mimeType ||
        oldWidget.sourceFileId != widget.sourceFileId) {
      _resetSource();
    }
  }

  void _accessChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ChatFileAccess.accessChanges.removeListener(_accessChanged);
    super.dispose();
  }

  String get _fileName => FileUiUtils.cleanFileName(widget.fileName);
  bool get _isPdf {
    final name = _fileName.toLowerCase();
    final mime = (widget.mimeType ?? '').toLowerCase();
    return mime.contains('pdf') || name.endsWith('.pdf');
  }

  bool _previewCurrent(int revision) => mounted &&
      revision == _sourceRevision &&
      identical(_previewClient, ChatFileAccess.currentClientIdentity) &&
      _access.isCurrent(widget.fileUrl);

  Future<void> _downloadAndOpen() async {
    if (_opening || !_access.isCurrent(widget.fileUrl)) return;
    final revision = _sourceRevision;
    setState(() => _opening = true);
    try {
      final file = await _ensureCachedFile();
      if (!_previewCurrent(revision)) return;
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
      if (mounted && revision == _sourceRevision) setState(() => _opening = false);
    }
  }

  Future<File> _ensureCachedFile() {
    if (_namedExport != null) return _namedExport!;
    final revision = _sourceRevision;
    final url = widget.fileUrl;
    final access = _access;
    final client = _previewClient;
    bool current() => mounted && revision == _sourceRevision &&
        widget.fileUrl == url && identical(client, ChatFileAccess.currentClientIdentity) &&
        access.isCurrent(url);
    return _namedExport = _downloadRemoteFileToCache(
        url: url, fileName: _fileName, access: access, sourceCurrent: current);
  }

  Future<File> _ensurePdfPreview(int revision) async {
    final url = widget.fileUrl;
    final access = _access;
    final client = _previewClient;
    bool current() => mounted &&
        revision == _sourceRevision &&
        widget.fileUrl == url &&
        identical(client, ChatFileAccess.currentClientIdentity) &&
        access.isCurrent(url);
    if (!current()) throw StateError('Доступ к вложению изменился.');
    final path = await ChatFileAccess.cachedPathForOpen(url, permit: current);
    if (!current()) throw StateError('Доступ к вложению изменился.');
    if (path != null && path.isNotEmpty) return File(path);
    final file = await _ensureCachedFile();
    if (!current()) throw StateError('Доступ к вложению изменился.');
    return file;
  }

  Future<void> _shareCachedFile() async {
    if (!_access.isCurrent(widget.fileUrl)) return;
    final revision = _sourceRevision;
    try {
      final file = await _ensureCachedFile();
      if (!_previewCurrent(revision)) return;
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
    final url = widget.fileUrl;
    final revision = _sourceRevision;
    bool current() => widget.fileUrl == url && _previewCurrent(revision);
    if (!current()) return;
    try {
      final file = await _ensureCachedFile();
      if (!current()) return;
      final meta = await _writeFileBytesToClipboard(
        file: file,
        fileName: _fileName,
        mimeType: widget.mimeType,
        isCurrent: current,
      );
      if (!current()) return;
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
    final allowed = _access.isCurrent(widget.fileUrl) &&
        (!_isPdf || _previewCurrent(_sourceRevision));

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
            onPressed: _opening || !allowed ? null : _downloadAndOpen,
          ),
        ],
      ),
      body: !allowed
          ? const _RevokedMedia()
          : (_isPdf ? _buildPdfPreview() : _buildFileActionCard(theme, scheme)),
      bottomNavigationBar: _ViewerActionBar(
        actions: [
          _ViewerAction(
            icon: Icons.open_in_new_rounded,
            label: _opening ? 'Открываем' : 'Открыть',
            onTap: _opening || !allowed ? null : _downloadAndOpen,
          ),
          _ViewerAction(
            icon: Icons.ios_share_rounded,
            label: 'Поделиться',
            onTap: allowed ? _shareCachedFile : null,
          ),
          _ViewerAction(
            icon: Icons.copy_rounded,
            label: 'Копировать',
            onTap: allowed ? _copyCachedFileToClipboard : null,
          ),
        ],
      ),
    );
  }

  Widget _buildPdfPreview() {
    final revision = _sourceRevision;
    return FutureBuilder<File>(
      future: _previewFileFuture,
      builder: (context, snapshot) {
        if (!_previewCurrent(revision)) return const _RevokedMedia();
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: ProductLoadingIndicator.page(color: Colors.white),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return _buildFileActionCard(
              Theme.of(context), Theme.of(context).colorScheme);
        }
        return PdfDocumentViewBuilder.file(
          snapshot.data!.path,
          loadingBuilder: (context) => !_previewCurrent(revision)
              ? const _RevokedMedia()
              : const Center(child: ProductLoadingIndicator.page(color: Colors.white)),
          errorBuilder: (context, error, stackTrace) => !_previewCurrent(revision)
              ? const _RevokedMedia()
              : Center(
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
            if (!_previewCurrent(revision)) return const _RevokedMedia();
            if (document == null) {
              return const Center(
                child: ProductLoadingIndicator.page(color: Colors.white),
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
                            child: ProductLoadingIndicator(),
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
                              child: ProductLoadingIndicator(),
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
