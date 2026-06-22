# Stage 0 REAL Index

## Correct Project

- Correct project path: `C:\student_platform`
- Previous wrong project: `C:\flutter_gen_ai_chat_ui`
- Pubspec name: `student_platform`
- Branch: `refactor/chat-tab`
- Remote: `origin https://github.com/mill196158-pixel/student_platform.git`

## Docs Inventory Summary

Existing docs found: yes. Stage 0 read 11 existing markdown files in `docs/` and did not overwrite them.

Key reusable docs:

- `docs/academic_architecture_for_frontend.md`
- `docs/academic_rls_and_visibility_plan.md`
- `docs/bulk_import_cli_usage.md`
- `docs/bulk_import_runbook_full.md`
- `docs/bulk_import_simple_for_beginner.md`
- `docs/CHAT_FAQ.md`
- `docs/legacy_to_new_academic_migration_notes.md`
- `docs/migration_status_2026_06_08.md`
- `docs/supabase_tables_explained.md`
- `docs/vv_2024_import_next_steps.md`
- `docs/vv_2024_staging_import.md`

Main docs issue: some files are older stage snapshots and conflict with later post-import notes and live DB.

## Code Summary

Flutter is not a blank skeleton. Existing modules include:

- auth/login/change password;
- bottom navigation;
- home/useful placeholder;
- learning/team list;
- team details with assignments/chat/files;
- direct chats/my chats;
- profile/edit profile;
- friends/classmates;
- schedule;
- subject diary;
- study plan/academic subjects in `exams_screen.dart`.

Academic-v2 logic is partial: study plan uses `student_enrollments` and `subject_offerings`, while learning/team/chat flows are still mostly team-centric and partly legacy-compatible.

## Supabase Summary

Live Supabase check succeeded through MCP for project `gwdanmwluhrcfxbnplwd`.

Key counts:

- `users=34`
- `groups=2`
- `student_enrollments=29`
- `subject_catalog=27`
- `subject_aliases=27`
- `curriculum_subjects=31`
- `subject_offerings=54`
- `teams=12`
- `chats=16`
- `messages=174`
- `lessons=176`
- `stage_students_vv_2024=29`
- `stage_curriculum_vv_2024=66`

Critical risk: many academic/public tables have RLS disabled, including `groups`, `student_enrollments`, `subject_catalog`, `curriculum_subjects`, `subject_offerings`, and `lessons`.

## Existing Features Summary

Reusable now:

- auth;
- profile;
- navigation;
- learning teams;
- team chat;
- files;
- assignments;
- direct chats;
- friends;
- schedule;
- diary;
- study plan.

Partial or placeholder:

- Useful materials;
- academic-v2 alignment for learning/team/chat;
- admin/import UI.

## Confirmed Academic Decisions

- Subject name is not a key.
- `subject_id` is canonical subject identity.
- `subject_offering_id` is group + semester subject identity.
- Active group comes from `student_enrollments`.
- `users.group_name` is legacy compatibility only.
- Teams/chats should be created for current-semester offerings.
- Archived/future subjects should be read from `subject_offerings` without active chat.
- Do not insert into `auth.users` by SQL.
- Do not expose service role keys in frontend.

## Current Risks

- RLS disabled on many academic tables.
- Docs contain stage-timeline contradictions.
- Chat FAQ is partially stale.
- Learning screen has hardcoded group code.
- Existing working tree was already dirty before Stage 0; unrelated changes must not be reverted.

## New Stage 0 Files

- `00_PROJECT_REALITY_CHECK.md`
- `01_EXISTING_DOCS_INVENTORY.md`
- `02_DOCS_CONTRADICTIONS_AND_FRESHNESS.md`
- `03_FLUTTER_CODE_MAP.md`
- `04_SUPABASE_CODE_USAGE_MAP.md`
- `05_SUPABASE_LIVE_SCHEMA_CHECK.md`
- `06_EXISTING_FEATURES_MAP.md`
- `07_ACADEMIC_DOMAIN_DECISIONS.md`
- `08_NEXT_STAGE_PLAN.md`
- `WORKLOG.md`
- `supabase_manual_check_stage0_real.sql`

Snapshot files were written to `docs/_snapshots/`.

## Next Stage

Recommended next stage:

**Stage 1: Academic frontend alignment, read-only first.**

Start by replacing hardcoded/legacy group context in learning flows with a read-only current academic context loader, while preserving current UI and avoiding schema/RLS/import changes.

## Stage 1 Update

Stage 1 added the first read-only academic context:

- model/service: `lib/src/data/academic_context_service.dart`;
- UI connection: `lib/src/ui/learning/learning_screen.dart`;
- documentation: `docs/stage0_real/STAGE1_ACADEMIC_CONTEXT.md`.

The Learning screen no longer uses the hardcoded `1-См(ВВ)-1` helper. It loads active academic context from `student_enrollments`, `groups`, and `group_term_semesters`, then shows group/semester/source in a small read-only block. Existing team/chat flow remains unchanged.

## Stage 2.0 Update

Stage 2.0 audited the existing schedule-to-subject link read-only:

- audit doc: `docs/stage0_real/STAGE2_SCHEDULE_SUBJECT_LINK_AUDIT.md`;
- actual schedule table: `public.lessons`;
- Flutter schedule flow: `ScheduleScreen` -> `get_my_lessons` -> `Lesson` -> `LessonCard` -> `LessonDetailsScreen`;
- direct FK coverage: `subject_id=0/176`, `subject_offering_id=0/176`;
- existing normalizer: live DB `public.f_norm_subject`, with related SQL checks using `subject_aliases`;
- no Flutter code, Supabase schema, RLS, migrations, import/apply scripts, git add, or commit were run.

Recommended next safe step: implement a read-only resolver for `lessons` -> `subject_offerings` using group + inferred lesson semester + normalized title/aliases, then open SubjectHub only for unique matches.

## Stage 2.1 Update

Stage 2.1 created and applied an idempotent dev/test seed for checking the link from current-semester study plan subjects to schedule lessons and teams/chats:

- seed: `supabase/dev_seed_test_schedule_subject_link.sql`;
- rollback: `supabase/dev_seed_test_schedule_subject_link_rollback.sql`;
- report: `docs/stage0_real/STAGE2_1_TEST_SUBJECT_SCHEDULE_LINK.md`;
- groups: `1-См(ВВ)-2`, `2-См(ВВ)-2`;
- current semester used: semester 4, `весна 2026`;
- subjects: `Тест 1`, `Тест 2`, `Проверка 1`, `Проверка 2`;
- subject offerings: 4;
- lessons: 8 total on `2026-06-19` and `2026-06-21`;
- lessons with `subject_id` and `subject_offering_id`: 8/8;
- teams/chats: 4 teams and 4 `team_main` chats, all linked to `subject_offering_id`;
- active group students are present in team/chat members; existing legacy trigger also added 2 legacy/non-active-by-enrollment members per test team/chat.

No Flutter code, Supabase schema, RLS, policies, migrations, auth users, parser rewrite, legacy cleanup, or chat module changes were made.

Recommended next safe step: Stage 2.2 should extend the schedule read path so `LessonDetailsScreen` can see `subject_offering_id`, display a small linked-state debug block, and open SubjectHub/team/chat for linked lessons.

## Stage 2.2 Update

Stage 2.2 extended the Flutter schedule read path without changing Supabase schema/RLS:

- report: `docs/stage0_real/STAGE2_2_SCHEDULE_READ_PATH_SUBJECT_LINK.md`;
- approach: Flutter enrichment adapter after `get_my_lessons`;
- `get_my_lessons` was not changed;
- `Lesson` now carries nullable `groupId`, `subjectId`, `subjectOfferingId`, `academicYearId`, `academicTermId`, `semesterNumber`, and `aliasMatchStatus`;
- `LessonCard` shows `Предмет связан` / `Не привязано`;
- `LessonDetailsScreen` shows a linked-state block and an `Открыть предмет` button;
- minimal `SubjectHubScreen` was added for checking the passed IDs;
- ChatScreen/chat module were not changed.

Recommended next safe step: Stage 3 should fill SubjectHub with real subject blocks, then connect existing team/chat through `subject_offering_id`.

## Stage 2.3 Update

Stage 2.3 added server-side schedule linking for future parser inserts and replaced the temporary debug SubjectHub path with user-facing subject information:

- report: `docs/stage0_real/STAGE2_3_SERVER_SCHEDULE_RESOLVER_AND_USEFUL_SUBJECT_INFO.md`;
- SQL: `supabase/stage2_3_schedule_subject_resolver.sql`;
- rollback: `supabase/stage2_3_schedule_subject_resolver_rollback.sql`;
- functions: `public.f_norm_schedule_subject`, `public.resolve_subject_offering_for_schedule`, `public.link_lesson_subject_from_schedule`;
- new parser test subjects: `Тест парсинга пары`, `Проверка парсинга пары`;
- new parser test lessons: 4 unresolved lessons on `2026-06-23`, linked by `link_lesson_subject_from_schedule`;
- verified offering IDs: `7e4bb6eb-e812-4b37-8ec0-1ce6f72bec8b` and `95fb3bc2-69b9-4805-8aad-ec700f4ae5ae`;
- schedule card no longer shows `Предмет связан` / `Не привязано`;
- lesson details opens `Информация о предмете` without exposing technical IDs;
- `Полезная` tab now lists current-semester `subject_offerings`.

No RLS, policies, tables, `get_my_lessons`, ChatScreen, chat module, or assignments flow were changed.

Recommended next safe step: Stage 4 should fill `Информация о предмете` with real useful materials/files and connect concrete subject data sources.

## Stage 3.1 Update

Stage 3.1 polished the `Полезная` tab and connected subject info to the existing chat flow:

- report: `docs/stage0_real/STAGE3_1_USEFUL_TAB_AND_SUBJECT_INFO_POLISH.md`;
- checked 6 Stage 2.1/2.3 test `subject_offering_id` values for duplicate teams/chats;
- result: each test offering has exactly one team and one `team_main` chat;
- no cleanup was performed; legacy/non-active extra members were only documented;
- `Открыть чат предмета` now opens existing `TeamDetailsScreen(initialTabIndex: 1)`;
- ChatScreen/chat module were not rewritten;
- `Полезная` now has a `Команды`/`Расписание`-style light header;
- `Полезная` loads all subject offerings for the active group and groups them by semester;
- current semester is selected by default;
- semester chips and control-form filters were added;
- subject cards now show title, semester, control form, description/placeholder, teacher, and `Материалы`/`Чат`/`Дневник` badges;
- `Информация о предмете` still contains brief info, teacher, useful files, chat, and diary, with no assignments.

No RLS, policies, tables, imports, test-data cleanup, ChatScreen, ScheduleScreen, or Learning tab rewrite were done.

Recommended next safe step: connect real useful files/materials and richer subject metadata.

## Stage 3.2 Update

Stage 3.2 simplified the `Полезная` UX and lesson-to-subject transition:

- report: `docs/stage0_real/STAGE3_2_USEFUL_TAB_STRUCTURE_AND_LESSON_LINK_UX.md`;
- `Полезная` now has two semantic blocks: `Предметы` and `Справка`;
- subject filter chips were replaced by dropdowns `Семестр` and `Тип`;
- defaults are current semester and `Все`;
- subject cards no longer have the extra `Открыть` button;
- subject cards open `Информация о предмете` by tapping the whole card;
- added static help cards for login, materials, certificates, software, map/audiences, and FAQ;
- `LessonDetailsScreen` no longer has a duplicate subject-info button;
- the whole `Информация о предмете` block in lesson details is clickable and has a right chevron.

No RLS, Supabase schema, parser, ChatScreen, ScheduleScreen rewrite, technical IDs, or assignments were added.

Recommended next safe step: fill `Справка` and `Полезные файлы` with real content/data sources.

## Stage 3.3 Update

Stage 3.3 polished the `Полезная` UX after design feedback:

- report: `docs/stage0_real/STAGE3_3_USEFUL_TAB_ADVANCED_UX.md`;
- removed the large `Предметы` / `Справка` switch from the screen body;
- moved section selection into a soft round button in the `Полезная` header;
- added a `Раздел` bottom sheet with `Предметы` and `Справка`;
- added a lightweight active-section intro under the header;
- replaced square dropdown fields with pill selectors for semester and type;
- semester and type are selected through bottom sheets with checks/accent state;
- subject cards now use a softer rounded/tinted design with a left subject initial, compact badges, and right chevron;
- subject cards remain clickable as a whole and do not restore the `Открыть` button;
- help entries remain local placeholders but are shown as polished instruction cards;
- `LessonDetailsScreen` keeps a clickable subject-info card without a duplicate button;
- `SubjectInfoScreen` keeps brief info, teacher, useful files, chat, and diary, without technical IDs or assignment blocks.

No RLS, Supabase schema, server functions, parser, ChatScreen, ScheduleScreen rewrite, technical IDs, or assignments were added.

Recommended next safe step: fill `Справка` and `Полезные файлы` with real reviewed content/data sources.

## Stage 3.4 Update

Stage 3.4 redesigned `Информация о предмете` into a modern, softer UI while preserving current data and routes:

- report: `docs/stage0_real/STAGE3_4_SUBJECT_INFO_FIGMA_UI.md`;
- added a strong subject hero-card with large initial, readable title/meta, gradient/tint, and chips;
- added quick actions for `Чат`, `Дневник`, and `Файлы`;
- `Файлы` quick action scrolls to the files block;
- chat action still opens the existing team/chat path only when a team/chat exists;
- diary action still opens existing `SubjectDiaryScreen`;
- added safe display getters to hide empty/technical values such as `dev`, `test`, `stage2_*`, and `*_resolver`;
- zero `credits`/`hours` are hidden;
- `Краткая информация` became a structured content-card with user-friendly placeholders;
- `Преподаватель` became a teacher-card with avatar placeholder and difficulty status;
- `Полезные файлы` became file-category rows for templates, examples, methodical materials, and uploaded files;
- `Чат` and `Дневник` became modern action-cards;
- added a soft, non-commercial help block at the bottom.

No RLS, Supabase schema, server functions, parser, ChatScreen, new packages, technical IDs, `Предмет связан`, or assignments were added.

Recommended next safe step: fill `Справка` and `Полезные файлы` with real reviewed content/data sources.

## Stage 3.5 Update

Stage 3.5 brought the `Полезная` body closer to the `Зачёты и экзамены` style and reduced empty-feeling subject info screens:

- report: `docs/stage0_real/STAGE3_5_USEFUL_EXAMS_STYLE_AND_SUBJECT_EMPTY_STATE.md`;
- `Полезная` header was not changed;
- bottom sheet selectors now return selected values and update parent state after the sheet closes;
- this addresses the likely semantics assertion trigger around `Navigator.pop()` plus immediate `setState`;
- compact quick action cards in `SubjectInfoScreen` were simplified by removing `Spacer`;
- `Полезная` body now uses a light background and a purple semester summary-card;
- summary metrics show disciplines, control forms, and chats;
- semester/type pill filters remain compact;
- selected semester is shown as an expansion-style section;
- subjects are grouped by control form: exams, credits, graded credits, practices, courseworks/KR, and other forms;
- subject cards are compact, clickable cards with a left initial, subtitle, control pill, files/diary/chat icons, and chevron;
- `Справка` now has a summary-card and grouped sections for access, documents, programs, map/audiences, and FAQ;
- `Информация о предмете` now uses a visible empty-content callout when data is missing;
- long empty file rows were replaced with one polished `Материалы пока не загружены` block.

No RLS, Supabase schema, server functions, parser, ChatScreen, ScheduleScreen, new packages, technical IDs, `Предмет связан`, `Открыть` button, or assignments were added.

Recommended next safe step: connect real reviewed help/material content and run runtime verification with Supabase dart-defines.

## Stage 3.5 Follow-up

The large purple `Выбранный семестр` card under the `Полезная` header was removed after visual review.

Replacement:

- compact academic context strip;
- group;
- semester;
- record book number from `users.login`.

The `Полезная` header itself was not changed. The subject list no longer uses the `ExpansionTile` wrapper that corresponded to the red runtime error area below the filters. A later compact pass removed `course` and the `Зачётка` prefix, leaving only group, semester, and the raw record book number. `dart analyze lib/src/ui/info/info_screen.dart` and `flutter build windows --debug` passed.

## Stage 3.6 Update

Stage 3.6 completed a control audit before moving to the personal diary stage:

- audit doc: `docs/stage0_real/STAGE3_6_FULL_LINKAGE_AND_USEFUL_AUDIT.md`;
- live DB functions exist: `f_norm_schedule_subject`, `resolve_subject_offering_for_schedule`, `link_lesson_subject_from_schedule`, `f_norm_title`, `f_norm_subject`;
- resolver test calls for both groups and all required seminar/practice/Teams variants returned `matched` with one candidate;
- all six Stage 2.1/2.3 test `subject_offerings` exist with correct group, semester 4, academic IDs, subject IDs, and curriculum subject IDs;
- all 12 test lessons on `2026-06-19`, `2026-06-21`, and `2026-06-23` are linked with `alias_match_status = matched`;
- every test offering has exactly one team and one `team_main` chat;
- legacy/non-active +2 members per test team/chat remain documented, not cleaned;
- Flutter read path, `Полезная`, `Информация о предмете`, lesson transition, and existing chat transition were checked in code;
- focused analyze found no issues in `info_screen.dart`, `subject_info_screen.dart`, and `lesson.dart`; schedule files still have existing warnings/infos;
- full `flutter analyze` still reports 356 existing project-wide issues;
- `flutter build windows --debug` passed;
- runtime UI verification remains blocked until valid local Supabase dart-defines are provided.

Important finding before production parser/server usage: effective execute privileges for `resolve_subject_offering_for_schedule` and `link_lesson_subject_from_schedule` are still available to `anon` and `authenticated` through PUBLIC execute. Stage 3.6 did not change DB privileges because it was audit/checkpoint only.

Next major stage:

**Stage 4 - Личный дневник текущего семестра.**

## Stage 4.0 Update

Stage 4.0 audited the existing subject diary before implementing a personal diary:

- audit doc: `docs/stage0_real/STAGE4_0_PERSONAL_DIARY_AUDIT.md`;
- existing subject diary files found: `lib/src/ui/schedule/subject_diary_screen.dart`, `lib/src/ui/schedule/subject_diary/*`, `lib/src/ui/schedule/diary_entry_details_screen.dart`, and `lib/src/data/subject_diary_repository_supabase.dart`;
- current subject diary opens from `LessonDetailsScreen` and `SubjectInfoScreen`;
- current subject diary API is `subjectKey`/display-name based and does not pass `subject_offering_id`;
- live diary tables found: `subject_diary_entries` and `subject_diary_files`;
- live diary entries: 4 total, 4 with `author_id`, 0 with `subject_offering_id`, 1 with `lesson_id`;
- live diary files: 7 total, all attached to one diary entry and all with `uploaded_by`;
- expected `user_id` columns are not present in the live diary tables; actual columns are `author_id` and `uploaded_by`;
- existing diary rows do not have `subject_id`, `group_id`, or `semester_number` filled;
- profile placement for Stage 4.1 should be under `Учёба`, directly after `Текущий семестр` and before `Карта СПБГАСУ`;
- Stage 4.1 can start safely as a conservative personal diary aggregator, but it must not assume existing diary rows are `subject_offering_id`-linked;
- Stage 4.2 should connect assignments later, because current assignments are team-centric and live rows are not `subject_offering_id`-linked.

No Flutter code, Supabase schema, RLS, assignments, ChatScreen, `git add`, or commit were changed in Stage 4.0.

## Stage 4.1 Update

Stage 4.1 implemented the personal diary MVP:

- report: `docs/stage0_real/STAGE4_1_PERSONAL_DIARY_MVP.md`;
- route added: `/my-diary`;
- screen added: `lib/src/ui/profile/personal_diary_screen.dart`;
- service added: `lib/src/data/personal_diary_service.dart`;
- profile now has `Мой дневник` in `Учёба`, after `Текущий семестр` and before `Карта СПБГАСУ`;
- `SubjectDiaryArgs` added for offering-aware subject diary navigation;
- `SubjectDiaryScreen` supports both `SubjectDiaryArgs` and legacy `subjectKey`;
- `SubjectQuickNoteScreen` and `SubjectPhotoConspectScreen` accept optional args;
- `SubjectInfoScreen` and `LessonDetailsScreen` now pass `subject_offering_id` into diary flows when available;
- new diary writes through the offering-aware path set `author_id = auth.uid()` and `subject_offering_id`;
- personal diary aggregates current-semester `subject_offerings`, entry counts, file/photo counts, and latest real entries;
- personal diary can switch between available semesters for the active group and defaults to the current semester;
- the subject diary list block is hidden when the selected semester has no subjects;
- empty-like entries are filtered from the personal diary;
- assignments, ChatScreen, Supabase schema, RLS, migrations, and legacy row migration were not changed.

Verification:

- focused analyze on changed files: no errors; existing warnings/infos remain;
- `flutter build windows --debug`: passed;
- runtime UI/test row creation was not performed because no authenticated app runtime with Supabase dart-defines was available.

Next stage:

**Stage 4.2 - connect assignments from learning/chat into the personal diary as a separate stage.**

## Stage 4.2 Audit Update

Stage 4.2 audited assignments before implementing diary integration:

- report: `docs/stage0_real/STAGE4_2_ASSIGNMENTS_AND_PERSONAL_DIARY_AUDIT.md`;
- Flutter code, Supabase schema/RLS/migrations, ChatScreen, PersonalDiaryScreen, and assignment data were not changed;
- assignment tables found: `assignments`, `assignment_votes`, `assignment_done`;
- `chat_messages` table was not found; current chat table is `messages`;
- live assignments: 1 total, 0/1 with `subject_offering_id`;
- live votes: 2; live done/status rows: 0;
- the live assignment is connected to `team_id` and one `messages.assignment_id` card, but team/chat/assignment `subject_offering_id` values are null;
- current personal status is boolean only through `assignment_done.done`;
- current personal diary code does not load assignments;
- active creation path is chat/team based through `propose_assignment`;
- current voting path is inconsistent: direct Flutter vote insert stores `value = 1`, while fallback `vote_assignment` owns the `>=2` threshold but omits `value`;
- no `assignment_votes` trigger was found, and the live assignment remains draft despite 2 votes;
- live `team_members` roles are all `member`, so starosta/trusted publishing is conceptually present but not represented in current data;
- assignment attachments are JSON in `assignments.attachments`; no `assignment_files` table was found.

Recommended next stages:

- Stage 4.2.1 - stabilize assignment data model and `subject_offering_id` fill path;
- Stage 4.2.2 - show published group assignments in the personal diary by `subject_offering_id`;
- Stage 4.2.3 - add private student personal tasks and subject diary assignments;
- Stage 4.2.4 - apply/verify personal task SQL and complete authenticated runtime checks.

## Stage 4.2.1 Implementation Update

Stage 4.2.1 hardened group assignment creation, voting, and chat bubble integration:

- report: `docs/stage0_real/STAGE4_2_1_ASSIGNMENT_MODEL_HARDENING.md`;
- SQL: `supabase/stage4_2_1_assignment_model_hardening.sql`;
- rollback: `supabase/stage4_2_1_assignment_model_hardening_rollback.sql`;
- `Team` now carries nullable `subjectOfferingId`, `groupId`, `subjectId`, `academicYearId`, `academicTermId`, and `semesterNumber`;
- teams are enriched from `public.teams` after existing `get_my_teams`, so the `get_my_teams` signature was not changed;
- `Assignment` now carries nullable status, due/published timestamps, and academic IDs;
- `get_team_assignments` returns `status`, `published_at`, `due_at`, `subject_offering_id`, `group_id`, `subject_id`, academic year/term IDs, and `semester_number`;
- `propose_assignment` fills new assignment academic fields from `teams`;
- assignment creation still creates a normal `messages` row with `assignment_id`;
- trusted roles create `assignmentPublished`; ordinary members create `assignmentDraft`;
- Flutter voting now uses RPC `vote_assignment`;
- `vote_assignment` writes `assignment_votes.value = 1`, publishes at 2 positive votes, and updates the existing message row to `assignmentPublished`;
- `AssignmentBubble` remains inside the normal message list and ordinary members can now see/vote on draft bubbles;
- `assignment_done` remains a private boolean completion layer;
- existing live assignment was not migrated or force-published;
- PersonalDiaryScreen and personal tasks were not changed.

Verification:

- Supabase RPC hardening applied through MCP `execute_sql`;
- focused analyze: no errors, 24 warnings/infos remain;
- `flutter build windows --debug`: passed;
- runtime UI was not run with authenticated dart-defines and no test assignment row was created.

Runtime assertion follow-up:

- After a Windows debug red screen with Flutter `_dependents.isEmpty`, `ChatMessageList` was adjusted to avoid wrapping the whole message/bubble subtree in `GlobalKey`.
- A small scroll marker `GlobalKey` remains, while the actual message subtree uses `ValueKey('message-${m.id}')`.
- Focused analyze for the chat assertion fix had no errors, and `flutter build windows --debug` passed.

## Stage 4.2.1B Implementation Update

Stage 4.2.1B fixed disappearing assignment bubbles by completing the server chat fetch contract:

- report: `docs/stage0_real/STAGE4_2_1B_ASSIGNMENT_PERSISTENCE_FIX.md`;
- SQL: `supabase/stage4_2_1b_assignment_persistence_fix.sql`;
- rollback: `supabase/stage4_2_1b_assignment_persistence_fix_rollback.sql`;
- root cause: `get_chat_messages_for_team` did not return `assignment_id`, so assignment messages could lose their bubble after normal chat reload;
- `get_chat_messages_for_team` now returns `chat_id`, `msg_type`, `assignment_id`, `file_id`, and `created_at`;
- `propose_assignment` now returns JSONB with `assignment_id`, `message_id`, `msg_type`, `status`, and `published`;
- Flutter now requires server `assignment_id` and `message_id` before treating assignment creation as successful;
- title-based local assignment-id hydration was removed;
- publish local helper no longer calls `saveChat`, so it cannot send a duplicate message;
- `AssignmentBubble` now keeps a server-message placeholder when assignment details are still hydrating;
- DB check: assignment messages = 3, orphan assignment messages = 0, assignments without message = 0;
- DB check: published, `subject_offering_id`-linked assignments = 1;
- PersonalDiaryScreen, personal tasks, RLS, and table schema were not changed.

Verification:

- focused analyze: no errors, 7 old infos remain;
- `flutter build windows --debug`: passed;
- IDE lints: no errors for changed files.

## Stage 4.2.2 Implementation Update

Stage 4.2.2 connected published group assignments to `Мой дневник`:

- report: `docs/stage0_real/STAGE4_2_2_GROUP_ASSIGNMENTS_IN_PERSONAL_DIARY.md`;
- `PersonalDiaryService` now loads only `published` assignments whose `subject_offering_id` belongs to the selected/current semester offerings;
- draft assignments are excluded;
- legacy assignments without `subject_offering_id` are excluded;
- `PersonalDiaryData` now contains published/upcoming assignments and assignment counts;
- `PersonalDiarySubject` now contains assignment count and incomplete assignment count;
- `PersonalDiaryScreen` shows a summary card with assignment totals;
- `PersonalDiaryScreen` shows `Ближайшие задания`;
- assignment cards support personal done toggle through existing `set_assignment_done`;
- assignment details open in a bottom sheet;
- PersonalDiaryScreen was changed, but ChatScreen, assignment creation, assignment bubble, voting, RLS, and schema were not changed;
- no personal student tasks were created.

Verification:

- DB check: 3 assignments total, 1 draft excluded, 2 null-offering legacy assignments excluded, 1 diary-eligible assignment included;
- focused analyze: no errors, 7 old infos remain;
- `flutter build windows --debug`: passed;
- IDE lints: no errors for changed diary files.

## Stage 4.2.3 Implementation Update

Stage 4.2.3 refined `Мой дневник`, added private personal task plumbing, and connected assignments/tasks to `Дневник предмета`:

- report: `docs/stage0_real/STAGE4_2_3_PERSONAL_TASKS_AND_SUBJECT_DIARY_ASSIGNMENTS.md`;
- SQL: `supabase/stage4_2_3_personal_diary_tasks.sql`;
- rollback: `supabase/stage4_2_3_personal_diary_tasks_rollback.sql`;
- `Мой дневник` hero-card no longer shows overloaded counters;
- hero-card shows current semester and record book number when `AcademicContext.recordBookNumber` is available;
- search was added to `Мой дневник`;
- `Дневники с записями` was renamed to `Предметы семестра`;
- subject cards now include records, files, group assignments, and personal task counts;
- `PersonalDiaryService` now separates `PersonalDiaryAssignment` from `PersonalDiaryTask`;
- personal task statuses are `todo`, `in_progress`, and `done`;
- personal tasks are stored in `personal_diary_tasks` and do not create chat messages;
- `Дневник предмета` header now uses the subject title and `Дневник предмета` subtitle;
- `Дневник предмета` now shows published group assignments and personal tasks for its `subject_offering_id`;
- search was added to `Дневник предмета`;
- draft assignments and legacy null-`subject_offering_id` assignments remain excluded;
- ChatScreen, assignment bubble, assignment creation, voting, PDF export, and gamification were not changed.

Verification:

- Supabase remote apply/check: not completed because MCP denied `execute_sql`, `apply_migration`, and read-only verification for this project;
- focused analyze: exit code 0; only existing `withOpacity` info diagnostics remain in `subject_diary_screen.dart`;
- `flutter build windows --debug`: passed;
- IDE lints: no errors for changed diary files.

## Stage 4.2.3B SQL And Runtime Check Update

Stage 4.2.3B applied and verified the remote `personal_diary_tasks` SQL:

- report: `docs/stage0_real/STAGE4_2_3B_PERSONAL_TASKS_SQL_AND_RUNTIME_CHECK.md`;
- SQL applied to live Supabase project `gwdanmwluhrcfxbnplwd` through MCP `apply_migration`;
- table `public.personal_diary_tasks` exists;
- RLS is enabled;
- self-only select/insert/update/delete policies exist;
- authenticated role privileges were verified;
- one general personal task and one subject-linked personal task were created through an authenticated role simulation;
- status transitions `todo -> in_progress -> done -> todo` were verified;
- `completed_at` is filled for `done` and cleared when moving away from `done`;
- personal task creation did not create rows in `messages`, `assignments`, `assignment_votes`, or `assignment_done`;
- group assignment DB shape remains unchanged: 3 assignments total, 1 diary-eligible published assignment, 1 draft assignment, 2 legacy null-`subject_offering_id` assignments;
- focused analyze passed with only existing `withOpacity` infos;
- `flutter build windows --debug` passed.

Not driven interactively by the agent:

- Windows UI creation from `Профиль -> Мой дневник`;
- visual search checks;
- visual group assignment done-toggle checks.

Next stage:

**Stage 4.2.4 - human UI runtime pass for personal tasks/search/group assignment diary behavior, then continue only after the checkpoint is accepted.**
