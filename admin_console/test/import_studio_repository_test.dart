import 'package:excel/excel.dart';
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

    test('listDomains exposes Stage 19 domain matrix', () async {
      final domains = await repo.listDomains();
      expect(domains, hasLength(9));

      final teachers = domains.firstWhere((d) => d.domain == 'teachers');
      expect(teachers.domainState, ImportStudioDomainState.apply);
      expect(teachers.canApply, isTrue);
      expect(teachers.templateColumns, contains('full_name'));

      final curriculum = domains.firstWhere((d) => d.domain == 'curriculum');
      expect(curriculum.domainState, ImportStudioDomainState.validateOnly);
      expect(curriculum.canApply, isFalse);

      final offerings = domains.firstWhere((d) => d.domain == 'offerings');
      expect(offerings.domainState, ImportStudioDomainState.notImplemented);
      expect(offerings.canDryRun, isFalse);
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

    test('validate-only domain refuses apply', () async {
      final batch = await repo.startDryRun(
        domain: 'groups',
        rows: [
          {'name': 'ИТ-101'},
        ],
        batchKey: 'group-key',
      );

      expect(batch.supportsApply, isFalse);

      expect(
        () => repo.apply(batchId: batch.batchId, confirmBatchKey: 'group-key'),
        throwsA(
          isA<ImportStudioRepositoryException>().having(
            (e) => e.code,
            'code',
            'apply_not_supported_for_domain_groups',
          ),
        ),
      );
    });

    test('not_implemented domain refuses dry-run', () async {
      expect(
        () => repo.startDryRun(
          domain: 'offerings',
          rows: [
            {'name': 'x'},
          ],
        ),
        throwsA(
          isA<ImportStudioRepositoryException>().having(
            (e) => e.code,
            'code',
            'not_implemented_domain_offerings',
          ),
        ),
      );
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

    test('rollback always refused in foundation', () async {
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
  });
}
