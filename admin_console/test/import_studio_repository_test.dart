import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/import_studio_item.dart';
import 'package:student_platform_admin/features/import_studio/import_studio_mapping.dart';
import 'package:student_platform_admin/features/import_studio/import_studio_repository.dart';
import 'package:student_platform_admin/features/import_studio/import_studio_template_service.dart';
import 'package:student_platform_admin/features/import_studio/import_studio_workbook_service.dart';
void main() {
  group('LocalImportStudioRepository state machine', () {
    late LocalImportStudioRepository repo;

    setUp(() {
      repo = LocalImportStudioRepository();
    });

    test('listDomains exposes Stage 19 completion domain matrix (all apply)', () async {
      final domains = await repo.listDomains();
      expect(domains, hasLength(9));

      for (final domain in domains) {
        expect(
          domain.domainState,
          ImportStudioDomainState.apply,
          reason: '${domain.domain} should be apply after Stage 19 completion',
        );
        expect(domain.canApply, isTrue, reason: domain.domain);
        expect(domain.canDryRun, isTrue, reason: domain.domain);
        expect(domain.supportsApply, isTrue, reason: domain.domain);
      }

      final teachers = domains.firstWhere((d) => d.domain == 'teachers');
      expect(teachers.templateColumns, contains('full_name'));

      final curriculum = domains.firstWhere((d) => d.domain == 'curriculum');
      expect(curriculum.templateColumns, contains('curriculum_subject_id'));

      final offerings = domains.firstWhere((d) => d.domain == 'offerings');
      expect(offerings.templateColumns, contains('offering_id'));

      final teacherLinks = domains.firstWhere((d) => d.domain == 'teacher_links');
      expect(teacherLinks.templateColumns, contains('teacher_link_id'));

      final enrollments = domains.firstWhere((d) => d.domain == 'enrollments');
      expect(enrollments.templateColumns, contains('enrollment_id'));
    });

    test('dry-run → diff → confirm apply → batch id', () async {
      final batch = await repo.startDryRun(
        domain: 'teachers',
        rows: [
          {
            'full_name': 'Иванов Иван',
            'email': 'ivan@example.edu',
            'department': 'ИТ',
          },
        ],
        fileName: 'teachers.csv',
        batchKey: 'test-batch-key',
      );

      expect(batch.status, ImportStudioBatchStatus.dryRun);
      expect(batch.batchKey, 'test-batch-key');
      expect(batch.batchId, isNotEmpty);
      expect(batch.errorCount, 0);

      final diff = await repo.getDiff(batchId: batch.batchId);
      expect(diff.rows, hasLength(1));
      expect(diff.rows.first.classification, ImportStudioRowClassification.newRow);

      final applied = await repo.apply(
        batchId: batch.batchId,
        confirmBatchKey: 'test-batch-key',
      );

      expect(applied.status, ImportStudioBatchStatus.applied);
      expect(applied.batchId, batch.batchId);
      expect(applied.alreadyApplied, isFalse);
    });

    test('apply rejects wrong batch_key confirmation', () async {
      final batch = await repo.startDryRun(
        domain: 'subjects',
        rows: [
          {'canonical_name': 'Математика', 'department': 'ИТ'},
        ],
        batchKey: 'correct-key',
      );

      expect(
        () => repo.apply(batchId: batch.batchId, confirmBatchKey: 'wrong-key'),
        throwsA(
          isA<ImportStudioRepositoryException>().having(
            (e) => e.code,
            'code',
            'batch_key_confirmation_mismatch',
          ),
        ),
      );
    });

    test('apply is idempotent for already applied batch', () async {
      final batch = await repo.startDryRun(
        domain: 'students',
        rows: [
          {'login': 'student01', 'name': 'Иван', 'surname': 'Иванов'},
        ],
        batchKey: 'student-key',
      );

      await repo.apply(
        batchId: batch.batchId,
        confirmBatchKey: 'student-key',
      );

      final replay = await repo.apply(
        batchId: batch.batchId,
        confirmBatchKey: 'student-key',
      );

      expect(replay.status, ImportStudioBatchStatus.applied);
      expect(replay.idempotentReplay, isTrue);
      expect(replay.alreadyApplied, isTrue);
    });

    test('dry-run with validation errors blocks apply', () async {
      final batch = await repo.startDryRun(
        domain: 'teachers',
        rows: [
          {'email': 'bad@example.edu'},
        ],
      );

      expect(batch.errorCount, greaterThan(0));

      expect(
        () => repo.apply(
          batchId: batch.batchId,
          confirmBatchKey: batch.batchKey,
        ),
        throwsA(
          isA<ImportStudioRepositoryException>().having(
            (e) => e.code,
            'code',
            'batch_has_errors',
          ),
        ),
      );
    });

    test('applied batch_key with different payload raises mismatch', () async {
      final first = await repo.startDryRun(
        domain: 'teachers',
        rows: [
          {
            'full_name': 'Иванов Иван',
            'contacts_public': {'public_email': 'ivan@example.edu'},
          },
        ],
        batchKey: 'same-key',
      );
      await repo.apply(
        batchId: first.batchId,
        confirmBatchKey: 'same-key',
      );

      expect(
        () => repo.startDryRun(
          domain: 'teachers',
          rows: [
            {
              'full_name': 'Петров Пётр',
              'contacts_public': {'public_email': 'petrov@example.edu'},
            },
          ],
          batchKey: 'same-key',
        ),
        throwsA(
          isA<ImportStudioRepositoryException>().having(
            (e) => e.code,
            'code',
            'batch_key_payload_mismatch',
          ),
        ),
      );
    });

    test('delegated apply failure persists failed and throws', () async {
      final batch = await repo.startDryRun(
        domain: 'teachers',
        rows: [
          {'full_name': 'Сидоров', 'email': 'sid@example.edu'},
        ],
        batchKey: 'fail-key',
      );
      repo.failNextApply = true;

      expect(
        () => repo.apply(
          batchId: batch.batchId,
          confirmBatchKey: 'fail-key',
        ),
        throwsA(
          isA<ImportStudioRepositoryException>().having(
            (e) => e.code,
            'code',
            'delegated_apply_failed',
          ),
        ),
      );

      final batches = await repo.listBatches(domain: 'teachers');
      final failed = batches.firstWhere((b) => b.batchId == batch.batchId);
      expect(failed.status, ImportStudioBatchStatus.failed);
      expect(failed.status, isNot(ImportStudioBatchStatus.applied));
    });

    test('teacher mapping normalizes email into contacts_public payload', () async {
      final mapped = mapImportStudioRows(
        domain: 'teachers',
        rawRows: [
          {
            'ФИО': 'Иванов Иван',
            'Email': 'ivan@example.edu',
            'Кафедра': 'ИТ',
          },
        ],
        fieldToHeader: {
          'full_name': 'ФИО',
          'public_email': 'Email',
          'department': 'Кафедра',
        },
      );

      expect(mapped.single['full_name'], 'Иванов Иван');
      expect(
        mapped.single['contacts_public'],
        {'public_email': 'ivan@example.edu'},
      );

      final batch = await repo.startDryRun(
        domain: 'teachers',
        rows: mapped,
      );
      final diff = await repo.getDiff(batchId: batch.batchId);
      expect(
        diff.rows.single.mappedPayload['contacts_public'],
        {'public_email': 'ivan@example.edu'},
      );
    });

    test('template service and workbook parser produce mappable rows', () {
      final templateBytes =
          ImportStudioTemplateService().buildTemplateBytes('teachers');
      final sheet = ImportStudioWorkbookService().readWorkbook(templateBytes).sheets.first;
      final mapping = suggestImportStudioHeaderMapping('teachers', sheet.headers);
      expect(mapping['full_name'], 'ФИО');
      expect(mapping['public_email'], 'Email');

      final rows = mapImportStudioRows(
        domain: 'teachers',
        rawRows: sheet.rows,
        fieldToHeader: mapping,
      );
      expect(rows, hasLength(1));
      expect(rows.first['contacts_public'], isNotNull);
    });

    test('dry-run idempotency refreshes same batch_key', () async {
      final first = await repo.startDryRun(
        domain: 'terms',
        rows: [
          {
            'academic_year_name': '2025/2026',
            'name': 'Осенний',
            'term_in_year': '1',
            'starts_on': '2025-09-01',
            'ends_on': '2026-01-31',
          },
        ],
        batchKey: 'terms-key',
      );

      final second = await repo.startDryRun(
        domain: 'terms',
        rows: [
          {
            'academic_year_name': '2025/2026',
            'name': 'Весенний',
            'term_in_year': '2',
            'starts_on': '2026-02-01',
            'ends_on': '2026-06-30',
          },
        ],
        batchKey: 'terms-key',
      );

      expect(second.batchId, first.batchId);
      expect(second.batchKey, 'terms-key');
      expect(second.rowCount, 1);
    });

    test('rollback always refused for teachers (non rollback-safe domain)', () async {
      final batch = await repo.startDryRun(
        domain: 'teachers',
        rows: [
          {'full_name': 'Петров Пётр'},
        ],
        batchKey: 'rollback-key',
      );
      await repo.apply(
        batchId: batch.batchId,
        confirmBatchKey: 'rollback-key',
      );

      final rollback = await repo.rollbackBatch(
        batchId: batch.batchId,
        confirmBatchKey: 'rollback-key',
      );

      expect(rollback.ok, isFalse);
      expect(rollback.refused, isTrue);
      expect(rollback.errorCode, 'rollback_not_supported_for_batch');
    });

    test('groups: apply creates group, warns about team/chat, rollback refused', () async {
      final batch = await repo.startDryRun(
        domain: 'groups',
        rows: [
          {'name': 'ИТ-101'},
        ],
        batchKey: 'group-key',
      );

      expect(batch.supportsApply, isTrue);
      expect(batch.summary.warnings, isNotEmpty);
      expect(batch.summary.warnings.first, contains('group_space'));

      final applied = await repo.apply(batchId: batch.batchId, confirmBatchKey: 'group-key');
      expect(applied.status, ImportStudioBatchStatus.applied);
      expect(applied.rollbackSafe, isFalse);

      final rollback = await repo.rollbackBatch(
        batchId: batch.batchId,
        confirmBatchKey: 'group-key',
      );
      expect(rollback.ok, isFalse);
      expect(rollback.errorCode, 'rollback_not_supported_for_batch');
    });

    test('groups: second row with same name classifies as update, not duplicate', () async {
      final first = await repo.startDryRun(
        domain: 'groups',
        rows: [
          {'name': 'ИТ-102'},
        ],
        batchKey: 'group-first',
      );
      await repo.apply(batchId: first.batchId, confirmBatchKey: 'group-first');

      final second = await repo.startDryRun(
        domain: 'groups',
        rows: [
          {'name': 'ИТ-102'},
        ],
        batchKey: 'group-second',
      );
      final diff = await repo.getDiff(batchId: second.batchId);
      expect(diff.rows.single.classification, ImportStudioRowClassification.update);
    });

    test('terms: apply creates new term and rollback succeeds', () async {
      final batch = await repo.startDryRun(
        domain: 'terms',
        rows: [
          {
            'academic_year_name': '2026/2027',
            'name': 'Весенний 2027',
            'term_in_year': '2',
            'starts_on': '2027-02-01',
            'ends_on': '2027-06-30',
          },
        ],
        batchKey: 'term-apply-key',
      );
      expect(batch.summary.warnings, isNotEmpty);

      final applied = await repo.apply(
        batchId: batch.batchId,
        confirmBatchKey: 'term-apply-key',
      );
      expect(applied.rollbackSafe, isTrue);

      final rollback = await repo.rollbackBatch(
        batchId: batch.batchId,
        confirmBatchKey: 'term-apply-key',
      );
      expect(rollback.ok, isTrue);
      expect(rollback.deletedCount, 1);
    });

    test('terms: is_current flip is forbidden', () async {
      final batch = await repo.startDryRun(
        domain: 'terms',
        rows: [
          {
            'academic_year_name': '2025/2026',
            'name': 'Весенний',
            'term_in_year': '2',
            'starts_on': '2026-02-01',
            'ends_on': '2026-06-30',
            'is_current': true,
          },
        ],
        batchKey: 'term-flip-key',
      );
      expect(batch.errorCount, 1);
      final diff = await repo.getDiff(batchId: batch.batchId);
      expect(diff.rows.single.errorText, contains('current_term_flip_forbidden'));
    });

    test(
      'terms: rollback is refused with rollback_refused_row_drift if the term '
      'was hand-edited after apply (P1: rollback drift check)',
      () async {
        final batch = await repo.startDryRun(
          domain: 'terms',
          rows: [
            {
              'academic_year_name': '2028/2029',
              'name': 'Осенний до правки',
              'term_in_year': '1',
              'starts_on': '2028-09-01',
              'ends_on': '2029-01-31',
            },
          ],
          batchKey: 'term-drift-key',
        );
        final applied = await repo.apply(
          batchId: batch.batchId,
          confirmBatchKey: 'term-drift-key',
        );
        expect(applied.rollbackSafe, isTrue);

        final termId = repo.debugAppliedEntityId(batchId: batch.batchId, rowIndex: 0);
        expect(termId, isNotNull);

        // Simulate a later admin edit of the SAME term (id-provided update),
        // which drifts it away from the apply-time fingerprint.
        final editBatch = await repo.startDryRun(
          domain: 'terms',
          rows: [
            {
              'term_id': termId,
              'academic_year_name': '2028/2029',
              'name': 'Осенний ПОСЛЕ правки',
              'starts_on': '2028-09-01',
              'ends_on': '2029-01-31',
            },
          ],
          batchKey: 'term-drift-edit-key',
        );
        await repo.apply(batchId: editBatch.batchId, confirmBatchKey: 'term-drift-edit-key');

        // Rolling back the ORIGINAL creating batch must now be refused —
        // never silently delete a term that no longer matches what apply
        // actually created.
        final rollback = await repo.rollbackBatch(
          batchId: batch.batchId,
          confirmBatchKey: 'term-drift-key',
        );
        expect(rollback.ok, isFalse);
        expect(rollback.refused, isTrue);
        expect(rollback.errorCode, 'rollback_refused_row_drift');
      },
    );

    test('curriculum: requires an existing group and dedupes by (subject, semester)', () async {
      final missingGroup = await repo.startDryRun(
        domain: 'curriculum',
        rows: [
          {'group_name': 'НЕТ-000', 'subject_name': 'Математика', 'semester_number': '1'},
        ],
        batchKey: 'curriculum-missing-group',
      );
      expect(missingGroup.errorCount, 1);

      final groupBatch = await repo.startDryRun(
        domain: 'groups',
        rows: [
          {'name': 'ИТ-201'},
        ],
        batchKey: 'curriculum-group-key',
      );
      await repo.apply(batchId: groupBatch.batchId, confirmBatchKey: 'curriculum-group-key');

      final batch = await repo.startDryRun(
        domain: 'curriculum',
        rows: [
          {
            'group_name': 'ИТ-201',
            'subject_name': 'Математика',
            'semester_number': '1',
            'credits': '4',
          },
        ],
        batchKey: 'curriculum-key',
      );
      expect(batch.errorCount, 0);

      final applied = await repo.apply(
        batchId: batch.batchId,
        confirmBatchKey: 'curriculum-key',
      );
      expect(applied.rollbackSafe, isTrue);

      final rollback = await repo.rollbackBatch(
        batchId: batch.batchId,
        confirmBatchKey: 'curriculum-key',
      );
      expect(rollback.ok, isTrue);
      expect(rollback.deletedCount, 1);
    });

    test('offerings + teacher_links: full workflow with blocked-then-allowed rollback', () async {
      final groupBatch = await repo.startDryRun(
        domain: 'groups',
        rows: [
          {'name': 'ИТ-301'},
        ],
        batchKey: 'off-group-key',
      );
      await repo.apply(batchId: groupBatch.batchId, confirmBatchKey: 'off-group-key');

      final termBatch = await repo.startDryRun(
        domain: 'terms',
        rows: [
          {
            'academic_year_name': '2025/2026',
            'name': 'Осенний офферинг',
            'term_in_year': '1',
            'starts_on': '2025-09-01',
            'ends_on': '2026-01-31',
          },
        ],
        batchKey: 'off-term-key',
      );
      await repo.apply(batchId: termBatch.batchId, confirmBatchKey: 'off-term-key');

      final offeringBatch = await repo.startDryRun(
        domain: 'offerings',
        rows: [
          {
            'group_name': 'ИТ-301',
            'subject_name': 'Физика',
            'academic_year_name': '2025/2026',
            'term_name': 'Осенний офферинг',
            'semester_number': '1',
          },
        ],
        batchKey: 'off-offering-key',
      );
      expect(offeringBatch.errorCount, 0);
      final appliedOffering = await repo.apply(
        batchId: offeringBatch.batchId,
        confirmBatchKey: 'off-offering-key',
      );
      expect(appliedOffering.rollbackSafe, isTrue);

      final linkBatch = await repo.startDryRun(
        domain: 'teacher_links',
        rows: [
          {
            'group_name': 'ИТ-301',
            'subject_name': 'Физика',
            'academic_year_name': '2025/2026',
            'term_name': 'Осенний офферинг',
            'teacher_full_name': 'Смирнов Пётр',
            'role': 'lecturer',
          },
        ],
        batchKey: 'off-link-key',
      );
      expect(linkBatch.errorCount, 0);
      final appliedLink = await repo.apply(
        batchId: linkBatch.batchId,
        confirmBatchKey: 'off-link-key',
      );
      expect(appliedLink.rollbackSafe, isTrue);

      // Offering rollback is now blocked: a teacher_link was applied against it.
      final blockedRollback = await repo.rollbackBatch(
        batchId: offeringBatch.batchId,
        confirmBatchKey: 'off-offering-key',
      );
      expect(blockedRollback.ok, isFalse);
      expect(blockedRollback.errorCode, 'rollback_blocked_by_dependency');

      // teacher_links is a pure junction — its own rollback always succeeds.
      final linkRollback = await repo.rollbackBatch(
        batchId: linkBatch.batchId,
        confirmBatchKey: 'off-link-key',
      );
      expect(linkRollback.ok, isTrue);
      expect(linkRollback.deletedCount, 1);

      // Now that the dependency is gone, the offering can be rolled back.
      final offeringRollback = await repo.rollbackBatch(
        batchId: offeringBatch.batchId,
        confirmBatchKey: 'off-offering-key',
      );
      expect(offeringRollback.ok, isTrue);
      expect(offeringRollback.deletedCount, 1);
    });

    test(
      'curriculum: natural-key match (no id) classifies as update, and rollback refuses '
      'the batch that updated instead of deleting the pre-existing row (P0 regression)',
      () async {
        final groupBatch = await repo.startDryRun(
          domain: 'groups',
          rows: [
            {'name': 'ИТ-501'},
          ],
          batchKey: 'cur-nk-group-key',
        );
        await repo.apply(batchId: groupBatch.batchId, confirmBatchKey: 'cur-nk-group-key');

        // batchA creates the curriculum_subjects row (no id given: brand new).
        final batchA = await repo.startDryRun(
          domain: 'curriculum',
          rows: [
            {
              'group_name': 'ИТ-501',
              'subject_name': 'Химия',
              'semester_number': '2',
              'credits': '3',
            },
          ],
          batchKey: 'cur-nk-a',
        );
        final diffA = await repo.getDiff(batchId: batchA.batchId);
        expect(diffA.rows.single.classification, ImportStudioRowClassification.newRow);
        final appliedA = await repo.apply(batchId: batchA.batchId, confirmBatchKey: 'cur-nk-a');
        expect(appliedA.rollbackSafe, isTrue);

        // batchB re-imports the SAME (subject, semester) with no explicit
        // curriculum_subject_id: this MUST classify as 'update' (natural-key
        // match against the row batchA created), never 'new' again.
        final batchB = await repo.startDryRun(
          domain: 'curriculum',
          rows: [
            {
              'group_name': 'ИТ-501',
              'subject_name': 'Химия',
              'semester_number': '2',
              'credits': '5',
            },
          ],
          batchKey: 'cur-nk-b',
        );
        final diffB = await repo.getDiff(batchId: batchB.batchId);
        expect(diffB.rows.single.classification, ImportStudioRowClassification.update);
        final appliedB = await repo.apply(batchId: batchB.batchId, confirmBatchKey: 'cur-nk-b');
        expect(appliedB.rollbackSafe, isTrue);

        // Rolling back batchB (which only updated a pre-existing row) must be
        // refused wholesale — never delete the row batchA created.
        final rollbackB = await repo.rollbackBatch(
          batchId: batchB.batchId,
          confirmBatchKey: 'cur-nk-b',
        );
        expect(rollbackB.ok, isFalse);
        expect(rollbackB.refused, isTrue);
        expect(rollbackB.errorCode, 'rollback_refused_has_updates');

        // The actual creator (batchA) can still be rolled back cleanly.
        final rollbackA = await repo.rollbackBatch(
          batchId: batchA.batchId,
          confirmBatchKey: 'cur-nk-a',
        );
        expect(rollbackA.ok, isTrue);
        expect(rollbackA.deletedCount, 1);
      },
    );

    test(
      'offerings: natural-key match (no id) classifies as update, and rollback of the '
      'updating batch is refused',
      () async {
        final groupBatch = await repo.startDryRun(
          domain: 'groups',
          rows: [
            {'name': 'ИТ-502'},
          ],
          batchKey: 'off-nk-group-key',
        );
        await repo.apply(batchId: groupBatch.batchId, confirmBatchKey: 'off-nk-group-key');

        final termBatch = await repo.startDryRun(
          domain: 'terms',
          rows: [
            {
              'academic_year_name': '2025/2026',
              'name': 'Осенний оффер NK',
              'term_in_year': '1',
              'starts_on': '2025-09-01',
              'ends_on': '2026-01-31',
            },
          ],
          batchKey: 'off-nk-term-key',
        );
        await repo.apply(batchId: termBatch.batchId, confirmBatchKey: 'off-nk-term-key');

        final offeringRow = {
          'group_name': 'ИТ-502',
          'subject_name': 'Биология',
          'academic_year_name': '2025/2026',
          'term_name': 'Осенний оффер NK',
          'semester_number': '1',
        };

        final batchA = await repo.startDryRun(
          domain: 'offerings',
          rows: [offeringRow],
          batchKey: 'off-nk-a',
        );
        expect(
          (await repo.getDiff(batchId: batchA.batchId)).rows.single.classification,
          ImportStudioRowClassification.newRow,
        );
        await repo.apply(batchId: batchA.batchId, confirmBatchKey: 'off-nk-a');

        final batchB = await repo.startDryRun(
          domain: 'offerings',
          rows: [
            {...offeringRow, 'status': 'active'},
          ],
          batchKey: 'off-nk-b',
        );
        expect(
          (await repo.getDiff(batchId: batchB.batchId)).rows.single.classification,
          ImportStudioRowClassification.update,
        );
        await repo.apply(batchId: batchB.batchId, confirmBatchKey: 'off-nk-b');

        final rollbackB = await repo.rollbackBatch(
          batchId: batchB.batchId,
          confirmBatchKey: 'off-nk-b',
        );
        expect(rollbackB.ok, isFalse);
        expect(rollbackB.errorCode, 'rollback_refused_has_updates');

        final rollbackA = await repo.rollbackBatch(
          batchId: batchA.batchId,
          confirmBatchKey: 'off-nk-a',
        );
        expect(rollbackA.ok, isTrue);
        expect(rollbackA.deletedCount, 1);
      },
    );

    test(
      'teacher_links: natural-key match (no id) classifies as update, and rollback of the '
      'updating batch is refused',
      () async {
        final groupBatch = await repo.startDryRun(
          domain: 'groups',
          rows: [
            {'name': 'ИТ-503'},
          ],
          batchKey: 'link-nk-group-key',
        );
        await repo.apply(batchId: groupBatch.batchId, confirmBatchKey: 'link-nk-group-key');

        final termBatch = await repo.startDryRun(
          domain: 'terms',
          rows: [
            {
              'academic_year_name': '2025/2026',
              'name': 'Осенний линк NK',
              'term_in_year': '1',
              'starts_on': '2025-09-01',
              'ends_on': '2026-01-31',
            },
          ],
          batchKey: 'link-nk-term-key',
        );
        await repo.apply(batchId: termBatch.batchId, confirmBatchKey: 'link-nk-term-key');

        final offeringBatch = await repo.startDryRun(
          domain: 'offerings',
          rows: [
            {
              'group_name': 'ИТ-503',
              'subject_name': 'География',
              'academic_year_name': '2025/2026',
              'term_name': 'Осенний линк NK',
              'semester_number': '1',
            },
          ],
          batchKey: 'link-nk-offering-key',
        );
        await repo.apply(batchId: offeringBatch.batchId, confirmBatchKey: 'link-nk-offering-key');

        final linkRow = {
          'group_name': 'ИТ-503',
          'subject_name': 'География',
          'academic_year_name': '2025/2026',
          'term_name': 'Осенний линк NK',
          'teacher_full_name': 'Кузнецова Анна',
          'role': 'lecturer',
        };

        final batchA = await repo.startDryRun(
          domain: 'teacher_links',
          rows: [linkRow],
          batchKey: 'link-nk-a',
        );
        expect(
          (await repo.getDiff(batchId: batchA.batchId)).rows.single.classification,
          ImportStudioRowClassification.newRow,
        );
        await repo.apply(batchId: batchA.batchId, confirmBatchKey: 'link-nk-a');

        final batchB = await repo.startDryRun(
          domain: 'teacher_links',
          rows: [linkRow],
          batchKey: 'link-nk-b',
        );
        expect(
          (await repo.getDiff(batchId: batchB.batchId)).rows.single.classification,
          ImportStudioRowClassification.update,
        );
        await repo.apply(batchId: batchB.batchId, confirmBatchKey: 'link-nk-b');

        final rollbackB = await repo.rollbackBatch(
          batchId: batchB.batchId,
          confirmBatchKey: 'link-nk-b',
        );
        expect(rollbackB.ok, isFalse);
        expect(rollbackB.errorCode, 'rollback_refused_has_updates');

        final rollbackA = await repo.rollbackBatch(
          batchId: batchA.batchId,
          confirmBatchKey: 'link-nk-a',
        );
        expect(rollbackA.ok, isTrue);
        expect(rollbackA.deletedCount, 1);
      },
    );

    test('enrollments: new enrollment applies, cross-group transfer refused, rollback refused', () async {
      final groupBatch = await repo.startDryRun(
        domain: 'groups',
        rows: [
          {'name': 'ИТ-401'},
        ],
        batchKey: 'enroll-group-key',
      );
      await repo.apply(batchId: groupBatch.batchId, confirmBatchKey: 'enroll-group-key');

      final enrollBatch = await repo.startDryRun(
        domain: 'enrollments',
        rows: [
          {'login': 'student42', 'group_name': 'ИТ-401', 'started_at': '2026-02-01'},
        ],
        batchKey: 'enroll-key',
      );
      expect(enrollBatch.summary.warnings, isNotEmpty);
      final applied = await repo.apply(batchId: enrollBatch.batchId, confirmBatchKey: 'enroll-key');
      expect(applied.rollbackSafe, isFalse);

      final rollback = await repo.rollbackBatch(
        batchId: enrollBatch.batchId,
        confirmBatchKey: 'enroll-key',
      );
      expect(rollback.ok, isFalse);
      expect(rollback.errorCode, 'rollback_not_supported_for_batch');

      final transferBatch = await repo.startDryRun(
        domain: 'enrollments',
        rows: [
          {'login': 'student42', 'group_name': 'ИТ-401'},
        ],
        batchKey: 'enroll-transfer-key',
      );
      // Same group as before: idempotent no-op, not an error.
      expect(transferBatch.errorCount, 0);

      final otherGroupBatch = await repo.startDryRun(
        domain: 'groups',
        rows: [
          {'name': 'ИТ-402'},
        ],
        batchKey: 'enroll-group-key-2',
      );
      await repo.apply(batchId: otherGroupBatch.batchId, confirmBatchKey: 'enroll-group-key-2');

      final blockedTransfer = await repo.startDryRun(
        domain: 'enrollments',
        rows: [
          {'login': 'student42', 'group_name': 'ИТ-402'},
        ],
        batchKey: 'enroll-transfer-key-2',
      );
      expect(blockedTransfer.errorCount, 1);
      final diff = await repo.getDiff(batchId: blockedTransfer.batchId);
      expect(
        diff.rows.single.errorText,
        contains('user_already_enrolled_in_other_group'),
      );
    });
  });
}
