# Stage 3.2 - Useful Tab Structure And Lesson Link UX

Date: 2026-06-19

Scope: simplify the `Полезная` tab UX, replace chip-heavy filters with dropdowns, add a separate `Справка` block, remove redundant open buttons from subject cards, and make the lesson subject-info block itself clickable.

No RLS, Supabase schema, tables, parser, ChatScreen, ScheduleScreen rewrite, assignments, PDF export, general diary, or gamification were changed.

## Preflight

- Correct project: `C:\student_platform`
- Branch expected by request: `refactor/chat-tab`
- Preflight command: `git status --short`
- Working tree before Stage 3.2: already dirty with many unrelated modified/deleted/untracked files. Relevant Stage 3.1 files were already dirty/untracked: `lib/src/ui/info/info_screen.dart`, `lib/src/ui/info/subject_info_screen.dart`, `docs/stage0_real/*`, and snapshots.
- No `git add` or commit was run.
- Formatting was limited to Stage 3.2 Dart files.

## Useful Tab Structure

`lib/src/ui/info/info_screen.dart` now has:

1. Existing app-style header:
   - icon;
   - `Полезная`;
   - `Информация и материалы по предметам`.
2. Segmented switch:
   - `Предметы`;
   - `Справка`.

Default section: `Предметы`.

## Subject Filters

The previous horizontal chip rows were removed.

The `Предметы` section now uses one compact row:

- dropdown `Семестр`;
- dropdown `Тип`.

Defaults:

- `Семестр`: current student semester when available;
- `Тип`: `Все`.

Type options:

- `Все`
- `Экзамены`
- `Зачёты`
- `Практики`
- `Курсовые / КР`

If no subject matches a type, the screen shows a soft empty state and does not break.

## Subject Cards

The redundant `Открыть` button was removed from subject cards.

Subject cards are clickable as a whole and keep the chevron on the right. Tap opens `Информация о предмете`.

Card content:

- subject title;
- semester badge;
- control-form badge when present;
- `Материалы` badge;
- `Дневник` badge;
- `Чат` badge when a chat exists;
- real description or placeholder: `Информация появится после заполнения материалов.`

No technical IDs are shown.

## Help Section

Added the separate `Справка` section inside `Полезная`. It is not mixed with subjects and does not use new DB tables.

Static help cards:

- `Как зайти в личный кабинет` — `Краткая инструкция по входу и восстановлению доступа.`
- `Как скачать нужные материалы` — `Где искать файлы, методички и шаблоны.`
- `Как заказать справку` — `Основные действия для получения справки в университете.`
- `Как установить нужные программы` — `AutoCAD, Revit, офисные программы и другое ПО.`
- `Карта и аудитории` — `Как найти корпус, кабинет или аудиторию.`
- `Частые вопросы` — `Ответы на бытовые вопросы по учёбе.`

For Stage 3.2, tapping a help card opens a bottom sheet placeholder: `Информация будет добавлена позже.`

## Subject Info Screen

`lib/src/ui/info/subject_info_screen.dart` was checked and remains the logical continuation of a subject card.

It contains:

- top card with subject title, semester, control form, credits/hours when available;
- `Краткая информация`;
- `Преподаватель`;
- `Полезные файлы`;
- `Чат`;
- `Дневник`.

The chat button remains inside `Информация о предмете` and opens existing `TeamDetailsScreen(initialTabIndex: 1)` when the existing team/chat is found.

The diary button opens existing `SubjectDiaryScreen`.

Assignments were not added.

## Lesson Details UX

`lib/src/ui/schedule/lesson_details_screen.dart` changed only in the `Информация о предмете` block:

- removed the separate duplicate button;
- made the whole block clickable;
- added a right chevron;
- linked lessons open `SubjectInfoScreen`;
- unlinked lessons show disabled text: `Информация по предмету пока не доступна.`

No `Предмет связан`, `Не привязано`, `subject_id`, or `subject_offering_id` is shown to users.

## Navigation

Verified in code:

- `Полезная` -> subject card tap -> `SubjectInfoScreen`;
- `Расписание` -> lesson -> clickable `Информация о предмете` block -> `SubjectInfoScreen`;
- `SubjectInfoScreen` -> `Открыть чат предмета` -> existing `TeamDetailsScreen` chat tab;
- `SubjectInfoScreen` -> `Дневник предмета` -> existing `SubjectDiaryScreen`.

No new team/chat creation or chat membership changes were added.

## Verification

Flutter:

- `dart analyze lib/src/ui/info/info_screen.dart lib/src/ui/info/subject_info_screen.dart`: no issues.
- Focused analyze including `lesson_details_screen.dart`: no new errors; old `lesson_details_screen.dart` warnings/infos remain.
- Full `flutter analyze`: still reports 358 existing project-wide issues, consistent with Stage 3.1.

Runtime:

- Not rerun in Stage 3.2 because Stage 3.1 already showed Windows build succeeds but runtime requires missing `SUPABASE_URL` / `SUPABASE_ANON_KEY` dart-defines.

## Not Changed

- RLS: not changed.
- Supabase schema/tables: not changed.
- Parser: not changed.
- ChatScreen: not changed.
- ScheduleScreen: not rewritten.
- Assignments: not added.
- Technical IDs: not shown.
- `Предмет связан` / `Не привязано`: not restored.

## Next Stage

Stage 3.3/4 should fill the help cards and useful file sections with real content/data sources, still without mixing assignments into `Полезная`.
