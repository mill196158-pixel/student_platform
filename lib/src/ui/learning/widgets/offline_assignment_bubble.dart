import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/assignment_bubble.dart';
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
    return AssignmentBubble(
      message: message,
      isDraft: message.type == MessageType.assignmentDraft,
      time: DateFormat('HH:mm').format(message.at.toLocal()),
      localAssignment: a,
      onOpen: () {
        if (!_current) return;
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
          _OfflineAssignmentDetails(assignment: a, capabilities: capabilities, permit: permit)));
      },
    );
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
