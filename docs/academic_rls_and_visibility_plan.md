# Academic RLS And Visibility Plan

This plan prepares the security and visibility model before transferring VV 2024 data from staging tables into production academic tables.

## Current State

- `migration_001_core_academic_subjects` and `migration_002_extend_existing_tables` are applied.
- Staging tables are prepared for CSV import:
  - `public.stage_students_vv_2024`
  - `public.stage_curriculum_vv_2024`
- Final transfer from staging to production has not been written or run.
- Supabase Auth users, production users, groups, teams, chats, and team memberships must not be created during this stage.

## RLS Audit Summary

Read-only audit found that the new academic tables currently have RLS disabled and no policies:

- `academic_years`
- `academic_terms`
- `group_academic_profiles`
- `group_term_semesters`
- `subject_catalog`
- `subject_aliases`
- `subject_alias_review_queue`
- `curriculum_subjects`
- `subject_offerings`
- `student_enrollments`
- `teachers`
- `offering_teachers`

Checked old tables with nullable academic links:

- `users`
- `groups`
- `teams`
- `chats`
- `assignments`
- `chat_files`
- `lessons`
- `subject_diary_entries`

The compatibility columns added by `migration_002` are nullable, which is important for old Flutter compatibility.

`teacher_subjects` and `teacher_offerings` were not found as separate tables. The current teacher-to-offering link table is `offering_teachers`.

## Subject Identity Model

Subject names are not keys.

The canonical identity chain is:

- `subject_catalog.id` identifies a subject.
- `curriculum_subjects.subject_id` links curriculum rows to the canonical subject.
- `subject_offerings.subject_id` links a concrete group/term offering to the canonical subject.
- `teams.subject_offering_id` links an active team to one concrete offering.
- `chats.subject_offering_id`, `assignments.subject_offering_id`, `chat_files.subject_offering_id`, `lessons.subject_offering_id`, and `subject_diary_entries.subject_offering_id` isolate user-facing data by offering.

Teams must not be created from subject names alone.

## Why Not Create Teams/Chats For All Semesters

Creating teams and chats for all semesters would make future and archived subjects look active in the old app. It can also create noisy chats, duplicate memberships, and confusion around files, assignments, and unread counters.

The old Flutter flow is team/chat-centric. If every curriculum row creates a team, the UI cannot reliably distinguish active study from archived plan data without extra logic.

## Why Subject Offerings Can Exist For All Semesters

`subject_offerings` represent the academic plan for a concrete group and term. They can safely exist for semesters 1-4 because they are structure, not active communication spaces.

This lets the app or future v2 RPCs show:

- past subjects as archived/history;
- current semester subjects as active;
- future subjects as planned/upcoming.

## Team/Chat Creation Rule

For VV 2024 groups, the current semester is `4`.

Recommended rule:

- Create `subject_offerings` for all semesters 1-4.
- Create `teams`, `chats`, and `team_members` only for `subject_offerings` in the current semester.
- Do not create teams for archived or future semesters during the initial import.
- Add future semester teams later via a reviewed v2 RPC or admin operation.

## Visibility Status Recommendation

Do not add `subject_offerings.visibility_status`, `subject_offerings.is_current`, or `subject_offerings.is_archived` yet.

Prefer computing visibility from existing data:

- `subject_offerings.semester_number`
- `group_term_semesters.semester_number`
- active `student_enrollments`
- `academic_terms.starts_on`, `academic_terms.ends_on`, and `academic_terms.preload_starts_on`

This avoids storing duplicated state that can drift from the academic term model.

Recommended derived statuses:

- `current`: offering semester equals the group's active/current semester.
- `archived`: offering semester is lower than the group's active/current semester.
- `future`: offering semester is higher than the group's active/current semester.

If the UI later needs a manual override, add a separate reviewed column such as `visibility_status` with a check constraint. Do not add it before the first import unless derived visibility is proven insufficient.

## Frontend Behavior

Old Flutter should continue to use existing team/chat flows. New v2 UI/RPCs should:

- show active teams from `teams` linked to current `subject_offerings`;
- show archived/future subjects from `subject_offerings` without requiring teams;
- open chat/files/assignments only when a `team` and `chat` exist;
- avoid creating teams client-side;
- never infer subject identity from display name.

## Tables That Clients Should Not Write Directly

Regular client-side insert/update/delete should be blocked for academic structure tables:

- `academic_years`
- `academic_terms`
- `group_academic_profiles`
- `group_term_semesters`
- `group_name_history`
- `group_naming_profiles`
- `student_enrollments`
- `subject_catalog`
- `subject_aliases`
- `subject_alias_review_queue`
- `curriculum_subjects`
- `subject_offerings`
- `teachers`
- `offering_teachers`

Writes should go through reviewed admin workflows or v2 RPCs after security review.

## Proposed RLS Direction

Draft SQL is in:

`supabase/migrations/20260609093000_academic_rls_policies_draft.sql`

The draft proposes:

- enabling RLS on new academic tables;
- authenticated read access for basic reference tables;
- active-group-scoped read access for group academic metadata and `subject_offerings`;
- own-row read access for `student_enrollments`;
- admin manage policies based on Stage 12.1 RBAC (`private.can_manage_academic()` / `public.is_admin(auth.uid())`), not editable `users.role`;
- no regular client write policies for academic structure tables.

The draft must be reviewed before applying. It was not applied.

## Pre-Final-Import Checklist

Before transferring staging data into production tables:

- Review and apply a final RLS policy migration.
- Confirm old Flutter still works after RLS is enabled.
- Run `supabase/checks/academic_rls_audit.sql`.
- Import CSV files into staging tables only.
- Run `supabase/checks/stage_vv_2024_quality_checks.sql`.
- Resolve duplicate students and duplicate curriculum rows.
- Confirm group names and admission year `2024`.
- Confirm current semester number `4`.
- Confirm elective interpretation and whether elective options should create offerings.
- Define v2 RPC/import rules for:
  - creating/connecting `groups`;
  - creating `group_academic_profiles`;
  - creating `group_term_semesters`;
  - creating `subject_catalog` and `subject_aliases`;
  - creating `curriculum_subjects`;
  - creating `subject_offerings`;
  - creating current-semester `teams`, `chats`, and `team_members`.

## Risk To Old Flutter

Risk is low if the academic columns remain nullable and old team/chat policies are not changed.

Risk increases if RLS is enabled on old tables or if new academic table reads are required by old screens without matching policies. Keep old Flutter on current team/chat flows until v2 RPCs are ready.
