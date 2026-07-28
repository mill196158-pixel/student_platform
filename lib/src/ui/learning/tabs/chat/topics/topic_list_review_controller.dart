import 'topic_list_models.dart';

/// Case-insensitive, trimmed-title duplicate detector shared by the review
/// screen (draft list) and unit tests. Returns the normalized (lowercased)
/// title keys that appear more than once — never the raw titles, so callers
/// can highlight every row whose normalized title is in this set.
Set<String> duplicateTopicTitles(List<TopicDraft> topics) {
  final seen = <String>{};
  final dupes = <String>{};
  for (final topic in topics) {
    final key = topic.title.trim().toLowerCase();
    if (key.isEmpty) continue;
    if (!seen.add(key)) dupes.add(key);
  }
  return dupes;
}

/// Pure state helper for reviewing parsed topics before publish.
class TopicListReviewController {
  TopicListReviewController({List<TopicDraft>? initial})
      : _topics = List<TopicDraft>.from(initial ?? const []);

  List<TopicDraft> _topics;

  List<TopicDraft> get topics => List.unmodifiable(_topics);

  int get length => _topics.length;

  bool get isEmpty => _topics.isEmpty;

  /// Normalized title keys that appear more than once in the current list.
  Set<String> get duplicateKeys => duplicateTopicTitles(_topics);

  /// Count of rows with a blank (whitespace-only) title.
  int get emptyCount => _topics.where((t) => t.title.trim().isEmpty).length;

  /// Replaces current list with parsed topics (after user confirms import).
  void applyParseResult(TopicParseResult result) {
    if (result.hasError) return;
    _topics = List<TopicDraft>.from(result.topics);
  }

  void add({required String title, int capacity = 1}) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    _topics.add(TopicDraft(title: trimmed, capacity: capacity));
    _enforceLimit();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _topics.length) return;
    _topics.removeAt(index);
  }

  void editAt(int index, {String? title, int? capacity}) {
    if (index < 0 || index >= _topics.length) return;
    _topics[index] = _topics[index].copyWith(title: title, capacity: capacity);
  }

  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _topics.length ||
        newIndex < 0 ||
        newIndex >= _topics.length ||
        oldIndex == newIndex) {
      return;
    }
    final item = _topics.removeAt(oldIndex);
    _topics.insert(newIndex, item);
  }

  void mergeAdjacent(int firstIndex) {
    if (firstIndex < 0 || firstIndex >= _topics.length - 1) return;
    final first = _topics[firstIndex];
    final second = _topics[firstIndex + 1];
    _topics[firstIndex] = first.copyWith(
      title: '${first.title.trim()} ${second.title.trim()}'.trim(),
      capacity: first.capacity,
    );
    _topics.removeAt(firstIndex + 1);
  }

  /// Splits a topic at the first newline, em dash separator, or middle space.
  void splitLine(int index) {
    if (index < 0 || index >= _topics.length) return;
    final title = _topics[index].title;
    final newlineIndex = title.indexOf('\n');
    if (newlineIndex > 0 && newlineIndex < title.length - 1) {
      _insertSplit(index, title, newlineIndex);
      return;
    }

    final dashMatch = RegExp(r'\s+[—–-]\s+').firstMatch(title);
    if (dashMatch != null && dashMatch.start > 0) {
      _insertSplit(index, title, dashMatch.start);
      return;
    }

    final spaceIndex = title.lastIndexOf(' ', title.length ~/ 2);
    if (spaceIndex <= 0 || spaceIndex >= title.length - 1) return;
    _insertSplit(index, title, spaceIndex);
  }

  void _insertSplit(int index, String title, int splitAt) {
    final first = title.substring(0, splitAt).trim();
    final second =
        title.substring(splitAt).trim().replaceFirst(RegExp(r'^[—–-]\s*'), '');
    if (first.isEmpty || second.isEmpty) return;

    final original = _topics[index];
    _topics[index] = original.copyWith(title: first);
    _topics.insert(index + 1, original.copyWith(title: second));
    _enforceLimit();
  }

  void setCapacityAt(int index, int capacity) {
    if (index < 0 || index >= _topics.length) return;
    _topics[index] = _topics[index].copyWith(capacity: capacity.clamp(1, 9999));
  }

  /// Drops rows with a blank (whitespace-only) title.
  void removeEmpty() {
    _topics = _topics.where((t) => t.title.trim().isNotEmpty).toList();
  }

  /// Removes rows at the given indices (used by multi-select bulk delete).
  void removeIndices(Iterable<int> indices) {
    final toRemove = indices.toSet();
    _topics = [
      for (var i = 0; i < _topics.length; i++)
        if (!toRemove.contains(i)) _topics[i],
    ];
  }

  /// Inserts [topic] back at [index] (clamped) — used by undo-delete.
  void insertAt(int index, TopicDraft topic) {
    final at = index.clamp(0, _topics.length);
    _topics.insert(at, topic);
  }

  /// Case-insensitive dedupe preserving first occurrence.
  void dedupe() {
    final seen = <String>{};
    _topics = _topics.where((topic) {
      final key = topic.title.trim().toLowerCase();
      if (key.isEmpty || seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();
  }

  /// JSON payload for publish RPC — never called automatically by parser.
  List<Map<String, dynamic>> toPublishJson() {
    return [
      for (var i = 0; i < _topics.length; i++)
        {
          'title': _topics[i].title.trim(),
          'capacity': _topics[i].capacity,
          'sort_order': i,
        },
    ];
  }

  void _enforceLimit() {
    if (_topics.length <= topicListMaxTopics) return;
    _topics = _topics.take(topicListMaxTopics).toList();
  }
}
