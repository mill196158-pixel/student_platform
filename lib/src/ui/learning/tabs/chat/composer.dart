// FILE: lib/src/ui/learning/tabs/chat/composer.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/local_attach.dart';
import '../../widgets/file_card.dart';

class _PasteFileIntent extends Intent {
  const _PasteFileIntent();
}

class AttachedFile {
  final String localId;
  final String path;
  final String name;
  final bool isImage;
  final int size;
  final LocalAttachUploadStatus uploadStatus;
  final double progress;
  final String? errorMessage;
  final String? uploadedFileId;

  AttachedFile({
    required this.localId,
    required this.path,
    required this.name,
    required this.isImage,
    required this.size,
    this.uploadStatus = LocalAttachUploadStatus.uploaded,
    this.progress = 1,
    this.errorMessage,
    this.uploadedFileId,
  });

  bool get isUploading => uploadStatus == LocalAttachUploadStatus.uploading;
  bool get isQueued => uploadStatus == LocalAttachUploadStatus.queued;
  bool get isFailed => uploadStatus == LocalAttachUploadStatus.failed;
  bool get isUploaded => uploadStatus == LocalAttachUploadStatus.uploaded;
  bool get canCancel => isQueued || isUploading;
  bool get canRetry => isFailed;
}

class Composer extends StatefulWidget {
  final TextEditingController controller;
  final String? pickedImagePath;
  final Widget? leftButton;
  final VoidCallback onOpenEmoji;
  final VoidCallback onSend;
  final VoidCallback onClearPicked;
  final Future<void> Function() onPickImage;
  final VoidCallback? onAttachFile;
  final Future<void> Function()? onPasteFile;
  final FocusNode? focusNode;
  final List<AttachedFile> attachedFiles;
  final int forwardCount;
  final String? forwardPreview;
  final VoidCallback? onCancelForward;
  final Function(AttachedFile) onRemoveFile;
  final Function(AttachedFile) onAddFile;
  final bool isUploading;
  final bool hasFailedUploads;
  final bool isSending;
  final Function(AttachedFile)? onRetryFile;

  const Composer({
    super.key,
    required this.controller,
    required this.pickedImagePath,
    required this.onOpenEmoji,
    required this.onSend,
    required this.onClearPicked,
    required this.onPickImage,
    required this.attachedFiles,
    required this.onRemoveFile,
    required this.onAddFile,
    this.leftButton,
    this.focusNode,
    this.forwardCount = 0,
    this.forwardPreview,
    this.onCancelForward,
    this.onAttachFile,
    this.onPasteFile,
    this.isUploading = false,
    this.hasFailedUploads = false,
    this.isSending = false,
    this.onRetryFile,
  });

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibleAttachedFiles = widget.attachedFiles
        .where((file) => file.path != '__FG__')
        .toList(growable: false);

    // Same bottom level as ModernBottomNav; keep home-indicator gesture clear.
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final bottomPad = safeBottom > 0
        ? (safeBottom - 12).clamp(18.0, safeBottom)
        : 6.0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomPad),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: .96),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .06),
              blurRadius: 18,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.forwardCount > 0)
              _ForwardComposerPreview(
                count: widget.forwardCount,
                preview: widget.forwardPreview,
                onCancel: widget.onCancelForward,
              ),
            if (visibleAttachedFiles.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                height: 72,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: visibleAttachedFiles.length,
                  itemBuilder: (context, index) {
                    final file = visibleAttachedFiles[index];
                    final progress = file.progress.clamp(0.0, 1.0).toDouble();
                    final percent = (progress * 100).round();
                    final statusLabel = file.isFailed
                        ? 'Не удалось загрузить'
                        : file.isQueued
                            ? 'В очереди'
                            : file.isUploading
                                ? '$percent%'
                                : 'Готово';
                    if (file.isImage) {
                      return SizedBox(
                        width: 108,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _AttachedImagePreview(
                            file: file,
                            statusLabel: statusLabel,
                            statusColor: file.isFailed
                                ? theme.colorScheme.error
                                : file.isUploaded
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                            onRemove: () => widget.onRemoveFile(file),
                            onRetry: file.isFailed && widget.onRetryFile != null
                                ? () => widget.onRetryFile!(file)
                                : null,
                          ),
                        ),
                      );
                    }

                    return SizedBox(
                      width: 224,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _AttachedDocumentPreview(
                          file: file,
                          statusLabel: statusLabel,
                          statusColor: file.isFailed
                              ? theme.colorScheme.error
                              : file.isUploaded
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                          onRemove: () => widget.onRemoveFile(file),
                          onRetry: file.isFailed && widget.onRetryFile != null
                              ? () => widget.onRetryFile!(file)
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (widget.pickedImagePath != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: .2)),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(widget.pickedImagePath!),
                        height: 44,
                        width: 44,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('Вложение готово')),
                    IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: widget.onClearPicked),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                widget.leftButton ?? const SizedBox(width: 0),
                if (widget.leftButton != null) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: .58),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color:
                              theme.colorScheme.outline.withValues(alpha: .2)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Shortcuts(
                            shortcuts: widget.onPasteFile == null
                                ? const <ShortcutActivator, Intent>{}
                                : const <ShortcutActivator, Intent>{
                                    SingleActivator(
                                      LogicalKeyboardKey.keyV,
                                      control: true,
                                    ): _PasteFileIntent(),
                                    SingleActivator(
                                      LogicalKeyboardKey.keyV,
                                      meta: true,
                                    ): _PasteFileIntent(),
                                  },
                            child: Actions(
                              actions: <Type, Action<Intent>>{
                                _PasteFileIntent:
                                    CallbackAction<_PasteFileIntent>(
                                  onInvoke: (_) {
                                    widget.onPasteFile?.call();
                                    return null;
                                  },
                                ),
                              },
                              child: TextField(
                                focusNode: widget.focusNode,
                                controller: widget.controller,
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.send,
                                minLines: 1,
                                maxLines: 6,
                                decoration: const InputDecoration(
                                  hintText: 'Сообщение',
                                  border: InputBorder.none,
                                  isCollapsed: true,
                                  contentPadding:
                                      EdgeInsets.symmetric(vertical: 12),
                                ),
                                contextMenuBuilder: widget.onPasteFile == null
                                    ? null
                                    : (context, editableTextState) {
                                        final items = editableTextState
                                            .contextMenuButtonItems
                                            .where((item) =>
                                                item.type !=
                                                ContextMenuButtonType.paste);
                                        return AdaptiveTextSelectionToolbar
                                            .buttonItems(
                                          anchors: editableTextState
                                              .contextMenuAnchors,
                                          buttonItems: [
                                            ContextMenuButtonItem(
                                              label: 'Вставить',
                                              onPressed: () {
                                                ContextMenuController
                                                    .removeAny();
                                                widget.onPasteFile!();
                                              },
                                            ),
                                            ...items,
                                          ],
                                        );
                                      },
                                onSubmitted: (_) => widget.onSend(),
                              ),
                            ),
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.onAttachFile != null)
                              IconButton(
                                icon: const Icon(Icons.attach_file_rounded),
                                onPressed: widget.onAttachFile,
                                tooltip: 'Прикрепить файл',
                              ),
                            IconButton(
                              icon: const Icon(Icons.image_outlined),
                              onPressed: widget.onPickImage,
                              tooltip: 'Прикрепить изображение',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: (widget.isUploading || widget.isSending)
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.12)
                        : theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: Icon(
                      widget.hasFailedUploads
                          ? Icons.error_outline
                          : Icons.arrow_upward_rounded,
                      color: (widget.isUploading ||
                              widget.isSending ||
                              widget.hasFailedUploads)
                          ? Colors.grey
                          : Colors.white,
                    ),
                    onPressed: (widget.isUploading ||
                            widget.isSending ||
                            widget.hasFailedUploads)
                        ? null
                        : widget.onSend,
                    tooltip: widget.hasFailedUploads
                        ? 'Повторите или удалите файл'
                        : 'Отправить',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachedImagePreview extends StatelessWidget {
  final AttachedFile file;
  final String statusLabel;
  final Color statusColor;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;

  const _AttachedImagePreview({
    required this.file,
    required this.statusLabel,
    required this.statusColor,
    required this.onRemove,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showProgress = file.isUploading || file.isQueued;
    final progress = file.progress.clamp(0.0, 1.0).toDouble();
    final progressLabel = file.isQueued ? 'В очереди' : statusLabel;

    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(file.path),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.28),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.46),
                  ],
                  stops: const [0, 0.45, 1],
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: _MiniAttachmentButton(
                icon: Icons.close_rounded,
                tooltip: file.canCancel ? 'Отменить загрузку' : 'Удалить',
                onPressed: onRemove,
              ),
            ),
            if (onRetry != null)
              Positioned(
                top: 4,
                left: 4,
                child: _MiniAttachmentButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Повторить',
                  onPressed: onRetry!,
                ),
              ),
            if (showProgress)
              Positioned(
                left: 7,
                bottom: 12,
                child: _UploadPercentPill(label: progressLabel),
              ),
            if (!showProgress)
              Positioned(
                left: 8,
                right: 8,
                bottom: 7,
                child: Text(
                  statusLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: file.isUploaded ? Colors.white : statusColor,
                    fontWeight: FontWeight.w800,
                    shadows: const [
                      Shadow(
                        color: Colors.black54,
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
              ),
            if (showProgress)
              Positioned(
                left: 8,
                right: 8,
                bottom: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    value: file.isQueued ? null : progress,
                    backgroundColor: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ForwardComposerPreview extends StatelessWidget {
  final int count;
  final String? preview;
  final VoidCallback? onCancel;

  const _ForwardComposerPreview({
    required this.count,
    this.preview,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = count == 1 ? '1 сообщение' : '$count сообщений';
    final cleanPreview = (preview ?? '').trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .35),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.forward_rounded,
              color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Пересылка',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  cleanPreview.isEmpty ? label : '$label · $cleanPreview',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 20),
            visualDensity: VisualDensity.compact,
            tooltip: 'Отменить пересылку',
          ),
        ],
      ),
    );
  }
}

class _AttachedDocumentPreview extends StatelessWidget {
  final AttachedFile file;
  final String statusLabel;
  final Color statusColor;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;

  const _AttachedDocumentPreview({
    required this.file,
    required this.statusLabel,
    required this.statusColor,
    required this.onRemove,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showProgress = file.isUploading || file.isQueued;
    final progress = file.progress.clamp(0.0, 1.0).toDouble();

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: file.isFailed
              ? scheme.errorContainer.withValues(alpha: 0.22)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.52),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: file.isFailed
                ? scheme.error.withValues(alpha: 0.55)
                : scheme.outlineVariant.withValues(alpha: 0.36),
            width: file.isFailed ? 1.1 : 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Row(
                children: [
                  _DocumentAttachmentIcon(file: file),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          FileUiUtils.cleanFileName(file.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.05,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${FileUiUtils.formatFileSize(file.size)}  $statusLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w700,
                            height: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (onRetry != null)
                    _InlineAttachmentButton(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Повторить',
                      onPressed: onRetry!,
                    ),
                  _InlineAttachmentButton(
                    icon: Icons.close_rounded,
                    tooltip: file.canCancel ? 'Отменить загрузку' : 'Удалить',
                    onPressed: onRemove,
                  ),
                ],
              ),
            ),
            if (showProgress)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  minHeight: 3,
                  value: file.isQueued ? null : progress,
                  backgroundColor: scheme.outline.withValues(alpha: 0.14),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DocumentAttachmentIcon extends StatelessWidget {
  final AttachedFile file;

  const _DocumentAttachmentIcon({required this.file});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        FileUiUtils.iconFor(name: file.name),
        color: scheme.primary,
        size: 21,
      ),
    );
  }
}

class _InlineAttachmentButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _InlineAttachmentButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      icon: Icon(icon, size: 17),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

class _UploadPercentPill extends StatelessWidget {
  final String label;

  const _UploadPercentPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
        ),
      ),
    );
  }
}

class _MiniAttachmentButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _MiniAttachmentButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.36),
      shape: const CircleBorder(),
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        icon: Icon(icon, size: 16, color: Colors.white),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}
