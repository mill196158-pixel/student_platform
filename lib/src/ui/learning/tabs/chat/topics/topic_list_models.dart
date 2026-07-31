/// Local topic-list models for Stage 13.9 review-before-publish flow.
library;

import '../models/chat_group_actions.dart';

/// Maximum number of topics accepted from a single import.
const int topicListMaxTopics = 200;

/// Alias for [topicListMaxTopics].
const int maxTopics = topicListMaxTopics;

/// Maximum file size for local topic-list parsing (8 MB).
const int topicListMaxFileBytes = 8 * 1024 * 1024;

/// Maximum PDF pages to OCR in one import.
const int topicListMaxOcrPages = 10;

/// Render DPI for scanned PDF page rasterization before OCR.
const double topicListOcrRenderDpi = 150;

/// Alias for [topicListMaxFileBytes].
const int maxFileBytes = topicListMaxFileBytes;

/// A topic row awaiting user review before publish.
class TopicDraft {
  const TopicDraft({
    required this.title,
    this.capacity = 1,
  });

  final String title;
  final int capacity;

  TopicDraft copyWith({String? title, int? capacity}) {
    return TopicDraft(
      title: title ?? this.title,
      capacity: capacity ?? this.capacity,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopicDraft && title == other.title && capacity == other.capacity;

  @override
  int get hashCode => Object.hash(title, capacity);
}

/// Source kind for a parsed topic list.
enum TopicParseSourceKind {
  excel,
  word,
  pdf,
  image,
  manual,
}

/// Result of local topic-list parsing — never auto-published.
class TopicParseResult {
  const TopicParseResult({
    required this.sourceName,
    required this.kind,
    required this.topics,
    this.suggestedExcelColumn,
    this.excelHeaders,
    this.excelSheetNames,
    this.selectedExcelSheet,
    this.warnings = const [],
    this.error,
    this.needsOcr = false,
  });

  final String sourceName;
  final TopicParseSourceKind kind;
  final List<TopicDraft> topics;
  final int? suggestedExcelColumn;
  final List<String>? excelHeaders;
  final List<String>? excelSheetNames;
  final String? selectedExcelSheet;
  final List<String> warnings;
  final String? error;
  final bool needsOcr;

  bool get hasError => error != null && error!.isNotEmpty;
  bool get isSuccess => !hasError && topics.isNotEmpty;

  /// Maps parsed drafts to publish-ready option rows.
  List<TopicOptionDraft> toOptionDrafts() {
    return topicDraftsToOptionDrafts(topics);
  }

  TopicParseResult copyWith({
    String? sourceName,
    TopicParseSourceKind? kind,
    List<TopicDraft>? topics,
    int? suggestedExcelColumn,
    List<String>? excelHeaders,
    List<String>? excelSheetNames,
    String? selectedExcelSheet,
    List<String>? warnings,
    String? error,
    bool? needsOcr,
  }) {
    return TopicParseResult(
      sourceName: sourceName ?? this.sourceName,
      kind: kind ?? this.kind,
      topics: topics ?? this.topics,
      suggestedExcelColumn: suggestedExcelColumn ?? this.suggestedExcelColumn,
      excelHeaders: excelHeaders ?? this.excelHeaders,
      excelSheetNames: excelSheetNames ?? this.excelSheetNames,
      selectedExcelSheet: selectedExcelSheet ?? this.selectedExcelSheet,
      warnings: warnings ?? this.warnings,
      error: error ?? this.error,
      needsOcr: needsOcr ?? this.needsOcr,
    );
  }
}

/// Maps [TopicDraft] rows to [TopicOptionDraft] for publish RPC.
List<TopicOptionDraft> topicDraftsToOptionDrafts(List<TopicDraft> drafts) {
  return [
    for (var i = 0; i < drafts.length; i++)
      TopicOptionDraft(
        title: drafts[i].title.trim(),
        capacity: drafts[i].capacity,
        sortOrder: i + 1,
      ),
  ];
}

/// Maps controller publish JSON to [TopicOptionDraft] list.
List<TopicOptionDraft> publishJsonToOptionDrafts(
  List<Map<String, dynamic>> json,
) {
  return [
    for (var i = 0; i < json.length; i++)
      TopicOptionDraft(
        title: (json[i]['title'] ?? '').toString().trim(),
        capacity: int.tryParse(json[i]['capacity']?.toString() ?? '') ?? 1,
        sortOrder: i + 1,
      ),
  ];
}
