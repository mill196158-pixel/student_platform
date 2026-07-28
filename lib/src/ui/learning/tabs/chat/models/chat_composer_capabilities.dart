/// Server-backed composer `+` capabilities for a chat (Stage 13.10).
class ChatComposerCapabilities {
  const ChatComposerCapabilities({
    required this.chatType,
    required this.teamKind,
    required this.isActiveMember,
    required this.isActiveSubjectTeam,
    required this.showProposeAssignment,
    required this.showTopicSelection,
    required this.showCollection,
    required this.canProposeAssignment,
    required this.canManageAssignments,
    required this.canCreateTopicSelection,
    required this.canCreateCollection,
    this.reasons = const {},
    this.loading = false,
    this.fromCache = false,
  });

  final String chatType;
  final String teamKind;
  final bool isActiveMember;
  final bool isActiveSubjectTeam;

  /// Structural visibility — show in menu for this chat kind.
  final bool showProposeAssignment;
  final bool showTopicSelection;
  final bool showCollection;

  /// Authorization — whether the action can be executed now.
  final bool canProposeAssignment;
  final bool canManageAssignments;
  final bool canCreateTopicSelection;
  final bool canCreateCollection;

  final Map<String, String?> reasons;
  final bool loading;
  final bool fromCache;

  bool get isDm => chatType == 'dm' || teamKind == 'dm';
  bool get isGroupSpace => teamKind == 'group_space';
  bool get isSubject => teamKind == 'subject';

  String? reasonFor(String key) => reasons[key];

  String reasonLabel(String key) {
    switch (reasonFor(key)) {
      case 'dm_not_allowed':
        return 'Недоступно в личных сообщениях';
      case 'group_space_not_allowed':
        return 'Только в предметном чате';
      case 'subject_not_allowed':
        return 'Только в чате группы';
      case 'subject_inactive':
        return 'Предметный чат неактивен';
      case 'not_member':
        return 'Нет доступа к чату';
      case 'not_organizer':
        return 'Доступно организатору';
      case 'forbidden':
        return 'Недостаточно прав';
      case 'permissions_unavailable':
        return 'Не удалось проверить права. Попробуйте ещё раз';
      default:
        return loading ? 'Проверяем права…' : 'Недоступно';
    }
  }

  ChatComposerCapabilities copyWith({
    bool? loading,
    bool? fromCache,
    bool? canProposeAssignment,
    bool? canManageAssignments,
    bool? canCreateTopicSelection,
    bool? canCreateCollection,
  }) {
    return ChatComposerCapabilities(
      chatType: chatType,
      teamKind: teamKind,
      isActiveMember: isActiveMember,
      isActiveSubjectTeam: isActiveSubjectTeam,
      showProposeAssignment: showProposeAssignment,
      showTopicSelection: showTopicSelection,
      showCollection: showCollection,
      canProposeAssignment: canProposeAssignment ?? this.canProposeAssignment,
      canManageAssignments: canManageAssignments ?? this.canManageAssignments,
      canCreateTopicSelection:
          canCreateTopicSelection ?? this.canCreateTopicSelection,
      canCreateCollection: canCreateCollection ?? this.canCreateCollection,
      reasons: reasons,
      loading: loading ?? this.loading,
      fromCache: fromCache ?? this.fromCache,
    );
  }

  /// Local structural matrix while RPC loads / offline (auth disabled).
  factory ChatComposerCapabilities.structuralLoading({
    required String teamKind,
    required bool isDm,
  }) {
    final kind = isDm ? 'dm' : teamKind;
    return ChatComposerCapabilities(
      chatType: isDm ? 'dm' : 'team',
      teamKind: kind,
      isActiveMember: false,
      isActiveSubjectTeam: false,
      showProposeAssignment: !isDm,
      showTopicSelection: kind == 'subject',
      showCollection: kind == 'group_space',
      canProposeAssignment: false,
      canManageAssignments: false,
      canCreateTopicSelection: false,
      canCreateCollection: false,
      reasons: const {
        'propose_assignment': null,
        'topic_selection': null,
        'collection': null,
      },
      loading: true,
    );
  }

  factory ChatComposerCapabilities.fromJson(Map<String, dynamic> json) {
    final reasonsRaw = json['reasons'];
    final reasons = <String, String?>{};
    if (reasonsRaw is Map) {
      reasonsRaw.forEach((key, value) {
        final text = value?.toString().trim();
        reasons[key.toString()] = (text == null || text.isEmpty) ? null : text;
      });
    }
    return ChatComposerCapabilities(
      chatType: (json['chat_type'] ?? 'team').toString(),
      teamKind: (json['team_kind'] ?? 'subject').toString(),
      isActiveMember: json['is_active_member'] == true,
      isActiveSubjectTeam: json['is_active_subject_team'] == true,
      showProposeAssignment: json['show_propose_assignment'] == true,
      showTopicSelection: json['show_topic_selection'] == true,
      showCollection: json['show_collection'] == true,
      canProposeAssignment: json['can_propose_assignment'] == true,
      canManageAssignments: json['can_manage_assignments'] == true,
      canCreateTopicSelection: json['can_create_topic_selection'] == true,
      canCreateCollection: json['can_create_collection'] == true,
      reasons: reasons,
    );
  }

  /// Pure matrix helper for unit tests (no network).
  static bool showTopicForKind({
    required bool isDm,
    required String teamKind,
  }) =>
      !isDm && teamKind == 'subject';

  static bool showCollectionForKind({
    required bool isDm,
    required String teamKind,
  }) =>
      !isDm && teamKind == 'group_space';

  static bool showProposeForKind({
    required bool isDm,
  }) =>
      !isDm;
}
