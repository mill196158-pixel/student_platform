# Stage 3.5 - Useful Exams Style And Subject Empty State

Date: 2026-06-19

Scope: bring the body of `Полезная` closer to the successful `Зачёты и экзамены` style, reduce empty-feeling subject information screens, and address a runtime Flutter semantics assertion around recent interactive UI.

No RLS, Supabase schema, server functions, parser, ChatScreen, ScheduleScreen, new packages, assignments, technical IDs, or `Предмет связан` UI were changed.

## Preflight

- Correct project: `C:\student_platform`
- Branch expected by request: `refactor/chat-tab`
- Preflight command: `git status --short`
- Working tree before Stage 3.5: already dirty with many unrelated modified/deleted/untracked files. Relevant Stage 3.3/3.4 files were already dirty/untracked: `lib/src/ui/info/info_screen.dart`, `lib/src/ui/info/subject_info_screen.dart`, `lib/src/ui/schedule/lesson_details_screen.dart`, `docs/stage0_real/*`, and snapshots.
- No `git add` or commit was run.
- Formatting was limited to Stage 3.5 Dart files.

## Semantics Assertion

Runtime assertion reported:

`Failed assertion: '!semantics.parentDataDirty': is not true.`

Likely Stage 3.3 trigger:

- bottom sheet option taps closed the route and immediately called `setState` in the same tap callback;
- this affected section/semester/type selectors in `Полезная`.

Fix:

- section selector now awaits `showModalBottomSheet<_UsefulSection>()`;
- semester selector now awaits `showModalBottomSheet<int>()`;
- type selector now awaits `showModalBottomSheet<_UsefulFilter>()`;
- sheet tiles only `pop(selectedValue)`;
- parent callbacks run after the sheet is closed;
- state updates are guarded with `mounted` where the state object is involved.

Additional simplification:

- removed a `Spacer` from compact quick action cards in `SubjectInfoScreen`, replacing it with a fixed gap to keep layout/semantics geometry simpler.

## Useful Tab Body

The `Полезная` header was not changed.

The body now follows the `Зачёты и экзамены` structure more closely:

- light background: `#F7F7FB`;
- top semester summary-card with purple gradient/tint;
- selected/current semester title;
- subject count;
- control-form count;
- chat count;
- compact semester/type pill filters kept below the summary;
- selected semester content is shown in an `ExpansionTile` style section.

## Subject Grouping

Subjects are grouped by control form:

- `Экзамены`;
- `Зачёты`;
- `Зачёты с оценкой`;
- `Практики`;
- `Курсовые / КР`;
- `Другие формы контроля`.

Empty groups are not shown. If a type filter is selected, only matching subjects/groups are displayed.

## Subject Cards

Subject cards were changed from large tinted rectangles to compact cards inside the semester/control sections:

- full card remains clickable;
- no `Открыть` button was restored;
- small subject initial/avatar on the left;
- title with multiline support;
- teacher/description/placeholder subtitle;
- compact control-form pill;
- small status icons for files, diary, and chat;
- right chevron.

## Help Section

`Справка` remains available through the header section selector.

It now uses an exams-style structure:

- summary-card: `Справочная информация`;
- grouped sections:
  - `Доступы`;
  - `Документы`;
  - `Программы`;
  - `Карта и аудитории`;
  - `Частые вопросы`.

Cards remain static local placeholders and do not use DB.

## Subject Info Empty State

`Информация о предмете` no longer feels like a long list of empty blocks when real data is missing.

Changes:

- added a prominent empty-content callout in `Краткая информация` when description/control data are missing;
- kept human-readable placeholders instead of empty/raw text;
- replaced the long list of empty file rows with one polished file empty-state:
  `Материалы пока не загружены`;
- kept teacher placeholder: `Преподаватель будет указан позже.`;
- kept technical/seed value filtering from Stage 3.4.

Still preserved:

- hero-card;
- quick actions: chat, diary, files;
- brief information;
- teacher;
- useful files;
- chat;
- diary;
- soft help block.

## Navigation

Preserved in code:

- `Полезная` -> subject card -> `SubjectInfoScreen`;
- `Расписание` -> lesson details -> `SubjectInfoScreen`;
- `SubjectInfoScreen` -> chat -> existing `TeamDetailsScreen(initialTabIndex: 1)`;
- `SubjectInfoScreen` -> diary -> existing `SubjectDiaryScreen`.

No ChatScreen rewrite or new chat creation was added.

## Verification

Focused analyze:

- `dart analyze lib/src/ui/info/info_screen.dart`: no issues.
- `dart analyze lib/src/ui/info/subject_info_screen.dart`: no issues.
- `dart analyze lib/src/ui/schedule/lesson_details_screen.dart`: existing old warnings/infos remain in `lesson_details_screen.dart`; no Stage 3.5 code change was needed there.

Project/build:

- Full `flutter analyze`: still reports 356 existing project-wide issues.
- `flutter build windows --debug`: passed.

Runtime:

- Interactive runtime was not completed because this environment still lacks `SUPABASE_URL` and `SUPABASE_ANON_KEY` dart-defines for app startup.

## Not Changed

- RLS: not changed.
- Supabase schema/tables: not changed.
- Server functions: not changed.
- Parser: not changed.
- ChatScreen: not changed.
- ScheduleScreen: not changed.
- New packages: not added.
- Assignments: not added.
- Technical IDs: not rendered.
- `Предмет связан`: not shown.
- `Открыть` button on subject cards: not restored.
