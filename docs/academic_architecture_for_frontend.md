# Academic Architecture For Frontend

This document explains the new academic model for Flutter/frontend code.

## Main Rules

- A subject name is not a technical key.
- The main subject key is `subject_id`.
- A subject for a specific group in a specific semester is `subject_offering_id`.
- Teams are created only from `subject_offerings`.
- Chats, assignments, files, diary entries, and lessons should be linked to `subject_offering_id`.
- `users.group_name` exists only for legacy Flutter compatibility.
- The real active student group is stored in `student_enrollments` where `status = 'active'` and `ended_at is null`.
- `public.users.id` is linked to `auth.users.id`.

## Recommended Frontend Query Order

1. Load current auth user.
2. Load `public.users` by `id = auth.uid()`.
3. Load active `student_enrollments` for the user.
4. Load the user's `groups` row from the active enrollment.
5. Load `group_academic_profiles` for the group.
6. Load `group_term_semesters` for the group.
7. Use the current group semester to load `subject_offerings`.
8. Load `teams` and `chats` through `subject_offering_id`.
9. Load `assignments`, `chat_files`, `subject_diary_entries`, and `lessons` through `subject_offering_id`.

## Current Group

Do not trust only `public.users.group_name`.

Use:

```sql
select *
from public.student_enrollments
where user_id = :user_id
  and status = 'active'
  and ended_at is null;
```

Then use `student_enrollments.group_id` as the real current group.

## Current Semester

Use `group_term_semesters` for the user's active `group_id`.

Current semester is the active or current academic period for that group. For VV 2024 groups, current semester is `4`.

## Current Subjects

Current subjects come from `subject_offerings`.

Use:

- `subject_offerings.group_id = active group_id`;
- `subject_offerings.semester_number = current semester`.

Then join:

- `subject_catalog` by `subject_offerings.subject_id`;
- `curriculum_subjects` by `subject_offerings.curriculum_subject_id`.

## Archived And Future Subjects

Use derived visibility:

- current: `subject_offerings.semester_number = current group semester`;
- archived: `subject_offerings.semester_number < current group semester`;
- future: `subject_offerings.semester_number > current group semester`.

Do not add a separate UI status column until this derived model becomes insufficient.

## Teams And Chats

Teams are opened through `subject_offering_id`.

Recommended flow:

1. User picks a `subject_offering`.
2. Frontend loads `teams` where `teams.subject_offering_id = selected offering id`.
3. Frontend loads `chats` where `chats.team_id = team.id` and `chats.type = 'team_main'`.

Do not create teams by `subject_name` or display text.

## Why Not Search By Subject Name

Subject names can repeat, change, or have aliases. For example, the same canonical subject can appear with different raw names in source files.

Use IDs:

- `subject_id` for the canonical subject;
- `subject_offering_id` for a group-semester instance.

## Assignments, Files, Diary, Lessons

New frontend logic should prefer `subject_offering_id` links:

- assignments for an offering;
- files for an offering;
- diary entries for an offering;
- lessons for an offering.

Legacy team/chat links may remain for compatibility, but new academic screens should be offering-driven.

## Password Change

After login, frontend must check:

```sql
select must_change_password
from public.users
where id = auth.uid();
```

If `must_change_password = true`, force the student to change the temporary password before normal app usage.

For imported students:

- login = record book number;
- temporary email = `login || '@student.local'`;
- initial password = login;
- real email is added later by the student.

## Showing Curriculum Without Chat

`subject_offerings` can exist for all semesters. Teams/chats are created only for the current semester.

For archived or future subjects:

- show the curriculum card;
- show status as archived or future;
- hide or disable active chat actions if no team exists.

## Compatibility Fields

`public.users.group_name` and `teams.group_name` exist for old Flutter screens. They are not the source of truth.

New code should use:

- `student_enrollments.group_id`;
- `group_term_semesters`;
- `subject_offerings`;
- `teams.subject_offering_id`.
