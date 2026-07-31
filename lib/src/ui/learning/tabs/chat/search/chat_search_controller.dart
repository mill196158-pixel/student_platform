import 'package:flutter/material.dart';
import '../../../models/message.dart';

class ChatSearchController extends ChangeNotifier {
  final TextEditingController field = TextEditingController();
  final ValueNotifier<int> total = ValueNotifier(0);
  final ValueNotifier<int> index = ValueNotifier(0);

  String currentTargetId = '';
  List<String> matches = [];
  String _lastQuery = '';
  bool _isActive = false;

  bool get isActive => _isActive;
  bool get isSearching => _isActive && field.text.trim().isNotEmpty;

  void setActive(bool active) {
    _isActive = active;
    if (!active) {
      clear();
    }
    notifyListeners();
  }

  void recompute(List<Message> list, bool Function(Message, String) isMatch) {
    final q = field.text.trim().toLowerCase();
    matches = q.isEmpty
        ? []
        : list.where((m) => isMatch(m, q)).map((m) => m.id).toList();

    // Новее сверху, как в исходнике (сортировка по времени DESC)
    matches.sort((a, b) => list
        .firstWhere((m) => m.id == b)
        .at
        .compareTo(list.firstWhere((m) => m.id == a).at));

    if (_lastQuery != q) {
      index.value = matches.isEmpty ? 0 : 1;
      _lastQuery = q;
    } else {
      // Держим индекс в пределах (после обновления ленты)
      if (matches.isEmpty) {
        index.value = 0;
      } else if (index.value == 0) {
        index.value = 1;
      } else if (index.value > matches.length) {
        index.value = matches.length;
      }
    }

    total.value = matches.length;
    currentTargetId = matches.isEmpty ? '' : matches[index.value - 1];
    notifyListeners();
  }

  void next() {
    if (matches.isEmpty) return;
    index.value = (index.value % matches.length) + 1;
    currentTargetId = matches[index.value - 1];
    notifyListeners();
  }

  void prev() {
    if (matches.isEmpty) return;
    index.value = (index.value - 2 + matches.length) % matches.length + 1;
    currentTargetId = matches[index.value - 1];
    notifyListeners();
  }

  void clear() {
    field.clear();
    matches.clear();
    total.value = 0;
    index.value = 0;
    currentTargetId = '';
    notifyListeners();
  }

  @override
  void dispose() {
    field.dispose();
    total.dispose();
    index.dispose();
    super.dispose();
  }
}
