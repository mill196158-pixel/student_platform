/// Chat-scoped group actions (topic selection, collections, deadlines).
class ChatTopicSelection {
  const ChatTopicSelection({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.allowChange,
    required this.showResultsToAll,
    this.deadlineAt,
    this.completionDeadlineAt,
    this.sourceFileId,
    this.cardMessageId,
    this.freeSlots = 0,
    this.takenSlots = 0,
    this.totalCapacity = 0,
  });

  final String id;
  final String title;
  final String description;
  final String status;
  final bool allowChange;
  final bool showResultsToAll;
  final DateTime? deadlineAt;
  final DateTime? completionDeadlineAt;
  final String? sourceFileId;
  final String? cardMessageId;
  final int freeSlots;
  final int takenSlots;
  final int totalCapacity;

  bool get isOpen => status == 'open';

  factory ChatTopicSelection.fromJson(Map<String, dynamic> json) {
    final deadline = DateTime.tryParse(json['deadline_at']?.toString() ?? '');
    final completion =
        DateTime.tryParse(json['completion_deadline_at']?.toString() ?? '');
    return ChatTopicSelection(
      id: json['id'].toString(),
      title: (json['title'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      status: (json['status'] ?? 'open').toString(),
      allowChange: json['allow_change'] != false,
      showResultsToAll: json['show_results_to_all'] != false,
      // Canonical UI deadline: prefer deadline_at, fall back to legacy completion.
      deadlineAt: deadline ?? completion,
      completionDeadlineAt: completion,
      sourceFileId: _nullableId(json['source_file_id']),
      cardMessageId: _nullableId(json['card_message_id']),
      freeSlots: _asInt(json['free_slots']),
      takenSlots: _asInt(json['taken_slots']),
      totalCapacity: _asInt(json['total_capacity']),
    );
  }

  static String? _nullableId(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class ChatTopicOption {
  const ChatTopicOption({
    required this.id,
    required this.selectionId,
    required this.title,
    required this.capacity,
    required this.taken,
    required this.sortOrder,
    this.myPick = false,
    this.pickerNames = const [],
  });

  final String id;
  final String selectionId;
  final String title;
  final int capacity;
  final int taken;
  final int sortOrder;
  final bool myPick;
  final List<String> pickerNames;

  int get freeSlots => (capacity - taken).clamp(0, capacity);
  bool get isFull => freeSlots <= 0;

  factory ChatTopicOption.fromJson(Map<String, dynamic> json) {
    final namesRaw = json['picker_names'];
    final names = <String>[];
    if (namesRaw is List) {
      for (final item in namesRaw) {
        final text = item?.toString().trim() ?? '';
        if (text.isNotEmpty) names.add(text);
      }
    }
    return ChatTopicOption(
      id: json['id'].toString(),
      selectionId: json['selection_id'].toString(),
      title: (json['title'] ?? '').toString(),
      capacity: int.tryParse(json['capacity']?.toString() ?? '') ?? 0,
      taken: int.tryParse(json['taken']?.toString() ?? '0') ?? 0,
      sortOrder: int.tryParse(json['sort_order']?.toString() ?? '0') ?? 0,
      myPick: json['my_pick'] == true,
      pickerNames: names,
    );
  }
}

class GroupActionDeadline {
  const GroupActionDeadline({
    required this.eventType,
    required this.entityId,
    required this.title,
    required this.occursAt,
    this.chatId,
    this.teamId,
    this.groupId,
    this.cardMessageId,
    this.teamName,
    this.status,
    this.myPickText,
  });

  final String eventType;
  final String entityId;
  final String title;
  final DateTime occursAt;
  final String? chatId;
  final String? teamId;
  final String? groupId;
  final String? cardMessageId;
  final String? teamName;
  final String? status;
  final String? myPickText;

  bool get isTopic => eventType == 'topic_deadline';
  bool get isCollection => eventType == 'collection_deadline';

  factory GroupActionDeadline.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    Map<String, dynamic>? payloadMap;
    if (payload is Map) {
      payloadMap = Map<String, dynamic>.from(payload);
    }
    return GroupActionDeadline(
      eventType: (json['event_type'] ?? '').toString(),
      entityId: (json['entity_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      occursAt: DateTime.tryParse(json['occurs_at']?.toString() ?? '') ??
          DateTime.now(),
      chatId: _nullableId(json['chat_id']),
      teamId: _nullableId(json['team_id']),
      groupId: _nullableId(json['group_id']),
      cardMessageId: _nullableId(
        json['card_message_id'] ??
            payloadMap?['card_message_id'] ??
            payloadMap?['message_id'],
      ),
      teamName: _nullableId(json['team_name'] ?? payloadMap?['team_name']),
      status: _nullableId(json['status'] ?? payloadMap?['status']),
      myPickText:
          _nullableId(json['my_pick_text'] ?? payloadMap?['my_pick_text']),
    );
  }

  static String? _nullableId(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

/// Draft topic option before publish.
class TopicOptionDraft {
  const TopicOptionDraft({
    required this.title,
    this.capacity = 1,
    this.sortOrder = 0,
  });

  final String title;
  final int capacity;
  final int sortOrder;

  Map<String, dynamic> toJson() => {
        'title': title,
        'capacity': capacity,
        'sort_order': sortOrder,
      };

  TopicOptionDraft copyWith({
    String? title,
    int? capacity,
    int? sortOrder,
  }) {
    return TopicOptionDraft(
      title: title ?? this.title,
      capacity: capacity ?? this.capacity,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}
