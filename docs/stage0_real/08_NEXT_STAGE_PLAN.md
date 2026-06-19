# 08 Next Stage Plan

## Can Flutter Stage 1 Start?

Yes, Flutter Stage 1 can start in `C:\student_platform`, but it should not start by creating a new skeleton. The app already has a substantial Flutter structure and live Supabase data.

The safest Stage 1 is an integration/refinement stage, not a greenfield scaffold stage.

## Do We Need A Skeleton?

No. Reuse the existing app shell:

- `lib/main.dart`
- `lib/src/ui/navigation/navigation_screen.dart`
- `lib/src/ui/authentication/*`
- `lib/src/ui/learning/*`
- `lib/src/ui/chats/*`
- `lib/src/ui/schedule/*`
- `lib/src/ui/profile/*`
- `lib/src/ui/friends/*`
- `lib/src/ui/exams/exams_screen.dart`

## Reuse These Screens

- Auth/login/change password
- Bottom navigation
- Learning/team list
- Team details
- Chat
- Assignments
- Files
- Schedule
- Subject diary
- Profile/edit profile
- My chats/direct chats
- Friends/classmates
- Study plan in `exams_screen.dart`

## Screens To Add Or Complete Later

- Useful materials backed by a real table/RPC, if `useful_materials` is adopted.
- Academic subjects landing page if study plan should move out of `exams_screen.dart`.
- Admin/import UI only if explicitly required later; for now import should stay in trusted scripts.
- RLS/admin diagnostics UI only after security design.

## Existing Services

- `AuthService`
- `FileService`
- `S3Client`
- `ImageCacheService`
- `ProfileRepository`
- `SupabaseLearningRepository`
- `SubjectDiaryRepositorySupabase`
- Chat services: `IChatService`, `TeamChatService`, `DmChatService`, `DmApi`
- `ScheduleRepository` inside `schedule_screen.dart`
- `_StudyPlanRepository` inside `exams_screen.dart`

## Supabase Read-Only Before Code?

Yes. Before changing Flutter Stage 1 code that relies on academic tables, do a quick read-only confirmation of:

- RLS/policies for the specific tables/RPCs being used;
- whether the frontend should call RPCs instead of direct table reads;
- whether anon/authenticated clients can safely read the target resources.

## Safest First Change

The safest first Flutter change is to remove the hardcoded learning group source by introducing a read-only current-user academic context loader:

1. Get current auth user.
2. Load active `student_enrollments`.
3. Load `groups` and current `group_term_semesters`.
4. Use existing `get_my_teams` / subject RPCs to keep UI behavior stable.

This should be done after RLS implications are reviewed because `student_enrollments`, `groups`, and academic tables currently have RLS disabled.

## Files Not To Touch In The First Stage Without Explicit Reason

- Existing docs outside `docs/stage0_real/`
- `supabase/migrations/*`
- `supabase/checks/*`
- `scripts/import_academic_batch.js`
- `scripts/create_vv_2024_auth_users.js`
- Any `.env*`
- Platform files (`android/*`, `ios/*`) unless the task is specifically platform-related
- Large generated/aggregate files like `lib/all_dart_code.txt`

## Required Manual Review Before Code

Yes, a manual Supabase review is recommended before academic frontend writes:

- RLS disabled on many academic tables is a critical security issue.
- Current code uses both RPCs and direct table reads.
- Enabling RLS without policies can break existing Flutter screens.

## Proposed Next Stage

Stage 1 should be:

**Academic frontend alignment, read-only first**

Scope:

- Keep current UI.
- Add/centralize current academic context loading.
- Prefer existing RPCs for subject/team visibility.
- Do not create new tables.
- Do not write migrations.
- Do not change RLS in the same step.
- Add focused docs updates in `docs/stage0_real` or a new explicitly approved docs folder.

## Stage 1 Progress

Completed first safe slice:

- created read-only `AcademicContextService`;
- added minimal academic context models;
- removed the hardcoded Learning group helper;
- exposed group/semester/source from the Learning screen through an `i` info icon and bottom sheet;
- preserved existing team/chat/assignment/file flows.

Stage 1.1 smoke/UI adjustment:

- user reported that the app was launched and checked;
- the always-visible academic context block was replaced with a compact info icon;
- no Supabase schema/RLS/Auth/import/chat changes were made.

Next safe stage:

- decide whether academic context should be served by RLS-backed table reads or by a reviewed read-only RPC;
- then gradually use the context to align Learning subjects/teams with `subject_offering_id`.

## Stage 2.0 And 2.1 Progress

Stage 2.0 audited schedule subject linking and confirmed:

- active schedule table is `public.lessons`;
- `lessons.subject_id` and `lessons.subject_offering_id` exist;
- old schedule rows were not linked;
- existing DB normalizer `public.f_norm_subject` and `subject_aliases` can support a resolver/backfill design.

Stage 2.1 added a dev/test seed for the current semester:

- seed file: `supabase/dev_seed_test_schedule_subject_link.sql`;
- rollback file: `supabase/dev_seed_test_schedule_subject_link_rollback.sql`;
- report: `docs/stage0_real/STAGE2_1_TEST_SUBJECT_SCHEDULE_LINK.md`;
- created 4 test `subject_offerings`, 8 linked `lessons`, 4 teams, and 4 `team_main` chats;
- verified that seminar/practice and lecture/lab variants point to the same `subject_offering_id`;
- did not change Flutter code, Supabase schema, RLS, policies, migrations, or chat module code.

## Next Safe Stage 2.2

The next safe step is a small read-path/UI slice:

1. Extend `get_my_lessons` or add a reviewed read-only schedule RPC to return `group_id`, `subject_id`, `subject_offering_id`, `academic_term_id`, and `semester_number`.
2. Extend the Flutter `Lesson` model to carry those IDs.
3. Add a minimal linked-state block in `LessonDetailsScreen`, for example `Предмет связан: subject_offering_id = ...`.
4. Open SubjectHub/team/chat only when `subject_offering_id` is present.

Do not rewrite the chat module in Stage 2.2.

## Stage 2.2 Progress

Completed as a Flutter-only read-path/UI slice:

- kept `get_my_lessons` unchanged;
- added read-only enrichment from `public.lessons` by lesson IDs;
- extended `Lesson` with nullable academic link fields;
- added linked/unlinked status to schedule cards;
- added a linked-state block and `Открыть предмет` button to `LessonDetailsScreen`;
- added minimal `SubjectHubScreen` for checking IDs;
- did not change Supabase schema, RLS, policies, ChatScreen, or chat module code.

## Stage 2.3 Progress

Completed a server resolver + useful subject info slice:

- created `public.f_norm_schedule_subject`, `public.resolve_subject_offering_for_schedule`, and `public.link_lesson_subject_from_schedule`;
- revoked resolve/link execution from `anon`/`authenticated` and granted trusted `service_role` execution;
- added rollbackable Stage 2.3 parser test data for `Тест парсинга пары` and `Проверка парсинга пары`;
- verified seminar, practice, and Teams-code variants resolve to one `subject_offering_id` per group;
- removed user-facing schedule debug labels and technical IDs;
- replaced the temporary SubjectHub check screen with `Информация о предмете`;
- made `Полезная` list current-semester `subject_offerings`;
- kept RLS, policies, tables, `get_my_lessons`, ChatScreen, and assignments flow unchanged.

## Next Safe Stage 4

Stage 4 should fill `Информация о предмете` with real data and interactions:

1. Connect useful materials/files from the existing or chosen storage/table path.
2. Split templates, examples, methodical materials, and uploaded files into real sections.
3. Connect the existing team/chat opening flow through `subject_offering_id` without rewriting ChatScreen.
4. Add richer teacher/difficulty metadata if a reviewed source exists.
5. Keep assignments out of `Полезная`; assignments stay in diary/learning.

## Stage 3.1 Progress

Completed a UI polish and chat-link slice:

- verified Stage 2.1 and Stage 2.3 test offerings have no duplicate teams/chats;
- documented legacy/non-active extra members without cleanup;
- connected `Открыть чат предмета` to existing `TeamDetailsScreen(initialTabIndex: 1)`;
- kept ChatScreen and chat module unchanged;
- changed `Полезная` from a flat list into a semester-based study-plan style screen;
- added a light gradient header matching `Команды` and `Расписание`;
- loads all subject offerings for the active group, selects current semester by default, and allows semester switching;
- added filters for all/exams/credits/practices/courseworks;
- kept assignments out of `Информация о предмете`.

## Next Safe Stage 4.1

The next safe step is real content for the polished shell:

1. Decide the source of useful materials/files: existing `chat_files`, storage folders, or a reviewed future table/RPC.
2. Fill `Полезные файлы` with real templates, examples, methodical materials, and uploaded files.
3. Add real teacher/difficulty metadata only if a reviewed data source exists.
4. Consider a direct chat route only if it can reuse current chat state safely; otherwise keep opening through `TeamDetailsScreen`.
5. Do not add assignments, general semester diary, gamification, RLS changes, or new tables in the same slice.

## Stage 3.2 Progress

Completed a UX simplification slice:

- `Полезная` now has `Предметы` and `Справка` blocks;
- semester/type chips were replaced by dropdown filters;
- current semester and `Все` are the defaults;
- subject cards no longer show a redundant `Открыть` button and are clickable as a whole;
- static help cards were added as placeholders without new DB tables;
- `LessonDetailsScreen` now opens subject info by tapping the whole `Информация о предмете` block;
- assignments, technical IDs, `Предмет связан`, ChatScreen changes, parser changes, RLS, and Supabase schema changes were avoided.

## Next Safe Stage 4.2

The next safe step is content/data, not more navigation plumbing:

1. Fill `Справка` cards with real text or reviewed local markdown content.
2. Connect `Полезные файлы` to existing files/storage/chat-file data if the access path is clear.
3. Keep subject assignments out of `Полезная`.
4. Keep RLS/schema changes as a separate reviewed security/backend stage.

## Stage 3.3 Progress

Completed an advanced UX polish slice for `Полезная`:

- removed the large `Предметы` / `Справка` segmented control from the body;
- moved section selection into a soft header button and `Раздел` bottom sheet;
- added a lightweight active-section title/subtitle;
- replaced square dropdowns with pill selectors for semester and type;
- semester/type selection now uses bottom sheets with selected checks and current-semester badge;
- redesigned subject cards with softer radius, tint, left subject initial, compact badges, and full-card tap;
- kept the subject-card `Открыть` button removed;
- polished static `Справка` cards and kept them local/no DB;
- checked `LessonDetailsScreen` for the clickable subject-info card without duplicate button;
- checked `SubjectInfoScreen` and removed the remaining assignment mention.

## Next Safe Stage 4.3

The next safe step is content/data:

1. Fill `Справка` card details with reviewed static text or local markdown.
2. Connect `Полезные файлы` to an existing reviewed source such as storage/chat-file data if access rules are clear.
3. Keep assignments, new diary concepts, parser changes, ChatScreen changes, RLS changes, and schema changes out of this UX/content slice.
4. If files require backend access changes, split that into a separate RLS/schema review stage.

## Stage 3.4 Progress

Completed a Figma-level visual redesign of `Информация о предмете`:

- replaced the simple top block with a hero-card that shows subject initial, title, readable meta, and chips;
- added quick actions for chat, diary, and files;
- kept chat opening through the existing `TeamDetailsScreen(initialTabIndex: 1)` path;
- kept diary opening through existing `SubjectDiaryScreen`;
- made display values safer by hiding empty/technical strings and zero credits/hours;
- redesigned `Краткая информация`, `Преподаватель`, `Полезные файлы`, `Чат`, and `Дневник`;
- added a soft non-commercial help block;
- kept assignments, technical IDs, `Предмет связан`, ChatScreen changes, RLS, schema, and server function changes out of scope.

## Next Safe Stage 4.4

The next safe step is real content/data, not another visual shell:

1. Fill `Справка` card detail placeholders with reviewed text or local markdown.
2. Connect `Полезные файлы` to existing reviewed files/storage/chat-file data if access rules are already clear.
3. Add richer teacher/material metadata only from reviewed sources.
4. Keep assignments, new general diary concepts, parser changes, ChatScreen changes, RLS changes, and schema changes as separate stages.

## Stage 3.5 Progress

Completed a UI/runtime stabilization slice:

- addressed the likely Flutter semantics assertion trigger by moving bottom-sheet state updates after sheet close;
- simplified compact quick action card layout in `SubjectInfoScreen`;
- kept the `Полезная` header unchanged;
- moved the `Полезная` body closer to `Зачёты и экзамены` with summary-card, metrics, filters, and expansion-style semester section;
- grouped subjects by control form;
- made subject cards compact within control groups while preserving full-card tap and no `Открыть` button;
- grouped `Справка` cards by access, documents, programs, map/audiences, and FAQ;
- reduced empty-feeling `Информация о предмете` by adding an empty-content callout and one clear empty file block.

## Next Safe Stage 4.5

The next safe step is content plus runtime verification:

1. Run the app with valid local `SUPABASE_URL` and `SUPABASE_ANON_KEY` dart-defines and confirm the semantics assertion does not reproduce.
2. Fill `Справка` detail placeholders with reviewed static content.
3. Connect `Полезные файлы` to an existing reviewed source only if access rules are already clear.
4. Keep RLS/schema/server-function changes separate from UI/content work.

## Stage 3.6 Audit Result

Stage 3.6 performed the control audit before moving to a personal diary stage.

Confirmed:

- Stage 2.1/2.3 test `subject_offerings` exist for both groups.
- Test lessons on `2026-06-19`, `2026-06-21`, and `2026-06-23` are linked to `subject_id` and `subject_offering_id`.
- Resolver calls for seminar/practice/Teams variants return one matched offering.
- Test teams/chats have no duplicates: one team and one `team_main` chat per test offering.
- Flutter schedule read path carries academic link fields through the enrichment adapter while keeping `get_my_lessons` unchanged.
- `Полезная` and `Информация о предмете` preserve the intended navigation and avoid technical IDs, assignments, and ChatScreen rewrites.
- `flutter build windows --debug` passes.

Not fully closed:

- `resolve_subject_offering_for_schedule` and `link_lesson_subject_from_schedule` still have effective `anon`/`authenticated` execute through PUBLIC execute. Fix this in a separate backend/security step before using parser/linking from production trusted services.
- Runtime UI verification is still blocked until valid local Supabase dart-defines are provided.
- Full `flutter analyze` still reports existing project-wide warnings/infos.

## Next Major Stage

Stage 4 should be:

**Личный дневник текущего семестра**

Initial Stage 4 boundaries:

1. Start from the already verified current academic context and semester 4 `subject_offerings`.
2. Do not mix the personal diary with assignments, chat rewrites, RLS changes, or parser changes.
3. Before adding write flows, decide the safe DB/RLS/RPC contract for diary entries.
4. Keep the existing subject diary and team/chat flows reusable where possible.
5. Resolve or explicitly isolate the function execute privilege finding before any trusted server parser/linking work.
