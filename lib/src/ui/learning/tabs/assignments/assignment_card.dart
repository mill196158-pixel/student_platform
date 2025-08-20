import 'package:flutter/material.dart';
import '../../models/assignment.dart';

class AssignmentCard extends StatelessWidget {
  final Assignment assignment;
  final bool isDraft;
  final bool canPublish;
  final VoidCallback onOpen;
  final VoidCallback? onPublish;
  final VoidCallback? onVote;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const AssignmentCard({
    super.key,
    required this.assignment,
    required this.onOpen,
    this.onPublish,
    this.onVote,
    this.onEdit,
    this.onDelete,
    this.isDraft = false,
    this.canPublish = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = isDraft ? Colors.amber.withOpacity(.14) : cs.surfaceContainerHigh;
    final border = isDraft ? Colors.orangeAccent : cs.outlineVariant;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border.withOpacity(.6), width: .5),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isDraft ? Icons.edit_note_outlined : Icons.assignment_outlined, color: isDraft ? Colors.orangeAccent : cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(assignment.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              PopupMenuButton<String>(
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'open', child: Text('Открыть')),
                  PopupMenuItem(value: 'edit', child: Text('Редактировать')),
                  PopupMenuItem(value: 'delete', child: Text('Удалить')),
                ],
                onSelected: (v) {
                  if (v == 'open') onOpen();
                  if (v == 'edit') onEdit?.call();
                  if (v == 'delete') onDelete?.call();
                },
              ),
            ],
          ),
          if (assignment.due != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('до ${assignment.due}', style: Theme.of(context).textTheme.bodySmall),
            ),
          if (assignment.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(assignment.description, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(onPressed: onOpen, child: const Text('Открыть')),
              const Spacer(),
              if (isDraft && !canPublish)
                OutlinedButton.icon(onPressed: onVote, icon: const Icon(Icons.how_to_vote_outlined, size: 18), label: const Text('За')),
              if (canPublish)
                FilledButton.icon(onPressed: onPublish, icon: const Icon(Icons.publish_outlined, size: 18), label: const Text('Опубликовать')),
              if (isDraft) ...[
                const SizedBox(width: 8),
                Chip(label: Text('${assignment.votes}/3'), visualDensity: VisualDensity.compact),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
