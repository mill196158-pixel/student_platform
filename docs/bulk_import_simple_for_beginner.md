# Bulk Import Simple For Beginner

This is the simple version. Use it when you need to remember the order and avoid dangerous actions.

## Short Version

You do not put students, subjects, or teams directly into the final tables.

You first load CSV files into stage tables. Then you run checks. Then you apply migrations step by step.

## Step 1. Prepare Excel With Students

Make a table with students.

Important columns:

- record book number;
- login;
- surname;
- name;
- patronymic;
- full name;
- group name;
- admission year;
- current course;
- current semester;
- role.

For this project:

- login = record book number;
- first password = record book number.

## Step 2. Prepare Excel With Curriculum

Make a table with subjects.

Important columns:

- group name;
- semester number;
- subject index;
- raw subject name;
- display subject name;
- credits;
- hours;
- control form;
- department;
- elective flags;
- whether the subject should be visible by default.

## Step 3. Convert Excel To CSV

Save both Excel files as CSV.

Use UTF-8 if possible.

## Step 4. Upload CSV Only To Stage Tables

Upload students to:

- `public.stage_students_vv_2024`

Upload curriculum to:

- `public.stage_curriculum_vv_2024`

Do not upload CSV directly to real production tables.

## Step 5. Run Checks

Run checks before moving data.

Important check files:

- `supabase/checks/stage_vv_2024_quality_checks.sql`
- `supabase/checks/vv_2024_preflight_before_import.sql`

If checks show problems, stop and fix the CSV or staging data.

## Step 6. Create Academic Years And Semesters

Create:

- academic years;
- autumn/spring terms;
- group semester mapping.

Use migrations:

- `supabase/migrations/20260609114500_seed_academic_years_terms_2024_2026.sql`
- `supabase/migrations/20260609115000_seed_vv_2024_group_terms.sql`

## Step 7. Create Student Logins

First create Auth credentials staging:

- `supabase/migrations/20260609121000_create_vv_2024_auth_credentials_stage.sql`

Then run:

- `scripts/create_vv_2024_auth_users.js`

This creates Supabase Auth users through the Admin API.

Do not insert into `auth.users` by hand.

## Step 8. Create App Users

After Auth users exist, import students into:

- `public.users`;
- `public.student_enrollments`.

Use:

- `supabase/migrations/20260609121500_add_users_must_change_password_draft.sql`
- `supabase/migrations/20260609120000_import_vv_2024_students_from_stage_draft.sql`

Then run:

- `supabase/checks/vv_2024_students_import_post_check.sql`

## Step 9. Create Subjects

Import curriculum into:

- `subject_catalog`;
- `subject_aliases`;
- `curriculum_subjects`;
- `subject_offerings`.

Use:

- `supabase/migrations/20260609123000_add_curriculum_subject_metadata_columns_draft.sql`
- `supabase/migrations/20260609123500_import_vv_2024_curriculum_from_stage_draft.sql`

Then run:

- `supabase/checks/vv_2024_curriculum_import_post_check.sql`

## Step 10. Create Teams

Create teams only for the current semester.

Use:

- `supabase/migrations/20260609124500_create_vv_2024_current_semester_teams_draft.sql`

Do not create teams for old or future semesters.

Do not create teams by subject name.

Teams must come from `subject_offering_id`.

## Step 11. Check Everything

Run post-checks:

- `supabase/checks/vv_2024_students_import_post_check.sql`
- `supabase/checks/vv_2024_curriculum_import_post_check.sql`
- `supabase/checks/vv_2024_current_semester_teams_post_check.sql`

Check that:

- students exist;
- enrollments exist;
- subjects exist;
- current teams exist;
- current chats exist;
- there are no duplicates.

## Never Do This

- Do not upload students straight into `public.users`.
- Do not insert rows by hand into `auth.users`.
- Do not create teams by subject name.
- Do not delete old teams without checking.
- Do not delete old memberships without checking.
- Do not commit `.env.local`.
- Do not show `SUPABASE_SERVICE_ROLE_KEY` to anyone.
- Do not paste the service role key into frontend code.

## Simple Mental Model

Student login goes through `auth.users`.

Student profile goes through `public.users`.

Student group goes through `student_enrollments`.

Subject identity goes through `subject_catalog`.

Subject for a group and semester goes through `subject_offerings`.

Team and chat go through `subject_offering_id`.
