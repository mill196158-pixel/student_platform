# 07 Academic Domain Decisions

These decisions are gathered from existing docs and checked against live schema/code where possible.

## Confirmed Rules

- Subject name is not a key.
- `subject_id` means the canonical subject in `subject_catalog`.
- `subject_offering_id` means a subject for a concrete group and semester.
- Active group comes from `student_enrollments` where `status = 'active'` and `ended_at is null`.
- `users.group_name` is legacy compatibility only.
- `teams.group_name` is legacy compatibility only.
- Teams must be created from `subject_offering_id`, not from subject display text.
- Chats go through `teams` and `chats`; the main team chat is tied to a team.
- Assignments, files, diary entries, and lessons should link through `subject_offering_id` for new academic work.
- Teams/chats should exist only for current-semester active offerings.
- Archived/future subjects should come from `subject_offerings` without requiring an active team/chat.
- Derived visibility is preferred: current/archived/future is computed from offering semester and group term semester.
- Do not insert into `auth.users` by SQL.
- Supabase Auth users must be created through Admin API/trusted scripts only.
- Service role belongs only in trusted local/server scripts.
- Do not expose service role keys in frontend.

## Confirmed By Live DB

- Academic tables exist.
- Compatibility columns exist on user-facing tables, including `subject_offering_id` on `teams`, `chats`, `assignments`, `chat_files`, `lessons`, and `subject_diary_entries`.
- VV 2024-related production rows exist in `users`, `student_enrollments`, `subject_catalog`, `subject_aliases`, `curriculum_subjects`, `subject_offerings`, `teams`, `chats`, memberships, and staging tables.
- `rpc_get_my_subjects_v2` and `rpc_vote_subject_difficulty_v2` exist, supporting academic-v2 study plan work.

## Not Yet Fully Implemented In Flutter

- Learning team list still has a hardcoded group code helper.
- Team/chat/assignment/file flows are still mostly team-centric.
- The study plan screen is the clearest existing subject-offering-driven frontend module.
- Useful materials have no found DB-backed implementation.

## Security Boundary

Academic tables currently have RLS disabled in live DB. Stage 0 does not change RLS, but Stage 1+ must not assume exposed academic reads/writes are production-safe until policy work is reviewed and tested.
