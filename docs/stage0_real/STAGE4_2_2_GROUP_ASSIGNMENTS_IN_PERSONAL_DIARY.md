# Stage 4.2.2 - Group Assignments In Personal Diary

Date: 2026-06-20

Scope: show published group assignments from learning/chat in `Мой дневник` when they belong to the student's selected/current semester by `subject_offering_id`.

Not done: no personal student tasks, no `personal_tasks`, no `in_progress`/`submitted`, no RLS changes, no Supabase schema changes, no ChatScreen changes, no assignment bubble/creation changes, no git add, no commit.

## 1. Included Assignments

`PersonalDiaryService` now loads assignments only when all are true:

- `assignments.status = published`;
- `assignments.subject_offering_id in selected_semester_offering_ids`;
- `assignments.subject_offering_id is not null` by virtue of the selected offering id filter.

The selected offering ids come from `subject_offerings` for the active academic group and selected semester.

## 2. Excluded Assignments

Draft assignments are excluded because they are not approved group assignments yet.

Legacy assignments without `subject_offering_id` are excluded because they cannot be safely linked to a current-semester subject in the personal diary.

Assignments outside the selected/current semester are excluded because their `subject_offering_id` is not in the selected semester offering ids.

## 3. Data Model

Added `PersonalDiaryAssignment` in `lib/src/data/personal_diary_service.dart`.

Fields:

- `id`
- `subjectOfferingId`
- `subjectTitle`
- `title`
- `description`
- `dueAt`
- `dueText`
- `status`
- `completedByMe`
- `teamId`
- `messageId`
- `createdAt`
- `publishedAt`

No heavy attachment prefetch is performed.

## 4. Personal Diary Data

`PersonalDiaryData` now includes:

- `publishedAssignments`
- `upcomingAssignments`
- `totalAssignments`
- `pendingAssignmentsCount`
- `completedAssignmentsCount`

`PersonalDiarySubject` now includes:

- `assignmentCount`
- `incompleteAssignmentCount`

## 5. Assignment Counts

Hero/summary card:

- total assignments;
- completed assignments;
- remaining assignments.

Subject cards:

- assignment count per `subject_offering_id`;
- remaining count when there are unfinished assignments.

Counts are based only on published, selected-semester, offering-linked assignments.

## 6. Completed By Me

`completedByMe` is calculated from `assignment_done` for the current authenticated user.

The service reads:

- `assignment_done.assignment_id`
- `assignment_done.done`
- current user by `auth.currentUser.id`

It does not read or expose other students' done rows.

## 7. Done Toggle

`PersonalDiaryScreen` can toggle assignment completion from:

- the `Ближайшие задания` card;
- the assignment details bottom sheet.

The toggle calls the existing server-backed RPC:

```text
set_assignment_done(p_assignment_id, p_done)
```

After toggle, `PersonalDiaryScreen` refreshes its data.

The status remains personal because it is stored in `assignment_done` for the current user and not shown as a group list.

## 8. UI Changes

`PersonalDiaryScreen` now shows:

1. summary card at the top;
2. `Ближайшие задания`;
3. `Последние записи`;
4. `Дневники с записями`.

The assignment block:

- shows only published current-semester assignments;
- limits to the nearest 5 assignments;
- sorts assignments with `due_at` first, then no-deadline assignments by `created_at`;
- shows empty text when there are no eligible assignments.

Assignment cards show:

- title;
- subject;
- deadline;
- done/not done badge;
- done toggle button.

## 9. Assignment Details

Tapping an assignment opens a bottom sheet with:

- title;
- subject;
- deadline;
- description;
- personal done status;
- done/not done button.

No new large assignment screen was created.

No safe route to `TeamDetailsScreen` was added in this slice because `PersonalDiaryAssignment` intentionally remains a lightweight diary model and the existing team navigation requires a complete `Team` object.

## 10. Supabase Checks

Live DB read-only checks after implementation:

- total assignments: 3;
- draft assignments: 1;
- legacy assignments without `subject_offering_id`: 2;
- diary-eligible assignments: 1;
- `assignment_done` rows: 0 before runtime done-toggle testing.

The eligible row:

- `status = published`;
- `subject_offering_id` filled;
- `group_id` filled;
- `academic_year_id` filled;
- `academic_term_id` filled;
- `semester_number = 4`;
- linked `messages.assignment_id` exists.

This confirms the diary query should show one published, offering-linked assignment and exclude one draft plus one legacy/null-offering published assignment.

## 11. Verification

Focused analyze:

- command: `dart analyze` on `personal_diary_service.dart`, `personal_diary_screen.dart`, and related assignment files;
- result: no errors;
- remaining: 7 old infos in assignment details/tab files (`withOpacity`, deprecated `MaterialStatePropertyAll`).

IDE lints:

- no linter errors reported for changed diary files.

Build:

- `flutter build windows --debug`: passed.

Runtime UI:

- not driven directly by the agent in this environment;
- DB read-only checks confirm one eligible published assignment exists.

## 12. Files Changed

Flutter:

- `lib/src/data/personal_diary_service.dart`
- `lib/src/ui/profile/personal_diary_screen.dart`

Docs:

- `docs/stage0_real/STAGE4_2_2_GROUP_ASSIGNMENTS_IN_PERSONAL_DIARY.md`
- `docs/stage0_real/WORKLOG.md`
- `docs/stage0_real/STAGE0_REAL_INDEX.md`
- `docs/stage0_real/08_NEXT_STAGE_PLAN.md`

Snapshot:

- `docs/_snapshots/*`

## 13. Left For Stage 4.2.3

Stage 4.2.3 should add private student-created personal tasks only after choosing a clean storage model.

Still not done:

- personal task creation;
- `personal_tasks` schema;
- `in_progress` / `submitted` statuses;
- group-visible done lists;
- draft assignment display in the personal diary.
