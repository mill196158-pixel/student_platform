# Stage 4.2.1B - Assignment Persistence Fix

Date: 2026-06-20

Scope: fix disappearing assignment bubbles in chat by making assignment cards fully server-backed `messages` rows with durable `assignment_id`, and keep new assignment rows ready for Stage 4.2.2 personal diary integration.

Not done: no `PersonalDiaryScreen` integration, no personal student tasks, no new diary design, no RLS changes, no table/column changes, no ChatScreen rewrite, no git add, no commit.

## 1. Root Cause

Runtime symptom:

- assignment bubble appeared in chat after creation;
- after clicks/reload/refresh it disappeared.

The root cause was the chat fetch contract:

- `propose_assignment` did create a row in `assignments`;
- `propose_assignment` did create a row in `messages`;
- the message row had `messages.assignment_id`;
- realtime/direct `loadMessageById()` could see `assignment_id`;
- but `get_chat_messages_for_team()` did not return `assignment_id`, `chat_id`, `msg_type`, or `file_id`.

After `TeamCubit._reloadChatFromServer()` called `repo.loadChat()`, the server message came back without `assignment_id`. `MessageBuilder` could still see the type in some cases, but `AssignmentBubble` requires `message.assignmentId`; without it the bubble could not be reconstructed.

Secondary risk found:

- `_markDraftBubblePublished()` updated local chat and then called `repo.saveChat(state.team.id, chat)`;
- `saveChat()` sends the last message, so this could create a duplicate message path during publish.

## 2. Local-Only / Optimistic Path

No assignment bubble was created through `TeamCubit.sendMessage()`.

However, there was an unsafe local recovery path:

- `_hydrateAssignmentIdsInChat()` tried to infer a missing assignment id from message title text like `Черновик задания: ...`;
- this made a message look like an assignment bubble locally even when server fetch did not return `assignment_id`;
- after reload, the bubble could still disappear because the server contract was incomplete.

This title-based hydration is now removed for assignment ids.

## 3. SQL Changes

Created:

- `supabase/stage4_2_1b_assignment_persistence_fix.sql`
- `supabase/stage4_2_1b_assignment_persistence_fix_rollback.sql`

Applied through Supabase MCP `execute_sql` on project `gwdanmwluhrcfxbnplwd`.

Changed RPCs:

- `get_chat_messages_for_team(uuid, integer, timestamptz)`
- `propose_assignment(uuid, text, text, text, text, jsonb)`

No RLS policies, tables, columns, triggers, or migrations were changed.

## 4. Chat Fetch Contract

`get_chat_messages_for_team()` now returns:

- `id`
- `chat_id`
- `author_id`
- `author_login`
- `author_name`
- `author_avatar_url`
- `text`
- `type`
- `msg_type`
- `at`
- `created_at`
- `reply_to_id`
- `assignment_id`
- `file_id`
- `attachments`
- `reactions`
- `user_reactions`
- `is_pinned`

This lets `SupabaseLearningRepository._mapMessageRow()` map `assignment_id` from normal chat reloads, not only from direct message fetch.

## 5. Assignment Creation Contract

`propose_assignment()` now returns JSONB:

```json
{
  "assignment_id": "...",
  "message_id": "...",
  "msg_type": "assignmentDraft | assignmentPublished",
  "status": "draft | published",
  "published": false
}
```

It still creates assignment and message in one server transaction:

1. read `teams` by `p_team_id`;
2. resolve the `team_main` chat;
3. insert `assignments`;
4. insert `messages` with `assignment_id`;
5. return both ids.

If `team_main` chat is missing, the RPC raises `team_main_chat_not_found`, so it does not silently leave an assignment without a chat message.

## 6. Flutter Changes

`Message.fromJson()` now reads:

- `assignment_id` and `assignmentId`;
- `file_id` and `fileId`.

`TeamCubit.proposeAssignment()` now:

- expects `assignment_id` and `message_id` from the RPC;
- throws if either id is missing;
- reloads assignments;
- reloads chat from server;
- if the normal chat fetch is delayed, loads the returned `message_id` directly and merges it.

`ChatTab.onPropose` now catches create failures and shows a snackbar instead of allowing a fake success state.

`_hydrateAssignmentIdsInChat()` now only reconciles `assignmentDraft -> assignmentPublished` when a message already has a server `assignmentId`. It no longer invents `assignmentId` from the message title.

`_markDraftBubblePublished()` no longer calls `repo.saveChat()`, so publish no longer risks sending a duplicate message.

## 7. AssignmentBubble Hydration

`AssignmentBubble` still renders from:

```text
Message.type assignmentDraft/assignmentPublished
+ Message.assignmentId
+ TeamCubit.state.assignments
```

If the message has `assignment_id` but the assignment list has not hydrated yet, the bubble now shows a small server-message placeholder instead of disappearing:

- draft: `Задание загружается`;
- published/missing: `Задание недоступно`.

This keeps the chat message visible while assignment data catches up.

## 8. Draft / Published Behavior

Ordinary member assignment:

- `assignments.status = draft`;
- `messages.msg_type = assignmentDraft`;
- bubble shows draft/voting state.

Trusted assignment:

- `assignments.status = published`;
- `published_at` filled;
- `messages.msg_type = assignmentPublished`.

Two-vote threshold:

- `vote_assignment` keeps the Stage 4.2.1 behavior;
- two positive votes publish the assignment;
- the existing message row changes `assignmentDraft -> assignmentPublished`;
- no duplicate message is created.

## 9. DB Verification

Function check:

- `get_chat_messages_for_team` returns `assignment_id`;
- `propose_assignment` returns JSONB and includes `message_id`;
- both functions are `SECURITY DEFINER`;
- no RLS/table change was made.

Chat assignment fetch check:

- `get_chat_messages_for_team(...)` returned assignment message rows with:
  - `id`;
  - `chat_id`;
  - `assignment_id`;
  - `msg_type`;
  - `type`.

Integrity check:

- assignment messages: 3;
- orphan assignment messages: 0;
- assignments without message: 0.

Current aggregate:

- assignments total: 3;
- assignments with `subject_offering_id`: 1;
- published assignments: 2;
- diary-ready published assignments: 1;
- `assignment_done` rows: 0.

Observed latest rows:

- one draft assignment has `messages.msg_type = assignmentDraft`;
- one offering-linked published assignment has `subject_offering_id` filled, `2` positive votes, and `messages.msg_type = assignmentPublished`;
- one legacy published assignment still has null academic fields and should not be included in Stage 4.2.2 diary aggregation.

## 10. Personal Diary Readiness

New assignments created in offering-linked teams are ready for Stage 4.2.2 when they have:

- `status = published`;
- `subject_offering_id is not null`;
- `group_id is not null`;
- `academic_year_id is not null`;
- `academic_term_id is not null`;
- `semester_number is not null`.

Stage 4.2.2 should load only:

```sql
assignments.status = 'published'
and assignments.subject_offering_id is not null
```

and then filter by the student's current-semester `subject_offerings`.

## 11. Done / Completed By Me

No schema expansion was done.

The current done model remains:

- `assignment_done.assignment_id`;
- `assignment_done.user_id`;
- `assignment_done.done`;
- `get_team_assignments.completed_by_me`.

Current live `assignment_done` rows: 0.

## 12. Verification

Focused analyze:

- command: `dart analyze` over changed assignment/chat persistence files;
- result: no errors;
- remaining: 7 old infos in assignment details/tab files (`withOpacity`, deprecated `MaterialStatePropertyAll`).

IDE lints:

- no linter errors reported for changed files.

Build:

- `flutter build windows --debug`: passed.

Runtime UI:

- I did not drive the Windows app UI directly from this environment;
- live DB state shows runtime-created assignment/message rows exist and are linked.

## 13. Files Changed

Flutter:

- `lib/src/ui/learning/models/message.dart`
- `lib/src/ui/learning/state/team_cubit.dart`
- `lib/src/ui/learning/tabs/chat/assignment_bubble.dart`
- `lib/src/ui/learning/tabs/chat_tab.dart`

SQL:

- `supabase/stage4_2_1b_assignment_persistence_fix.sql`
- `supabase/stage4_2_1b_assignment_persistence_fix_rollback.sql`

Docs:

- `docs/stage0_real/STAGE4_2_1B_ASSIGNMENT_PERSISTENCE_FIX.md`
- `docs/stage0_real/WORKLOG.md`
- `docs/stage0_real/STAGE0_REAL_INDEX.md`
- `docs/stage0_real/08_NEXT_STAGE_PLAN.md`

## 14. Left For Stage 4.2.2

Stage 4.2.2 can now read published, offering-linked group assignments into the personal diary.

Do not include:

- draft assignments;
- legacy assignments with null `subject_offering_id`;
- personal student tasks, until Stage 4.2.3 chooses a private storage model.
