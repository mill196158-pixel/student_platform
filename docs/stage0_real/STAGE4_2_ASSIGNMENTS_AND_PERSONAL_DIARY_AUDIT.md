# Stage 4.2 - Assignments And Personal Diary Audit

Date: 2026-06-20

Scope: read-only audit of assignments, their current learning/chat flow, database shape, voting/completion behavior, files, and future integration with the personal student diary.

No Supabase schema, RLS, migrations, Flutter code, assignments, ChatScreen, PersonalDiaryScreen, data rows, `git add`, or commit were changed.

## 1. Audit Goal

The goal is to understand the existing assignment system before implementing assignments in `Мой дневник`.

Future product intent:

- group/chat assignments should appear in the student's personal diary only when they belong to the student's subject, group, and current semester;
- each student should have a private completion state;
- personal diary tasks created by a student should not be sent to group chat;
- trusted users such as starosta/owner/teacher/admin may publish group assignments directly;
- ordinary student suggestions should require approval or voting, for example 2 votes;
- group assignments should be linked by `subject_offering_id`, not by subject title.

## 2. Product Concept

Assignments should have two different surfaces:

- group assignments: shared objects created from the learning/chat context and visible to team members after approval;
- personal tasks: private student-owned tasks created inside the personal diary.

The personal diary should aggregate:

- current-semester subjects from `subject_offerings`;
- diary entries and files;
- nearest assignment deadlines;
- private status per student.

Assignments must not flood the diary. The diary should show focused blocks such as `Ближайшие задания`, `Мои задания`, and `Задания группы`, with filtering by current semester and status.

## 3. Found Flutter Files

Primary assignment files:

- `lib/src/ui/learning/models/assignment.dart`
- `lib/src/ui/learning/data/learning_repository.dart`
- `lib/src/ui/learning/data/supabase_learning_repository.dart`
- `lib/src/ui/learning/state/team_cubit.dart`
- `lib/src/ui/learning/team_details_screen.dart`
- `lib/src/ui/learning/tabs/assignments/assignments_tab.dart`
- `lib/src/ui/learning/tabs/assignments/assignment_card.dart`
- `lib/src/ui/learning/tabs/assignment_details_screen.dart`
- `lib/src/ui/learning/tabs/chat/assignment_bubble.dart`
- `lib/src/ui/learning/tabs/chat/assignments/assignment_form_dialog.dart`
- `lib/src/ui/learning/tabs/chat/assignments/edit_assignment_dialog.dart`
- `lib/src/ui/learning/tabs/chat/composer/chat_composer_bar.dart`
- `lib/src/ui/learning/tabs/chat_tab.dart`
- `lib/src/ui/learning/tabs/chat/message_builder.dart`
- `lib/src/ui/learning/tabs/chat/pinned_assignment_bar.dart`
- `lib/src/ui/learning/tabs/chat/pinned_strip.dart`

Legacy/duplicate assignment files also exist and should be treated carefully before editing:

- `lib/src/ui/learning/assignment_details_screen.dart`
- `lib/src/ui/learning/tabs/assignments_tab.dart`
- `lib/src/ui/learning/tabs/chat/plus_button.dart`

Related files:

- `lib/src/ui/learning/models/message.dart`
- `lib/src/ui/learning/models/team.dart`
- `lib/src/services/file_service.dart`
- `lib/src/services/s3_client.dart`
- `lib/src/data/personal_diary_service.dart`
- `lib/src/ui/profile/personal_diary_screen.dart`
- `lib/src/ui/schedule/subject_diary_screen.dart`

## 4. Found Supabase Tables

Assignment tables:

- `public.assignments`
- `public.assignment_votes`
- `public.assignment_done`

Related chat/team/file/academic tables checked:

- `public.messages`
- `public.chats`
- `public.teams`
- `public.team_members`
- `public.chat_members`
- `public.chat_files`
- `public.users`
- `public.subject_offerings`
- `public.groups`
- `public.student_enrollments`

Expected but not found:

- `public.chat_messages` does not exist. The active chat table is `public.messages`.
- No `assignment_files` table was found.

Small helper tables named `has_body`, `has_topic`, `has_extension`, `has_attachments`, `has_is_pinned`, `has_created_at`, `has_attachment`, and `has_reply_to` exist, but they are not assignment domain tables.

## 5. Current `assignments` Schema

Live columns:

- `id uuid`
- `team_id uuid`
- `author_id uuid`
- `title text`
- `body text`
- `due_at timestamptz`
- `status text`, check: `draft`, `voting`, `published`, `closed`
- `created_at timestamptz`
- `updated_at timestamptz`
- `published_at timestamptz`
- `due_text text`
- `attachments jsonb`
- `created_by uuid`
- `description text`
- `link text`
- `group_id uuid`
- `subject_id uuid`
- `subject_offering_id uuid`
- `academic_year_id uuid`
- `academic_term_id uuid`
- `semester_number integer`

Requested names that do not exist under those exact names:

- no `chat_id` column on `assignments`;
- no `deadline` column;
- no `files` column;
- no `is_pinned` column;
- no `is_approved` column;
- no stored `votes_count` column.

Current frontend mapping uses:

- title: `title`;
- description: `description`;
- link: `link`;
- due: `due_text`;
- attachments: `attachments`;
- published: `published_at is not null`;
- votes: count from `assignment_votes`;
- completed by current user: existence in `assignment_done`.

## 6. Current `assignment_votes` Schema

Live columns:

- `assignment_id uuid`
- `user_id uuid`
- `value smallint`, check: `-1` or `1`
- `created_at timestamptz`

Primary key:

- `(assignment_id, user_id)`

There is no `voter_id` column and no `vote_type` text column. The vote type is represented by `value`.

## 7. Current `assignment_done` Schema

Live columns:

- `assignment_id uuid`
- `user_id uuid`
- `done boolean`
- `done_at timestamptz`

Primary key:

- `(assignment_id, user_id)`

There is no `student_id`, `status`, `updated_at`, `in_progress`, `submitted`, or `closed` column.

Current DB model supports only a private done toggle, not a multi-step status.

## 8. Current Live Data

Project checked read-only through Supabase MCP: `gwdanmwluhrcfxbnplwd`.

Counts:

- `assignments`: 1
- `assignments.subject_offering_id` filled: 0/1
- assignments with `team_id` but no `subject_offering_id`: 1
- assignments with linked `messages.assignment_id`: 1
- assignment chat messages: 1
- `assignment_votes`: 2
- `assignment_done`: 0
- assignments with non-empty `attachments`: 0
- `chat_files` linked to assignment messages: 0

Observed assignment row:

- title: `ТЕСТ`;
- status: `draft`;
- `published_at`: null;
- `team_id`: filled;
- team name: `Надежность систем водоснабжения и водоотведения`;
- team `subject_offering_id`: null;
- main chat exists;
- chat `subject_offering_id`: null;
- `subject_offering_id`, `group_id`, `subject_id`, `academic_year_id`, `academic_term_id`, `semester_number`: all null;
- `created_by`: filled;
- `author_id`: null;
- `due_text`: `11.06`;
- `link`: filled;
- `attachments`: empty array;
- votes: 2;
- done rows: 0;
- linked message type: `assignmentDraft`.

This confirms the previous audit note: the only live assignment is team-centric and not offering-linked.

## 9. Current Assignment Creation Flow

Current active path:

1. User opens `TeamDetailsScreen`.
2. `TeamDetailsScreen` has tabs: `Задания`, `Чат`, `Файлы`.
3. `TeamCubit.init()` loads chat, files, assignments, and starosta status.
4. In `ChatTab`, `ChatComposerBar` shows `Новое задание` only when `state.isStarosta` is true.
5. `showAssignmentFormDialog` collects title, description, link, due date, and attachments.
6. `TeamCubit.proposeAssignment` calls RPC `propose_assignment`.
7. `propose_assignment` inserts into `assignments` and inserts an `assignmentDraft` row into `messages`.
8. Realtime reloads assignments and chat.

Server behavior in `propose_assignment`:

- inserts `team_id`, `title`, `description`, `link`, `due_text`, `attachments`, `created_by`;
- does not fill `subject_offering_id`, `group_id`, `subject_id`, academic fields, or `author_id`;
- finds `team_main` chat by `team_id`;
- inserts `messages` row with `type/msg_type = assignmentDraft` and `assignment_id`.

Other potential/legacy path:

- `lib/src/ui/learning/tabs/chat/plus_button.dart` contains an older `Предложить задание` flow with image picking.
- The currently inspected `ChatTab` uses `ChatComposerBar`, and the visible active compose path gates assignment creation by `state.isStarosta`.

No creation path was found in:

- `PersonalDiaryScreen`;
- `SubjectDiaryScreen`;
- `PersonalDiaryService`.

## 10. Current Voting Flow

Flutter:

- `TeamCubit.voteForPending()` votes for the latest pending assignment.
- `_voteAssignment()` writes directly to `assignment_votes` with `assignment_id`, `user_id`, and `value = 1`.
- It uses `upsert(... onConflict: assignment_id,user_id, ignoreDuplicates: true)`, so duplicate votes from one user should not create duplicate rows.
- If direct insert fails, it falls back to RPC `vote_assignment`.

Server:

- `vote_assignment(p_assignment_id)` attempts to insert into `assignment_votes`.
- The function then counts votes and sets `published_at = now()` when vote count is at least 2.

Important contradiction:

- `assignment_votes.value` is NOT NULL and has no default.
- `vote_assignment` inserts only `assignment_id` and `user_id`, so it can fail unless another default exists.
- Flutter comments explicitly say the direct insert was added to bypass the RPC problem.
- The direct insert path does not run the RPC threshold logic.
- No trigger on `assignment_votes` was found.
- Live data has 2 votes, but the assignment is still `draft` and the chat message is still `assignmentDraft`.

Conclusion: the desired “2 votes publish assignment” logic is not working reliably now.

## 11. Current Completion / Personal Status Flow

Flutter has two paths:

- `AssignmentsTab` toggles via `TeamCubit.toggleCompleted`, which calls RPC `set_assignment_done`.
- `AssignmentDetailsScreen` bottom button currently calls `markAssignmentDone`, which only updates local cubit state and does not call the RPC.

Server:

- `set_assignment_done(p_assignment_id, p_done)` inserts or deletes `assignment_done` for `auth.uid()`.
- `get_team_assignments` returns `completed_by_me` by checking `assignment_done` for current `auth.uid()`.

Privacy:

- `assignment_done` RLS select policies are self-only (`user_id = auth.uid()`).
- The current repository only reads `completed_by_me`, not a list of users who completed an assignment.
- The current group UI does not show who completed an assignment.

Limitation:

- status is boolean only: done/not done.
- There is no `not_started`, `in_progress`, `completed`, `submitted`, or `closed` per-user status column.

## 12. Assignment Links To Teams And Chats

Current hard link:

- `assignments.team_id -> teams.id`

Chat link:

- `assignments` has no `chat_id`;
- one chat card is represented by `messages.assignment_id`;
- `messages.assignment_id` has a unique index, so one assignment should have one message card;
- `messages.assignment_id` is not shown in the live schema output as a foreign key to `assignments`.

Current frontend:

- loads assignments by `get_team_assignments(p_team_id)`;
- loads main chat by `chats.team_id` and `type = team_main`;
- renders assignment messages by `MessageType.assignmentDraft` or `MessageType.assignmentPublished`.

## 13. Link To `subject_offering_id`

Live schema supports the desired academic identity:

- `teams.subject_offering_id` exists;
- `chats.subject_offering_id` exists;
- `assignments.subject_offering_id` exists;
- `chat_files.subject_offering_id` exists;
- `subject_diary_entries.subject_offering_id` exists.

Current assignment data does not use it:

- live assignment `subject_offering_id`: null;
- linked team `subject_offering_id`: null;
- linked chat `subject_offering_id`: null.

Flutter model gap:

- `Team` model does not include `subject_offering_id`;
- `get_my_teams` mapping in `SupabaseLearningRepository` does not map academic IDs into `Team`;
- `Assignment` model does not include `subject_offering_id`, `group_id`, `subject_id`, `status`, or `published_at`.

Stable future chain should be:

```text
teams.subject_offering_id
-> assignments.subject_offering_id
-> personal diary current semester subject_offerings
-> assignment_done or future personal status table
```

Risk:

- assignments created in legacy/non-academic teams or chat-only spaces cannot be safely shown in the personal diary unless they can be resolved to a current `subject_offering_id`.

## 14. Link To Personal Diary

Current personal diary:

- `PersonalDiaryService` loads active academic context, current/default semester, `subject_offerings`, `subject_diary_entries`, and `subject_diary_files`;
- `PersonalDiaryScreen` shows `Последние записи` and `Дневники с записями`;
- `SubjectDiaryScreen` is opened by `SubjectDiaryArgs` where possible;
- no assignment query is present.

Future insertion point:

- `PersonalDiaryService` should load assignments separately from diary entries;
- `PersonalDiaryData` can gain assignment summary fields;
- `PersonalDiaryScreen` can add separate blocks:
  - `Ближайшие задания`;
  - `Мои задания`;
  - `Задания группы`.

Do not mix assignments into `subject_diary_entries`. They are a different domain object.

## 15. Personal Tasks Possibility

Option A: use `assignments` with a future scope/type column.

- Pros: one assignment-like model.
- Cons: current table has no `scope`, `type`, or personal owner semantics; adding private personal tasks into `assignments` now would mix private diary tasks with group/team assignments.

Option B: create a future `personal_tasks` table.

- Pros: clean separation, private by default, can support diary-only tasks without chat messages.
- Cons: requires schema/RLS work in a later backend stage.

Option C: use `assignment_done` as personal layer over shared `assignments`.

- Pros: works for private state on group assignments.
- Cons: cannot represent student-created personal tasks because there is no shared assignment object to point to unless polluted into `assignments`.

Option D: no schema changes for MVP and defer personal task creation.

- Pros: safest if Stage 4.2 must avoid schema/RLS changes.
- Cons: does not satisfy personal task creation.

Audit recommendation:

- group assignments should stay in `assignments`;
- private status for group assignments can use `assignment_done` short-term, but it only supports done/not done;
- student-created personal tasks should probably be separate from `assignments` in a later schema stage, unless `assignments` is explicitly hardened with a reviewed `scope`/privacy model.

## 16. Assignment Files

Current group chat files:

- `FileService` uploads through backend-issued presigned URLs via edge function `generate-upload-url`;
- DB metadata is stored in `chat_files`;
- `chat_files` has academic columns including `subject_offering_id`.

Current assignment attachments:

- `Assignment.attachments` maps from `assignments.attachments`;
- form returns `List<Map<String,String>>`;
- `propose_assignment` stores the JSON directly;
- live assignment has empty attachments;
- no separate `assignment_files` table exists;
- no live `chat_files` row is linked to the assignment message.

Risk:

- assignment attachments are not normalized with `chat_files`;
- if attachments are local paths from old UI, they may not be durable after app restart/device change;
- diary display should not assume assignment attachment URLs are valid `chat_files`.

Future:

- group assignment files should be normalized either through `chat_files` plus `message_id`/`assignment_id`, or through a dedicated `assignment_files` table.

## 17. Chat Assignment Card

Current chat card exists.

Storage:

- `messages.msg_type` supports `assignmentDraft` and `assignmentPublished`;
- `messages.assignment_id` links the card to an assignment;
- `propose_assignment` inserts the message row;
- `publish_assignment` updates message `type/msg_type` to `assignmentPublished`.

Rendering:

- `message_builder.dart` renders `AssignmentBubble` when message type is `assignmentDraft` or `assignmentPublished`;
- `AssignmentBubble` looks up the actual assignment by `message.assignmentId` in `TeamCubit.state.assignments`;
- if no assignment is found, it renders nothing.

Important behavior:

- draft assignment bubbles are hidden from non-starosta users in `AssignmentBubble`;
- active creation UI in `ChatComposerBar` is shown only to starosta according to current `ChatTab` state;
- assignment cards are therefore real messages, but still depend on assignment list hydration to render.

Risk:

- if a message loses `assignment_id`, `_hydrateAssignmentIdsInChat` tries to guess by title from message text;
- this title-based fallback is fragile and should not be used for future durable logic.

## 18. Roles

Flutter role check:

- `TeamCubit._fetchIsStarosta` reads `team_members.role`;
- it treats `starosta`, `teacher`, `admin`, and `owner` as trusted.

Live data:

- `team_members.role` allowed values are `owner`, `starosta`, `member`;
- current role counts: all 289 `team_members` are `member`;
- `users.role` counts: all 34 users are `student`;
- no current live starosta/owner/admin/trusted assignment publisher was found.

Server:

- `publish_assignment` requires team membership role in `starosta`, `teacher`, `admin`, `owner`;
- because no live `team_members` row has such a role, manual publish through this RPC would be forbidden for current users;
- `propose_assignment` itself does not enforce starosta role; it inserts for `auth.uid()` and relies on membership/RLS/function behavior.

Product gap:

- trusted users are conceptually supported in code/RPC naming, but live data currently has no trusted role assignments.

## 19. Risks

Subject identity risk:

- current assignment row, team, and chat are not linked to `subject_offering_id`;
- Flutter `Team` and `Assignment` models do not carry academic IDs.

Voting risk:

- live 2 votes did not publish the assignment;
- direct Flutter vote insert bypasses RPC threshold;
- `vote_assignment` likely fails because it omits required `value`;
- there is no trigger to publish after direct votes.

Status risk:

- `assignment_done` only supports boolean done;
- `AssignmentDetailsScreen` updates local state only for the bottom done button;
- multi-status personal progress is not supported yet.

Role risk:

- current live `team_members` are all `member`;
- starosta/owner/admin/teacher publishing cannot be tested with current role data;
- `ChatTab` creation UI is starosta-gated, but `propose_assignment` itself is not a starosta-only RPC.

Files risk:

- assignment attachments are JSON, not normalized file rows;
- no `assignment_files` table;
- no current assignment file data to validate diary rendering.

Chat card risk:

- card is a real message, but rendering depends on a successful assignment lookup;
- title-based hydration fallback is fragile.

Security/RLS note:

- assignment tables have RLS enabled;
- many academic tables such as `groups`, `subject_offerings`, and `student_enrollments` still have RLS disabled, matching earlier audit findings;
- no RLS change was made in this audit.

## 20. Proposed Stable Model

For group assignments:

1. Use `subject_offering_id` as the primary academic link.
2. Derive assignment academic fields from `teams.subject_offering_id` when creating from a team/chat.
3. Store `assignments.subject_offering_id`, `group_id`, `subject_id`, `academic_year_id`, `academic_term_id`, and `semester_number` for new rows.
4. Show in personal diary only when the offering belongs to the student's active group and selected/current semester.
5. Show only published/trusted-approved assignments in diary.
6. Keep per-student completion private.

For voting:

1. Decide whether voting is direct table insert plus trigger, or RPC-only.
2. Do not split voting threshold between client and a broken fallback RPC.
3. A starosta/trusted assignment can bypass voting and publish immediately.
4. Ordinary student suggestion should create a draft/pending chat card and become published after threshold.

For personal tasks:

1. Prefer a future separate `personal_tasks` table for diary-only tasks.
2. Do not send personal tasks to chat.
3. If schema changes are not allowed, defer personal task creation rather than mixing private tasks into group `assignments`.

## 21. Stage 4.2.1-4.2.4 Plan

Stage 4.2.1 - Assignment data model hardening:

- update the assignment audit into an implementation design;
- decide minimal SQL/RLS/RPC changes separately;
- make creation fill `subject_offering_id` and academic fields;
- fix voting threshold path;
- decide whether boolean `assignment_done` is enough for MVP or a status model is required.

Stage 4.2.2 - Group assignments to personal diary:

- load current-semester published assignments by `subject_offering_id`;
- show nearest deadlines in personal diary;
- show per-subject unfinished count;
- let the student toggle personal status through the reviewed private status path.

Stage 4.2.3 - Personal tasks in diary:

- add student-created personal tasks only after choosing a clean storage model;
- keep them private and diary-only;
- allow linking to `subject_offering_id`;
- do not create chat messages.

Stage 4.2.4 - Chat assignment cards and voting:

- stabilize creation from chat;
- make server card/message authoritative;
- implement reliable voting threshold;
- let trusted roles publish directly;
- remove fragile title-based hydration assumptions.

## 22. What Not To Do Immediately

Do not immediately:

- connect all existing team assignments to the personal diary without `subject_offering_id`;
- infer subject identity from team name or assignment title;
- mix personal tasks into group assignments without a `scope`/privacy design;
- rely on the current 2-vote behavior;
- show assignment_done rows to the group;
- rewrite ChatScreen while adding diary aggregation;
- change RLS or schema in a UI-only slice;
- create or delete assignment data during implementation testing without an explicit test plan.

## 23. Can Implementation Start?

Yes, but only after splitting the work.

Safe first implementation stage is Stage 4.2.1: harden and design the assignment data contract. The current DB has the right nullable academic columns, but current creation does not fill them, voting threshold is inconsistent, and personal status is only boolean.

Stage 4.2.2 can then add a read path from published, offering-linked group assignments into the personal diary.

Personal task creation should wait for a separate decision because the current `assignments` table is group/team-oriented and would pollute group assignment semantics if used for private diary tasks without schema hardening.

## 24. Preflight Dirty Tree Notes

Preflight command: `git status --short`.

Working tree was already heavily dirty before Stage 4.2 audit. Unrelated dirty areas included platform files, many Flutter feature files, deleted legacy/vendor files, root SQL deletions, backup folders, assets, generated reports, Supabase files, and existing docs/snapshots.

Files/areas intentionally not touched:

- Flutter source code;
- `ChatScreen` / chat implementation;
- `PersonalDiaryScreen`;
- Supabase schema, functions, policies, migrations, and data;
- assignment rows, votes, done rows, messages, files;
- git staging/commit state.

Only Stage 0 REAL documentation and project snapshots are expected to change in this audit.
