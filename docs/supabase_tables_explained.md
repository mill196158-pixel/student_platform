# Supabase Tables Explained

This document explains the main tables in simple words.

## `auth.users`

Purpose: technical Supabase account used for login.

Main key: `auth.users.id`.

Linked to: `public.users.id`.

Do not:

- insert into this table by SQL;
- update it manually during imports;
- expose service role keys in frontend code.

Create Auth users only through Supabase Admin API or trusted service role scripts.

## `public.users`

Purpose: user profile inside the app.

Main key: `id`, same UUID as `auth.users.id`.

Important links:

- `primary_group_id` points to `groups.id`;
- `login` is the student record book number;
- `group_name` is legacy compatibility only.

Do not:

- create a new row before Auth user exists;
- treat `group_name` as the real group source;
- overwrite important roles without review.

## `groups`

Purpose: study groups, for example `1-См(ВВ)-2`.

Main key: `id`.

Important links:

- `student_enrollments.group_id`;
- `subject_offerings.group_id`;
- `group_term_semesters.group_id`;
- `teams.group_id`.

Do not:

- duplicate group names;
- infer group identity from text when `group_id` is available.

## `student_enrollments`

Purpose: group membership history for students.

Main key: `id`.

Important links:

- `user_id` points to `public.users.id`;
- `group_id` points to `groups.id`.

Active group rule:

```sql
status = 'active'
and ended_at is null
```

Do not:

- use only `users.group_name` to determine active group;
- create two active enrollments for one student;
- close or transfer enrollments without explicit review.

## `academic_years`

Purpose: academic years, for example `2024/2025`.

Main key: `id`.

Important links:

- `academic_terms.academic_year_id`;
- `group_term_semesters.academic_year_id`;
- `subject_offerings.academic_year_id`;
- `teams.academic_year_id`.

Do not:

- create duplicate years;
- change dates after terms and offerings are connected without review.

## `academic_terms`

Purpose: academic terms, for example autumn or spring.

Main key: `id`.

Important links:

- `group_term_semesters.academic_term_id`;
- `subject_offerings.academic_term_id`;
- `teams.academic_term_id`.

Do not:

- guess a term by text only if `academic_term_id` is available;
- change term sequence casually.

## `group_academic_profiles`

Purpose: academic profile of a group, such as admission year and nominal semesters.

Main key: group-related profile row.

Important links:

- `group_id` points to `groups.id`.

Do not:

- use it as a student membership table;
- replace `student_enrollments` with it.

## `group_term_semesters`

Purpose: tells which semester a group has in each academic term.

Main key: `id`.

Important links:

- `group_id`;
- `academic_year_id`;
- `academic_term_id`;
- `semester_number`.

Do not:

- hardcode current semester in frontend when this table can answer it;
- create duplicate mappings for the same group and term.

## `subject_catalog`

Purpose: canonical subject dictionary.

Main key: `id`, also called `subject_id` in related tables.

Important links:

- `subject_aliases.subject_id`;
- `curriculum_subjects.subject_id`;
- `subject_offerings.subject_id`;
- `teams.subject_id`.

Do not:

- treat subject name as the key;
- create duplicate subjects with the same normalized name;
- create elective module headers as real subjects.

## `subject_aliases`

Purpose: stores alternative names for subjects.

Main key: `id`.

Important links:

- `subject_id` points to `subject_catalog.id`;
- `normalized_alias` is unique.

Do not:

- point one alias to multiple subjects;
- create duplicate aliases;
- use alias text as the primary subject key.

## `curriculum_subjects`

Purpose: subject rows from a curriculum plan.

Main key: `id`.

Important links:

- `subject_id` points to `subject_catalog.id`;
- `subject_offerings.curriculum_subject_id`.

Stores:

- semester;
- hours;
- credits;
- block/control metadata;
- elective metadata.

Do not:

- duplicate one curriculum subject per group when the row is the same;
- use it as the active class/team table;
- create teams from this table directly.

## `subject_offerings`

Purpose: one subject for one group in one semester.

Main key: `id`, also called `subject_offering_id`.

Important links:

- `subject_id`;
- `curriculum_subject_id`;
- `group_id`;
- `academic_year_id`;
- `academic_term_id`;
- `semester_number`;
- `teams.subject_offering_id`;
- future assignments/files/diary/lessons links.

Do not:

- replace it with subject name;
- create duplicate offerings for the same group, term, and subject;
- create teams without `subject_offering_id`.

## `teams`

Purpose: active team/class workspace for a subject offering.

Main key: `id`.

Important links:

- `subject_offering_id` points to `subject_offerings.id`;
- `group_id`;
- `subject_id`;
- `team_members.team_id`;
- `chats.team_id`.

Do not:

- create teams by raw subject name;
- create teams for semesters 1-3 when only current semester teams are needed;
- delete legacy teams without separate cleanup;
- rely on `group_name` as the main key.

## `chats`

Purpose: chat connected to a team.

Main key: `id`.

Important links:

- `team_id` points to `teams.id`;
- `subject_offering_id` can point to `subject_offerings.id`;
- `chat_members.chat_id`.

Do not:

- create duplicate `team_main` chats for one team;
- create chats before the team exists;
- use chats as the source of academic subject identity.

## `team_members`

Purpose: users inside a team.

Main key: `(team_id, user_id)`.

Important links:

- `team_id` points to `teams.id`;
- `user_id` points to `public.users.id`.

Do not:

- create duplicate memberships;
- add students to academic teams by `users.group_name` when active `student_enrollments` should be used;
- delete legacy memberships without a reviewed cleanup.

## `chat_members`

Purpose: users inside a chat.

Main key: `(chat_id, user_id)`.

Important links:

- `chat_id` points to `chats.id`;
- `user_id` points to `public.users.id`.

Do not:

- create duplicate chat memberships;
- add users to chats when the corresponding team membership does not exist;
- delete legacy chat memberships without review.

## `assignments`

Purpose: assignments for students.

Main key: assignment row `id`.

New academic link:

- should use `subject_offering_id`.

Do not:

- link new assignments only by subject name;
- assume one assignment belongs to every group with a similar subject name.

## `chat_files`

Purpose: files shared in chats or subject context.

Main key: file row `id`.

New academic link:

- should use `subject_offering_id` when the file belongs to a subject.

Do not:

- infer subject identity from filename or chat title;
- attach academic files only by subject text.

## `lessons`

Purpose: scheduled lessons/classes.

Main key: lesson row `id`.

New academic link:

- should use `subject_offering_id`.

Do not:

- schedule lessons by subject name only;
- mix group-specific lessons without `group_id` or offering context.

## `subject_diary_entries`

Purpose: subject diary entries.

Main key: diary entry row `id`.

New academic link:

- should use `subject_offering_id`.

Do not:

- use raw subject name as the link;
- mix entries from different groups or semesters.
