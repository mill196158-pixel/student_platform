import 'package:flutter/material.dart';
import '../pinned_strip.dart';
import 'pin_controller.dart';

class PinnedStripContainer extends StatelessWidget {
  final List<PinEntry> pins;
  final PinController controller;
  final void Function(PinEntry p) onOpen;
  final Future<void> Function(PinEntry p)? onUnpin; // only for message pins

  const PinnedStripContainer({
    super.key,
    required this.pins,
    required this.controller,
    required this.onOpen,
    this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    if (controller.hidden || pins.isEmpty) return const SizedBox.shrink();

    return PinnedStrip(
      entries: pins,
      onOpen: (p) => onOpen(p),
      onUnpin: (p) async {
        // Только серверные закрепы (сообщения) открепляются через колбэк
        if (p.type == PinType.message && onUnpin != null) {
          await onUnpin!(p);
        } else {
          // Локальные: текстовые — просто удалить из локального контроллера
          controller.removePin(p.id);
        }
      },
      onMore: () => _showMoreSheet(context),
    );
  }

  Future<void> _showMoreSheet(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Скрыть ленту'),
              onTap: () {
                Navigator.pop(context);
                controller.setHidden(true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Автозакрепление заданий'),
              trailing: Switch(
                value: controller.autoAssignment,
                onChanged: (v) {
                  controller.setAutoAssignment(v);
                  Navigator.pop(context);
                },
              ),
            ),
            if (pins.isNotEmpty) const Divider(height: 12),
            ...pins.map((p) => ListTile(
                  leading: Icon(p.icon),
                  title: Text(p.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: p.subtitle != null ? Text(p.subtitle!) : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      if (p.type == PinType.message && onUnpin != null) {
                        onUnpin!(p);
                      } else {
                        controller.removePin(p.id);
                      }
                    },
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    onOpen(p);
                  },
                )),
          ],
        ),
      ),
    );
  }
}
