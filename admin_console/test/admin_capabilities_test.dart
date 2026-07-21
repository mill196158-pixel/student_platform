import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';

void main() {
  test('parses capabilities json from get_my_admin_capabilities', () {
    final caps = AdminCapabilities.fromJson({
      'user_id': 'u-1',
      'permissions': ['dashboard.view', 'content.read', 'content.write'],
      'assignments': [
        {
          'role_code': 'content_editor',
          'scope_type': 'global',
          'scope_id': null,
          'expires_at': null,
        },
      ],
    });

    expect(caps.userId, 'u-1');
    expect(caps.canViewDashboard, isTrue);
    expect(caps.canReadContent, isTrue);
    expect(caps.canWriteContent, isTrue);
    expect(caps.canManageRoles, isFalse);
    expect(caps.assignments.single.roleCode, 'content_editor');
  });

  test('empty permissions means no admin access', () {
    final caps = AdminCapabilities.fromJson({
      'user_id': 'student-1',
      'permissions': <String>[],
      'assignments': <Object>[],
    });
    expect(caps.hasAnyAdminAccess, isFalse);
  });
}
