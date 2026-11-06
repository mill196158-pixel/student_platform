import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/cache_budget_policy_experiment.dart';

void main() {
  CacheFootprintObservation item(String id, int bytes, CacheFootprintClass kind,
      {CacheFootprintKind source = CacheFootprintKind.other, bool inUse = false}) =>
      CacheFootprintObservation(physicalIdentity: id, bytes: bytes,
          classification: kind, kind: source, inUse: inUse);

  test('accounts physical DB, WAL and SHM separately while protecting mixed files', () {
    final estimate = CacheBudgetPolicyExperiment.estimate([
      item('db-inode', 300000000, CacheFootprintClass.mixed, source: CacheFootprintKind.conversation),
      item('wal-inode', 60000000, CacheFootprintClass.mixed, source: CacheFootprintKind.conversation),
      item('shm-inode', 32768, CacheFootprintClass.mixed, source: CacheFootprintKind.conversation),
      item('public-image', 400000000, CacheFootprintClass.temporary, source: CacheFootprintKind.image),
      item('active-read', 150000000, CacheFootprintClass.temporary, source: CacheFootprintKind.file, inUse: true),
      item('offline-pinned', 90000000, CacheFootprintClass.protected),
    ], complete: true)!;
    expect(estimate.budgetBytes, 500000000);
    expect(estimate.measuredBytes, 1000032768);
    expect(estimate.temporaryBytes, 550000000);
    expect(estimate.inUseTemporaryBytes, 150000000);
    expect(estimate.protectedOrMixedBytes, 450032768);
    expect(estimate.definiteTemporaryExcessBytes, 50000000);
    expect(estimate.budgetClassificationComplete, isFalse);
    expect(estimate.confirmedReclaimableBytes, 0);
  });

  test('rejects incomplete scans, duplicate identities, invalid sizes and overflow', () {
    final one = item('one', 10, CacheFootprintClass.temporary);
    expect(CacheBudgetPolicyExperiment.estimate([one], complete: false), isNull);
    expect(CacheBudgetPolicyExperiment.estimate([one, one], complete: true), isNull);
    expect(CacheBudgetPolicyExperiment.estimate([item('', 1, CacheFootprintClass.temporary)], complete: true), isNull);
    expect(CacheBudgetPolicyExperiment.estimate([item('negative', -1, CacheFootprintClass.temporary)], complete: true), isNull);
    expect(CacheBudgetPolicyExperiment.estimate([one], complete: true, budgetBytes: -1), isNull);
    expect(CacheBudgetPolicyExperiment.estimate([
      item('a', 9007199254740991, CacheFootprintClass.temporary),
      item('b', 1, CacheFootprintClass.protected),
    ], complete: true), isNull);
  });

  test('reports protected overage without inventing candidates and prioritizes conversations', () {
    final estimate = CacheBudgetPolicyExperiment.estimate([
      item('drafts-and-receipts', 501, CacheFootprintClass.protected),
      item('conversation', 200, CacheFootprintClass.temporary, source: CacheFootprintKind.conversation),
      item('file', 150, CacheFootprintClass.temporary, source: CacheFootprintKind.file),
    ], budgetBytes: 500, complete: true)!;
    expect(estimate.protectedOrMixedExceedsBudget, isTrue);
    expect(estimate.budgetClassificationComplete, isTrue);
    expect(estimate.definiteTemporaryExcessBytes, 0);
    expect(estimate.confirmedReclaimableBytes, 0);
    expect(CacheFootprintKind.conversation.preservationPriority,
        greaterThan(CacheFootprintKind.file.preservationPriority));
  });
}
