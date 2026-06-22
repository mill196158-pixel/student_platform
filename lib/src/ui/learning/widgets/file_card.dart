import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;

class FileUiUtils {
  FileUiUtils._();

  static String cleanFileName(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return 'Файл';
    final withoutQuery = raw.split('?').first;
    final name = withoutQuery.split(RegExp(r'[\\/]')).last.trim();
    return name.isEmpty ? 'Файл' : name;
  }

  static String formatFileSize(int bytes) {
    if (bytes <= 0) return '0 Б';
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  static IconData iconFor({String? name, String? mimeType}) {
    final mime = (mimeType ?? '').toLowerCase();
    final ext = cleanFileName(name).split('.').last.toLowerCase();

    if (mime.startsWith('image/') ||
        ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'].contains(ext)) {
      return Icons.image_outlined;
    }
    if (mime.contains('pdf') || ext == 'pdf')
      return Icons.picture_as_pdf_outlined;
    if (mime.contains('word') || ['doc', 'docx'].contains(ext)) {
      return Icons.description_outlined;
    }
    if (mime.contains('excel') ||
        mime.contains('spreadsheet') ||
        ['xls', 'xlsx', 'csv'].contains(ext)) {
      return Icons.table_chart_outlined;
    }
    if (mime.contains('powerpoint') || ['ppt', 'pptx'].contains(ext)) {
      return Icons.slideshow_outlined;
    }
    if (ext == 'dwg') return Icons.architecture_outlined;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return Icons.folder_zip_outlined;
    }
    if (mime.startsWith('text/') || ['txt', 'md', 'rtf'].contains(ext)) {
      return Icons.text_snippet_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

class AppFileCard extends StatelessWidget {
  final String fileName;
  final int fileSize;
  final String? mimeType;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Widget? leading;
  final String? statusLabel;
  final Color? statusColor;
  final bool selected;
  final bool dense;
  final int maxNameLines;
  final bool showFileSize;
  final bool compact;
  final Color? backgroundColor;
  final Color? borderColor;

  const AppFileCard({
    super.key,
    required this.fileName,
    required this.fileSize,
    this.mimeType,
    this.onTap,
    this.trailing,
    this.leading,
    this.statusLabel,
    this.statusColor,
    this.selected = false,
    this.dense = false,
    this.maxNameLines = 2,
    this.showFileSize = true,
    this.compact = false,
    this.backgroundColor,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = FileUiUtils.cleanFileName(fileName);
    final isCompact = compact || dense;
    final radius = BorderRadius.circular(isCompact ? 16 : 18);
    final bg = backgroundColor ??
        (selected
            ? scheme.primaryContainer.withValues(alpha: 0.36)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.52));
    final effectiveBorderColor = borderColor ??
        (selected
            ? scheme.primary.withValues(alpha: 0.72)
            : scheme.outlineVariant.withValues(alpha: 0.36));

    return LayoutBuilder(
      builder: (context, _) {
        final iconWidth = isCompact ? 42.0 : 48.0;
        final gap = isCompact ? 10.0 : 12.0;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Ink(
              padding: EdgeInsets.symmetric(
                horizontal: isCompact ? 10 : 12,
                vertical: isCompact ? 8 : 10,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: radius,
                border: Border.all(
                    color: effectiveBorderColor, width: selected ? 1.2 : .6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: iconWidth,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: leading ??
                          _DefaultFileIcon(
                              name: name, mimeType: mimeType, dense: isCompact),
                    ),
                  ),
                  SizedBox(width: gap),
                  Flexible(
                    fit: FlexFit.loose,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: isCompact ? 1 : maxNameLines,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.12,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 3),
                        if (showFileSize ||
                            (statusLabel != null && statusLabel!.isNotEmpty))
                          Wrap(
                            spacing: 6,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (showFileSize)
                                Text(
                                  FileUiUtils.formatFileSize(fileSize),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              if (statusLabel != null &&
                                  statusLabel!.isNotEmpty)
                                Text(
                                  statusLabel!,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: statusColor ?? scheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    SizedBox(width: isCompact ? 8 : 10),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class AppNetworkImagePreview extends StatefulWidget {
  final String imageUrl;
  final String fileName;
  final VoidCallback? onTap;
  final Widget? overlay;
  final double? maxWidth;
  final double maxHeight;
  final double minHeight;
  final double borderRadius;
  final BoxFit fit;

  const AppNetworkImagePreview({
    super.key,
    required this.imageUrl,
    required this.fileName,
    this.onTap,
    this.overlay,
    this.maxWidth,
    this.maxHeight = 320,
    this.minHeight = 148,
    this.borderRadius = 20,
    this.fit = BoxFit.contain,
  });

  @override
  State<AppNetworkImagePreview> createState() => _AppNetworkImagePreviewState();
}

class _AppNetworkImagePreviewState extends State<AppNetworkImagePreview> {
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  double? _aspectRatio;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant AppNetworkImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _aspectRatio = null;
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _removeListener();
    super.dispose();
  }

  void _removeListener() {
    final stream = _imageStream;
    final listener = _imageListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _imageStream = null;
    _imageListener = null;
  }

  void _resolveImage() {
    _removeListener();
    final provider = CachedNetworkImageProvider(widget.imageUrl);
    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener((info, _) {
      final width = info.image.width.toDouble();
      final height = info.image.height.toDouble();
      if (width <= 0 || height <= 0 || !mounted) return;
      setState(() => _aspectRatio = width / height);
    });
    _imageStream = stream;
    _imageListener = listener;
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaWidth = MediaQuery.sizeOf(context).width;
        final defaultMaxWidth =
            mediaWidth >= 900 ? 288.0 : (mediaWidth * 0.66).clamp(152.0, 252.0);
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : defaultMaxWidth;
        final desiredMaxWidth =
            widget.maxWidth ?? defaultMaxWidth.clamp(220.0, 360.0);
        final effectiveMaxWidth =
            availableWidth < desiredMaxWidth ? availableWidth : desiredMaxWidth;
        final aspect = _aspectRatio;
        final isSquareLike = aspect != null && aspect > .82 && aspect < 1.22;
        final maxSide = math.min(
          math.min(effectiveMaxWidth, widget.maxHeight),
          245.0,
        );
        double width;
        double height;

        if (aspect == null) {
          width = isSquareLike ? maxSide : effectiveMaxWidth;
          height = width.clamp(widget.minHeight, widget.maxHeight);
        } else if (isSquareLike) {
          width = maxSide;
          height = maxSide;
        } else if (aspect > 1) {
          width = effectiveMaxWidth;
          height = (width / aspect).clamp(120.0, widget.maxHeight);
          if (height > widget.maxHeight) {
            height = widget.maxHeight;
            width = height * aspect;
          }
        } else {
          height = widget.maxHeight;
          width = (height * aspect).clamp(150.0, effectiveMaxWidth);
          height = width / aspect;
          if (height > widget.maxHeight) {
            height = widget.maxHeight;
            width = height * aspect;
          }
        }

        width = width.clamp(120.0, effectiveMaxWidth).toDouble();
        height = height.clamp(120.0, widget.maxHeight).toDouble();
        final radius = BorderRadius.circular(widget.borderRadius);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: .36),
                borderRadius: radius,
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: widget.imageUrl,
                        fit: widget.fit,
                        placeholder: (context, url) => _ImageState(
                          icon: Icons.image_outlined,
                          label: 'Загрузка...',
                          color: scheme.surfaceContainerHighest
                              .withValues(alpha: .72),
                        ),
                        errorWidget: (context, url, error) => _ImageState(
                          icon: Icons.broken_image_outlined,
                          label: 'Не удалось открыть изображение',
                          color: scheme.errorContainer.withValues(alpha: 0.42),
                        ),
                      ),
                      if (widget.overlay != null) widget.overlay!,
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DefaultFileIcon extends StatelessWidget {
  final String name;
  final String? mimeType;
  final bool dense;

  const _DefaultFileIcon({
    required this.name,
    required this.mimeType,
    required this.dense,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = dense ? 42.0 : 48.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        FileUiUtils.iconFor(name: name, mimeType: mimeType),
        color: scheme.primary,
        size: dense ? 21 : 24,
      ),
    );
  }
}

class _ImageState extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _ImageState({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: color,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
