// lib/src/ui/learning/tabs/chat/assignment_bubble.dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../state/team_cubit.dart';
import '../../models/message.dart';
import '../../models/assignment.dart';
import '../../assignment_details_screen.dart';

class AssignmentBubble extends StatelessWidget {
  final Message message;
  final bool isDraft; // true -> черновик, false -> опубликовано
  final String time;
  final VoidCallback? onOpen;
  final VoidCallback? onPublish; // для старосты
  final VoidCallback? onVote;    // обычные
  final VoidCallback? onLongPress;
  final VoidCallback? onPin;

  const AssignmentBubble({
    super.key,
    required this.message,
    required this.isDraft,
    required this.time,
    this.onOpen,
    this.onPublish,
    this.onVote,
    this.onLongPress,
    this.onPin,
  });

  @override
  Widget build(BuildContext context) {
    final st = context.watch<TeamCubit>().state;

    // Рендерим карточку ТОЛЬКО если есть валидный assignmentId и нашли задание.
    final String? aid = (message.assignmentId ?? '').isNotEmpty
        ? message.assignmentId
        : null;
    if (aid == null) return const SizedBox.shrink();

    Assignment? a;
    final byId = st.assignments.where((x) => x.id == aid);
    if (byId.isNotEmpty) a = byId.first;
    if (a == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    // Сдержанные цвета без «жёлто-чёрной ленты»
    final bg     = isDraft ? cs.secondaryContainer.withOpacity(.25)
                           : cs.primary.withOpacity(.10);
    final border = isDraft ? cs.secondaryContainer.withOpacity(.9) : cs.primary;
    final textColor = Theme.of(context).textTheme.bodyLarge?.color ?? Colors.black;
    final subColor  = Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(.65) ?? Colors.black54;

    // Автор карточки — из самого сообщения
    final authorDisplay = () {
      final n = (message.authorName ?? '').trim();
      if (n.isNotEmpty) return n;
      final l = (message.authorLogin ?? '').trim();
      return l.isNotEmpty ? l : 'участник';
    }();

    final headerText = isDraft ? 'Черновик задания' : 'Задание опубликовано';
    final whoDidText = isDraft ? 'предложил: $authorDisplay'
                               : 'опубликовал: $authorDisplay';

    // Показываем прогресс голосов в черновике (если модель его отдаёт)
    final votesText = isDraft ? ' (${a.votes}/2)' : '';

    final canPublish = isDraft && st.isStarosta;
    final canVote    = isDraft && !st.isStarosta && !a.published;

    // ДЕФОЛТНЫЕ действия, если снаружи не передали колбэки
    void _defaultOpen() {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AssignmentDetailsScreen(assignmentId: a!.id),
        ),
      );
    }

    Future<void> _defaultPublish() async {
      await context.read<TeamCubit>().publishPendingManually();
    }

    Future<void> _defaultVote() async {
      await context.read<TeamCubit>().voteForPending();
      // тут можно всплывашку показать — на твой вкус
      // ScaffoldMessenger.of(context).showSnackBar(
      //   const SnackBar(content: Text('Голос засчитан')),
      // );
    }

    return GestureDetector(
      onLongPress: onLongPress,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // левая пустая зона для выравнивания системного сообщения
          const SizedBox(width: 36),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: bg,
                border: Border.all(color: border, width: 1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ШАПКА
                  Row(
                    children: [
                      Icon(
                        isDraft ? Icons.pending_outlined : Icons.assignment_outlined,
                        color: isDraft ? cs.secondary : cs.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          headerText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: textColor.withOpacity(.8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(time, style: const TextStyle(fontSize: 11, color: Colors.black54)),
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

                  const SizedBox(height: 6),

                  // КОНТЕНТ
                  Text(
                    a.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  if ((a.due ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('до ${a.due!}', style: TextStyle(fontSize: 12, color: subColor)),
                    ),
                  if (a.description.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      a.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: textColor.withOpacity(.9)),
                    ),
                  ],

                  const SizedBox(height: 8),

                  // КНОПКИ
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: onOpen ?? _defaultOpen,
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('Открыть'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                      ),
                      if (canPublish)
                        FilledButton.icon(
                          onPressed: onPublish ?? _defaultPublish,
                          icon: const Icon(Icons.publish, size: 18),
                          label: const Text('Опубликовать'),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                        ),
                      if (canVote)
                        OutlinedButton.icon(
                          onPressed: onVote ?? _defaultVote,
                          icon: const Icon(Icons.how_to_vote_outlined, size: 18),
                          label: Text('Голосовать «за»$votesText'),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                        ),
                      if (!isDraft)
                        Chip(
                          label: const Text('Опубликовано'),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
