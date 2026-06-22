# VV 2024 Staging Import

This document describes the safe intermediate import layer for VV 2024 students and curriculum data.

## CSV Files

- `supabase_stage_students_vv_2024.csv`
- `supabase_stage_curriculum_vv_2024.csv`

## Staging Tables

The local migration `supabase/migrations/20260609080000_create_vv_2024_staging_tables.sql` creates:

- `public.stage_students_vv_2024`
- `public.stage_curriculum_vv_2024`

These are staging tables only. They are not the final production tables.

## Current Scope

This step is only for preliminary CSV import and data-quality review.

It does not:

- insert into `public.users`;
- insert into `public.groups`;
- insert into `public.group_academic_profiles`;
- insert into `public.group_term_semesters`;
- insert into `public.subject_catalog`;
- insert into `public.curriculum_subjects`;
- insert into `public.subject_offerings`;
- create Supabase Auth users;
- run backfill;
- create RPC, rollover, or auto-rename functions;
- change old production data.

## Manual CSV Import

After applying the staging migration, import CSV files manually through Supabase Dashboard:

1. Open Supabase Dashboard for the project.
2. Go to Table Editor.
3. Open `public.stage_students_vv_2024`.
4. Use Import CSV and upload `supabase_stage_students_vv_2024.csv`.
5. Map CSV columns to same-name table columns.
6. Do not map service columns unless needed:
   `id`, `imported_at`, `import_batch_id`, `validation_status`, `validation_errors`.
7. Repeat the same steps for `public.stage_curriculum_vv_2024` with `supabase_stage_curriculum_vv_2024.csv`.

The service columns have defaults and can be left empty during import.

## Quality Checks

After CSV import, run the read-only checks in:

`supabase/checks/stage_vv_2024_quality_checks.sql`

The checks cover:

- students count by group;
- duplicate `login`;
- duplicate `record_book`;
- empty student names;
- empty student groups;
- `admission_year` not equal to `2024`;
- `current_semester_number` not equal to `4`;
- curriculum discipline counts by group and semester;
- empty `raw_subject_name` / `display_name`;
- duplicate disciplines in the same group and semester;
- electives list;
- curriculum rows with unexpected `admission_year`;
- curriculum rows with unexpected `current_semester_number`.

## Next Step

Final transfer from staging tables to real tables must be a separate reviewed migration after:

- quality checks are reviewed;
- RLS/security audit for the new academic tables is complete;
- import rules for Auth users, groups, enrollments, subjects, curriculum subjects, and offerings are confirmed.
