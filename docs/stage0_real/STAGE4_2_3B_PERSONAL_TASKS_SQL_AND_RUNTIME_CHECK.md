# Stage 4.2.3B - Personal Tasks SQL And Runtime Check

Date: 2026-06-20

## Scope

Stage 4.2.3B applied and verified the remote SQL for diary-only personal tasks.

No new feature work was started:

- no PDF export;
- no gamification;
- no assignment bubble changes;
- no ChatScreen changes;
- no assignment expansion beyond the existing Stage 4.2.1/4.2.2 behavior.

## SQL Application

SQL file:

- `supabase/stage4_2_3_personal_diary_tasks.sql`

Rollback file checked but not run:

- `supabase/stage4_2_3_personal_diary_tasks_rollback.sql`

Applied to live Supabase project:

- project id: `gwdanmwluhrcfxbnplwd`
- method: Supabase MCP `apply_migration`
- migration name: `stage4_2_3_personal_diary_tasks`
- result: success

The SQL creates `public.personal_diary_tasks` with:

- `id`
- `author_id`
- `subject_offering_id`
- `title`
- `description`
- `due_at`
- `status`
- `created_at`
- `updated_at`
- `completed_at`

`status` supports:

- `todo`
- `in_progress`
- `done`

Indexes verified:

- `personal_diary_tasks_author_idx`
- `personal_diary_tasks_author_subject_idx`
- `personal_diary_tasks_author_status_due_idx`
- primary key index

## RLS Verification

RLS is enabled on `public.personal_diary_tasks`.

Policies verified:

- `personal_diary_tasks_select_own`: `author_id = auth.uid()`
- `personal_diary_tasks_insert_own`: `author_id = auth.uid()`
- `personal_diary_tasks_update_own`: `author_id = auth.uid()`
- `personal_diary_tasks_delete_own`: `author_id = auth.uid()`

Privileges for `authenticated` were verified for:

- select;
- insert;
- update;
- delete.

Minimal self-only test through an `authenticated` role simulation:

- current user saw 2 own test rows;
- current user saw 0 other-user rows;
- current user updated 0 other-user rows;
- current user deleted 0 other-user rows.

## Authenticated Data Checks

Two test rows were created through an `authenticated` role simulation.

Task without subject:

- title: `Тест личной задачи без предмета`
- `author_id`: current simulated authenticated user id
- `subject_offering_id`: `null`
- `status`: `todo`

Task with subject:

- title: `Тест личной задачи по предмету`
- `author_id`: current simulated authenticated user id
- `subject_offering_id`: filled
- `status`: `todo`

Status transitions were verified on the personal task row:

- `todo -> in_progress`: status changed, `completed_at` stayed empty;
- `in_progress -> done`: status changed, `completed_at` was filled;
- `done -> todo`: status changed, `completed_at` was cleared.

After reload/readback, both test rows persisted in `personal_diary_tasks`.

## Separation From Group Assignment Data

After personal task creation:

- `messages` count did not change;
- `assignments` count did not change;
- `assignment_votes` count did not change;
- `assignment_done` count did not change.

Current assignment shape remains:

- total assignments: 3;
- published assignments: 2;
- draft assignments: 1;
- legacy null-`subject_offering_id` assignments: 2;
- diary-eligible published assignments: 1.

Stage 4.2.2/4.2.3 Flutter queries still only show published, `subject_offering_id`-linked group assignments in the diary paths.

## Runtime UI Status

The Windows app was not driven interactively by the agent in this environment.

What was verified:

- remote table exists;
- RLS and policies exist;
- authenticated role can create and update own rows;
- self-only RLS blocks access to another user's row;
- personal task rows persist;
- personal task inserts do not create messages, assignments, votes, or assignment_done rows;
- focused analyze passed with only existing infos;
- Windows debug build passed.

What still needs a human screen check:

- create a personal task from `Профиль -> Мой дневник -> + -> Личная задача`;
- create a subject-linked personal task from the diary UI;
- visually confirm it appears in `Мой дневник`;
- visually confirm it appears in `Дневник предмета`;
- visually confirm local search by subject, personal task, group assignment, and diary entry;
- visually confirm group assignment done toggle still works from the diary UI.

## Verification Commands

Focused analyze:

- command: `dart analyze lib/src/data/personal_diary_service.dart lib/src/ui/profile/personal_diary_screen.dart lib/src/ui/schedule/subject_diary_screen.dart`
- result: exit code 0;
- remaining diagnostics: 22 existing `withOpacity` info diagnostics in `subject_diary_screen.dart`;
- no errors or warnings.

Build:

- command: `flutter build windows --debug`
- result: passed;
- output: `build\windows\x64\runner\Debug\student_platform.exe`

## Not Done

- No Flutter code changes in Stage 4.2.3B.
- No manual RLS changes outside the stage SQL.
- Rollback was not run.
- UI runtime was not driven interactively.
