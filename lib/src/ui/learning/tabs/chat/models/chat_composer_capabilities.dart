/// Server-backed composer `+` capabilities for a chat (Stage 13.11).
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
    required this.canCreateAssignment,
    required this.canCreateTopicSelection,
    required this.canCreateCollection,
    required this.canEditOwnBeforeActivity,
    required this.canModerateTopicSelection,
    required this.canModerateCollection,
    required this.canManageCollectionReceipts,
    required this.canDeleteGroupAction,
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
  final bool canCreateAssignment;
  final bool canCreateTopicSelection;
  final bool canCreateCollection;
  final bool canEditOwnBeforeActivity;
  final bool canModerateTopicSelection;
  final bool canModerateCollection;
  final bool canManageCollectionReceipts;
  final bool canDeleteGroupAction;

  final Map<String, String?> reasons;
  final bool loading;
  final bool fromCache;

  bool get isDm => chatType == 'dm' || teamKind == 'dm';
  bool get isGroupSpace => teamKind == 'group_space';
  bool get isSubject => teamKind == 'subject';

  String? reasonFor(String key) => reasons[key];

  /// User-facing reason only — never "Проверяем права" / developer labels.
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
        // Legacy reason code — creation is membership-based; keep soft label.
        return 'Недоступно';
      case 'forbidden':
        return 'Недостаточно прав';
      case 'permissions_unavailable':
        return 'Недоступно';
      default:
        return 'Недоступно';
    }
  }

  ChatComposerCapabilities copyWith({
    bool? loading,
    bool? fromCache,
    bool? canProposeAssignment,
    bool? canManageAssignments,
    bool? canCreateAssignment,
    bool? canCreateTopicSelection,
    bool? canCreateCollection,
    bool? canEditOwnBeforeActivity,
    bool? canModerateTopicSelection,
    bool? canModerateCollection,
    bool? canManageCollectionReceipts,
    bool? canDeleteGroupAction,
    Map<String, String?>? reasons,
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
      canCreateAssignment: canCreateAssignment ?? this.canCreateAssignment,
      canCreateTopicSelection:
          canCreateTopicSelection ?? this.canCreateTopicSelection,
      canCreateCollection: canCreateCollection ?? this.canCreateCollection,
      canEditOwnBeforeActivity:
          canEditOwnBeforeActivity ?? this.canEditOwnBeforeActivity,
      canModerateTopicSelection:
          canModerateTopicSelection ?? this.canModerateTopicSelection,
      canModerateCollection:
          canModerateCollection ?? this.canModerateCollection,
      canManageCollectionReceipts:
          canManageCollectionReceipts ?? this.canManageCollectionReceipts,
      canDeleteGroupAction: canDeleteGroupAction ?? this.canDeleteGroupAction,
      reasons: reasons ?? this.reasons,
      loading: loading ?? this.loading,
      fromCache: fromCache ?? this.fromCache,
    );
  }

  /// Local structural matrix while RPC loads (auth unknown — keep last success).
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
      canCreateAssignment: false,
      canCreateTopicSelection: false,
      canCreateCollection: false,
      canEditOwnBeforeActivity: false,
      canModerateTopicSelection: false,
      canModerateCollection: false,
      canManageCollectionReceipts: false,
      canDeleteGroupAction: false,
      reasons: const {},
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
    final canPropose = json['can_propose_assignment'] == true;
    final canCreateAssignment =
        json['can_create_assignment'] == true || canPropose;
    return ChatComposerCapabilities(
      chatType: (json['chat_type'] ?? 'team').toString(),
      teamKind: (json['team_kind'] ?? 'subject').toString(),
      isActiveMember: json['is_active_member'] == true,
      isActiveSubjectTeam: json['is_active_subject_team'] == true,
      showProposeAssignment: json['show_propose_assignment'] == true,
      showTopicSelection: json['show_topic_selection'] == true,
      showCollection: json['show_collection'] == true,
      canProposeAssignment: canPropose,
      canManageAssignments: json['can_manage_assignments'] == true,
      canCreateAssignment: canCreateAssignment,
      canCreateTopicSelection: json['can_create_topic_selection'] == true,
      canCreateCollection: json['can_create_collection'] == true,
      canEditOwnBeforeActivity: json['can_edit_own_before_activity'] == true,
      canModerateTopicSelection: json['can_moderate_topic_selection'] == true,
      canModerateCollection: json['can_moderate_collection'] == true,
      canManageCollectionReceipts:
          json['can_manage_collection_receipts'] == true,
      canDeleteGroupAction: json['can_delete_group_action'] == true,
      reasons: reasons,
    );
  }

  Map<String, dynamic> toJson() => {
        'chat_type': chatType,
        'team_kind': teamKind,
        'is_active_member': isActiveMember,
        'is_active_subject_team': isActiveSubjectTeam,
        'show_propose_assignment': showProposeAssignment,
        'show_topic_selection': showTopicSelection,
        'show_collection': showCollection,
        'can_propose_assignment': canProposeAssignment,
        'can_manage_assignments': canManageAssignments,
        'can_create_assignment': canCreateAssignment,
        'can_create_topic_selection': canCreateTopicSelection,
        'can_create_collection': canCreateCollection,
        'can_edit_own_before_activity': canEditOwnBeforeActivity,
        'can_moderate_topic_selection': canModerateTopicSelection,
        'can_moderate_collection': canModerateCollection,
        'can_manage_collection_receipts': canManageCollectionReceipts,
        'can_delete_group_action': canDeleteGroupAction,
        'reasons': reasons,
      };

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
