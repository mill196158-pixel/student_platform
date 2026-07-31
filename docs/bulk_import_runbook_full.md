# Bulk Import Runbook Full

This is the full repeatable process for importing students and curriculum into the new academic architecture.

Never import CSV files directly into production tables. Always use staging, checks, draft migrations, and post-checks.

## Stage 1. Prepare Students CSV

Required fields:

- `record_book`
- `login`
- `surname`
- `name`
- `patronymic`
- `full_name`
- `group_name`
- `admission_year`
- `current_course`
- `current_semester_number`
- `current_academic_year`
- `role`

Recommended fields:

- `auth_email`
- `initial_password`
- `faculty`
- `direction`
- `program_profile`
- `qualification`
- `education_level`
- `study_form`
- `import_note`

Rules:

- `login` must be the record book number.
- `record_book` and `login` should match.
- Do not put real passwords into Git.
- Initial Auth password can be generated later as `login`.

## Stage 2. Prepare Curriculum CSV

Required fields:

- `group_name`
- `admission_year`
- `semester_number`
- `subject_index`
- `raw_subject_name`
- `display_name`
- `credits_total`
- `hours_total`
- `control_form`
- `department`
- `is_elective`
- `is_elective_option`
- `include_in_subject_catalog`
- `include_in_group_offerings_default`

Recommended fields:

- `block_name`
- `subject_type`
- `subject_kind`
- `elective_module_code`
- `is_elective_module_header`
- `import_order`
- `dedupe_key`
- `import_note`

Rules:

- Elective module headers are not real subjects.
- Elective options can be stored in `curriculum_subjects`.
- Elective options should become `subject_offerings` only when `include_in_group_offerings_default = true`.

## Stage 3. Load CSV Into Staging Only

Use staging tables:

- `public.stage_students_vv_2024`
- `public.stage_curriculum_vv_2024`

Do not load directly into:

- `public.users`
- `auth.users`
- `subject_catalog`
- `curriculum_subjects`
- `subject_offerings`
- `teams`
- `chats`

Migration used:

- `supabase/migrations/20260609080000_create_vv_2024_staging_tables.sql`

## Stage 4. Run Quality Checks

Run:

- `supabase/checks/stage_vv_2024_quality_checks.sql`
- `supabase/checks/vv_2024_preflight_before_import.sql`

Check:

- staging row counts;
- duplicate logins and record books;
- empty names and groups;
- group existence;
- academic year and term readiness;
- FK index readiness.

## Stage 5. Create Academic Years And Terms

Migration:

- `supabase/migrations/20260609114500_seed_academic_years_terms_2024_2026.sql`

Check:

- `supabase/checks/academic_years_terms_seed_check.sql`

## Stage 6. Create Group Academic Profiles And Terms

Migration:

- `supabase/migrations/20260609115000_seed_vv_2024_group_terms.sql`

Check:

- `supabase/checks/vv_2024_group_terms_check.sql`

This links groups to academic years, terms, and semester numbers.

## Stage 7. Create Auth Credentials Staging

Migration:

- `supabase/migrations/20260609121000_create_vv_2024_auth_credentials_stage.sql`

Check:

- `supabase/checks/vv_2024_auth_credentials_dry_run.sql`

Rules:

- Auth email = `login || '@student.local'`.
- Initial password = `login`.
- `need_password_change = true`.
- No direct SQL inserts into `auth.users`.

## Stage 8. Create Auth Users

Use Admin API script:

- `scripts/create_vv_2024_auth_users.js`

Requirements:

- `SUPABASE_URL` in local environment or `.env.local`;
- `SUPABASE_SERVICE_ROLE_KEY` in local environment or `.env.local`;
- never commit `.env.local`;
- never expose the service role key.

The script:

- reads `public.stage_student_auth_credentials_vv_2024`;
- creates Auth users through Supabase Admin API;
- writes `auth_user_id`;
- marks `created_in_auth = true`;
- records errors per row and continues.

## Stage 9. Import Students

Migrations:

- `supabase/migrations/20260609121500_add_users_must_change_password_draft.sql`
- `supabase/migrations/20260609120000_import_vv_2024_students_from_stage_draft.sql`

Checks:

- `supabase/checks/vv_2024_students_import_dry_run.sql`
- `supabase/checks/vv_2024_students_import_post_check.sql`

Rules:

- `public.users.id = auth.users.id`.
- New `public.users` require already-created Auth users.
- Real active group is `student_enrollments`.
- `users.group_name` is compatibility only.
- `must_change_password = true` for imported students.

## Stage 10. Import Curriculum

Migrations:

- `supabase/migrations/20260609123000_add_curriculum_subject_metadata_columns_draft.sql`
- `supabase/migrations/20260609123500_import_vv_2024_curriculum_from_stage_draft.sql`

Checks:

- `supabase/checks/vv_2024_curriculum_import_dry_run.sql`
- `supabase/checks/vv_2024_curriculum_import_post_check.sql`

Order:

1. `subject_catalog`
2. `subject_aliases`
3. `curriculum_subjects`
4. `subject_offerings`

Rules:

- `subject_catalog` is unique by normalized subject name.
- `subject_aliases` stores raw/display name variants.
- `curriculum_subjects` is distinct by curriculum subject identity, not by group.
- `subject_offerings` is per group and semester.
- Create `subject_offerings` for all semesters.
- Do not create teams/chats in this stage.

## Stage 11. Create Current Semester Teams And Chats

Migration:

- `supabase/migrations/20260609124500_create_vv_2024_current_semester_teams_draft.sql`

Checks:

- `supabase/checks/vv_2024_current_semester_teams_dry_run.sql`
- `supabase/checks/vv_2024_current_semester_teams_post_check.sql`

Rules:

- Create teams only for current semester `subject_offerings`.
- Do not create teams for semesters 1-3.
- Team is created only from `subject_offering_id`.
- Existing trigger creates `team_main` chats.
- Team members are added from active `student_enrollments`.
- Existing trigger creates `chat_members`.
- Do not delete legacy teams or memberships.

## Stage 12. Run Post-Checks

Run all relevant post-checks:

- `supabase/checks/vv_2024_students_import_post_check.sql`
- `supabase/checks/vv_2024_curriculum_import_post_check.sql`
- `supabase/checks/vv_2024_current_semester_teams_post_check.sql`
- `supabase/checks/vv_2024_preflight_before_import.sql`

Confirm:

- no missing users;
- no missing active enrollments;
- no duplicate active enrollments;
- no broken subject links;
- no duplicate subject offerings;
- current semester teams/chats exist;
- legacy teams are not deleted.

## Stage 13. Connect Frontend

Only after checks are clean:

- switch new subject screens to `subject_offerings`;
- open chats through `teams.subject_offering_id`;
- keep legacy fields only for compatibility;
- enforce `must_change_password`.

## Created SQL And Check Files

Migrations:

- `supabase/migrations/20260609080000_create_vv_2024_staging_tables.sql`
- `supabase/migrations/20260609103000_add_academic_fk_indexes.sql`
- `supabase/migrations/20260609114500_seed_academic_years_terms_2024_2026.sql`
- `supabase/migrations/20260609115000_seed_vv_2024_group_terms.sql`
- `supabase/migrations/20260609121000_create_vv_2024_auth_credentials_stage.sql`
- `supabase/migrations/20260609121500_add_users_must_change_password_draft.sql`
- `supabase/migrations/20260609120000_import_vv_2024_students_from_stage_draft.sql`
- `supabase/migrations/20260609123000_add_curriculum_subject_metadata_columns_draft.sql`
- `supabase/migrations/20260609123500_import_vv_2024_curriculum_from_stage_draft.sql`
- `supabase/migrations/20260609124500_create_vv_2024_current_semester_teams_draft.sql`
- `supabase/migrations/20260609093000_academic_rls_policies_draft.sql`

Checks:

- `supabase/checks/stage_vv_2024_quality_checks.sql`
- `supabase/checks/vv_2024_preflight_before_import.sql`
- `supabase/checks/academic_years_terms_seed_check.sql`
- `supabase/checks/vv_2024_group_terms_check.sql`
- `supabase/checks/vv_2024_auth_credentials_dry_run.sql`
- `supabase/checks/vv_2024_students_import_dry_run.sql`
- `supabase/checks/vv_2024_students_import_post_check.sql`
- `supabase/checks/vv_2024_curriculum_import_dry_run.sql`
- `supabase/checks/vv_2024_curriculum_import_post_check.sql`
- `supabase/checks/vv_2024_current_semester_teams_dry_run.sql`
- `supabase/checks/vv_2024_current_semester_teams_post_check.sql`
- `supabase/checks/academic_rls_audit.sql`

## Never Do This

- Do not insert directly into `auth.users`.
- Do not commit `.env.local`.
- Do not expose `SUPABASE_SERVICE_ROLE_KEY`.
- Do not create teams by subject name.
- Do not delete legacy teams or memberships without a separate reviewed cleanup.
- Do not use `users.group_name` as the source of truth for active group membership.
