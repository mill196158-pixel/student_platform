// lib/src/ui/learning/tabs/chat/assignment_bubble.dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'dart:math' as math;

import '../../state/team_cubit.dart';
import '../../models/message.dart';
import '../../models/assignment.dart';
import '../../assignment_details_screen.dart';
import '../../widgets/file_card.dart';
import '../../widgets/fullscreen_image.dart';
import 'assignments/assignment_form_dialog.dart';

class AssignmentBubble extends StatelessWidget {
  final Message message;
  final bool isDraft; // true -> черновик, false -> опубликовано
  final String time;
  final VoidCallback? onOpen;
  final VoidCallback? onPublish; // для старосты
  final VoidCallback? onEdit;
  final VoidCallback? onCancel;
  final VoidCallback? onVote; // обычные
  final VoidCallback? onLongPress;
  final VoidCallback? onPin;
  final Map<String, int>? reactions;
  final VoidCallback? onReact;
  final Key? boundaryKey;

  const AssignmentBubble({
    super.key,
    required this.message,
    required this.isDraft,
    required this.time,
    this.onOpen,
    this.onPublish,
    this.onEdit,
    this.onCancel,
    this.onVote,
    this.onLongPress,
    this.onPin,
    this.reactions,
    this.onReact,
    this.boundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final st = context.watch<TeamCubit>().state;

    // Рендерим карточку ТОЛЬКО если есть валидный assignmentId и нашли задание.
    final String? aid =
        (message.assignmentId ?? '').isNotEmpty ? message.assignmentId : null;
    if (aid == null) return const SizedBox.shrink();

    Assignment? a;
    final byId = st.assignments.where((x) => x.id == aid);
    if (byId.isNotEmpty) a = byId.first;
    if (a == null) {
      return _MissingAssignmentBubble(
        isDraft: isDraft,
        time: time,
        onLongPress: onLongPress,
        boundaryKey: boundaryKey,
      );
    }
    final assignment = a;

    final cs = Theme.of(context).colorScheme;

    // Сдержанные цвета без «жёлто-чёрной ленты»
    final bg = isDraft
        ? cs.secondaryContainer.withValues(alpha: .28)
        : cs.primary.withValues(alpha: .08);
    final border = isDraft
        ? cs.secondary.withValues(alpha: .45)
        : cs.primary.withValues(alpha: .38);
    final textColor =
        Theme.of(context).textTheme.bodyLarge?.color ?? Colors.black;
    final subColor =
        Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: .65) ??
            Colors.black54;

    // Автор карточки — из самого сообщения
    final authorDisplay = () {
      final n = message.authorName.trim();
      if (n.isNotEmpty) return n;
      final l = message.authorLogin.trim();
      return l.isNotEmpty ? l : 'участник';
    }();

    final headerText = isDraft ? 'Черновик задания' : 'Задание опубликовано';
    final whoDidText =
        isDraft ? 'предложил: $authorDisplay' : 'опубликовал: $authorDisplay';

    final canManageDraft = isDraft && st.isStarosta;
    final canVoteDraft = isDraft && !st.isStarosta;

    // ДЕФОЛТНЫЕ действия, если снаружи не передали колбэки
    void _defaultOpen() {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BlocProvider.value(
            value: context.read<TeamCubit>(),
            child: AssignmentDetailsScreen(assignmentId: assignment.id),
          ),
        ),
      );
    }

    Future<void> _defaultPublish() async {
      await context.read<TeamCubit>().publishAssignment(assignment.id);
    }

    Future<void> _defaultEdit() async {
      final res = await showAssignmentFormDialog(context, initial: assignment);
      if (res == null || !context.mounted) return;
      await context.read<TeamCubit>().updateAssignment(
            assignment.id,
            title: res.$1,
            description: res.$2,
            link: res.$3,
            due: res.$4,
            attachments: res.$5,
          );
    }

    Future<void> _defaultCancel() async {
      await context.read<TeamCubit>().removeAssignment(assignment.id);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        const sideOffset = 36.0;
        final available = math.max(120.0, rowWidth - sideOffset - 8);
        final bubbleMaxWidth = math.min(
          rowWidth >= 700 ? 430.0 : available * 0.96,
          available,
        );

        return GestureDetector(
          onLongPress: onLongPress,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // левая пустая зона для выравнивания системного сообщения
              const SizedBox(width: 36),
              Flexible(
                child: ConstrainedBox(
                  key: boundaryKey,
                  constraints: BoxConstraints(maxWidth: bubbleMaxWidth),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                    decoration: BoxDecoration(
                      color: bg,
                      border: Border.all(color: border, width: .7),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isDraft
                                      ? cs.secondary.withValues(alpha: .12)
                                      : cs.primary.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isDraft
                                          ? Icons.pending_outlined
                                          : Icons.assignment_outlined,
                                      color:
                                          isDraft ? cs.secondary : cs.primary,
                                      size: 14,
                                    ),
                                    const SizedBox(width: 5),
                                    Flexible(
                                      child: ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(maxWidth: 190),
                                        child: Text(
                                          headerText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                            color: isDraft
                                                ? cs.secondary
                                                : cs.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              time,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.black54),
                            ),
                          ],
                        ),

                        // КТО сделал действие
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            whoDidText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: subColor),
                          ),
                        ),

                        const SizedBox(height: 7),

                        // КОНТЕНТ
                        Text(
                          assignment.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                            color: textColor,
                          ),
                        ),
                        if ((assignment.due ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: _AssignmentMetaChip(
                              icon: Icons.schedule_rounded,
                              label: 'до ${assignment.due!}',
                              color: subColor,
                            ),
                          ),
                        if (assignment.description.trim().isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            assignment.description,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: textColor.withValues(alpha: .9)),
                          ),
                        ],
                        if (assignment.attachments.isNotEmpty) ...[
                          const SizedBox(height: 7),
                          _AssignmentAttachmentsPreview(
                              attachments: assignment.attachments),
                        ],

                        const SizedBox(height: 7),

                        // КНОПКИ
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (isDraft)
                              _AssignmentMetaChip(
                                icon: Icons.how_to_vote_outlined,
                                label: '${assignment.votesCount}/2 голосов',
                                color: subColor,
                              ),
                            if (!isDraft)
                              _AssignmentMetaChip(
                                icon: Icons.check_circle_outline,
                                label: 'Опубликовано',
                                color: cs.primary,
                              ),
                            if (canManageDraft) ...[
                              TextButton.icon(
                                onPressed: onEdit ?? _defaultEdit,
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                label: const Text('Редактировать'),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: onCancel ?? _defaultCancel,
                                icon: const Icon(Icons.close, size: 18),
                                label: const Text('Отменить'),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 10),
                                ),
                              ),
                              FilledButton.icon(
                                onPressed: onPublish ?? _defaultPublish,
                                icon: const Icon(Icons.publish, size: 18),
                                label: const Text('Опубликовать'),
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 10),
                                ),
                              ),
                            ] else if (canVoteDraft) ...[
                              FilledButton.icon(
                                onPressed: onVote ??
                                    () => context
                                        .read<TeamCubit>()
                                        .voteFor(a!.id),
                                icon: const Icon(Icons.how_to_vote_outlined,
                                    size: 18),
                                label: const Text('Голосовать'),
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 10),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: onOpen ?? _defaultOpen,
                                icon: const Icon(Icons.open_in_new, size: 18),
                                label: const Text('Открыть'),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                              ),
                            ] else ...[
                              TextButton.icon(
                                onPressed: onOpen ?? _defaultOpen,
                                icon: const Icon(Icons.open_in_new, size: 18),
                                label: const Text('Открыть'),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                              ),
                            ],
                          ],
                        ),

                        // Ряд реакций под карточкой задания
                        if (reactions != null && reactions!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: reactions!.entries
                                  .map((e) => GestureDetector(
                                        onTap: onReact,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.black
                                                .withValues(alpha: .08),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text('${e.key} ${e.value}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: textColor)),
                                        ),
                                      ))
                                  .toList(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MissingAssignmentBubble extends StatelessWidget {
  final bool isDraft;
  final String time;
  final VoidCallback? onLongPress;
  final Key? boundaryKey;

  const _MissingAssignmentBubble({
    required this.isDraft,
    required this.time,
    this.onLongPress,
    this.boundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const title = 'Задание загружается...';
    const subtitle = 'Данные задания подтягиваются.';

    return GestureDetector(
      onLongPress: onLongPress,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const SizedBox(width: 36),
          Flexible(
            child: ConstrainedBox(
              key: boundaryKey,
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.70,
              ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: .55),
                  border: Border.all(color: cs.outlineVariant),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                time,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color
                                  ?.withValues(alpha: .72),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssignmentMetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _AssignmentMetaChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _AssignmentAttachmentsPreview extends StatelessWidget {
  final List<Map<String, String>> attachments;

  const _AssignmentAttachmentsPreview({required this.attachments});

  @override
  Widget build(BuildContext context) {
    final images = attachments.where(_isImageAttachment).toList();
    final documents = attachments.where((a) => !_isImageAttachment(a)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (images.isNotEmpty) ...[
          _AssignmentImageGrid(images: images),
          if (documents.isNotEmpty) const SizedBox(height: 8),
        ],
        if (documents.isNotEmpty)
          Column(
            children: documents
                .map(
                  (doc) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppFileCard(
                      fileName: _attachmentName(doc),
                      fileSize: 0,
                      mimeType: _attachmentMime(doc),
                      showFileSize: false,
                      dense: true,
                    ),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

class _AssignmentImageGrid extends StatelessWidget {
  final List<Map<String, String>> images;

  const _AssignmentImageGrid({required this.images});

  @override
  Widget build(BuildContext context) {
    if (images.length == 1) {
      final image = images.first;
      return AppNetworkImagePreview(
        imageUrl: _attachmentUrl(image),
        fileName: _attachmentName(image),
        maxHeight: 300,
        onTap: () => _openViewer(context, image),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final cellSize = ((width - 4) / 2).clamp(110.0, 190.0).toDouble();

        return SizedBox(
          width: cellSize * 2 + 4,
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
              childAspectRatio: 1,
            ),
            itemCount: images.length > 4 ? 4 : images.length,
            itemBuilder: (context, index) {
              final image = images[index];
              final isLast = index == 3 && images.length > 4;

              return Stack(
                fit: StackFit.expand,
                children: [
                  AppNetworkImagePreview(
                    imageUrl: _attachmentUrl(image),
                    fileName: _attachmentName(image),
                    minHeight: cellSize,
                    maxHeight: cellSize,
                    maxWidth: cellSize,
                    borderRadius: 10,
                    onTap: () => _openViewer(context, image),
                  ),
                  if (isLast)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          '+${images.length - 4}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _openViewer(BuildContext context, Map<String, String> image) {
    final initialIndex = images.indexOf(image);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullscreenImage(
          imageUrl: _attachmentUrl(image),
          fileName: _attachmentName(image),
          galleryUrls: images.map(_attachmentUrl).toList(),
          galleryFileNames: images.map(_attachmentName).toList(),
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
        ),
      ),
    );
  }
}

bool _isImageAttachment(Map<String, String> attachment) {
  final mime = _attachmentMime(attachment).toLowerCase();
  if (mime.startsWith('image/')) return true;

  final value = '${_attachmentName(attachment)} ${_attachmentUrl(attachment)}'
      .toLowerCase()
      .split('?')
      .first;
  return const ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic']
      .any(value.endsWith);
}

String _attachmentName(Map<String, String> attachment) {
  final explicit = (attachment['name'] ??
          attachment['filename'] ??
          attachment['title'] ??
          attachment['file'] ??
          '')
      .trim();
  if (explicit.isNotEmpty) return FileUiUtils.cleanFileName(explicit);

  final url = _attachmentUrl(attachment);
  return FileUiUtils.cleanFileName(url);
}

String _attachmentUrl(Map<String, String> attachment) {
  return (attachment['path'] ??
          attachment['url'] ??
          attachment['link'] ??
          attachment['href'] ??
          '')
      .trim();
}

String _attachmentMime(Map<String, String> attachment) {
  return (attachment['mime'] ??
          attachment['mimeType'] ??
          attachment['type'] ??
          attachment['fileType'] ??
          '')
      .trim();
}
