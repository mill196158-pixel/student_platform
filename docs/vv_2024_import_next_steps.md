# VV 2024 Import Next Steps

This is the proposed order for the VV 2024 staging import and final transfer. Do not skip review gates.

## Order

1. Apply the staging migration:
   `supabase/migrations/20260609080000_create_vv_2024_staging_tables.sql`

2. Import CSV files into staging tables only:
   - `supabase_stage_students_vv_2024.csv` -> `public.stage_students_vv_2024`
   - `supabase_stage_curriculum_vv_2024.csv` -> `public.stage_curriculum_vv_2024`

3. Run quality checks:
   `supabase/checks/stage_vv_2024_quality_checks.sql`

4. Run preflight checks:
   `supabase/checks/vv_2024_preflight_before_import.sql`

5. Apply FK index migration after review:
   `supabase/migrations/20260609103000_add_academic_fk_indexes.sql`

6. Seed academic years/terms and group term mappings:
   - `supabase/migrations/20260609114500_seed_academic_years_terms_2024_2026.sql`
   - `supabase/migrations/20260609115000_seed_vv_2024_group_terms.sql`

7. Prepare students import dry-run and draft migration:
   - `supabase/migrations/20260609121000_create_vv_2024_auth_credentials_stage.sql`
   - `supabase/checks/vv_2024_auth_credentials_dry_run.sql`
   - `scripts/create_vv_2024_auth_users.js`
   - `supabase/migrations/20260609121500_add_users_must_change_password_draft.sql`
   - `supabase/checks/vv_2024_students_import_dry_run.sql`
   - `supabase/migrations/20260609120000_import_vv_2024_students_from_stage_draft.sql`
   - `supabase/checks/vv_2024_students_import_post_check.sql`

8. Create Supabase Auth users through the Admin API only, after the Auth credentials dry-run is clean. Use technical email addresses in the form `login@student.local`; the initial password is the record book/login.

9. Rerun students import dry-run after Auth creation and review the counts for `public.users` and `student_enrollments`.

10. Review and apply RLS policies:
   `supabase/migrations/20260609093000_academic_rls_policies_draft.sql`

11. Only after successful checks, manual conflict review, and separate approval, apply the students import migration or replace it with a reviewed final version.

12. Prepare curriculum import separately after students import is verified. This includes:
   - `supabase/checks/vv_2024_curriculum_import_dry_run.sql`
   - `supabase/migrations/20260609123000_add_curriculum_subject_metadata_columns_draft.sql`
   - `supabase/migrations/20260609123500_import_vv_2024_curriculum_from_stage_draft.sql`
   - `supabase/checks/vv_2024_curriculum_import_post_check.sql`

13. Apply curriculum metadata/import only after separate approval. The curriculum import must stop at `subject_offerings` and must not create teams, chats, team members, or chat members.

## Safety Rules

- Do not import CSV directly into production tables.
- Do not create Supabase Auth users or passwords in the students import phase; Auth provisioning is a separate approved stage.
- Do not touch `auth.users` from SQL migrations.
- Use `public.users.login` as the student's record book number.
- Treat `public.student_enrollments` as the authoritative group membership history.
- Keep `public.users.group_name` and `public.users.primary_group_id` as compatibility/fast-access academic fields.
- Do not create `groups`, `teams`, `chats`, or `team_members` during students import.
- Do not run backfill until quality checks and RLS policies are approved.
- Keep old Flutter behavior on existing team/chat flows.

## Legacy Team/Chat Side Effect

The students import filled `public.users.group_name` for the VV 2024 students. Existing legacy trigger `trg_users_after_update` reacts to `users.group_name` changes and automatically adds users to old `team_members` and `chat_members` for existing teams/chats with the same `group_name`.

This is legacy behavior and is not part of the new academic architecture. New curriculum import must not create, update, or delete `teams`, `chats`, `team_members`, or `chat_members`. Cleanup of old memberships/teams should be a separate reviewed stage after the app moves to `subject_offering_id` based visibility.

Current decision: keep the automatically created legacy memberships as-is; do not roll them back during curriculum import preparation.

## Students Import Scope

The Auth stage is limited to:

- preparing `public.stage_student_auth_credentials_vv_2024` from `public.stage_students_vv_2024`;
- creating Supabase Auth users through the Admin API/service role, never by direct SQL into `auth.users`;
- using `public.stage_student_auth_credentials_vv_2024.auth_email = login || '@student.local'`;
- using the record book/login as the temporary password;
- storing `need_password_change = true` in credentials and Auth user metadata for later frontend handling.

The `public.users` and enrollment import is limited to:

- creating or updating compatible fields in `public.users` for staging students;
- creating active `public.student_enrollments` rows for the resolved group;
- skipping rows with missing groups, missing required Auth identities for new `public.users`, or active enrollments in a different group;
- preserving existing critical user data unless the dry-run shows it is compatible.

Because `public.users.id` references `auth.users.id`, new `public.users` rows cannot be created without an existing Auth identity. The draft migration does not create Auth users and therefore can insert new `public.users` only when a matching `auth.users.email` already exists. Creating Auth users and initial passwords must remain a separate reviewed process.

## Curriculum Transfer Scope

The curriculum transfer should be a separate reviewed migration or admin-only RPC set. It should define explicit rules for:

- connecting or creating groups;
- creating `group_academic_profiles`;
- creating `group_term_semesters`;
- creating `subject_catalog` and `subject_aliases`;
- creating `curriculum_subjects`;
- creating `subject_offerings` for semesters 1-4;
- not creating `teams`, `chats`, `team_members`, or `chat_members` during curriculum import.

The current `curriculum_subjects` production schema is narrower than the VV 2024 staging data. It lacks these staging metadata fields:

- `subject_index`;
- `block_name`;
- `control_form`;
- `department`;
- `subject_type`;
- `subject_kind`;
- `is_elective`;
- `elective_module_code`.

Use `supabase/migrations/20260609123000_add_curriculum_subject_metadata_columns_draft.sql` if these fields should be preserved for UI/filtering before applying the curriculum import.

## Visibility Rule

Use derived visibility for now:

- current: `subject_offerings.semester_number = group_term_semesters.semester_number`;
- archived: offering semester is lower than the current group semester;
- future: offering semester is higher than the current group semester.

Do not add `visibility_status`, `is_current`, or `is_archived` until derived visibility is proven insufficient.
