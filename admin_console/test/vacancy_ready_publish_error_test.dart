import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_operation_error.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('maps invalid_status_transition_draft_to_published to RU guidance', () {
    final mapped = mapVisualEditorOperationError(
      PostgrestException(
        message: 'invalid_status_transition_draft_to_published',
        code: '55000',
      ),
      stage: 'publish',
    );
    expect(mapped.isValidation, isTrue);
    expect(mapped.message, contains('модерац'));
    expect(mapped.code, 'invalid_status_transition_draft_to_published');
  });

  test('maps ready_publish_origin_forbidden', () {
    final mapped = mapVisualEditorOperationError(
      PostgrestException(
        message: 'ready_publish_origin_forbidden',
        code: '42501',
      ),
      stage: 'publish',
    );
    expect(mapped.message, contains('admin/demo'));
  });
}
