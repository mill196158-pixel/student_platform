class AdminCapabilities {
  const AdminCapabilities({
    required this.userId,
    required this.permissions,
    required this.assignments,
  });

  final String? userId;
  final Set<String> permissions;
  final List<AdminAssignmentScope> assignments;

  static const empty = AdminCapabilities(
    userId: null,
    permissions: {},
    assignments: [],
  );

  bool get hasAnyAdminAccess => permissions.isNotEmpty;

  bool can(String permission) => permissions.contains(permission);

  bool get canViewDashboard => can('dashboard.view');
  bool get canReadContent => can('content.read') || can('content.write');
  bool get canWriteContent => can('content.write');
  bool get canReadAcademic =>
      can('academic.read') || can('subjects.write') || can('teachers.write');
  bool get canWriteSubjects => can('subjects.write');
  bool get canWriteTeachers => can('teachers.write');
  bool get canManageRoles => can('roles.manage');
  bool get canReadAudit => can('audit.read');

  factory AdminCapabilities.fromJson(Map<String, dynamic> json) {
    final rawPermissions = json['permissions'];
    final permissions = <String>{};
    if (rawPermissions is List) {
      for (final item in rawPermissions) {
        if (item != null) permissions.add(item.toString());
      }
    }

    final rawAssignments = json['assignments'];
    final assignments = <AdminAssignmentScope>[];
    if (rawAssignments is List) {
      for (final item in rawAssignments) {
        if (item is Map) {
          assignments.add(
            AdminAssignmentScope(
              roleCode: item['role_code']?.toString() ?? '',
              scopeType: item['scope_type']?.toString() ?? 'global',
              scopeId: item['scope_id']?.toString(),
              expiresAt: item['expires_at'] == null
                  ? null
                  : DateTime.tryParse(item['expires_at'].toString()),
            ),
          );
        }
      }
    }

    return AdminCapabilities(
      userId: json['user_id']?.toString(),
      permissions: permissions,
      assignments: assignments,
    );
  }
}

class AdminAssignmentScope {
  const AdminAssignmentScope({
    required this.roleCode,
    required this.scopeType,
    this.scopeId,
    this.expiresAt,
  });

  final String roleCode;
  final String scopeType;
  final String? scopeId;
  final DateTime? expiresAt;
}
