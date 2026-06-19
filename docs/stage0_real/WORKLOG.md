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
