/// Conservative admission arithmetic for a future cooperating Android news
/// writer. No filesystem access, eviction or runtime wiring is performed here.
/// The caller must independently prove the SQLite profile, bounds and complete
/// inventory. This does not enforce a quota on other writers or processes.
class NewsSqlitePeakEstimate {
  const NewsSqlitePeakEstimate(this.fileLengthBytes);
  /// Sum of file lengths, not allocated filesystem blocks or unlinked files.
  final int fileLengthBytes;
}

class NewsSqlitePeakBudget {
  static const int _maxInt64 = 9223372036854775807;

  /// [observedBytes] may already include the DB and sidecars: double counting
  /// is deliberately conservative. Null means unverified and is never zero.
  /// Assumes one bounded DELETE-journal transaction with no ATTACH,
  /// SAVEPOINT, VACUUM, runtime DDL, auto-vacuum, triggers, WAL or temp spill.
  /// This calculation cannot verify those conditions or the sector bound.
  static NewsSqlitePeakEstimate? estimate({required int? observedBytes,
    required int? maxDatabasePages, required int? pageSize,
    required int? maxSectorSize, required int? footerAllowance,
    required int? controlAllowance, required int? maxBlobBytes}) {
    if (observedBytes == null || maxDatabasePages == null ||
        pageSize == null || maxSectorSize == null || footerAllowance == null ||
        controlAllowance == null || maxBlobBytes == null || observedBytes < 0 ||
        maxDatabasePages <= 0 || pageSize < 512 || pageSize > 65536 ||
        (pageSize & (pageSize - 1)) != 0 || maxSectorSize < 512 ||
        footerAllowance < 0 || controlAllowance < 0 || maxBlobBytes <= 0) return null;
    int? add(int a, int b) => a < 0 || b < 0 || a > _maxInt64 - b ? null : a + b;
    int? multiply(int a, int b) => a < 0 || b < 0 || (b != 0 && a > _maxInt64 ~/ b) ? null : a * b;
    final pageRecord = add(pageSize, 8);
    final segmentCount = add(maxDatabasePages, 1);
    if (pageRecord == null || segmentCount == null) return null;
    final db = multiply(maxDatabasePages, pageSize);
    final records = multiply(maxDatabasePages, pageRecord);
    final headers = multiply(segmentCount, maxSectorSize);
    final alignment = multiply(segmentCount, maxSectorSize - 1);
    final blobs = multiply(maxBlobBytes, 2);
    if (db == null || records == null || headers == null || alignment == null || blobs == null) return null;
    int? total = observedBytes;
    for (final part in [db, records, headers, alignment, blobs, footerAllowance, controlAllowance]) {
      total = add(total!, part);
      if (total == null) return null;
    }
    return NewsSqlitePeakEstimate(total!);
  }
}
