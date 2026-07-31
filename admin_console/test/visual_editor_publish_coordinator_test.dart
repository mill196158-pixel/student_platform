import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_operation_error.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_publish_coordinator.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_item.dart';
import 'package:student_ui/student_ui.dart';

HomePromoItem _item({
  int schemaVersion = 1,
  int? workingDraftRowVersion = 1,
  bool hasWorkingDraft = true,
}) {
  return HomePromoItem(
    id: 'item-1',
    status: HomePromoStatus.published,
    origin: ContentOrigin.admin,
    title: 'Title',
    payload: HomePromoPayload.demoStuckWithAssignment,
    rowVersion: 3,
    priority: 0,
    sortOrder: 0,
    audienceMode: 'all',
    schemaVersion: schemaVersion,
    hasWorkingDraft: hasWorkingDraft,
    workingDraftRowVersion: workingDraftRowVersion,
  );
}

void main() {
  test('home schema 1 patch includes target_schema_version 2', () {
    final patch = _item(schemaVersion: 1).toWorkingDraftPatch();
    expect(patch['target_schema_version'], 2);
    expect(patch.containsKey('payload'), isTrue);
  });

  test('home schema 2 patch includes target_schema_version 2', () {
    final patch = _item(schemaVersion: 2).toWorkingDraftPatch();
    expect(patch['target_schema_version'], 2);
  });

  test('dirty draft publish autosaves then publishes with saved RV', () async {
    final coordinator = VisualEditorPublishCoordinator();
    final calls = <String>[];
    var draftRv = 1;

    final result = await coordinator.publishChanges<HomePromoItem>(
      editingWorkingDraft: true,
      validate: () async => null,
      uploadPendingMedia: () async {
        calls.add('upload');
        draftRv = 2;
        return const VisualEditorUploadAdopt(workingDraftRowVersion: 2);
      },
      saveDraft: () async {
        calls.add('save:$draftRv');
        draftRv = 3;
        return VisualEditorSavedDraft(
          item: _item(workingDraftRowVersion: draftRv),
          expectedDraftRowVersion: draftRv,
        );
      },
      publishWorkingDraft: ({required expectedDraftRowVersion}) async {
        calls.add('publish:$expectedDraftRowVersion');
        expect(expectedDraftRowVersion, 3);
        return _item(
          schemaVersion: 2,
          workingDraftRowVersion: null,
          hasWorkingDraft: false,
        );
      },
      refetch: (published) async {
        calls.add('refetch');
        return published;
      },
    );

    expect(calls, ['upload', 'save:2', 'publish:3', 'refetch']);
    expect(result.hasWorkingDraft, isFalse);
  });

  test('upload failure blocks publish', () async {
    final coordinator = VisualEditorPublishCoordinator();
    var published = false;
    await expectLater(
      () => coordinator.publishChanges<HomePromoItem>(
        editingWorkingDraft: true,
        validate: () async => null,
        uploadPendingMedia: () async {
          throw const VisualEditorOperationError(
            'Не удалось загрузить изображение. Черновик сохранён, публикация не выполнена',
            code: 'media_upload_failed',
            isMedia: true,
          );
        },
        saveDraft: () async {
          fail('save should not run');
        },
        publishWorkingDraft: ({required expectedDraftRowVersion}) async {
          published = true;
          fail('publish should not run');
        },
        refetch: (published) async => published,
      ),
      throwsA(isA<VisualEditorOperationError>()),
    );
    expect(published, isFalse);
  });

  test('autosave failure blocks publish', () async {
    final coordinator = VisualEditorPublishCoordinator();
    var published = false;
    await expectLater(
      () => coordinator.publishChanges<HomePromoItem>(
        editingWorkingDraft: true,
        validate: () async => null,
        saveDraft: () async {
          throw const VisualEditorOperationError(
            'Карточка изменилась в другой вкладке. Обновили данные — проверьте изменения и повторите',
            code: 'row_version_conflict',
            isConflict: true,
          );
        },
        publishWorkingDraft: ({required expectedDraftRowVersion}) async {
          published = true;
          fail('publish should not run');
        },
        refetch: (published) async => published,
      ),
      throwsA(
        isA<VisualEditorOperationError>().having(
          (e) => e.isConflict,
          'isConflict',
          isTrue,
        ),
      ),
    );
    expect(published, isFalse);
  });

  test('double click shares one in-flight publish', () async {
    final coordinator = VisualEditorPublishCoordinator();
    var publishCount = 0;
    var saveCount = 0;

    Future<HomePromoItem> start() {
      return coordinator.publishChanges<HomePromoItem>(
        editingWorkingDraft: true,
        validate: () async => null,
        saveDraft: () async {
          saveCount += 1;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return VisualEditorSavedDraft(
            item: _item(workingDraftRowVersion: 4),
            expectedDraftRowVersion: 4,
          );
        },
        publishWorkingDraft: ({required expectedDraftRowVersion}) async {
          publishCount += 1;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return _item(hasWorkingDraft: false, workingDraftRowVersion: null);
        },
        refetch: (published) async => published,
      );
    }

    final results = await Future.wait([start(), start()]);
    expect(results.length, 2);
    expect(saveCount, 1);
    expect(publishCount, 1);
  });

  test('maps invalid_schema_upgrade away from generic message', () {
    final mapped = mapVisualEditorOperationError(
      const FormatException('invalid_schema_upgrade'),
      stage: 'autosave',
    );
    expect(mapped.code, 'invalid_schema_upgrade');
    expect(mapped.message, isNot(contains('Не удалось выполнить операцию')));
  });

  test('maps working_draft_required message', () {
    final mapped = mapVisualEditorOperationError(
      Exception('working_draft_required'),
      stage: 'publish',
    );
    expect(mapped.message, 'Сначала создайте черновик изменений');
  });
}
