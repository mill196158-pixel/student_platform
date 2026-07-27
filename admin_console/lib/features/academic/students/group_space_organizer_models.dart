class GroupSpaceMemberOrganizer {
  const GroupSpaceMemberOrganizer({
    required this.userId,
    required this.login,
    this.name = '',
    this.surname = '',
    this.isActive = true,
    this.hasAdminGrant = false,
    this.hasSubjectTeamAuthority = false,
    this.subjectTeamRoles = const [],
    this.sources = const [],
  });

  final String userId;
  final String login;
  final String name;
  final String surname;
  final bool isActive;
  final bool hasAdminGrant;
  final bool hasSubjectTeamAuthority;
  final List<String> subjectTeamRoles;
  final List<String> sources;

  bool get isOrganizer => hasAdminGrant || hasSubjectTeamAuthority;

  String get displayName {
    final full = '${surname.trim()} ${name.trim()}'.trim();
    return full.isEmpty ? login : full;
  }

  String get sourceLabel {
    final labels = <String>[];
    if (hasAdminGrant) labels.add('explicit grant');
    if (hasSubjectTeamAuthority) {
      final roles = subjectTeamRoles.isEmpty
          ? 'starosta/owner'
          : subjectTeamRoles.join('/');
      labels.add('active subject-team ($roles)');
    }
    if (labels.isEmpty) return 'нет';
    return labels.join(' + ');
  }

  factory GroupSpaceMemberOrganizer.fromJson(Map<String, dynamic> json) {
    List<String> asStringList(dynamic value) {
      if (value is! List) return const [];
      return [
        for (final item in value)
          if (item != null && '$item'.trim().isNotEmpty) '$item',
      ];
    }

    final sources = asStringList(json['sources']);
    final hasAdmin =
        json['has_admin_grant'] == true || sources.contains('admin');
    final hasSubject =
        json['has_subject_team_authority'] == true ||
        sources.contains('subject_team');

    return GroupSpaceMemberOrganizer(
      userId: '${json['user_id'] ?? ''}',
      login: '${json['login'] ?? ''}',
      name: '${json['name'] ?? ''}',
      surname: '${json['surname'] ?? ''}',
      isActive: json['is_active'] != false,
      hasAdminGrant: hasAdmin,
      hasSubjectTeamAuthority: hasSubject,
      subjectTeamRoles: asStringList(json['subject_team_roles']),
      sources: sources,
    );
  }
}

class GroupSpaceOrganizerState {
  const GroupSpaceOrganizerState({
    required this.groupId,
    required this.groupName,
    this.spaceExists = false,
    this.teamId,
    this.canManage = false,
    this.assistantsSupported = false,
    this.members = const [],
  });

  final String groupId;
  final String groupName;
  final bool spaceExists;
  final String? teamId;
  final bool canManage;
  final bool assistantsSupported;
  final List<GroupSpaceMemberOrganizer> members;

  List<GroupSpaceMemberOrganizer> get organizers =>
      members.where((m) => m.isOrganizer).toList(growable: false);

  factory GroupSpaceOrganizerState.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'];
    final members = <GroupSpaceMemberOrganizer>[];
    if (rawMembers is List) {
      for (final item in rawMembers) {
        if (item is Map) {
          members.add(
            GroupSpaceMemberOrganizer.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return GroupSpaceOrganizerState(
      groupId: '${json['group_id'] ?? ''}',
      groupName: '${json['group_name'] ?? ''}',
      spaceExists: json['space_exists'] == true,
      teamId: json['team_id']?.toString(),
      canManage: json['can_manage'] == true,
      assistantsSupported: json['assistants_supported'] == true,
      members: members,
    );
  }
}
