# Bulk Import CLI Usage

This document explains how to use `scripts/import_academic_batch.js` for future mass imports.

The CLI is safe by default: without `--apply`, it runs dry-run only and does not write production data.

## What The CLI Does

The CLI can run these steps:

- `preflight` checks staging, groups, terms, duplicates, and blocking issues.
- `auth` prepares Auth credentials and creates Supabase Auth users through Admin API.
- `students` fills `public.users` and creates active `student_enrollments`.
- `curriculum` creates `subject_catalog`, `subject_aliases`, `curriculum_subjects`, and `subject_offerings`.
- `teams` creates teams only for current-semester `subject_offerings`.
- `postcheck` verifies users, enrollments, offerings, teams, chats, and duplicates.
- `all` runs all steps.

## Safety Rules

- Default mode is dry-run.
- `--apply` is required for production writes.
- `--step all --apply` also requires `--confirm-full-import`.
- If blocked rows are found, apply is refused.
- Auth users are created only through Supabase Admin API.
- The CLI does not insert into `auth.users` by SQL.
- The CLI does not contain any service role key.
- Read secrets from `.env.local` or process environment only.
- Do not commit `.env.local`.
- Do not share `SUPABASE_SERVICE_ROLE_KEY`.
- Legacy cleanup is not automatic.

## Environment

Create local `.env.local`:

```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

This file is ignored by Git and must stay local.

## Config File

Example:

```json
{
  "batch": "vv_2024_sem4",
  "admission_year": 2024,
  "current_course": 2,
  "current_semester_number": 4,
  "current_academic_year": "2025/2026",
  "current_term_code": "20252",
  "groups": ["1-См(ВВ)-2", "2-См(ВВ)-2"],
  "students_stage_table": "stage_students_vv_2024",
  "curriculum_stage_table": "stage_curriculum_vv_2024",
  "auth_credentials_stage_table": "stage_student_auth_credentials_vv_2024",
  "technical_email_domain": "student.local",
  "initial_password_strategy": "login",
  "create_teams_for_current_semester": true,
  "create_teams_for_past_semesters": false,
  "create_teams_for_electives": false
}
```

Start by copying:

```bash
cp scripts/import_configs/vv_2024.example.json scripts/import_configs/vv_2024.json
```

Then edit the real config if needed. Do not put secrets in it.

## Prepare CSV

Students CSV should contain:

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

Curriculum CSV should contain:

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

## Load CSV Into Staging

Upload CSV only into staging tables:

- students into `public.stage_students_vv_2024`;
- curriculum into `public.stage_curriculum_vv_2024`.

Never upload directly into production tables like `public.users`, `subject_catalog`, or `teams`.

## Dry-Run Commands

Run all dry-runs:

```bash
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.example.json --step all --dry-run
```

Run one dry-run:

```bash
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.example.json --step preflight --dry-run
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.example.json --step auth --dry-run
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.example.json --step students --dry-run
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.example.json --step curriculum --dry-run
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.example.json --step teams --dry-run
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.example.json --step postcheck --dry-run
```

## Apply Commands

Apply one step at a time:

```bash
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step auth --apply
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step students --apply
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step curriculum --apply
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step teams --apply
```

Full apply is intentionally harder:

```bash
node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step all --apply --confirm-full-import
```

Use full apply only when you have already tested every step separately.

## What To Look For In Output

Each step prints JSON.

Important fields:

- `blocked`: must be `0` before apply.
- `blockedDetails`: first rows that need manual fix.
- `authUsersToCreate`: Auth users planned.
- `publicUsersToCreate`: app users planned.
- `enrollmentsToCreate`: active enrollments planned.
- `subjectCatalogToCreate`: subjects planned.
- `subjectOfferingsCandidates`: offerings planned.
- `teamsToCreate`: current-semester teams planned.
- `teamMembersToCreate`: active students to add.

If anything is blocked, stop and fix the data.

## When Apply Is Safe

Apply is safe only when:

- dry-run was executed;
- `blocked = 0`;
- counts match expectations;
- CSV was reviewed;
- stage tables contain only the intended batch;
- service role key is local only;
- you know which step you are applying.

## Logical Rollback

Do not panic-delete data.

If something goes wrong:

1. Stop.
2. Run the matching post-check.
3. Identify exactly which rows were created by the batch.
4. Prepare a separate read-only cleanup dry-run.
5. Review cleanup with another person or another agent.
6. Apply cleanup only after explicit approval.

For Auth users, remember that deleting users does not always invalidate all sessions immediately. Treat Auth cleanup as a separate security-sensitive step.

## Why Not Write Directly To `auth.users`

Supabase Auth owns `auth.users`.

Direct SQL inserts can skip password hashing, email confirmation logic, metadata handling, and internal Auth consistency.

Always use:

- Supabase Admin API;
- service role key;
- trusted server-side script only.

## Simple Instruction

1. Prepare students Excel.
2. Prepare curriculum Excel.
3. Export both to CSV.
4. Upload CSV to staging tables only.
5. Copy and edit config JSON.
6. Run `--step all --dry-run`.
7. Fix all blocked rows.
8. Run `--step auth --apply`.
9. Run `--step students --apply`.
10. Run `--step curriculum --apply`.
11. Run `--step teams --apply`.
12. Run `--step postcheck --dry-run`.

Never commit `.env.local`.
