# Stage 2.2 - Schedule Read Path Subject Link

Date: 2026-06-19

Scope: minimally extend the Flutter schedule read path so lessons can carry `subject_id` and `subject_offering_id`, show linked status, and open a minimal SubjectHub check screen.

No RLS, Supabase schema, tables, policies, seed/rollback, ChatScreen, or chat module code were changed.

## Preflight

- Correct project: `C:\student_platform`
- Branch expected by request: `refactor/chat-tab`
- Working tree before Stage 2.2: already dirty with many unrelated modified/deleted/untracked files.
- No `git add`, commit, or unrelated formatting was run.

## Previous Read Path

Before Stage 2.2:

`ScheduleScreen -> ScheduleRepository.loadMonth -> rpc get_my_lessons -> Lesson.fromMap -> LessonCard -> LessonDetailsScreen`

`get_my_lessons` returns:

- `id`
- `week`
- `day`
- `date`
- `pair_num`
- `time_start`
- `time_end`
- `subject`
- `room`
- `teacher`

It does not return:

- `group_id`
- `subject_id`
- `subject_offering_id`
- `academic_year_id`
- `academic_term_id`
- `semester_number`
- `alias_match_status`

## Chosen Approach

Chosen: Variant B, Flutter enrichment adapter.

Reason: changing `get_my_lessons` would require changing a live SQL function return type and could affect existing callers. The adapter keeps the RPC stable and performs a second read-only query by returned lesson IDs:

`public.lessons.select(id, group_id, subject_id, subject_offering_id, academic_year_id, academic_term_id, semester_number, alias_match_status).inFilter('id', ids)`

If enrichment fails, the UI keeps using the original lessons with nullable link fields.

## Flutter Changes

### Lesson Model

`lib/src/ui/schedule/models/lesson.dart` now has nullable fields:

- `groupId`
- `subjectId`
- `subjectOfferingId`
- `academicYearId`
- `academicTermId`
- `semesterNumber`
- `aliasMatchStatus`

It also has:

- `copyWithAcademicFields`
- `hasSubjectLink`

Existing constructors remain compatible because all new fields are optional.

### Schedule Repository

`ScheduleRepository.loadMonth` still calls `get_my_lessons`. After mapping the RPC rows to `Lesson`, it enriches them from `public.lessons` by `id`.

No Supabase writes are performed.

### Schedule Card

`LessonCard` now shows a small linked-state line:

- `Предмет связан` when `subjectOfferingId != null`;
- `Не привязано` when no link is present.

The existing card structure and tap flow remain unchanged.

### Lesson Details

`LessonDetailsScreen` now shows a subject link block:

- linked lesson: `Предмет связан`, small `subject_offering_id`, enabled `Открыть предмет` button;
- unlinked lesson: `Предмет не привязан`, disabled `Открыть предмет` button.

Existing quick note and subject diary buttons remain unchanged.

### SubjectHub

No existing SubjectHub screen was found in `lib/`, so Stage 2.2 added a minimal check screen:

`lib/src/ui/schedule/subject_hub_screen.dart`

It displays:

- subject title;
- `subject_id`;
- `subject_offering_id`;
- `lesson_id`;
- semester number;
- placeholder rows for `Чат`, `Задания`, `Дневник`, `Файлы`, `Полезное`.

Chat/team actions are intentionally not connected in this stage.

## Test Pair Expectations

The Stage 2.1 data should now be visible to Flutter as linked lessons:

| Group | Pair variants | Expected subject_offering_id |
|---|---|---|
| `1-См(ВВ)-2` | `Тест 1 (сем.)` / `Тест 1, практика Teams TEST-1` | `cbb94b65-5eab-49dd-ba68-376204364a79` |
| `1-См(ВВ)-2` | `Тест 2 (л.)` / `Тест 2 (лаб.)` | `006161e3-0800-48e9-8aad-1647f1b12bbd` |
| `2-См(ВВ)-2` | `Проверка 1 (сем.)` / `Проверка 1, практика Teams TEST-A` | `f9eb2899-e24d-4981-8597-abaad7092401` |
| `2-См(ВВ)-2` | `Проверка 2 (л.)` / `Проверка 2 (лаб.)` | `c62045c0-0f41-4d72-a226-0b266851250f` |

Manual runtime login/date navigation was not performed in this agent run because it requires interactive test-student credentials. `flutter devices` found Windows, Chrome, and Edge targets.

## Verification

- IDE diagnostics for changed Stage 2.2 files: no linter errors.
- Focused analyze command:
  `dart analyze lib/src/ui/schedule/models/lesson.dart lib/src/ui/schedule/schedule_screen.dart lib/src/ui/schedule/widgets/lesson_card.dart lib/src/ui/schedule/lesson_details_screen.dart lib/src/ui/schedule/subject_hub_screen.dart`
- Focused analyze result: no errors and no new Stage 2.2 warnings; existing schedule warnings remain (`_pickDateFromHeader`, unused optional parameters) plus existing `withOpacity` infos in old schedule widgets.
- Full `flutter analyze`: still fails on pre-existing project-wide warnings/infos; latest run reported 358 issues. No Stage 2.2 errors were introduced.

## Next Stage

Stage 3 should fill SubjectHub with real blocks, then connect the existing team/chat flow through `subject_offering_id`.

Do not rewrite ChatScreen/chat module as part of the first SubjectHub content stage.
