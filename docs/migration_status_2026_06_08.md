# Migration Status 2026-06-08

- migration_001_core_academic_subjects applied successfully.
- migration_002_extend_existing_tables applied successfully.
- migration_003, migration_004, and migration_005 were not applied.
- Backfill was not executed.
- RPC, rollover, and auto-rename functions were not created.
- Flutter code was not changed during the migration application.
- Windows smoke-test was partially successful.
- No `column does not exist` or schema cache errors were found.
- Old table counts did not change.
- Next stage: RLS/security audit for the new tables before backfill.
