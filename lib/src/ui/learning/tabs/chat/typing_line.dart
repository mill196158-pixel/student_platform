import 'package:flutter/material.dart';

class TypingLine extends StatelessWidget {
  final List<String> names;
  const TypingLine({super.key, required this.names});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final who = names.join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          Icon(Icons.more_horiz, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$who печатает…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
