# Stage 3.3 - Useful Tab Advanced UX

Date: 2026-06-19

Scope: visual UX polish for the `Полезная` tab after Stage 3.2 design feedback. This stage keeps the existing data/navigation logic and changes only UI/UX around section selection, filters, subject cards, help cards, and the lesson subject-info entry point.

No RLS, Supabase schema, server functions, parser, ChatScreen, ScheduleScreen rewrite, assignments, technical IDs, or new general diary were changed.

## Preflight

- Correct project: `C:\student_platform`
- Branch expected by request: `refactor/chat-tab`
- Preflight command: `git status --short`
- Working tree before Stage 3.3: already dirty with many unrelated modified/deleted/untracked files. Relevant Stage 3.2 files were already dirty/untracked: `lib/src/ui/info/info_screen.dart`, `lib/src/ui/info/subject_info_screen.dart`, `lib/src/ui/schedule/lesson_details_screen.dart`, `docs/stage0_real/*`, and snapshots.
- No `git add` or commit was run.
- Formatting was limited to Stage 3.3 Dart files.

## Useful Header

The large `Предметы` / `Справка` segmented control was removed from the screen body.

Section selection moved into the `Полезная` header:

- the header keeps the app-style icon, title, and subtitle;
- the right side now has a soft round section button;
- tapping the button opens a bottom sheet titled `Раздел`;
- options are `Предметы` and `Справка`;
- the selected option is marked with an accent/check.

## Active Section Block

Under the header, the screen now shows a light active-section intro:

- `Предметы семестра` with `Учебный план, материалы и информация по дисциплинам`;
- `Справочная информация` with `Инструкции, доступы, документы и бытовые вопросы`.

The block is text-led and light, without a heavy square border.

## Pill Selectors

The square dropdown fields `Семестр` and `Тип` were removed.

Subject filters now use compact pill selectors:

- semester pill, for example `4 семестр • текущий`;
- type pill, for example `Все`;
- pills have rounded corners, soft tint, icons, and a small down arrow;
- tapping a pill opens a bottom sheet instead of a form-like dropdown.

Bottom sheets:

- `Семестр`: lists available semesters, marks the current semester with `текущий`, and marks the selected item with a check;
- `Тип`: lists `Все`, `Экзамены`, `Зачёты`, `Практики`, `Курсовые / КР`, and marks the selected item with a check.

Current semester and type-filter behavior stayed unchanged.

## Subject Cards

Subject cards were redesigned to feel lighter and more premium:

- the whole card remains clickable;
- the `Открыть` button was not restored;
- right chevron remains;
- border radius increased to a softer card shape;
- card tint/gradient and softer shadow were added;
- a small circular subject initial/accent appears on the left;
- title, description/placeholder, compact badges, and teacher remain.

Badges remain compact and user-facing:

- semester;
- control type;
- `Материалы`;
- `Дневник`;
- `Чат` only when a chat exists.

If a description is not filled, the placeholder remains: `Информация появится после заполнения материалов.`

## Help Section

The `Справка` section now opens through the header section button and uses card-style instruction entries, not a plain list.

Static help cards remain local placeholders without DB integration:

- `Как зайти в личный кабинет`;
- `Как скачать нужные материалы`;
- `Как заказать справку`;
- `Как установить нужные программы`;
- `Карта и аудитории`;
- `Частые вопросы`.

Tapping a help card opens the existing placeholder bottom sheet: `Информация будет добавлена позже.`

## Lesson Details

`LessonDetailsScreen` keeps the whole `Информация о предмете` block clickable.

The duplicate button is not present. The linked-state text is now:

`Краткая информация, материалы, чат и дневник предмета.`

Unlinked lessons keep a disabled state: `Информация по предмету пока не доступна.`

## Subject Info Screen

`Информация о предмете` was checked and kept as the destination for subject cards and linked lessons.

It keeps:

- `Краткая информация`;
- `Преподаватель`;
- `Полезные файлы`;
- `Чат`;
- `Дневник`.

Technical IDs, `Предмет связан`, debug labels, and assignment blocks are not shown.

## Verification

Flutter:

- `dart format lib/src/ui/info/info_screen.dart lib/src/ui/info/subject_info_screen.dart lib/src/ui/schedule/lesson_details_screen.dart`: passed.
- `dart analyze lib/src/ui/info/info_screen.dart lib/src/ui/info/subject_info_screen.dart`: no issues.
- Focused analyze including `lesson_details_screen.dart`: only old existing warnings/infos in `lesson_details_screen.dart` remain.
- Full `flutter analyze`: still fails on existing project-wide issues; current count is 356 issues.
- `flutter build windows --debug`: passed.

Runtime:

- Interactive runtime UI verification could not be completed without Supabase dart-defines.
- Existing Windows run built successfully, then stopped at app startup because `SUPABASE_URL` and `SUPABASE_ANON_KEY` were not provided.

## Not Changed

- RLS: not changed.
- Supabase schema/tables: not changed.
- Server functions: not changed.
- Parser: not changed.
- ChatScreen: not changed.
- ScheduleScreen: not rewritten.
- Assignments: not added.
- Technical IDs: not shown in UI.
- `Открыть` button: not restored in subject cards.
