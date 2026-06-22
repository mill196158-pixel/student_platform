import 'package:flutter/material.dart';
import '../../../models/message.dart';
import '../../../models/assignment.dart';
import '../../../state/team_cubit.dart';
import '../pinned_strip.dart';

class PinController extends ChangeNotifier {
  final List<PinEntry> _pins = [];
  bool hidden = false;
  bool autoAssignment = false;

  List<PinEntry> buildFromState(TeamState st) {
    // Серверные закрепы: по сообщениям isPinned
    final serverPins = <PinEntry>[];
    for (final m in st.chat) {
      if (m.isPinned) {
        final title = m.text.trim().isNotEmpty 
            ? m.text.trim().split('\n').first 
            : (m.attachments?.isNotEmpty == true 
                ? m.attachments!.first.fileName 
                : 'Сообщение');
        final subtitle = '${_time(m.at)} • ${m.authorName.isNotEmpty ? m.authorName : m.authorLogin}';
        serverPins.add(PinEntry.message(
          id: 'msg-${m.id}',
          title: title,
          subtitle: subtitle,
          messageId: m.id,
        ));
      }
    }

    // Локальные закрепы: текст/задания, добавляем поверх, без дубликатов по id
    final merged = <PinEntry>[];
    final seen = <String>{};
    for (final p in serverPins) {
      merged.add(p);
      seen.add(p.id);
    }
    for (final p in _pins) {
      if (!seen.contains(p.id)) {
        merged.add(p);
        seen.add(p.id);
      }
    }
    return merged;
  }

  void setHidden(bool value) {
    hidden = value;
    notifyListeners();
  }

  void setAutoAssignment(bool value) {
    autoAssignment = value;
    notifyListeners();
  }

  void pinText(String text) {
    final title = text.trim();
    if (title.isEmpty) return;
    final entry = PinEntry.text(
      id: 'text-${DateTime.now().millisecondsSinceEpoch}',
      title: title.split('\n').first,
    );
    _pins.add(entry);
    notifyListeners();
  }

  void pinAssignment(Assignment a) {
    // Избегаем дублей ручных закрепов одного и того же задания
    if (_pins.any((p) => p.type == PinType.assignment && p.refId == a.id && !p.isAuto)) {
      return;
    }
    final entry = PinEntry.assignment(
      id: 'assignment-${a.id}',
      title: a.title,
      subtitle: 'Задание • ${_time(a.createdAt)}',
      assignmentId: a.id,
      isAuto: autoAssignment,
    );
    _pins.add(entry);
    notifyListeners();
  }

  void removePin(String id) {
    _pins.removeWhere((p) => p.id == id);
    notifyListeners();
  }

  void clearAll() {
    _pins.clear();
    notifyListeners();
  }

  List<PinEntry> get pins => List.from(_pins);

  String _time(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
