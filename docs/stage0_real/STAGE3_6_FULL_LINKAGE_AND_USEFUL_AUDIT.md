# Stage 3.6 - Full Linkage And Useful Audit

Date: 2026-06-19

Scope: control audit of Stage 2.0-3.5 schedule-subject linkage, test data, Flutter read path, `Полезная`, `Информация о предмете`, documentation, analyze/build status, and checkpoint readiness.

No new features, RLS changes, policy changes, tables, imports, rollbacks, test-data cleanup, or ChatScreen rewrites were performed.

## Preflight

- Correct project: `C:\student_platform`.
- Branch expected by request/docs: `refactor/chat-tab`.
- Preflight command: `git status --short`.
- Working tree before Stage 3.6: dirty with many unrelated modified/deleted/untracked files.
- Stage-related dirty/untracked areas identified for possible checkpoint:
  - `lib/src/ui/info/info_screen.dart`
  - `lib/src/ui/info/subject_info_screen.dart`
  - `lib/src/ui/schedule/models/lesson.dart`
  - `lib/src/ui/schedule/schedule_screen.dart`
  - `lib/src/ui/schedule/widgets/lesson_card.dart`
  - `lib/src/ui/schedule/lesson_details_screen.dart`
  - `lib/src/data/academic_context_service.dart`
  - `supabase/dev_seed_test_schedule_subject_link.sql`
  - `supabase/dev_seed_test_schedule_subject_link_rollback.sql`
  - `supabase/stage2_3_schedule_subject_resolver.sql`
  - `supabase/stage2_3_schedule_subject_resolver_rollback.sql`
  - `docs/stage0_real/`
  - `docs/_snapshots/`
- Unrelated dirty/untracked areas must not be committed in this checkpoint: platform files, auth/chat/learning/profile refactors, vendor removals, old root SQL deletions, lottie/assets, backup folders, generated Android build reports, unrelated docs, and other pre-existing dirty tree files.

## Supabase Functions

Live DB check was completed through Supabase MCP `execute_sql` on project `gwdanmwluhrcfxbnplwd`.

Existing functions:

| Function | Signature | Exists | Notes |
|---|---|---:|---|
| `public.f_norm_schedule_subject` | `f_norm_schedule_subject(text)` | yes | Plain SQL/PL function, callable by client roles through default PUBLIC execute. |
| `public.resolve_subject_offering_for_schedule` | `resolve_subject_offering_for_schedule(uuid,text,date,integer)` | yes | `SECURITY DEFINER`, returns one resolver row. |
| `public.link_lesson_subject_from_schedule` | `link_lesson_subject_from_schedule(uuid)` | yes | `SECURITY DEFINER`, updates one lesson after resolver result. |
| `public.f_norm_title` | `f_norm_title(text)` | yes | Existing normalizer. |
| `public.f_norm_subject` | `f_norm_subject(text)` | yes | Existing subject normalizer. |

Important access finding:

- `resolve_subject_offering_for_schedule` and `link_lesson_subject_from_schedule` have ACL text without explicit `anon`/`authenticated`, but PUBLIC execute is still present (`=X/postgres`).
- `has_function_privilege('anon', ..., 'execute')` and `has_function_privilege('authenticated', ..., 'execute')` returned `true` for both resolver/link functions.
- This means `link_lesson_subject_from_schedule` is not yet restricted to service-role/trusted server usage at the privilege level.
- Flutter code does not use `service_role` and no Flutter call to `link_lesson_subject_from_schedule` was found.
- No privilege fix was applied in Stage 3.6 because this stage is audit/checkpoint only.

## Resolver Test Calls

All required resolver calls returned `match_status = matched`, `candidates_count = 1`, and non-null `subject_offering_id`.

For `1-См(ВВ)-2`:

- `Тест 1 (сем.)` -> `cbb94b65-5eab-49dd-ba68-376204364a79`
- `Тест 1, практика Teams TEST-1` -> `cbb94b65-5eab-49dd-ba68-376204364a79`
- `Тест парсинга пары (сем.)` -> `7e4bb6eb-e812-4b37-8ec0-1ce6f72bec8b`
- `Тест парсинга пары, практика Teams PARSE-1` -> `7e4bb6eb-e812-4b37-8ec0-1ce6f72bec8b`

For `2-См(ВВ)-2`:

- `Проверка 1 (сем.)` -> `f9eb2899-e24d-4981-8597-abaad7092401`
- `Проверка 1, практика Teams TEST-A` -> `f9eb2899-e24d-4981-8597-abaad7092401`
- `Проверка парсинга пары (сем.)` -> `95fb3bc2-69b9-4805-8aad-ec700f4ae5ae`
- `Проверка парсинга пары, практика Teams PARSE-A` -> `95fb3bc2-69b9-4805-8aad-ec700f4ae5ae`

Seminar/practice/Teams variants resolve to the same `subject_offering_id` for each subject.

## Test Subject Offerings

All six test offerings exist.

For every checked offering:

- `group_id` matches the expected group.
- `semester_number = 4`.
- `academic_year_id` is filled.
- `academic_term_id` is filled.
- `subject_id` is filled.
- `curriculum_subject_id` is filled.
- `status = active`.

Checked offerings:

- `1-См(ВВ)-2`: `Тест 1`, `Тест 2`, `Тест парсинга пары`
- `2-См(ВВ)-2`: `Проверка 1`, `Проверка 2`, `Проверка парсинга пары`

## Lessons

Checked dates:

- `2026-06-19`
- `2026-06-21`
- `2026-06-23`

All 12 expected test lessons exist for the two groups.

For every checked lesson:

- `group_id` is filled and correct.
- `subject_id` is filled.
- `subject_offering_id` is filled.
- `academic_year_id` is filled.
- `academic_term_id` is filled.
- `semester_number = 4`.
- `alias_match_status = matched`.
- Teams-code variants are linked to the same offering as the base seminar/practice subject.

Stage 2.1 lessons were seeded already linked. Stage 2.3 lessons on `2026-06-23` are linked and have base `normalized_subject_name` values produced by the Stage 2.3 resolver/link flow.

Small data note:

- Stage 2.1 seeded `normalized_subject_name` still contains lesson-type/Teams text, for example `тест 1 (сем )` and `тест 1 практика teams test 1`.
- This does not break the current link because `subject_id`, `subject_offering_id`, and `alias_match_status` are filled.

## Teams And Chats

All six test offerings have exactly:

- `teams_count = 1`
- `team_main_chats_count = 1`
- `all_chats_count = 1`

Member counts:

- `1-См(ВВ)-2` offerings: 19 team members / 19 chat members, of which 17 are active enrollment students and 2 are legacy/non-active-by-enrollment members.
- `2-См(ВВ)-2` offerings: 14 team members / 14 chat members, of which 12 are active enrollment students and 2 are legacy/non-active-by-enrollment members.

No duplicate teams or duplicate `team_main` chats were found. Legacy/non-active extra members were only documented; no cleanup was performed.

## Flutter Read Path

Checked files:

- `lib/src/ui/schedule/models/lesson.dart`
- `lib/src/ui/schedule/schedule_screen.dart`
- `lib/src/ui/schedule/widgets/lesson_card.dart`
- `lib/src/ui/schedule/lesson_details_screen.dart`

Confirmed:

- `Lesson` contains nullable `groupId`, `subjectId`, `subjectOfferingId`, `academicYearId`, `academicTermId`, `semesterNumber`, and `aliasMatchStatus`.
- `Lesson.copyWithAcademicFields` and `Lesson.hasSubjectLink` are present.
- `ScheduleScreen` still calls `get_my_lessons`.
- The enrichment adapter reads `public.lessons` by lesson IDs and selects `group_id`, `subject_id`, `subject_offering_id`, `academic_year_id`, `academic_term_id`, `semester_number`, and `alias_match_status`.
- `get_my_lessons` was not changed.
- `LessonCard` does not show `Предмет связан`, `Не привязано`, `subject_id`, or `subject_offering_id`.
- `LessonDetailsScreen` does not show technical IDs.
- The `Информация о предмете` block is clickable when `subjectOfferingId` is present and opens `SubjectInfoScreen`.
- `lib/src/ui/schedule/subject_hub_screen.dart` no longer exists.

## Useful Tab

Checked file: `lib/src/ui/info/info_screen.dart`.

Confirmed:

- The header remains in place.
- Sections exist: `Предметы` and `Справка`.
- Section selection uses a bottom sheet and updates state after the sheet closes.
- Subjects load from `subject_offerings` for the active academic group.
- Current semester is selected by default.
- The compact academic context strip shows group, semester, and `recordBookNumber` from `AcademicContextService`.
- Course was removed from the strip.
- Record book number is displayed directly without the `Зачётка` prefix.
- Subject cards are grouped/styled in the current study-screen style and remain clickable as whole cards.
- The `Открыть` button was not restored.
- Subject cards open `SubjectInfoScreen`.
- Help cards open local placeholder/detail bottom sheets.
- Technical IDs are not rendered to the user.

## Subject Info Screen

Checked file: `lib/src/ui/info/subject_info_screen.dart`.

Confirmed:

- Opens from `Полезная`.
- Opens from linked lesson details.
- Hero-card exists.
- Technical/seed values are filtered by safe display getters.
- Empty subject data is shown with human-readable placeholders and `_EmptyContentCallout`.
- Quick actions exist: `Чат`, `Дневник`, `Файлы`.
- `Краткая информация`, `Преподаватель`, and `Полезные файлы` blocks exist.
- `Полезные файлы` uses a single polished empty state when materials are missing.
- Chat opens through existing `TeamDetailsScreen(initialTabIndex: 1)` when a team and `team_main` chat are found.
- ChatScreen was not rewritten.
- Assignments were not added.
- A soft help block exists at the bottom.

## Runtime UI

Interactive runtime UI verification could not be completed in this environment because `SUPABASE_URL` and `SUPABASE_ANON_KEY` are not present as environment variables and should not be guessed or exposed.

Known run state from terminal:

- `flutter run -d windows` built the Windows app.
- App startup stopped with: `Supabase config is missing. Run with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`.

Because runtime did not reach the UI, Stage 3.6 did not reproduce or re-check the Flutter semantics assertion:

`Failed assertion: '!semantics.parentDataDirty'`

No new runtime error was observed during Stage 3.6 because the app could not pass Supabase config validation.

## Analyze And Build

Focused analyze:

- `dart analyze lib/src/ui/info/info_screen.dart`: no issues.
- `dart analyze lib/src/ui/info/subject_info_screen.dart`: no issues.
- `dart analyze lib/src/ui/schedule/models/lesson.dart`: no issues.
- `dart analyze lib/src/ui/schedule/lesson_details_screen.dart`: 15 existing warnings/infos, mostly `withOpacity` plus unused optional parameters.
- `dart analyze lib/src/ui/schedule/widgets/lesson_card.dart`: 6 existing `withOpacity` infos.
- `dart analyze lib/src/ui/schedule/schedule_screen.dart`: 7 existing warnings/infos, including unused `_pickDateFromHeader` and `withOpacity`.

Full project analyze:

- `flutter analyze`: 356 existing project-wide issues.
- No unrelated project-wide issues were fixed in Stage 3.6.

Build:

- `flutter build windows --debug`: passed.
- Output executable: `build\windows\x64\runner\Debug\student_platform.exe`.

IDE lints for the audited files reported no linter errors.

## SQL And Docs Files

SQL files exist:

- `supabase/dev_seed_test_schedule_subject_link.sql`
- `supabase/dev_seed_test_schedule_subject_link_rollback.sql`
- `supabase/stage2_3_schedule_subject_resolver.sql`
- `supabase/stage2_3_schedule_subject_resolver_rollback.sql`

Docs exist:

- `docs/stage0_real/STAGE2_SCHEDULE_SUBJECT_LINK_AUDIT.md`
- `docs/stage0_real/STAGE2_1_TEST_SUBJECT_SCHEDULE_LINK.md`
- `docs/stage0_real/STAGE2_2_SCHEDULE_READ_PATH_SUBJECT_LINK.md`
- `docs/stage0_real/STAGE2_3_SERVER_SCHEDULE_RESOLVER_AND_USEFUL_SUBJECT_INFO.md`
- `docs/stage0_real/STAGE3_1_USEFUL_TAB_AND_SUBJECT_INFO_POLISH.md`
- `docs/stage0_real/STAGE3_2_USEFUL_TAB_STRUCTURE_AND_LESSON_LINK_UX.md`
- `docs/stage0_real/STAGE3_3_USEFUL_TAB_ADVANCED_UX.md`
- `docs/stage0_real/STAGE3_4_SUBJECT_INFO_FIGMA_UI.md`
- `docs/stage0_real/STAGE3_5_USEFUL_EXAMS_STYLE_AND_SUBJECT_EMPTY_STATE.md`
- `docs/stage0_real/WORKLOG.md`
- `docs/stage0_real/STAGE0_REAL_INDEX.md`
- `docs/stage0_real/08_NEXT_STAGE_PLAN.md`

Rollback files were not run.

## Closed

Can be considered closed:

- Stage 2.1 and 2.3 test offerings exist and are linked.
- Resolver matching works for the required seminar/practice/Teams variants.
- Test lessons on the required dates are linked.
- Test teams/chats are one-to-one with test offerings.
- Flutter read path carries linked subject data without changing `get_my_lessons`.
- `Полезная` uses subject offerings and keeps subject cards clickable without technical UI.
- `Информация о предмете` preserves chat/diary/files flow without assignments or ChatScreen rewrite.
- Windows debug build passes.

## Remaining Before Personal Diary

Before starting Stage 4, resolve or explicitly accept:

1. Restrict execute privileges for `resolve_subject_offering_for_schedule` and especially `link_lesson_subject_from_schedule` so normal client roles cannot call trusted linking functions through PUBLIC execute.
2. Run interactive runtime UI verification with valid local `SUPABASE_URL` and `SUPABASE_ANON_KEY` dart-defines for both test students/groups.
3. Confirm the `!semantics.parentDataDirty` assertion does not reproduce during real navigation.
4. Decide whether to normalize Stage 2.1 `normalized_subject_name` values in a separate data cleanup stage; current links are correct, so this is not blocking the UI flow.

Next major stage:

**Stage 4 - Личный дневник текущего семестра.**
