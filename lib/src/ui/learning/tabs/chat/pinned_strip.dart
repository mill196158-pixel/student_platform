import 'package:flutter/material.dart';

enum PinType { text, message, assignment }

class PinEntry {
  final String id;
  final PinType type;
  final String title;
  final String? subtitle;
  final String? refId;
  final bool isAuto;

  const PinEntry._({
    required this.id,
    required this.type,
    required this.title,
    this.subtitle,
    this.refId,
    this.isAuto = false,
  });

  factory PinEntry.text({required String id, required String title}) =>
      PinEntry._(id: id, type: PinType.text, title: title);

  factory PinEntry.message({required String id, required String title, String? subtitle, required String messageId}) =>
      PinEntry._(id: id, type: PinType.message, title: title, subtitle: subtitle, refId: messageId);

  factory PinEntry.assignment({required String id, required String title, String? subtitle, required String assignmentId, bool isAuto = false}) =>
      PinEntry._(id: id, type: PinType.assignment, title: title, subtitle: subtitle, refId: assignmentId, isAuto: isAuto);

  IconData get icon => switch (type) {
        PinType.text => Icons.push_pin_outlined,
        PinType.message => Icons.chat_bubble_outline,
        PinType.assignment => Icons.assignment_outlined,
      };
}

class PinnedStrip extends StatelessWidget {
  final List<PinEntry> entries;
  final ValueChanged<PinEntry> onOpen;
  final ValueChanged<PinEntry> onUnpin;
  final VoidCallback onMore;

  const PinnedStrip({
    super.key,
    required this.entries,
    required this.onOpen,
    required this.onUnpin,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withOpacity(.6), width: .5),
      ),
      child: Row(
        children: [
          Icon(Icons.push_pin, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => _ChipItem(
                  entry: entries[i],
                  onTap: () => onOpen(entries[i]),
                  onClose: () => onUnpin(entries[i]),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onMore,
            borderRadius: BorderRadius.circular(20),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.more_vert, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipItem extends StatelessWidget {
  final PinEntry entry;
  final VoidCallback onTap;
  final VoidCallback onClose;
  const _ChipItem({required this.entry, required this.onTap, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primary.withOpacity(.10),
      shape: const StadiumBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(entry.icon, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  entry.subtitle != null ? '${entry.title}  •  ${entry.subtitle}' : entry.title,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!entry.isAuto) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onClose,
                  child: const Icon(Icons.close, size: 16),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
