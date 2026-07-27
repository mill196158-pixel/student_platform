/// Snapshot of the caller's permanent academic group space.
class GroupSpaceSnapshot {
  const GroupSpaceSnapshot({
    required this.groupId,
    required this.teamId,
    required this.chatId,
    required this.title,
    required this.isOrganizer,
  });

  final String? groupId;
  final String? teamId;
  final String? chatId;
  final String? title;
  final bool isOrganizer;

  bool get exists =>
      groupId != null &&
      groupId!.isNotEmpty &&
      teamId != null &&
      teamId!.isNotEmpty &&
      chatId != null &&
      chatId!.isNotEmpty;

  factory GroupSpaceSnapshot.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const GroupSpaceSnapshot(
        groupId: null,
        teamId: null,
        chatId: null,
        title: null,
        isOrganizer: false,
      );
    }
    String? asId(dynamic value) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }

    return GroupSpaceSnapshot(
      groupId: asId(json['group_id']),
      teamId: asId(json['team_id']),
      chatId: asId(json['chat_id']),
      title: asId(json['title']) ?? 'Общий чат группы',
      isOrganizer: json['is_organizer'] == true,
    );
  }
}

class GroupCollection {
  const GroupCollection({
    required this.id,
    required this.title,
    required this.description,
    required this.purpose,
    required this.status,
    this.deadlineAt,
    this.amountOptional,
  });

  final String id;
  final String title;
  final String description;
  final String purpose;
  final String status;
  final DateTime? deadlineAt;
  final double? amountOptional;

  bool get isOpen => status == 'open';

  factory GroupCollection.fromJson(Map<String, dynamic> json) {
    return GroupCollection(
      id: json['id'].toString(),
      title: (json['title'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      purpose: (json['purpose'] ?? '').toString(),
      status: (json['status'] ?? 'open').toString(),
      deadlineAt: DateTime.tryParse(json['deadline_at']?.toString() ?? ''),
      amountOptional: json['amount_optional'] == null
          ? null
          : double.tryParse(json['amount_optional'].toString()),
    );
  }
}

class GroupTopicSelection {
  const GroupTopicSelection({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.allowChange,
    this.deadlineAt,
  });

  final String id;
  final String title;
  final String description;
  final String status;
  final bool allowChange;
  final DateTime? deadlineAt;

  bool get isOpen => status == 'open';

  factory GroupTopicSelection.fromJson(Map<String, dynamic> json) {
    return GroupTopicSelection(
      id: json['id'].toString(),
      title: (json['title'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      status: (json['status'] ?? 'open').toString(),
      allowChange: json['allow_change'] != false,
      deadlineAt: DateTime.tryParse(json['deadline_at']?.toString() ?? ''),
    );
  }
}

class GroupTopicOption {
  const GroupTopicOption({
    required this.id,
    required this.selectionId,
    required this.title,
    required this.capacity,
    required this.taken,
    required this.sortOrder,
  });

  final String id;
  final String selectionId;
  final String title;
  final int capacity;
  final int taken;
  final int sortOrder;

  int get freeSlots => (capacity - taken).clamp(0, capacity);
  bool get isFull => freeSlots <= 0;

  factory GroupTopicOption.fromJson(Map<String, dynamic> json) {
    return GroupTopicOption(
      id: json['id'].toString(),
      selectionId: json['selection_id'].toString(),
      title: (json['title'] ?? '').toString(),
      capacity: int.tryParse(json['capacity']?.toString() ?? '') ?? 0,
      taken: int.tryParse(json['taken']?.toString() ?? '0') ?? 0,
      sortOrder: int.tryParse(json['sort_order']?.toString() ?? '0') ?? 0,
    );
  }
}
