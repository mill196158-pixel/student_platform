# Worklog

## Stage 0 REAL - correct project discovery with existing docs

- Date: 2026-06-17
- Correct project: `C:\student_platform`
- Previous wrong project: `C:\flutter_gen_ai_chat_ui`
- Existing docs found: yes
- Existing docs overwritten: no
- Flutter code changed: no
- Supabase schema changed: no
- RLS changed: no
- Import/apply scripts run: no
- Auth users created: no
- Snapshot script created: yes, `scripts/collect_project_snapshot.ps1`
- Snapshot script run: yes
- Snapshot output: `docs/_snapshots/`
- Note: request mentioned `docs_snapshots`, but allowed-change list and final check allowed `docs/_snapshots/*`; Stage 0 used `docs/_snapshots` to stay within allowed files.
- Live DB checked: yes, read-only through Supabase MCP after authentication
- Supabase project checked: `gwdanmwluhrcfxbnplwd`
- Manual SQL created: yes, `docs/stage0_real/supabase_manual_check_stage0_real.sql`
- Old docs stale/conflicting: yes, recorded in `02_DOCS_CONTRADICTIONS_AND_FRESHNESS.md`
- Next step: Stage 1 academic frontend alignment, read-only first, starting with current academic context and RLS-aware data access review.

## Stage 1 - Academic frontend alignment, read-only first

- Date: 2026-06-17
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 1.
- Flutter code changed: yes, minimal and limited to AcademicContext + Learning UI.
- Supabase schema changed: no
- RLS changed: no
- Migrations written: no
- Import/apply scripts run: no
- Auth users touched: no
- Chat module rewritten: no
- Team/chat creation changed: no
- New model/service: `lib/src/data/academic_context_service.dart`
- UI connection: `lib/src/ui/learning/learning_screen.dart`
- Tables read by new service: `users`, `student_enrollments`, `groups`, `group_term_semesters`, `academic_terms`
- New doc: `docs/stage0_real/STAGE1_ACADEMIC_CONTEXT.md`
- RLS risk: `student_enrollments`, `groups`, `group_term_semesters`, and `academic_terms` were RLS disabled in Stage 0 live check; future RLS/RPC contract required.
- `flutter analyze`: run; full project still fails on pre-existing errors in `lib/src/ui/schedule/diary_entry_details_screen.dart` (`subject_quick_note_screen.dart` missing, `getTemporaryDirectory` undefined, `File` undefined).
- Focused analyze for Stage 1 files: `dart analyze lib/src/data/academic_context_service.dart lib/src/ui/learning/learning_screen.dart`; no Stage 1 warnings/errors, only existing `withOpacity` deprecation infos in `learning_screen.dart`.
- Snapshot script run after Stage 1: yes, `docs/_snapshots/` updated.

## Stage 1.1 - runtime smoke-test AcademicContext

- Date: 2026-06-17
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 1.1.
- App launched: user-reported yes
- Target: user-reported local Flutter runtime; agent did not rerun `flutter run` because the user said runtime steps could be skipped.
- Academic context block visible: changed from always-visible inline block to an `i` info icon in the Learning header.
- Academic context UI result: details open in a bottom sheet showing group, semester, and source, or `Учебный контекст не найден`.
- Runtime errors: none reported by user during smoke check.
- Build blockers: not rechecked through `flutter run`; previous full `flutter analyze` blocker remains pre-existing in `lib/src/ui/schedule/diary_entry_details_screen.dart`.
- Files changed in Stage 1.1: `lib/src/ui/learning/learning_screen.dart`, `docs/stage0_real/STAGE1_ACADEMIC_CONTEXT.md`, `docs/stage0_real/WORKLOG.md`, `docs/stage0_real/08_NEXT_STAGE_PLAN.md`, `docs/_snapshots/*`.
- Supabase schema changed: no
- RLS changed: no
- Auth users changed: no
- Chat module changed: no
- Team/chat flow changed: no
- Focused analyze: `dart analyze lib/src/data/academic_context_service.dart lib/src/ui/learning/learning_screen.dart`; no Stage 1.1 errors, only existing `withOpacity` infos.
- Next safe step: Stage 2 data contract decision for AcademicContext, preferably reviewed RLS-backed reads or a reviewed read-only RPC.

## Stage 2.0 - schedule subject link audit

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 2.0.
- Flutter code changed: no
- Supabase schema changed: no
- RLS changed: no
- Migrations written: no
- Import/apply scripts run: no
- Git add/commit run: no
- New audit doc: `docs/stage0_real/STAGE2_SCHEDULE_SUBJECT_LINK_AUDIT.md`
- Schedule table found: `public.lessons`
- `schedule_lessons` used by Flutter: no
- Existing parser/normalizer found: yes, live DB functions `public.f_norm_title` and `public.f_norm_subject`; weaker Flutter fallback `_normalizeSubject` exists in `lib/src/data/subject_diary_repository_supabase.dart`.
- `subject_id` coverage: 0/176 lessons
- `subject_offering_id` coverage: 0/176 lessons
- Alias read-only coverage through `public.f_norm_subject` + `subject_aliases`: 130/176 lessons single-subject matches, 46/176 no alias match, 0 ambiguous.
- Any-semester offering read-only coverage by group: 96/176 lessons single-offering matches, 80/176 no offering match, 0 ambiguous.
- Current AcademicContext semester coverage: 0/176 lessons match current semester 4 offerings; existing lessons are dated 2025-09-01 to 2025-11-20 and partially align with semester 3 offerings.
- Next safe step: add a read-only `ScheduleSubjectResolver`/RPC contract that resolves lesson title + group + inferred lesson semester to a single `subject_offering_id`, and opens SubjectHub only on unique matches.

## Stage 2.1 - test subject schedule link seed

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 2.1.
- Flutter code changed: no
- Supabase schema changed: no
- RLS changed: no
- Policies changed: no
- Migrations written: no
- Import/apply scripts run: no
- Git add/commit run: no
- Chat module changed: no
- Seed file created: `supabase/dev_seed_test_schedule_subject_link.sql`
- Rollback file created: `supabase/dev_seed_test_schedule_subject_link_rollback.sql`
- Seed applied: yes, through Supabase MCP `execute_sql`
- Rollback applied: no
- Test doc created: `docs/stage0_real/STAGE2_1_TEST_SUBJECT_SCHEDULE_LINK.md`
- Current semester used: semester 4, academic term `весна 2026`
- Groups seeded: `1-См(ВВ)-2`, `2-См(ВВ)-2`
- Test subjects: `Тест 1`, `Тест 2`, `Проверка 1`, `Проверка 2`
- Subject offerings created: 4
- Lessons created: 8 on `2026-06-19` and `2026-06-21`
- Lessons with `subject_id`: 8/8
- Lessons with `subject_offering_id`: 8/8
- Teams created/verified: 4
- Team main chats created/verified: 4
- Team/chat members: all active students are present; existing trigger also added 2 legacy/non-active-by-enrollment members per test team/chat.
- Link verification: seminar/practice and lecture/lab variants each resolve to one `subject_offering_id`; Teams-code variants are linked to the same offering.
- Flutter UI check: not run manually. Existing `get_my_lessons` still does not return `subject_id` or `subject_offering_id`, so Stage 2.2 should extend the read path and show/open linked SubjectHub.

## Stage 2.2 - schedule read path and SubjectHub check

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 2.2.
- Flutter code changed: yes, limited to schedule read path/details/card and a minimal SubjectHub check screen.
- Supabase schema changed: no
- RLS changed: no
- Policies changed: no
- Tables created: no
- Seed/rollback changed: no
- ChatScreen changed: no
- Chat module changed: no
- Chosen approach: Variant B, Flutter enrichment adapter after `get_my_lessons`.
- Reason: `get_my_lessons` return type stays stable; no live function replacement needed.
- Lesson model fields added: `groupId`, `subjectId`, `subjectOfferingId`, `academicYearId`, `academicTermId`, `semesterNumber`, `aliasMatchStatus`.
- Schedule card: shows `Предмет связан` / `Не привязано`.
- LessonDetails: shows linked-state block and enabled/disabled `Открыть предмет` button.
- SubjectHub: created minimal `lib/src/ui/schedule/subject_hub_screen.dart` for ID verification only; chat/team actions are placeholders.
- Runtime app check: not run interactively because test-student login/navigation requires credentials; `flutter devices` found Windows, Chrome, and Edge.
- Focused analyze: no Stage 2.2 errors; existing schedule warnings/infos remain.
- Full `flutter analyze`: still fails on pre-existing project-wide warnings/infos; latest run reported 358 issues.
- New doc: `docs/stage0_real/STAGE2_2_SCHEDULE_READ_PATH_SUBJECT_LINK.md`
- Next step: Stage 3, fill SubjectHub with real blocks and then connect existing team/chat through `subject_offering_id`.

## Stage 2.3 - server schedule resolver and useful subject info

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 2.3.
- SQL functions created/replaced: `public.f_norm_schedule_subject`, `public.resolve_subject_offering_for_schedule`, `public.link_lesson_subject_from_schedule`.
- Function access: `anon`/`authenticated` revoked for resolve/link; `service_role` granted execute.
- SQL file created: `supabase/stage2_3_schedule_subject_resolver.sql`
- Rollback file created: `supabase/stage2_3_schedule_subject_resolver_rollback.sql`
- SQL applied: yes, through Supabase MCP `execute_sql`
- RLS changed: no
- Policies changed: no
- Tables created: no
- `get_my_lessons` changed: no
- ChatScreen changed: no
- Chat module rewritten: no
- Stage 2.1 test data deleted: no
- Test subjects created: `Тест парсинга пары`, `Проверка парсинга пары`
- Test lessons created: 4 on `2026-06-23`, inserted unresolved first and then linked through `link_lesson_subject_from_schedule`.
- Verified subject offerings: `Тест парсинга пары` -> `7e4bb6eb-e812-4b37-8ec0-1ce6f72bec8b`; `Проверка парсинга пары` -> `95fb3bc2-69b9-4805-8aad-ec700f4ae5ae`.
- Link verification: seminar, practice, and Teams-code variants all returned `matched`, `candidates_count = 1`, and filled `subject_id`/`subject_offering_id`.
- Flutter UI changed: schedule cards no longer show `Предмет связан` / `Не привязано`; lesson details now show `Информация о предмете`; the temporary debug SubjectHub screen was replaced by `lib/src/ui/info/subject_info_screen.dart`.
- Useful tab changed: `lib/src/ui/info/info_screen.dart` now lists current-semester `subject_offerings` for the active academic context.
- Assignments added to useful information: no.
- Focused analyze: no new Stage 2.3 errors; existing schedule warnings/infos remain.
- Full `flutter analyze`: still fails with 358 pre-existing project-wide issues.
- New doc: `docs/stage0_real/STAGE2_3_SERVER_SCHEDULE_RESOLVER_AND_USEFUL_SUBJECT_INFO.md`
- Next step: Stage 4, fill `Информация о предмете` with real useful materials/files and connect richer subject data.

## Stage 3.1 - useful tab polish and subject chat link

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 3.1.
- Supabase schema changed: no
- RLS changed: no
- Policies changed: no
- Tables created: no
- Mass import run: no
- Test data deleted: no
- ChatScreen changed: no
- Chat module rewritten: no
- ScheduleScreen rewritten: no
- Learning tab rewritten: no
- Duplicate check: completed for 6 test `subject_offering_id` values from Stage 2.1 and Stage 2.3.
- Duplicate result: no duplicate teams/chats; every test offering has exactly 1 team and 1 `team_main` chat.
- Legacy members: still present as expected; no cleanup performed.
- Chat button: `Информация о предмете` now opens existing `TeamDetailsScreen(initialTabIndex: 1)` when team/chat exists.
- Useful tab changed: new `Команды`/`Расписание`-style header, current semester card, semester selector, filters, and richer subject cards.
- Useful data scope: loads all `subject_offerings` for the active group and lets the user switch semesters; current semester is selected by default.
- Filters added: `Все`, `Экзамены`, `Зачёты`, `Практики`, `Курсовые / КР`.
- Subject info blocks kept: brief info, teacher, useful files, chat, diary.
- Assignments added to useful information: no.
- Diary: existing `SubjectDiaryScreen` remains linked from subject info.
- Focused analyze: `dart analyze lib/src/ui/info/info_screen.dart lib/src/ui/info/subject_info_screen.dart` passed with no issues.
- Full `flutter analyze`: still fails with 358 existing project-wide issues.
- Runtime smoke: `flutter run -d windows` built successfully, then stopped because `SUPABASE_URL`/`SUPABASE_ANON_KEY` dart-defines were not provided.
- New doc: `docs/stage0_real/STAGE3_1_USEFUL_TAB_AND_SUBJECT_INFO_POLISH.md`
- Next step: connect real useful materials/files and richer subject metadata.

## Stage 3.2 - useful tab structure and lesson link UX

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 3.2.
- Supabase schema changed: no
- RLS changed: no
- Tables created: no
- Parser changed: no
- ChatScreen changed: no
- ScheduleScreen rewritten: no
- Assignments added to useful information: no
- Useful tab changed: added `Предметы` / `Справка` segmented switch.
- Subject filters changed: chip rows replaced with dropdowns `Семестр` and `Тип`.
- Defaults: current semester when available; type `Все`.
- Subject cards changed: removed redundant `Открыть` button; whole card is clickable and keeps right chevron.
- Help section added with 6 static cards and a placeholder bottom sheet.
- LessonDetails changed: removed duplicate `Информация о предмете` button; whole info block is clickable with right chevron.
- SubjectInfo checked: keeps brief info, teacher, useful files, chat, diary; no assignments.
- Focused analyze: `dart analyze lib/src/ui/info/info_screen.dart lib/src/ui/info/subject_info_screen.dart` passed with no issues.
- Full `flutter analyze`: still fails with 358 existing project-wide issues.
- New doc: `docs/stage0_real/STAGE3_2_USEFUL_TAB_STRUCTURE_AND_LESSON_LINK_UX.md`
- Next step: fill help cards/useful files with real content and data sources.

## Stage 3.3 - useful tab advanced UX

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 3.3.
- Supabase schema changed: no
- RLS changed: no
- Server functions changed: no
- Parser changed: no
- ChatScreen changed: no
- ScheduleScreen rewritten: no
- Assignments added to useful information: no
- Useful tab changed: removed the large `Предметы` / `Справка` segmented control from the body.
- Section selection changed: moved to a soft round button in the `Полезная` header with a `Раздел` bottom sheet.
- Active section block added: lightweight title/subtitle for `Предметы семестра` or `Справочная информация`.
- Subject filters changed: square dropdown fields were replaced with pill selectors for semester and type.
- Bottom sheets added: semester selector marks `текущий`; type selector lists `Все`, `Экзамены`, `Зачёты`, `Практики`, `Курсовые / КР`.
- Subject cards changed: softer rounded card, tint/gradient, left subject initial, compact badges, chevron, whole-card tap retained.
- Help section changed: remains static/local but uses polished instruction cards and opens through the header section selector.
- LessonDetails checked: no duplicate subject-info button; clickable card remains and uses the requested text.
- SubjectInfo checked: keeps brief info, teacher, useful files, chat, diary; assignment mention removed.
- Focused analyze: `dart analyze lib/src/ui/info/info_screen.dart lib/src/ui/info/subject_info_screen.dart` passed with no issues.
- Full `flutter analyze`: still fails on existing project-wide issues; current count is 356 issues.
- Build smoke: `flutter build windows --debug` passed.
- Runtime UI: could not be completed without Supabase dart-defines; existing Windows run fails at startup when `SUPABASE_URL`/`SUPABASE_ANON_KEY` are missing.
- New doc: `docs/stage0_real/STAGE3_3_USEFUL_TAB_ADVANCED_UX.md`
- Next step: fill help cards and useful files with real reviewed content/data sources.

## Stage 3.4 - subject info Figma UI

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 3.4.
- Supabase schema changed: no
- RLS changed: no
- Server functions changed: no
- Parser changed: no
- ChatScreen changed: no
- New packages added: no
- Assignments added: no
- Subject info changed: redesigned `Информация о предмете` into a modern soft card-based UI.
- Hero changed: added large subject initial, readable title/meta, soft gradient, chips for materials/chat/diary.
- Quick actions added: `Чат`, `Дневник`, `Файлы`; chat stays enabled only when existing team/chat is found.
- Technical value handling added: empty/`dev`/`test`/`stage2_*`/`*_resolver` user-facing values are replaced with placeholders; zero credits/hours are hidden.
- `Краткая информация` changed: structured content-card with human-readable placeholders.
- `Преподаватель` changed: teacher-card with avatar placeholder and difficulty status.
- `Полезные файлы` changed: category rows for templates, examples, methodical materials, and uploaded files.
- `Чат` and `Дневник` changed: modern action-cards preserving existing routes.
- Soft help block added at the bottom without payment/purchase/ad flow.
- Focused analyze: `dart analyze lib/src/ui/info/subject_info_screen.dart` passed with no issues.
- Build smoke: `flutter build windows --debug` passed.
- Runtime UI: could not be completed without Supabase dart-defines.
- New doc: `docs/stage0_real/STAGE3_4_SUBJECT_INFO_FIGMA_UI.md`
- Next step: fill help cards and useful files with real reviewed content/data sources.

## Stage 3.5 - useful exams style and subject empty state

- Date: 2026-06-19
- Correct project: `C:\student_platform`
- Branch: `refactor/chat-tab`
- Preflight dirty tree: yes, many unrelated files were already dirty before Stage 3.5.
- Supabase schema changed: no
- RLS changed: no
- Server functions changed: no
- Parser changed: no
- ChatScreen changed: no
- ScheduleScreen changed: no
- New packages added: no
- Assignments added: no
- Semantics assertion addressed: bottom sheets now return selected values and parent state updates happen after the sheet closes; `mounted` guard added for section selection.
- Additional semantics/layout simplification: compact quick-action cards no longer use `Spacer`.
- Useful header changed: no.
- Useful body changed: closer to `Зачёты и экзамены` with light background, purple semester summary-card, metrics, filters, and expansion-style semester section.
- Subject grouping added: exams, credits, graded credits, practices, courseworks/KR, and other control forms.
- Subject cards changed: compact cards inside control sections with subject initial, subtitle, control pill, status icons, and chevron; no `Открыть` button.
- Help section changed: summary-card plus grouped sections for access, documents, programs, map/audiences, and FAQ.
- SubjectInfo empty state improved: added empty-content callout and replaced long empty file rows with one polished empty file block.
- Focused analyze: `info_screen.dart` and `subject_info_screen.dart` passed with no issues; `lesson_details_screen.dart` still has old existing warnings/infos.
- Full `flutter analyze`: still reports 356 existing project-wide issues.
- Build smoke: `flutter build windows --debug` passed.
- Runtime UI: could not be completed without Supabase dart-defines.
- New doc: `docs/stage0_real/STAGE3_5_USEFUL_EXAMS_STYLE_AND_SUBJECT_EMPTY_STATE.md`
- Next step: connect real reviewed help/material content and verify runtime with dart-defines.

## Stage 3.5 follow-up - compact useful context strip

- Date: 2026-06-19
- Useful header changed: no.
- Removed the large purple `Выбранный семестр` summary-card from the `Полезная` body.
- Replaced it with a compact academic context strip: group, semester, course, and `Зачётка`.
- Removed the `ExpansionTile` wrapper from the subject list area and replaced it with a simple static section container.
- This also removes the runtime area that showed `type 'double' is not a subtype of type 'bool' in type cast` under the filters.
- Focused analyze: `dart analyze lib/src/ui/info/info_screen.dart` passed with no issues.
- Build smoke: `flutter build windows --debug` passed.
- RLS, Supabase schema, ChatScreen, parser, ScheduleScreen, assignments, and technical IDs were not changed.

## Stage 3.5 follow-up - record book number in useful context

- Date: 2026-06-19
- `AcademicContextService` now reads `public.users.login` as `recordBookNumber`.
- Reason: import docs define `record_book` and `login` as matching values, so the user's record book number is available through the existing user row.
- The compact `Полезная` context strip now shows `Зачётка №<номер>` instead of a static `Зачётка` label.
- If the DB value is missing, the UI shows `Зачётка не указана`.
- Supabase schema/RLS/server functions were not changed.
- Focused analyze passed for `academic_context_service.dart` and `info_screen.dart`.
- Build smoke: `flutter build windows --debug` passed.

## Stage 3.5 follow-up - compact record book display

- Date: 2026-06-19
- The `Полезная` context strip was compacted again after visual feedback.
- Removed `course` from the strip.
- Removed the `Зачётка` prefix from the record book display.
- The strip now shows only group, semester, and the raw record book number from `AcademicContext.recordBookNumber`.
- Fallback text is `Номер не указан`.
- Focused analyze: `dart analyze lib/src/ui/info/info_screen.dart` passed.

## Stage 3.6 - full linkage and useful audit

- Date: 2026-06-19
- New audit doc: `docs/stage0_real/STAGE3_6_FULL_LINKAGE_AND_USEFUL_AUDIT.md`.
- Supabase live DB functions checked: `f_norm_schedule_subject`, `resolve_subject_offering_for_schedule`, `link_lesson_subject_from_schedule`, `f_norm_title`, `f_norm_subject`.
- Resolver calls for both test groups and required seminar/practice/Teams variants returned `matched`, `candidates_count = 1`, and non-null `subject_offering_id`.
- Important access finding: `resolve_subject_offering_for_schedule` and `link_lesson_subject_from_schedule` still have effective `anon`/`authenticated` execute through PUBLIC execute. No DB privilege change was made in this audit stage.
- All six test `subject_offerings` exist with correct groups, semester 4, academic IDs, subject IDs, and curriculum subject IDs.
- All 12 test lessons on `2026-06-19`, `2026-06-21`, and `2026-06-23` exist and are linked with `alias_match_status = matched`.
- Teams/chats duplicate check: no duplicates; each test offering has exactly 1 team and 1 `team_main` chat.
- Legacy/non-active extra members remain documented only: +2 team/chat members per test offering.
- Flutter read path checked: `get_my_lessons` stays stable and enrichment reads academic fields from `public.lessons`.
- `Полезная` checked: sections, compact academic context strip, subject grouping/cards, help placeholders, and no technical IDs.
- `Информация о предмете` checked: hero, quick actions, empty states, teacher/files/help blocks, existing chat route, no assignments, no ChatScreen rewrite.
- Runtime UI verification was blocked because `SUPABASE_URL` and `SUPABASE_ANON_KEY` are not available in the environment.
- Focused analyze: `info_screen.dart`, `subject_info_screen.dart`, and `lesson.dart` clean; schedule files still have existing warnings/infos.
- Full `flutter analyze`: 356 existing project-wide issues.
- Build: `flutter build windows --debug` passed.
- Snapshot script planned after doc updates.
- Next major stage: Stage 4 - Личный дневник текущего семестра.

## Stage 4.0 - personal diary audit

- Date: 2026-06-19
- New audit doc: `docs/stage0_real/STAGE4_0_PERSONAL_DIARY_AUDIT.md`.
- Scope: read-only audit of the existing subject diary before creating a personal current-semester diary from profile.
- Flutter code changed: no.
- Supabase schema changed: no.
- RLS changed: no.
- Tables created: no.
- Migrations created/applied: no.
- ChatScreen changed: no.
- Assignments changed or connected to diary: no.
- Git add/commit run: no.
- Preflight dirty tree: yes, many unrelated modified/deleted/untracked files existed before Stage 4.0; only Stage 0 REAL docs are intended to change.
- Found subject diary files: `subject_diary_screen.dart`, `subject_diary/*`, `diary_entry_details_screen.dart`, and `subject_diary_repository_supabase.dart`.
- Current subject diary entry points: `LessonDetailsScreen` and `SubjectInfoScreen`.
- Current subject diary screens accept only `subjectKey` and do not accept `subject_offering_id`.
- Live DB checked through Supabase MCP on project `gwdanmwluhrcfxbnplwd`.
- Live diary tables: `subject_diary_entries` and `subject_diary_files`.
- Live diary data: 4 diary entries, 7 diary files, 2 distinct authors, 3 distinct teams.
- `subject_diary_entries.author_id` exists and is filled for all 4 entries; expected `user_id` column does not exist.
- `subject_diary_files.uploaded_by` exists and is filled for all 7 files; expected `user_id` column does not exist.
- `subject_diary_entries.subject_offering_id`: exists but 0/4 entries filled.
- `subject_diary_entries.subject_id`: exists but 0/4 entries filled.
- `subject_diary_entries.lesson_id`: 1/4 entries filled; the linked lesson has no `subject_offering_id`.
- `subject_diary_entries.group_id` and `semester_number`: exist but 0/4 entries filled.
- Files/photo-conspects use `subject_diary_files` plus Yandex S3 keys under `diaries/{teamId}/{userId}/{yyyymmdd}/...`.
- Profile placement for future Stage 4.1: add `Мой дневник` in `ProfileScreen` under `Учёба`, directly after `_ExamsBanner` and before `_MapBanner`.
- Stage 4.1 recommendation: create `Мой дневник` as a read-only/current-semester aggregator from profile, using current `student_enrollments`, `group_term_semesters`, `subject_offerings`, existing diary rows, and quick links into the subject diary.
- Stage 4.2 recommendation: connect assignments from learning/chat only later; current assignment rows are team-centric and 0/1 rows have `subject_offering_id`.
- Main risk: existing diary data is team/name-driven, not offering-driven, so Stage 4.1 must not assume `subject_diary_entries.subject_offering_id` is populated.

## Stage 4.1 - personal diary MVP

- Date: 2026-06-19
- New MVP doc: `docs/stage0_real/STAGE4_1_PERSONAL_DIARY_MVP.md`.
- Flutter code changed: yes.
- Supabase schema changed: no.
- RLS changed: no.
- Tables created: no.
- Migrations created/applied: no.
- ChatScreen changed: no.
- Assignments connected: no.
- Git add/commit run: no.
- Added `SubjectDiaryArgs` with `subjectOfferingId`, `subjectId`, `subjectTitle`, `groupId`, `semesterNumber`, `lessonId`, `date`, and `legacySubjectKey`.
- `SubjectDiaryScreen` now supports both `SubjectDiaryArgs` and legacy `subjectKey`.
- `SubjectQuickNoteScreen` and `SubjectPhotoConspectScreen` now accept optional `SubjectDiaryArgs`.
- `SubjectDiaryRepository` now supports `listByArgs(...)` and optional args on add methods.
- `SubjectDiaryRepositorySupabase` keeps the old subject-name/RPC path as fallback and adds offering-aware reads/writes.
- New offering-aware diary rows write `author_id = auth.uid()`, `subject_offering_id`, `subject_id`, `group_id`, academic term/year IDs, `semester_number`, and optional `lesson_id`.
- Files/photo-conspects still use existing Yandex S3 + `subject_diary_files.entry_id`; `uploaded_by` remains handled by existing RPC.
- Created `lib/src/data/personal_diary_service.dart` to load current academic context, current-semester `subject_offerings`, diary counts, file counts, and latest real entries without prefetching files.
- Created `lib/src/ui/profile/personal_diary_screen.dart`.
- Personal diary now supports selecting available semesters from the active group's `subject_offerings`; current semester is the default.
- The subject list block is hidden when the selected semester has no subjects, and shown as `Дневники предметов` only when subjects exist.
- Added route `/my-diary` in `lib/main.dart`.
- Added profile card `Мой дневник` under `Учёба`, after `Текущий семестр` and before `Карта СПБГАСУ`.
- Updated `SubjectInfoScreen` diary action to pass `subject_offering_id`.
- Updated `LessonDetailsScreen` diary and quick-note actions to pass `subject_offering_id` and `lesson_id` when lesson linkage exists.
- Runtime test row was not created because there was no authenticated app runtime with Supabase dart-defines available; no SQL seed was used.
- Focused analyze on changed files: no errors; 63 warnings/infos remain, mostly existing `withOpacity`, unused old diary helpers, and old repository type-check warnings. Follow-up focused analyze for the semester selector change passed with no issues.
- IDE lints for changed files: no linter errors.
- Build: `flutter build windows --debug` passed.
- Next stage: Stage 4.2 - connect assignments from learning/chat into the personal diary separately.

## Stage 4.2 - assignments and personal diary audit

- Date: 2026-06-20
- New audit doc: `docs/stage0_real/STAGE4_2_ASSIGNMENTS_AND_PERSONAL_DIARY_AUDIT.md`.
- Scope: read-only audit of assignments, voting, completion status, chat cards, files, roles, subject offering linkage, and future personal diary integration.
- Flutter code changed: no.
- Supabase schema changed: no.
- RLS changed: no.
- Tables created: no.
- Migrations created/applied: no.
- ChatScreen changed: no.
- PersonalDiaryScreen changed: no.
- Assignments/votes/done rows changed: no.
- Git add/commit run: no.
- Live DB checked through Supabase MCP on project `gwdanmwluhrcfxbnplwd`.
- Assignment tables found: `assignments`, `assignment_votes`, `assignment_done`.
- `chat_messages` table not found; active chat table is `messages`.
- Live `assignments`: 1 row.
- Live `assignments.subject_offering_id`: 0/1 filled.
- Live assignment is linked to `team_id` and one `messages.assignment_id` card, but not to `subject_offering_id`, `group_id`, `subject_id`, or semester fields.
- Live `assignment_votes`: 2 rows.
- Live `assignment_done`: 0 rows.
- Current assignment status model is shared `assignments.status/published_at` plus private boolean `assignment_done.done`; no multi-status personal progress exists.
- Current creation path is `ChatComposerBar` -> `showAssignmentFormDialog` -> `TeamCubit.proposeAssignment` -> RPC `propose_assignment`.
- `propose_assignment` creates an `assignmentDraft` message and does not fill academic fields.
- Voting inconsistency found: Flutter direct-upserts `assignment_votes.value = 1`, while fallback RPC `vote_assignment` contains the `>=2` threshold but inserts no `value`; no trigger was found.
- Live row has 2 votes but remains `draft` with an `assignmentDraft` chat message.
- Role check exists in Flutter/RPC for `starosta`/trusted roles, but live `team_members` are all `member` and `users.role` values are all `student`.
- Assignment files are stored as `assignments.attachments` JSON; no `assignment_files` table and no live `chat_files` linked to assignment cards were found.
- Personal diary code currently does not read assignments.
- Recommended Stage 4.2.1: harden assignment data model and `subject_offering_id` fill path before UI integration.
- Recommended Stage 4.2.2: add published group assignments to personal diary by `subject_offering_id`.
- Recommended Stage 4.2.3: add private student personal tasks only after choosing a clean storage model.
- Recommended Stage 4.2.4: stabilize chat assignment cards, trusted publishing, and voting threshold.

## Stage 4.2.1 - assignment model hardening

- Date: 2026-06-20
- New implementation doc: `docs/stage0_real/STAGE4_2_1_ASSIGNMENT_MODEL_HARDENING.md`.
- Flutter code changed: yes.
- Supabase RPCs changed: yes, through `execute_sql`.
- Supabase tables/columns changed: no.
- RLS changed: no.
- Migrations created/applied: no.
- PersonalDiaryScreen changed: no.
- Personal student tasks created: no.
- Git add/commit run: no.
- SQL created: `supabase/stage4_2_1_assignment_model_hardening.sql`.
- Rollback created: `supabase/stage4_2_1_assignment_model_hardening_rollback.sql`.
- `Team` now carries nullable `subjectOfferingId`, `groupId`, `subjectId`, `academicYearId`, `academicTermId`, and `semesterNumber`.
- `SupabaseLearningRepository.loadTeams()` enriches teams from `public.teams` by id after existing `get_my_teams`.
- `Assignment` now carries nullable `status`, `publishedAt`, `dueAt`, `subjectOfferingId`, `groupId`, `subjectId`, `academicYearId`, `academicTermId`, and `semesterNumber`.
- `get_team_assignments` now returns assignment status and academic fields.
- `propose_assignment` now derives academic fields from `teams` and writes them into new assignments.
- `propose_assignment` now creates `assignmentPublished` immediately for trusted roles and `assignmentDraft` for ordinary members.
- `vote_assignment` now writes `assignment_votes.value = 1`, counts positive votes, publishes at threshold `>= 2`, and updates the existing linked `messages` row to `assignmentPublished`.
- Flutter voting now calls RPC `vote_assignment`; direct frontend upsert into `assignment_votes` is no longer the main path.
- `AssignmentBubble` remains inside the normal message list and now lets ordinary members see/vote on draft bubbles.
- The details done action now writes through `set_assignment_done`; boolean `completed_by_me` remains the only personal completion model.
- Existing live assignment was checked but not migrated: it remains `draft`, has 2 votes, and still has null academic fields.
- Focused analyze: no errors; 24 warnings/infos remain, mostly existing deprecated `withOpacity`, deprecated `MaterialStatePropertyAll`, and old `team_details_screen` warnings.
- IDE lints for changed files: no linter errors.
- Build: `flutter build windows --debug` passed.
- Runtime UI was not run with authenticated dart-defines; no test assignment row was created.
- Next stage: Stage 4.2.2 should read only published, `subject_offering_id`-linked group assignments into the personal diary.

## Stage 4.2.1 - chat runtime assertion fix

- Date: 2026-06-20
- Trigger: Windows app showed Flutter debug red screen with `framework.dart` assertion `_dependents.isEmpty`.
- Likely cause: chat list wrapped full message/bubble subtrees in `GlobalKey`; assignment bubbles depend on inherited providers, and moving/rebuilding global-keyed subtrees can trip Flutter's inherited dependency deactivation assert.
- Fix: `ChatMessageList` no longer global-keys the full message or bubble subtree.
- Kept: a lightweight marker `GlobalKey` for scroll/search target positioning.
- Chat message identity now uses `ValueKey('message-${m.id}')` for the actual message subtree.
- No Supabase changes, RLS changes, personal diary changes, git add, or commit.
- Focused analyze for `chat_message_list.dart`, `chat_tab.dart`, and `assignment_bubble.dart`: no errors; only existing `withOpacity` infos remain.
- IDE lints for `chat_message_list.dart`: no errors.
- Build: `flutter build windows --debug` passed.

## Stage 4.2.1B - assignment persistence fix

- Date: 2026-06-20
- New implementation doc: `docs/stage0_real/STAGE4_2_1B_ASSIGNMENT_PERSISTENCE_FIX.md`.
- Flutter code changed: yes.
- Supabase RPCs changed: yes, through `execute_sql`.
- Supabase tables/columns changed: no.
- RLS changed: no.
- Migrations created/applied: no.
- PersonalDiaryScreen changed: no.
- Personal student tasks created: no.
- Git add/commit run: no.
- SQL created: `supabase/stage4_2_1b_assignment_persistence_fix.sql`.
- Rollback created: `supabase/stage4_2_1b_assignment_persistence_fix_rollback.sql`.
- Root cause found: `get_chat_messages_for_team` did not return `assignment_id`, so assignment messages could appear through realtime/direct fetch and then lose the bubble after normal chat reload.
- `get_chat_messages_for_team` now returns `chat_id`, `msg_type`, `assignment_id`, `file_id`, and `created_at`.
- `propose_assignment` now returns JSONB with `assignment_id`, `message_id`, `msg_type`, `status`, and `published`.
- `TeamCubit.proposeAssignment` now requires both server ids and falls back to direct `loadMessageById` if normal chat reload is delayed.
- `Message.fromJson` now reads snake_case `assignment_id` and `file_id`.
- `_hydrateAssignmentIdsInChat` no longer invents `assignmentId` by parsing assignment title from message text.
- `_markDraftBubblePublished` no longer calls `repo.saveChat`, preventing duplicate message sends on publish.
- `AssignmentBubble` now shows a server-message placeholder if `assignment_id` exists but assignment details are still hydrating.
- DB check: assignment messages = 3, orphan assignment messages = 0, assignments without message = 0.
- DB check: assignments total = 3, assignments with `subject_offering_id` = 1, published assignments = 2, diary-ready published assignments = 1, `assignment_done` rows = 0.
- Focused analyze: no errors; 7 old infos remain in assignment details/tab files.
- IDE lints for changed files: no linter errors.
- Build: `flutter build windows --debug` passed.
- Runtime UI was not driven directly by the agent; live DB state shows runtime-created assignment/message rows are linked.
- Next stage: Stage 4.2.2 can read published, `subject_offering_id`-linked assignments into the personal diary.

## Stage 4.2.2 - group assignments in personal diary

- Date: 2026-06-20
- New implementation doc: `docs/stage0_real/STAGE4_2_2_GROUP_ASSIGNMENTS_IN_PERSONAL_DIARY.md`.
- Flutter code changed: yes.
- Supabase schema changed: no.
- RLS changed: no.
- Tables created: no.
- Migrations created/applied: no.
- ChatScreen changed: no.
- Assignment creation/bubble/voting changed: no.
- Personal student tasks created: no.
- Git add/commit run: no.
- `PersonalDiaryService` now loads published assignments by selected-semester `subject_offering_id`.
- Draft assignments are excluded.
- Legacy assignments with null `subject_offering_id` are excluded.
- `PersonalDiaryData` now includes assignment lists and total/completed/pending counts.
- `PersonalDiarySubject` now includes per-subject assignment count and incomplete assignment count.
- `PersonalDiaryScreen` now shows a top summary card with assignment counts.
- `PersonalDiaryScreen` now shows `Ближайшие задания` before latest entries.
- Assignment cards show title, subject, deadline, personal done badge, and done toggle.
- Assignment details open in a bottom sheet with description and done toggle.
- Done toggle uses existing `set_assignment_done`; no multi-status model was added.
- Personal status remains personal; no group-visible done list was added.
- Safe team/chat navigation was not added in this slice because the diary assignment model is lightweight and does not carry a full `Team` object.
- DB check: total assignments = 3, draft assignments = 1, legacy/null-offering assignments = 2, diary-eligible assignments = 1, `assignment_done` rows = 0 before runtime done-toggle testing.
- Focused analyze: no errors; 7 old infos remain in assignment details/tab files.
- IDE lints for changed diary files: no errors.
- Build: `flutter build windows --debug` passed.
- Runtime UI was not driven directly by the agent; DB read-only checks confirm one eligible published assignment exists.
- Next stage: Stage 4.2.3 should add private student-created personal tasks only after choosing a clean storage model.

## Stage 4.2.3 - personal tasks and subject diary assignments

- Date: 2026-06-20
- New implementation doc: `docs/stage0_real/STAGE4_2_3_PERSONAL_TASKS_AND_SUBJECT_DIARY_ASSIGNMENTS.md`.
- Flutter code changed: yes.
- Supabase schema SQL created: yes, `supabase/stage4_2_3_personal_diary_tasks.sql`.
- Rollback SQL created: yes, `supabase/stage4_2_3_personal_diary_tasks_rollback.sql`.
- Remote Supabase application: not applied; MCP returned permission errors for `execute_sql`, `apply_migration`, and read-only verification.
- RLS changed in local SQL: yes, self-only policies for `personal_diary_tasks`.
- ChatScreen changed: no.
- Assignment bubble/chat assignment creation changed: no.
- Git add/commit run: no.
- `Мой дневник` hero-card no longer shows overloaded counters.
- `Мой дневник` hero-card shows current semester and record book number when `AcademicContext.recordBookNumber` is available.
- `Мой дневник` now has local search over subjects, latest entries, published group assignments, and personal tasks.
- `Предметы семестра` replaces `Дневники с записями` and includes all current-semester subjects.
- `PersonalDiaryService` now has a separate `PersonalDiaryTask` model and does not mix personal tasks with group assignments.
- Personal tasks have statuses `todo`, `in_progress`, and `done`; `completed_at` is set/cleared by status updates.
- Personal tasks are saved through `personal_diary_tasks` and do not create messages or assignment rows.
- `Дневник предмета` now shows the subject title as the header title and `Дневник предмета` as subtitle.
- `Дневник предмета` now loads published group assignments and personal tasks for its `subject_offering_id`.
- `Дневник предмета` now has local search over entries, files, group assignments, and personal tasks.
- Draft assignments remain excluded because queries require `status = published`.
- Legacy assignments without `subject_offering_id` remain excluded.
- Focused analyze: exit code 0; only existing `withOpacity` info diagnostics remain in `subject_diary_screen.dart`.
- Build: `flutter build windows --debug` passed.
- Runtime DB checks for `personal_diary_tasks` were not completed because the remote schema could not be applied/verified through MCP permissions.
- Next stage: apply/verify the personal task SQL in Supabase, then perform authenticated runtime creation/status/search checks.

## Stage 4.2.3 follow-up - diary UX fixes

- Date: 2026-06-20
- Trigger: runtime feedback from `Мой дневник` and `Дневник предмета`.
- False failure snackbar on delayed status updates removed; the UI now silently refreshes again instead of showing `Не удалось...` before the status appears.
- `Ближайшие задания` cards are now hidden behind compact expandable groups.
- Active upcoming items and completed items are split into separate collapsed groups.
- In `Дневник предмета`, tapping a group assignment card opens assignment details instead of toggling done.
- The done toggle remains available as an explicit `Выполнить` / `Снять` button.
- Personal task form dropdown text color/readability was fixed.
- Personal task bottom sheets now have height caps and scroll better on smaller screens.
- Focused analyze: exit code 0; only existing `withOpacity` info diagnostics remain in `subject_diary_screen.dart`.
- Build: `flutter build windows --debug` passed.
- Git add/commit run: no.

## Stage 4.2.3 follow-up - compact subjects and optimistic status

- Date: 2026-06-20
- Trigger: runtime feedback that diary status changed only after leaving/re-entering the screen.
- `Мой дневник` now uses optimistic local status overrides for group assignment done state and personal task status.
- `Дневник предмета` now uses optimistic local status overrides for group assignment done state and personal task status.
- Status chips/buttons update immediately after tap while server persistence and reload continue in the background.
- `Активные дневники` and `Предметы семестра` are now separate compact expandable sections.
- `Активные дневники` contains subjects with diary records/files.
- `Предметы семестра` contains all current-semester subjects.
- Focused analyze: exit code 0; only existing `withOpacity` info diagnostics remain in `subject_diary_screen.dart`.
- Build: `flutter build windows --debug` passed.
- Git add/commit run: no.

## Stage 4.2.3 follow-up - local task fallback and diary calendar

- Date: 2026-06-20
- Trigger: runtime feedback that `Создать задачу` did not visibly create/send a personal task.
- `PersonalDiaryService.createPersonalTask` now falls back to local `shared_preferences` storage if the Supabase `personal_diary_tasks` insert fails.
- Local fallback tasks use ids prefixed with `local-`.
- Local fallback tasks are merged into the same `PersonalDiaryTask` UI lists as server tasks.
- Local fallback task status updates are persisted locally.
- This keeps the UI usable while remote `personal_diary_tasks` SQL/RLS still needs to be applied with sufficient Supabase permissions.
- Added `Календарь дневника` action to the `+` sheet in `Мой дневник`.
- The diary calendar shows day markers for latest diary entries, published group assignment deadlines, and personal task deadlines.
- Tapping a calendar event opens the subject diary, group assignment details, or personal task details.
- Focused analyze for `personal_diary_service.dart` and `personal_diary_screen.dart`: no issues found.
- Build: `flutter build windows --debug` passed.
- Git add/commit run: no.

## Stage 4.2.3 follow-up - diary calendar event dots

- Date: 2026-06-20
- Trigger: runtime feedback that the diary calendar had no visible dots/events.
- `Календарь дневника` now loads linked schedule lessons through `PersonalDiaryService.loadScheduleLessons`.
- Calendar events now include lessons/pairs.
- Calendar assignment events now include only not-done published group assignments.
- Calendar personal task events include personal task due dates.
- Calendar entry events include latest diary entries.
- The calendar opens on the nearest day that has an event instead of always opening on an empty current month.
- Day markers are now colored by event type: lessons, assignments, personal tasks, and entries.
- The `+` bottom sheet is scrollable and height-limited to avoid bottom overflow.
- Focused analyze for `personal_diary_screen.dart`: no issues found.
- Build: `flutter build windows --debug` passed.
- Git add/commit run: no.

## Stage 4.2.3B - personal task SQL and runtime check

- Date: 2026-06-20
- Trigger: apply `personal_diary_tasks` SQL, verify RLS, verify personal task persistence, and prepare a checkpoint.
- SQL applied to live Supabase project `gwdanmwluhrcfxbnplwd` through MCP `apply_migration`.
- SQL file: `supabase/stage4_2_3_personal_diary_tasks.sql`.
- Rollback checked but not run: `supabase/stage4_2_3_personal_diary_tasks_rollback.sql`.
- Added and applied `personal_diary_tasks_author_status_due_idx` for owner/status/deadline queries.
- Table `public.personal_diary_tasks` exists with expected columns.
- RLS is enabled.
- Self-only policies for select, insert, update, and delete were verified.
- `authenticated` role privileges for select, insert, update, and delete were verified.
- Created one personal task without subject and one subject-linked personal task through an authenticated role simulation.
- Verified status transitions `todo -> in_progress -> done -> todo`.
- Verified `completed_at` is filled at `done` and cleared when the task returns from `done`.
- Verified personal task creation did not create messages, assignments, assignment votes, or assignment_done rows.
- Verified current assignment DB shape remains unchanged: 3 total, 2 published, 1 draft, 2 legacy null-`subject_offering_id`, 1 diary-eligible published.
- Focused analyze: exit code 0; 22 existing `withOpacity` infos remain in `subject_diary_screen.dart`.
- Build: `flutter build windows --debug` passed.
- UI runtime was not driven interactively by the agent.
- New report: `docs/stage0_real/STAGE4_2_3B_PERSONAL_TASKS_SQL_AND_RUNTIME_CHECK.md`.

## Home notifications - persisted read state

- Date: 2026-06-23
- Trigger: runtime feedback that local-only notification read state forces repeated taps after reload/restart.
- Flutter code changed: yes, limited to home dashboard notification read state.
- Supabase schema migration written: yes, `supabase/migrations/20260623094000_home_notification_reads.sql`.
- New table design: `public.home_notification_reads` stores one row per `(user_id, notification_id)` with `read_at`.
- RLS design: enabled on `home_notification_reads`; authenticated users can select, insert, and update only their own rows.
- Client behavior: `HomeDashboardService.load()` reads persisted notification ids; tapping a notification updates UI optimistically and upserts the read marker.
- Fallback behavior: if the remote table is not applied yet or a write fails, the UI still works locally for the current session and logs the Supabase error.
- Supabase remote apply: completed through Supabase MCP `apply_migration` on project `gwdanmwluhrcfxbnplwd`.
- Remote verification: `public.home_notification_reads` exists, RLS is enabled, select/insert/update policies are scoped to `auth.uid()`, and indexes include primary key, `user_id`, and unique `(user_id, notification_id)`.
- Supabase advisors: security/performance advisors were run after apply; output contains broad pre-existing project notices, while targeted verification for `home_notification_reads` passed.
- Focused analyze: `dart analyze lib/src/ui/home/home_screen.dart lib/src/ui/home/home_dashboard_service.dart lib/src/ui/home/models/home_dashboard_data.dart` passed with no issues.
- Git add/commit run: no.

## Direct chat info - profile navigation and card refresh

- Date: 2026-07-15
- Trigger: user requested Stage 1 update for personal chat info profile navigation and design.
- Flutter code changed: yes, limited to `lib/src/ui/chats/direct_chat_info_screen.dart`.
- `DirectChatScreen` inspected: existing `BlocProvider.value` wrapper for `DirectChatInfoScreen` remains unchanged.
- `FriendProfileScreen` inspected: real profile route is `FriendProfileScreen(userId: ...)`, matching friends-list navigation.
- Removed separate `ListTile` action `Перейти в профиль пользователя`.
- Removed temporary profile `Scaffold` fallback.
- New behavior: tapping the large avatar/name card opens `FriendProfileScreen(userId: peerId)`.
- Media behavior: `Фото и файлы диалога` remains available as a separate card and still opens `ChatMediaSheet(messagesStream: service.watchMessages())`.
- Format: `dart format lib/src/ui/chats/direct_chat_info_screen.dart` passed.
- Focused analyze: `flutter analyze --no-pub lib/src/ui/chats/direct_chat_info_screen.dart` passed with no issues.
- Full analyze: `flutter analyze --no-pub` was run; it exits with existing project diagnostics outside this change, including missing `subject_quick_note_screen.dart` and undefined `getTemporaryDirectory`/`File` in `lib/src/ui/schedule/diary_entry_details_screen.dart`.
- Git add/commit run: no.

## Android debug build - AGP/NDK compatibility fix

- Date: 2026-07-15
- Trigger: Android emulator debug build failed because newer AndroidX AAR metadata requires Android Gradle Plugin `8.9.1+`, while the project used `8.7.3`; plugin `jni` also required Android NDK `28.2.13676358`.
- Android build config changed: `android/settings.gradle.kts` now uses `com.android.application` `8.9.1`.
- Android build config changed: `android/app/build.gradle.kts` now uses NDK `28.2.13676358`.
- Asset validation fix: added `assets/images/.gitkeep` because `pubspec.yaml` declares `assets/images/`.
- Verification: `flutter build apk --debug` passed and produced `build/app/outputs/flutter-apk/app-debug.apk` after a long first Gradle build.
- Git add/commit run: no.

## Direct chat info - minimal edge-to-edge redesign

- Date: 2026-07-15
- Trigger: user requested a cleaner modern personal chat info screen where only the avatar opens the user profile.
- Flutter code changed: yes, limited to `lib/src/ui/chats/direct_chat_info_screen.dart`.
- `DirectChatScreen` inspected: existing `BlocProvider.value` wrapper and header tap opening `DirectChatInfoScreen` remain unchanged.
- `FriendProfileScreen` inspected: real profile route remains `FriendProfileScreen(userId: ...)`, matching friends-list navigation.
- Removed standard app bar, `Профиль диалога`, `Личный чат`, and `Открыть профиль`.
- New behavior: only tapping the large avatar calls `HapticFeedback.selectionClick()` and opens `FriendProfileScreen(userId: peerId)`.
- Name behavior: display-only, theme-contrast color, two-line limit with ellipsis.
- Back behavior: custom blurred circular back button calls `Navigator.maybePop(context)` and accounts for top SafeArea.
- Media behavior: compact `Фото и файлы` card still opens `ChatMediaSheet(messagesStream: service.watchMessages())`.
- Format: `dart format lib/src/ui/chats/direct_chat_info_screen.dart` passed.
- Focused analyze: `flutter analyze --no-pub lib/src/ui/chats/direct_chat_info_screen.dart` passed with no issues.
- Full analyze: `flutter analyze` was run; it exits with existing project diagnostics outside this change, including missing `subject_quick_note_screen.dart` and undefined `getTemporaryDirectory`/`File` in `lib/src/ui/schedule/diary_entry_details_screen.dart`.
- Git add/commit run: no.

## Chat map - Yandex cleanup worker + final technical audit

- Date: 2026-07-18
- Trigger: close last technical tail of the chat/social map (Yandex cleanup worker + one-pass audit).
- Queue gate: `chat_file_cleanup_queue` total `0` → apply/deploy/cron allowed; no physical Yandex deletes.
- Added migration `supabase/migrations/20260718115327_chat_file_cleanup_worker.sql`: lease/claim/retry RPCs, `chat_file_cleanup_errors`, finalize + message purge, Cron schedule.
- Added Edge Function `supabase/functions/cleanup-chat-files` (Yandex DELETE via existing `YANDEX_*` secrets; 404 = success; keys only from DB).
- Secrets (names only): Edge `CLEANUP_DISPATCH_SECRET`; Vault `chat_file_cleanup_secret`. Values not logged.
- Deployed function; Cron `cleanup-chat-files` active exactly once (`*/15 * * * *`).
- Smoke: empty queue HTTP 200, `claimed=0`.
- Audit: Stage 1–11 helper grants closed for anon; friendship/blocks/archive/push outbox protected; no `Timer.periodic` on social chat screens; `deno check` OK for cleanup + push; `generate-upload-url` has pre-existing TS client typing errors; `dart format --set-exit-if-changed` reports many pre-existing style diffs (not applied); `flutter analyze` = 3 pre-existing compile errors in diary details + style infos; `flutter test` fails on stale `MyApp` widget_test.
- Status: technical map closed; remaining = device/user-scenario checks.
- Git: commit/push of cleanup worker as requested in the same session.

## Direct chat info and friend profile - back button and spacing polish

- Date: 2026-07-15
- Trigger: user requested keeping the latest design direction but moving back navigation to the normal top-left SafeArea position and tightening profile vertical spacing.
- Flutter code changed: yes, limited to `lib/src/ui/chats/direct_chat_info_screen.dart` and `lib/src/ui/friends/friend_profile_screen.dart`.
- `DirectChatInfoScreen`: removed avatar-level blurred back button, kept the edge-to-edge gradient, avatar, display-only name, and compact `Фото и файлы` card.
- `DirectChatInfoScreen`: header now uses content padding instead of a large fixed height, with tighter avatar/name/header-bottom/media-card spacing.
- `DirectChatInfoScreen`: profile navigation remains only on the large avatar; `ChatMediaSheet(messagesStream: service.watchMessages())` remains unchanged.
- `FriendProfileScreen`: removed standard `AppBar` and `Профиль` title from loading, error, and loaded states.
- `FriendProfileScreen`: added matching top-left 48x48 `arrow_back_rounded` button using `Navigator.maybePop(context)`.
- `FriendProfileScreen`: lifted avatar/name/group/status, action buttons, metrics, and friends section while preserving existing friendship, request, message, metric, and list logic.
- Overflow handling: long name/group/status text now has line limits and ellipsis in the profile header.
- Format: `dart format lib/src/ui/chats/direct_chat_info_screen.dart lib/src/ui/friends/friend_profile_screen.dart` passed.
- Focused analyze: `flutter analyze --no-pub lib/src/ui/chats/direct_chat_info_screen.dart lib/src/ui/friends/friend_profile_screen.dart` ran; no new compile errors, existing `FriendProfileScreen` warnings/infos remain.
- Full analyze: `flutter analyze` was run; it exits with existing project diagnostics outside this change, including missing `subject_quick_note_screen.dart` and undefined `getTemporaryDirectory`/`File` in `lib/src/ui/schedule/diary_entry_details_screen.dart`.
- Git add/commit run: no.
