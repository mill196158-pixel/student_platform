# Legacy To New Academic Migration Notes

This document records the transition from the old group/name based logic to the new academic architecture.

## Old Logic

The old application logic was based on text fields:

- `users.group_name`;
- `teams.group_name`;
- team name as subject name;
- automatic triggers that add users to teams/chats by matching `group_name`.

In the old model, a team could effectively mean:

```text
group name + subject name
```

This is fragile because names can repeat, change, or have aliases.

## New Logic

The new architecture uses stable IDs:

- active group membership: `student_enrollments`;
- canonical subject: `subject_catalog.id`;
- group-semester subject: `subject_offerings.id`;
- team for a subject: `teams.subject_offering_id`;
- chat for a team: `chats.team_id`;
- current semester: `group_term_semesters`.

The main rule:

```text
Team belongs to subject_offering_id, not to subject name text.
```

## Key Mapping

Old:

```text
users.group_name -> teams.group_name -> team name
```

New:

```text
auth.users.id
-> public.users.id
-> student_enrollments.group_id
-> group_term_semesters.semester_number
-> subject_offerings.id
-> teams.subject_offering_id
-> chats.team_id
```

## Legacy Side Effect

During student import, `public.users.group_name` was filled for compatibility with old Flutter screens.

Existing trigger:

- `trg_users_after_update`

reacted to `users.group_name` changes and automatically added imported students to old:

- `team_members`;
- `chat_members`.

This happened through old `group_name` matching. It is not part of the new academic architecture.

Decision:

- do not clean this automatically now;
- do not delete legacy teams now;
- do not delete legacy memberships now;
- cleanup must be a separate reviewed stage after the frontend fully moves to `subject_offering_id`.

## Current State After VV 2024 Import

Students:

- Auth users created through Admin API;
- `public.users` filled;
- `student_enrollments` created;
- `must_change_password = true` set.

Curriculum:

- `subject_catalog` created;
- `subject_aliases` created;
- `curriculum_subjects` created;
- `subject_offerings` created for all semesters.

Current semester teams:

- teams/chats created only for semester 4 subject offerings;
- teams linked by `teams.subject_offering_id`;
- team members added from active `student_enrollments`;
- chat members created through existing trigger.

Legacy:

- old teams/chats remain;
- old auto-created memberships remain;
- old triggers still exist.

## Frontend Migration Plan

1. Keep old fields for compatibility.
2. Build the new subjects screen through `subject_offerings`.
3. Open the new chat through `teams.subject_offering_id`.
4. Link assignments/files/diary/lessons to `subject_offering_id`.
5. Use `student_enrollments` to get the user's active group.
6. Use `group_term_semesters` to determine current, archived, and future subjects.
7. When the frontend fully uses new logic, separately review legacy triggers.
8. Only after review, disable or rewrite legacy triggers.
9. Only after review, clean old teams and memberships if needed.

## Triggers To Review Later

Known legacy triggers:

- `trg_users_after_insert`;
- `trg_users_after_update`;
- `trg_teams_after_insert`;
- `trg_team_members_after_insert_add_to_chat`;
- `team_members_after_insert_add_to_chat`.

They can automatically create or connect:

- team members;
- chat members;
- team main chats.

Do not remove them until old Flutter screens are verified against the new model.

## What New Code Should Do

New frontend/backend code should:

- use `subject_offering_id` for subject-specific screens;
- use `student_enrollments` for group membership;
- use `teams.subject_offering_id` to find the team;
- use `chats.team_id` to find the chat;
- use `subject_catalog.id` for canonical subject identity;
- treat `users.group_name` and `teams.group_name` as compatibility fields only.

New code should not:

- create teams from subject name strings;
- search subjects by raw text as a key;
- use `users.group_name` as the source of truth;
- directly insert into `auth.users`;
- delete legacy memberships without a cleanup plan.

## Migration Checklist

- [x] Staging tables created.
- [x] Student CSV loaded into staging.
- [x] Curriculum CSV loaded into staging.
- [x] Quality checks clean.
- [x] Auth users created.
- [x] `public.users` filled.
- [x] `student_enrollments` created.
- [x] Academic calendar created.
- [x] Group semesters created.
- [x] `subject_catalog` created.
- [x] `subject_aliases` created.
- [x] `curriculum_subjects` created.
- [x] `subject_offerings` created.
- [x] Current semester teams/chats created.
- [x] Post-checks clean.
- [x] `service_role` key not committed.

## Future Cleanup Checklist

Do this only after frontend migration:

- review old teams;
- review old chats;
- review legacy memberships;
- decide which legacy teams are still needed;
- decide whether to disable old group-name triggers;
- prepare dry-run cleanup checks;
- apply cleanup only after separate approval.
