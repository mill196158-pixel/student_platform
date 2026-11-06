/// Pure, disconnected accounting experiment. It reads no files and provides
/// no eviction candidates, authorization, storage limit or UI integration.
enum CacheFootprintClass { temporary, protected, mixed }

/// Categories describe preservation priority, not permission to delete.
enum CacheFootprintKind { conversation, homeSnapshot, image, file, other }

extension CacheFootprintPriority on CacheFootprintKind {
  /// Higher means retain earlier, if a future independently reviewed eviction
  /// policy can establish that an item is actually safe to remove.
  int get preservationPriority => switch (this) {
    CacheFootprintKind.conversation => 3,
    CacheFootprintKind.homeSnapshot => 2,
    CacheFootprintKind.image || CacheFootprintKind.file || CacheFootprintKind.other => 1,
  };
}

class CacheFootprintObservation {
  const CacheFootprintObservation({required this.physicalIdentity,
      required this.bytes, required this.classification, required this.kind,
      this.inUse = false});
  /// Opaque identity from a future trusted collector; do not use a path alone.
  final String physicalIdentity;
  final int bytes;
  final CacheFootprintClass classification;
  final CacheFootprintKind kind;
  final bool inUse;
}

class CacheBudgetEstimate {
  const CacheBudgetEstimate._({required this.budgetBytes, required this.measuredBytes,
      required this.temporaryBytes, required this.inUseTemporaryBytes,
      required this.protectedOrMixedBytes, required this.hasMixedComponents});
  final int budgetBytes;
  /// All submitted components, including protected components, after a
  /// caller asserts its collection is complete. This is not app storage.
  final int measuredBytes;
  final int temporaryBytes;
  final int inUseTemporaryBytes;
  final int protectedOrMixedBytes;
  final bool hasMixedComponents;
  /// Mixed SQLite/WAL bytes cannot be allocated accurately between classes.
  bool get budgetClassificationComplete => !hasMixedComponents;
  int get definiteTemporaryExcessBytes => temporaryBytes > budgetBytes
      ? temporaryBytes - budgetBytes : 0;
  bool get protectedOrMixedExceedsBudget => protectedOrMixedBytes > budgetBytes;
  /// No component is proven evictable by an accounting observation.
  int get confirmedReclaimableBytes => 0;
}

class CacheBudgetPolicyExperiment {
  static const int defaultBudgetBytes = 500000000;
  // Exact on Dart VM and JavaScript; reject rather than wrap/round.
  static const int _maxExactBytes = 9007199254740991;
  static const int _maxComponents = 100000;

  /// Null means incomplete, conflicting or invalid observations. The caller
  /// must establish classification, physical identity and completeness; none
  /// is inferred from paths, names or this method's input.
  static CacheBudgetEstimate? estimate(Iterable<CacheFootprintObservation> observations,
      {int budgetBytes = defaultBudgetBytes, required bool complete}) {
    if (!complete || budgetBytes < 0 || budgetBytes > _maxExactBytes) return null;
    final identities = <String>{};
    var count = 0, total = 0, temporary = 0, inUse = 0, protected = 0;
    var mixed = false;
    for (final item in observations) {
      if (++count > _maxComponents || item.physicalIdentity.isEmpty ||
          item.physicalIdentity.length > 512 || !identities.add(item.physicalIdentity) ||
          item.bytes < 0 || item.bytes > _maxExactBytes ||
          total > _maxExactBytes - item.bytes) return null;
      total += item.bytes;
      switch (item.classification) {
        case CacheFootprintClass.temporary:
          temporary += item.bytes;
          if (item.inUse) inUse += item.bytes;
        case CacheFootprintClass.protected:
          protected += item.bytes;
        case CacheFootprintClass.mixed:
          protected += item.bytes;
          mixed = true;
      }
    }
    return CacheBudgetEstimate._(budgetBytes: budgetBytes, measuredBytes: total,
        temporaryBytes: temporary, inUseTemporaryBytes: inUse,
        protectedOrMixedBytes: protected, hasMixedComponents: mixed);
  }
}
