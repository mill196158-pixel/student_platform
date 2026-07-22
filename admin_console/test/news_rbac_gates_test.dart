import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';

AdminCapabilities _caps(List<String> permissions) {
  return AdminCapabilities.fromJson({
    'user_id': 'u-1',
    'permissions': permissions,
    'assignments': <Object>[],
  });
}

void main() {
  test('content editor can write but not publish', () {
    final caps = _caps(['content.read', 'content.write']);
    expect(caps.canReadContent, isTrue);
    expect(caps.canWriteContent, isTrue);
    expect(caps.canPublishContent, isFalse);
  });

  test('content publisher can write and publish', () {
    final caps = _caps(['content.read', 'content.write', 'content.publish']);
    expect(caps.canWriteContent, isTrue);
    expect(caps.canPublishContent, isTrue);
  });

  test('read-only content role cannot write or publish', () {
    final caps = _caps(['content.read']);
    expect(caps.canReadContent, isTrue);
    expect(caps.canWriteContent, isFalse);
    expect(caps.canPublishContent, isFalse);
  });

  test('empty permissions gate everything', () {
    final caps = _caps(const []);
    expect(caps.canReadContent, isFalse);
    expect(caps.canWriteContent, isFalse);
    expect(caps.canPublishContent, isFalse);
    expect(caps.hasAnyAdminAccess, isFalse);
  });
}
