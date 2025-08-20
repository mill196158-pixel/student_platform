import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../state/team_cubit.dart';
import '../../models/assignment.dart';
import '../../assignment_details_screen.dart';

class PinnedAssignmentBar extends StatelessWidget {
  const PinnedAssignmentBar({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<TeamCubit>().state;
    final pending = st.pending;
    final lastPublished = st.published.isNotEmpty ? st.published.last : null;
    final isDraft = pending != null;

    final title = isDraft ? pending!.title : (lastPublished?.title ?? '');
    final due = isDraft ? pending!.due : lastPublished?.due;

    final theme = Theme.of(context);
    final bg = isDraft ? Colors.amber.withOpacity(.15) : theme.colorScheme.primary.withOpacity(.12);
    final border = isDraft ? Colors.orangeAccent : theme.colorScheme.primary;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border.withOpacity(.6), width: .6),
      ),
      child: Row(
        children: [
          Icon(isDraft ? Icons.edit_note_outlined : Icons.push_pin_outlined, color: border),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isDraft ? 'Черновик задания' : 'Закреплено: задание',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  title + (due != null ? ' (до $due)' : ''),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              final id = isDraft ? pending!.id : (lastPublished?.id ?? '');
              if (id.isEmpty) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BlocProvider.value(
                    value: context.read<TeamCubit>(),
                    child: AssignmentDetailsScreen(assignmentId: id),
                  ),
                ),
              );
            },
            child: const Text('Открыть'),
          ),
        ],
      ),
    );
  }
}
