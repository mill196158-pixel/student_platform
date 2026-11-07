import 'package:flutter/material.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

/// A saved copy is read-only; opening it never fetches or mutates the server.
class OfflineAssignmentBubble extends StatelessWidget {
  const OfflineAssignmentBubble({super.key, required this.message,
      required this.assignment, required this.capabilities, required this.permit});
  final Message message;
  final Assignment? assignment;
  final SessionCapabilities capabilities;
  final CapabilityPermit permit;

  bool get _current => capabilities.mode == SessionCapabilityMode.cacheOnly &&
      capabilities.permits(permit, SessionCapability.cachedRead);

  @override
  Widget build(BuildContext context) {
    final a = assignment;
    if (!_current) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    if (a == null) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 18),
          child: Text('Задание ещё не сохранено на устройстве',
              style: TextStyle(color: colors.onSurfaceVariant)));
    }
    return Align(alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 18),
        padding: const EdgeInsets.all(14),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(color: colors.primary.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.primary.withValues(alpha: .35))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, children: [
          if (message.authorName.trim().isNotEmpty)
            Text('опубликовал: ${message.authorName}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant)),
          Text(a.title, style: Theme.of(context).textTheme.titleSmall),
          if ((a.due ?? '').trim().isNotEmpty)
            Text('до ${a.due}', style: Theme.of(context).textTheme.labelSmall),
          if (a.description.trim().isNotEmpty) ...[
            const SizedBox(height: 6), Text(a.description, maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 6),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            Text(a.published ? 'Опубликовано' : 'Черновик',
                style: TextStyle(color: colors.primary)),
            TextButton.icon(onPressed: () {
              if (!_current) return;
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
                _OfflineAssignmentDetails(assignment: a, capabilities: capabilities, permit: permit)));
            }, icon: const Icon(Icons.open_in_new, size: 17), label: const Text('Открыть')),
          ]),
        ]),
      ));
  }
}

class _OfflineAssignmentDetails extends StatelessWidget {
  const _OfflineAssignmentDetails({required this.assignment,
      required this.capabilities, required this.permit});
  final Assignment assignment;
  final SessionCapabilities capabilities;
  final CapabilityPermit permit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: capabilities, builder: (context, _) {
      final valid = capabilities.mode == SessionCapabilityMode.cacheOnly &&
          capabilities.permits(permit, SessionCapability.cachedRead);
      if (!valid) return const Scaffold(body: Center(child: Text('Сохранённое задание недоступно.')));
      return Scaffold(appBar: AppBar(title: const Text('Задание')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(assignment.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(assignment.published ? 'Опубликовано · сохранённая копия' : 'Черновик · сохранённая копия'),
          if ((assignment.due ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12), Text('Срок: ${assignment.due}'),
          ],
          if (assignment.description.trim().isNotEmpty) ...[
            const SizedBox(height: 20), Text(assignment.description),
          ],
          if (assignment.attachments.isNotEmpty || (assignment.link ?? '').isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('Ссылки и файлы могут быть недоступны без сети.'),
          ],
        ]));
    });
}
