# Stage 4.2.1 - Assignment Model Hardening

Date: 2026-06-20

Scope: stabilize group assignments so new rows are diary-ready and chat assignments are normal `messages` rows rendered as `AssignmentBubble` inside the message list.

Not done: no personal diary integration, no personal student tasks, no personal multi-status UI, no RLS changes, no table/schema changes, no ChatScreen rewrite, no git add, no commit.

## 1. Team Model

`Team` now carries nullable academic fields:

- `subjectOfferingId`
- `groupId`
- `subjectId`
- `academicYearId`
- `academicTermId`
- `semesterNumber`

`SupabaseLearningRepository.loadTeams()` still calls existing `get_my_teams`, then safely enriches returned teams from `public.teams` by id. This avoids changing the `get_my_teams` RPC signature while making offering-linked teams available in Flutter.

Legacy teams with null academic fields still load normally.

## 2. Assignment Model

`Assignment` now carries nullable academic/status fields:

- `subjectOfferingId`
- `groupId`
- `subjectId`
- `academicYearId`
- `academicTermId`
- `semesterNumber`
- `status`
- `publishedAt`
- `dueAt`

Existing fields remain:

- `attachments`
- `votes`
- `completedByMe`
- `published`

`votesCount` is exposed as a getter over the existing `votes` field.

## 3. Supabase Assignment RPCs

Created:

- `supabase/stage4_2_1_assignment_model_hardening.sql`
- `supabase/stage4_2_1_assignment_model_hardening_rollback.sql`

Applied through Supabase MCP `execute_sql` on project `gwdanmwluhrcfxbnplwd`.

Changed RPCs:

- `get_team_assignments(uuid)`
- `propose_assignment(uuid,text,text,text,text,jsonb)`
- `publish_assignment(uuid)`
- `vote_assignment(uuid)`

No RLS policies, tables, columns, triggers, or migrations were changed.

## 4. Academic Field Fill

`propose_assignment` now reads `public.teams` by `p_team_id` and copies:

- `group_id`
- `subject_id`
- `subject_offering_id`
- `academic_year_id`
- `academic_term_id`
- `semester_number`

into the new `assignments` row.

If a team has `subject_offering_id = null`, the new assignment is still allowed as a legacy/team-only assignment, but it is not diary-ready for Stage 4.2.2.

Live DB check after hardening:

- total teams: 18
- teams with `subject_offering_id`: 10
- teams with `group_id`: 10
- teams with academic year/term/semester: 10

## 5. Chat Message Contract

The hard contract for chat assignments is:

```text
messages row
+ msg_type assignmentDraft or assignmentPublished
+ assignment_id
+ normal message rendering pipeline
+ AssignmentBubble inside message list
```

`propose_assignment` continues to create the assignment and its message row in one server path.

Message type:

- trusted user: `assignmentPublished`
- ordinary member: `assignmentDraft`

The chat UI does not create a separate floating assignment card. `message_builder.dart` continues to render `AssignmentBubble` only when a normal `Message` has `MessageType.assignmentDraft` or `MessageType.assignmentPublished`.

`TeamCubit.proposeAssignment()` now reloads assignments and chat after the RPC, so the message bubble appears even when realtime is slow.

## 6. Trusted Publishing

Trusted roles remain:

- `starosta`
- `teacher`
- `admin`
- `owner`

Flutter role detection still reads `team_members.role`.

Server behavior now also checks `team_members.role` in `propose_assignment`:

- trusted user creates a published assignment immediately;
- ordinary member creates a draft assignment;
- draft assignments require voting.

Live data note: current `team_members` are still all `member`; this was not changed.

## 7. Voting Threshold

Flutter no longer direct-upserts into `assignment_votes`.

`TeamCubit.voteFor()` and `voteForPending()` now call RPC `vote_assignment`.

`vote_assignment` now:

- inserts or updates `assignment_votes.value = 1`;
- counts positive votes;
- when votes are `>= 2`, sets `assignments.status = published`;
- fills `assignments.published_at`;
- updates the existing linked `messages` row from `assignmentDraft` to `assignmentPublished`;
- does not create a duplicate second message.

Read-only function check confirmed:

- `vote_assignment` mentions vote `value`;
- `vote_assignment` updates `assignmentPublished`;
- `propose_assignment` mentions `subject_offering_id`.

The existing live assignment was not migrated or force-published. It still has:

- `status = draft`
- `votes = 2`
- `subject_offering_id = null`
- linked message `msg_type = assignmentDraft`

This is intentional because Stage 4.2.1 only hardens new behavior and avoids unnecessary live data mutation.

## 8. AssignmentBubble

`AssignmentBubble` remains inside the normal message item flow.

Changes:

- draft bubbles are no longer hidden from ordinary members;
- ordinary members see a vote button on draft assignment bubbles;
- trusted users see edit/cancel/publish actions on draft bubbles;
- draft bubble shows vote count as `x/2`;
- published bubble shows published state;
- assignment lookup still uses `message.assignmentId`.

The old title-based hydration fallback remains only as compatibility for already-broken legacy cached messages. New assignment messages must use `assignment_id`.

## 9. Assignments Tab

The assignments tab still reads `assignments` as a list.

Changes:

- voting from an assignment card now calls `voteFor(a.id)` for the concrete assignment;
- draft vote chip uses the new `2` vote threshold;
- draft assignments do not pretend to be published.

This tab is not the source of chat cards. Chat cards come from `messages.assignment_id`.

## 10. Done / Completed By Me

Stage 4.2.1 keeps the existing boolean model.

The details screen path that previously updated local state only now writes through `set_assignment_done`.

`completed_by_me` is still returned by `get_team_assignments` from `assignment_done` for the current user. Group UI still does not show who completed an assignment.

Multi-status states such as `not_started`, `in_progress`, `done`, and `submitted` remain out of scope for Stage 4.2.1.

## 11. Pinned / Extra UI

`PinnedAssignmentBar` and pinned strip behavior were checked as secondary access surfaces.

They do not create assignment message rows and do not replace the main chat assignment bubble contract.

The main source for an assignment in chat is still:

```text
messages.assignment_id -> MessageBuilder -> AssignmentBubble
```

## 12. Runtime And Verification

Supabase verification:

- SQL hardening applied through MCP `execute_sql`.
- `get_team_assignments` returns `status`, `published_at`, `due_at`, `subject_offering_id`, `group_id`, `subject_id`, `academic_year_id`, `academic_term_id`, and `semester_number`.
- Live old assignment was checked read-only and not migrated.

Focused analyze:

- command: `dart analyze` over changed assignment/team/chat files;
- result: no analyzer errors;
- remaining: 24 warnings/infos, all old-style warnings such as `withOpacity`, deprecated `MaterialStatePropertyAll`, unnecessary import in `team_details_screen`, and unused optional key params.

IDE lints:

- no linter errors reported for changed files.

Build:

- `flutter build windows --debug`: passed.

Runtime UI:

- not run with authenticated dart-defines in this environment;
- no test assignment row was created through UI;
- no SQL seed was used.

## 13. Files Changed

Flutter:

- `lib/src/ui/learning/models/team.dart`
- `lib/src/ui/learning/models/assignment.dart`
- `lib/src/ui/learning/data/supabase_learning_repository.dart`
- `lib/src/ui/learning/state/team_cubit.dart`
- `lib/src/ui/learning/tabs/chat/assignment_bubble.dart`
- `lib/src/ui/learning/tabs/chat_tab.dart`
- `lib/src/ui/learning/tabs/assignments/assignments_tab.dart`
- `lib/src/ui/learning/tabs/assignments/assignment_card.dart`
- `lib/src/ui/learning/tabs/assignment_details_screen.dart`
- `lib/src/ui/learning/assignment_details_screen.dart`
- `lib/src/ui/learning/tabs/chat/pinned_assignment_bar.dart`

SQL:

- `supabase/stage4_2_1_assignment_model_hardening.sql`
- `supabase/stage4_2_1_assignment_model_hardening_rollback.sql`

Docs:

- `docs/stage0_real/STAGE4_2_1_ASSIGNMENT_MODEL_HARDENING.md`
- `docs/stage0_real/WORKLOG.md`
- `docs/stage0_real/STAGE0_REAL_INDEX.md`
- `docs/stage0_real/08_NEXT_STAGE_PLAN.md`

## 14. Left For Stage 4.2.2

Stage 4.2.2 should connect only published, offering-linked group assignments to the personal diary.

Required next work:

1. Load published assignments by current-semester `subject_offering_id`.
2. Show nearest assignment deadlines in `PersonalDiaryScreen`.
3. Show unfinished counts per subject.
4. Keep `assignment_done` private.
5. Do not include legacy assignments with null `subject_offering_id` in diary aggregation unless a reviewed migration/linking stage fixes them.

Stage 4.2.3 remains the place for private personal diary tasks.
