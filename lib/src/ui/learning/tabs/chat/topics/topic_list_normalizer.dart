import 'topic_list_models.dart';

/// Strips common list markers from the start of a line without touching
/// numbers that belong to the title (e.g. "Тема 12: анализ").
String stripTopicListMarker(String line) {
  var text = line.trim();
  if (text.isEmpty) return text;

  // Bullets and dashes.
  text = text.replaceFirst(RegExp(r'^[•·▪▫◦\-–—*]\s*'), '');

  // Numeric / letter enumerators: "1.", "1)", "1:", "а)", "A."
  text = text.replaceFirst(
    RegExp(
      r'^(?:\d{1,3}|[a-zA-Zа-яА-ЯёЁ])[\.\):]\s+',
      caseSensitive: false,
    ),
    '',
  );

  // Roman numerals at start: "IV.", "iv)"
  text = text.replaceFirst(
    RegExp(r'^(?:[IVXLCDMivxlcdm]+)[\.\):]\s+'),
    '',
  );

  return text.trim();
}

/// Returns true when [line] looks like the start of a new list item.
bool looksLikeTopicListItem(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return false;
  return RegExp(
    r'^(?:'
    r'[•·▪▫◦\-–—*]'
    r'|(?:\d{1,3}|[a-zA-Zа-яА-ЯёЁ])[\.\):]'
    r'|(?:[IVXLCDMivxlcdm]+)[\.\):]'
    r')\s*\S',
  ).hasMatch(trimmed);
}

/// Returns true when [line] looks like a soft-wrapped continuation of [previous].
bool looksLikeWrappedContinuation(String line, String previous) {
  if (looksLikeTopicListItem(line)) return false;

  final trimmed = line.trimLeft();
  if (trimmed.isEmpty) return false;
  if (!_startsWithLowercase(trimmed)) return false;

  final prev = previous.trim();
  if (prev.isEmpty) return false;
  if (RegExp(r'[.!?:;]$').hasMatch(prev)) return false;

  return looksLikeTopicListItem(prev) || prev.length > 35;
}

bool _startsWithLowercase(String text) {
  final first = text.runes.first;
  return (first >= 0x61 && first <= 0x7A) ||
      (first >= 0x430 && first <= 0x44F) ||
      first == 0x451;
}

/// Merges soft-wrapped continuation lines into a single topic line.
List<String> mergeWrappedTopicLines(List<String> lines) {
  if (lines.isEmpty) return const [];

  final merged = <String>[];
  final buffer = StringBuffer();

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (buffer.isEmpty) {
      buffer.write(line);
      continue;
    }

    if (looksLikeWrappedContinuation(line, buffer.toString())) {
      buffer.write(' $line');
    } else {
      merged.add(buffer.toString());
      buffer
        ..clear()
        ..write(line);
    }
  }

  if (buffer.isNotEmpty) {
    merged.add(buffer.toString());
  }
  return merged;
}

/// Case-insensitive dedupe while preserving first occurrence order.
List<String> dedupeTopicLines(List<String> lines) {
  final seen = <String>{};
  final result = <String>[];
  for (final line in lines) {
    final key = line.trim().toLowerCase();
    if (key.isEmpty || seen.contains(key)) continue;
    seen.add(key);
    result.add(line.trim());
  }
  return result;
}

/// Normalizes raw text lines into review-ready [TopicDraft]s.
List<TopicDraft> normalizeTopicLines(
  List<String> lines, {
  int defaultCapacity = 1,
}) {
  final nonEmpty = lines.map((l) => l.trim()).where((l) => l.isNotEmpty);
  final merged = mergeWrappedTopicLines(nonEmpty.toList());
  final stripped = merged.map(stripTopicListMarker).where((l) => l.isNotEmpty);
  final unique = dedupeTopicLines(stripped.toList());

  final limited = unique.take(topicListMaxTopics).toList();
  return [
    for (final title in limited)
      TopicDraft(title: title, capacity: defaultCapacity),
  ];
}

/// Returns a warning when input exceeds [topicListMaxTopics].
String? topicLimitWarning(int rawCount) {
  if (rawCount <= topicListMaxTopics) return null;
  return 'Список обрезан до $topicListMaxTopics тем '
      '(было $rawCount).';
}
