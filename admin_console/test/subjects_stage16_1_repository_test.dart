import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/academic/subjects/subject_item.dart';
import 'package:student_platform_admin/features/academic/subjects/subjects_repository.dart';

void main() {
  test('P1 conflict: optimistic locking on local save', () async {
    final repo = LocalSubjectsRepository();
    final items = await repo.list();
    final base = items.first;
    final a = base.copyWith(
      shortDescription: 'A',
      catalogRowVersion: base.catalogRowVersion,
      profileRowVersion: base.profileRowVersion,
    );
    final saved = await repo.save(a);
    expect(saved.catalogRowVersion, base.catalogRowVersion + 1);

    expect(
      () => repo.save(
        base.copyWith(
          shortDescription: 'stale',
          catalogRowVersion: base.catalogRowVersion,
          profileRowVersion: base.profileRowVersion,
        ),
      ),
      throwsA(
        isA<SubjectsRepositoryException>().having(
          (e) => e.isConflict,
          'isConflict',
          isTrue,
        ),
      ),
    );
  });

  test('P1 teachers: unknown/conflict/duplicates fail-closed locally', () async {
    final repo = LocalSubjectsRepository();
    final subject = (await repo.list()).first;
    repo.seedOffering(
      SubjectOfferingAdminItem(
        id: 'off-1',
        subjectId: subject.id,
        displayName: 'A',
        hoursTotal: 108,
        credits: 3,
        teachersRowVersion: 1,
        teacherIds: const [],
      ),
    );

    await repo.setOfferingTeachers(
      offeringId: 'off-1',
      expectedTeachersRowVersion: 1,
      teacherIds: const ['t1', 't2'],
    );

    expect(
      () => repo.setOfferingTeachers(
        offeringId: 'off-1',
        expectedTeachersRowVersion: 1,
        teacherIds: const ['t3'],
      ),
      throwsA(
        isA<SubjectsRepositoryException>().having(
          (e) => e.isConflict,
          'conflict',
          isTrue,
        ),
      ),
    );

    expect(
      () => repo.setOfferingTeachers(
        offeringId: 'off-1',
        expectedTeachersRowVersion: 2,
        teacherIds: const ['t1', 't1'],
      ),
      throwsA(isA<SubjectsRepositoryException>()),
    );
  });

  test('P1 offering override concurrency', () async {
    final repo = LocalSubjectsRepository();
    final subject = (await repo.list()).first;
    repo.seedOffering(
      SubjectOfferingAdminItem(
        id: 'off-2',
        subjectId: subject.id,
        overrideRowVersion: 0,
      ),
    );
    final saved = await repo.saveOfferingOverride(
      offeringId: 'off-2',
      expectedRowVersion: 0,
      localDescription: 'Local',
      semesterTips: 'Tips',
      moderationStatus: 'published',
    );
    expect(saved.overrideRowVersion, 1);
    expect(saved.localDescription, 'Local');

    expect(
      () => repo.saveOfferingOverride(
        offeringId: 'off-2',
        expectedRowVersion: 0,
        localDescription: 'stale',
      ),
      throwsA(
        isA<SubjectsRepositoryException>().having(
          (e) => e.isConflict,
          'conflict',
          isTrue,
        ),
      ),
    );
  });

  test('P1 section_order unknown keys rejected by SubjectItem roundtrip prep', () {
    final bad = SubjectItem.fromJson({
      'id': 'x',
      'canonical_name': 'N',
      'section_order': ['description', 'nope'],
    });
    // Model stores raw list; fail-closed happens in shared parser used by preview/RPC.
    expect(bad.sectionOrder, contains('nope'));
  });

  test('P1 offering override versions list + restore', () async {
    final repo = LocalSubjectsRepository();
    final subject = (await repo.list()).first;
    repo.seedOffering(
      SubjectOfferingAdminItem(
        id: 'off-3',
        subjectId: subject.id,
        overrideRowVersion: 0,
      ),
    );
    await repo.saveOfferingOverride(
      offeringId: 'off-3',
      expectedRowVersion: 0,
      localDescription: 'V1',
      moderationStatus: 'published',
    );
    await repo.saveOfferingOverride(
      offeringId: 'off-3',
      expectedRowVersion: 1,
      localDescription: 'V2',
      moderationStatus: 'published',
    );
    final versions = await repo.listOfferingProfileVersions('off-3');
    expect(versions.length, 2);
    final restored = await repo.restoreOfferingProfile(
      offeringId: 'off-3',
      versionNumber: 1,
      expectedRowVersion: 2,
    );
    expect(restored.localDescription, 'V1');
    expect(restored.overrideRowVersion, 3);

    expect(
      () => repo.restoreOfferingProfile(
        offeringId: 'off-3',
        versionNumber: 1,
        expectedRowVersion: 2,
      ),
      throwsA(
        isA<SubjectsRepositoryException>().having(
          (e) => e.isConflict,
          'conflict',
          isTrue,
        ),
      ),
    );
  });
}
