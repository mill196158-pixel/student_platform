# Stage 2.3 - Server Schedule Resolver And Useful Subject Info

Date: 2026-06-19

Scope: add server-side schedule subject resolving/linking for future parser inserts, add Stage 2.3 parser test data, remove user-facing debug link labels from schedule UI, and route linked lessons to a user-facing `Информация о предмете` screen in the `Полезная` area.

No RLS, policies, tables, `get_my_lessons`, ChatScreen, chat module, assignments UI, git add, or commit were changed.

## Preflight

- Correct project: `C:\student_platform`
- Branch expected by request: `refactor/chat-tab`
- Preflight command: `git status --short`
- Working tree before Stage 2.3: already dirty with many unrelated modified/deleted/untracked files. Relevant Stage 2.2 files were already present in the dirty tree, including schedule read-path/detail/card files and the temporary `subject_hub_screen.dart`.
- No `git add` or commit was run.
- Formatting was limited to Stage 2.3 Dart files.

## SQL Files

- Apply file: `supabase/stage2_3_schedule_subject_resolver.sql`
- Rollback file: `supabase/stage2_3_schedule_subject_resolver_rollback.sql`

Rollback deletes only Stage 2.3 test rows for:

- `Тест парсинга пары`
- `Проверка парсинга пары`
- lessons on `2026-06-23`
- teams/chats marked by `stage2_3_schedule_subject_resolver`
- functions created in this stage

It does not touch Stage 2.1 data: `Тест 1`, `Тест 2`, `Проверка 1`, `Проверка 2`.

## Normalization

Created:

- `public.f_norm_schedule_subject(t text)`

Reason: live `public.f_norm_subject` removes parenthesized `(сем.)`, `(л.)`, `(пр.)`, `(лаб.)`, but does not remove plain trailing `семинар`, `лекция`, `практика`, `лабораторная`, `зачёт`, `экзамен`, or Teams/команда technical suffixes.

Verified normalization examples:

- `Тест парсинга пары (сем.)` -> `тест парсинга пары`
- `Тест парсинга пары семинар` -> `тест парсинга пары`
- `Тест парсинга пары, практика Teams PARSE-1` -> `тест парсинга пары`
- `Тест парсинга пары лекция` -> `тест парсинга пары`
- `Тест парсинга пары лабораторная` -> `тест парсинга пары`
- `Тест парсинга пары зачёт` -> `тест парсинга пары`
- `Тест парсинга пары команда TEST-1` -> `тест парсинга пары`

## Resolve Function

Created:

`public.resolve_subject_offering_for_schedule(p_group_id uuid, p_raw_subject text, p_lesson_date date default null, p_semester_number integer default null)`

Returns one row:

- `subject_id`
- `subject_offering_id`
- `match_status`
- `normalized_input`
- `matched_alias`
- `candidates_count`
- `reason`

Behavior:

- normalizes input with `f_norm_schedule_subject`;
- uses explicit `p_semester_number` when passed;
- otherwise resolves semester from `group_term_semesters` + `academic_terms` by lesson date;
- searches `subject_offerings` only for the target group and semester/term;
- matches through `subject_aliases`, `subject_catalog`, `subject_offerings.display_name`, and `curriculum_subjects`;
- returns `matched` only when exactly one unique `subject_offering_id` is found;
- returns `not_found`, `ambiguous`, `no_term`, or `no_group` without creating or updating data.

Important implementation note: multiple aliases for the same `subject_offering_id` are counted as one candidate. The first live attempt surfaced this issue and it was fixed before final verification.

## Link Function

Created:

`public.link_lesson_subject_from_schedule(p_lesson_id uuid)`

Behavior:

- loads one `public.lessons` row;
- calls `resolve_subject_offering_for_schedule`;
- on `matched`, updates only `subject_id`, `subject_offering_id`, `normalized_subject_name`, and `alias_match_status = 'matched'`;
- on `ambiguous`, clears subject IDs and sets `alias_match_status = 'ambiguous'`;
- on `not_found`/`no_term`, clears subject IDs and sets `alias_match_status = 'pending'`.

Note: `lessons.alias_match_status` currently allows `matched`, `pending`, `ambiguous`, and `ignored`; it does not allow a literal `not_found` value, so the function returns `not_found` but stores `pending` for unresolved lessons.

## Function Access

Executed:

- `revoke all on function public.link_lesson_subject_from_schedule(uuid) from anon, authenticated`
- `revoke all on function public.resolve_subject_offering_for_schedule(uuid, text, date, integer) from anon, authenticated`
- `grant execute ... to service_role`

The Flutter client does not use `service_role` and does not call the link function.

## Parser Integration

Searches for active parser/import code by `parseSchedule`, `parser`, `schedule import`, `lessons insert`, `get_my_lessons`, `СПбГАСУ`, `расписание`, `f_norm_subject`, `subject_alias`, and `alias_match_status` did not find an active schedule parser implementation that inserts lessons.

Future parser usage:

1. Insert a lesson into `public.lessons` with `group_id`, raw `subject`, date, time, and optional `semester_number`.
2. Call `select * from public.link_lesson_subject_from_schedule('<lesson_id>');` from trusted server/service code.
3. If the parser already knows group/semester/title and wants a dry run, call `resolve_subject_offering_for_schedule` first.

Do not call `link_lesson_subject_from_schedule` from Flutter.

## Test Data

Created and applied idempotently with marker `stage2_3_schedule_subject_resolver`.

For group `1-См(ВВ)-2`:

- subject: `Тест парсинга пары`
- `subject_id`: `85737173-da2e-482f-8fce-80126fc486a2`
- `subject_offering_id`: `7e4bb6eb-e812-4b37-8ec0-1ce6f72bec8b`
- `team_id`: `46a8c853-3e8b-4704-9749-2e2c01a1c266`
- `chat_id`: `8fdce2bf-656b-4862-a486-66d7cbd7d698`

For group `2-См(ВВ)-2`:

- subject: `Проверка парсинга пары`
- `subject_id`: `4f72f450-0e30-47aa-8689-749aabe059d0`
- `subject_offering_id`: `95fb3bc2-69b9-4805-8aad-ec700f4ae5ae`
- `team_id`: `860d41b0-3f34-4854-a66e-1b8aa2572b20`
- `chat_id`: `0bbc1b2d-b2ae-47b1-b1c4-d57a1ed45218`

Aliases include base, `(сем.)`, `семинар`, `, практика`, `Teams`, and `, практика Teams` variants.

## Test Lessons

Inserted as unresolved lessons first (`subject_id = null`, `subject_offering_id = null`) and then linked through `link_lesson_subject_from_schedule`.

Date: `2026-06-23`

Verified results:

| Group | Lesson | subject_offering_id | Status |
|---|---|---|---|
| `1-См(ВВ)-2` | `Тест парсинга пары (сем.)` | `7e4bb6eb-e812-4b37-8ec0-1ce6f72bec8b` | `matched` |
| `1-См(ВВ)-2` | `Тест парсинга пары, практика Teams PARSE-1` | `7e4bb6eb-e812-4b37-8ec0-1ce6f72bec8b` | `matched` |
| `2-См(ВВ)-2` | `Проверка парсинга пары (сем.)` | `95fb3bc2-69b9-4805-8aad-ec700f4ae5ae` | `matched` |
| `2-См(ВВ)-2` | `Проверка парсинга пары, практика Teams PARSE-A` | `95fb3bc2-69b9-4805-8aad-ec700f4ae5ae` | `matched` |

Both seminar and practice/Teams variants resolve to the same `subject_offering_id` for their group.

## Flutter UI Changes

Changed:

- `lib/src/ui/schedule/widgets/lesson_card.dart`
- `lib/src/ui/schedule/lesson_details_screen.dart`
- `lib/src/ui/info/info_screen.dart`
- `lib/src/ui/info/subject_info_screen.dart`

Deleted:

- `lib/src/ui/schedule/subject_hub_screen.dart`

Schedule card:

- removed user-facing `Предмет связан` / `Не привязано`.

Lesson details:

- removed technical `subject_offering_id` display;
- replaced debug block with a user-facing `Информация о предмете` action;
- disabled the action with soft text if the lesson is not linked.

`Информация о предмете` screen:

- title: `Информация о предмете`;
- loads existing `subject_offerings`, `subject_catalog`, `curriculum_subjects`, `teams`, and `chats`;
- shows blocks:
  - `Краткая информация`
  - `Преподаватель`
  - `Полезные файлы`
  - `Чат`
  - `Дневник`
- does not show `subject_id` or `subject_offering_id` to the user;
- does not add assignments;
- opens the existing subject diary screen by button;
- keeps chat as a block without rewriting ChatScreen.

`Полезная` tab:

- now loads current academic context through `AcademicContextService`;
- lists current-semester `subject_offerings` for the student's group/semester;
- each card shows subject title, semester, control form if present, description if present, and `Открыть`.

## Verification

SQL:

- resolver matched seminar variants;
- resolver matched practice variants;
- Teams codes did not prevent matching;
- all four Stage 2.3 lessons have `subject_id`, `subject_offering_id`, `normalized_subject_name`, and `alias_match_status = matched`;
- teams/chats exist for both new subject offerings.

Flutter:

- focused command:
  `dart analyze lib/src/ui/info/info_screen.dart lib/src/ui/info/subject_info_screen.dart lib/src/ui/schedule/lesson_details_screen.dart lib/src/ui/schedule/widgets/lesson_card.dart`
- result: no new Stage 2.3 errors; old schedule warnings/infos remain in existing files.
- full `flutter analyze`: still fails with 358 project-wide issues, consistent with Stage 2.2. The output is dominated by pre-existing warnings/infos such as unnecessary type checks and deprecated `withOpacity`.

Manual runtime navigation with test-student credentials was not performed by the agent.

## Not Changed

- RLS: not changed.
- Policies: not changed.
- Tables: no new tables.
- `get_my_lessons`: not changed.
- `ScheduleScreen`: not rewritten.
- `ChatScreen`: not changed.
- Chat module: not rewritten.
- Assignments were not added to useful subject information.

## Next Stage

Stage 4: fill `Информация о предмете` with real useful materials/files and connect concrete data sources for templates, examples, methodical materials, chat opening, and richer teacher/difficulty information.
