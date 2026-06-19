# Stage 3.4 - Subject Info Figma UI

Date: 2026-06-19

Scope: redesign `Информация о предмете` into a modern, soft, card-based UI while preserving the current data source and navigation behavior.

No RLS, Supabase schema, server functions, parser, ChatScreen, new packages, assignments, technical IDs, or route rewrites were changed.

## Preflight

- Correct project: `C:\student_platform`
- Branch expected by request: `refactor/chat-tab`
- Preflight command: `git status --short`
- Working tree before Stage 3.4: already dirty with many unrelated modified/deleted/untracked files. Relevant files already dirty/untracked from prior stages included `lib/src/ui/info/subject_info_screen.dart`, `lib/src/ui/info/info_screen.dart`, `lib/src/ui/schedule/lesson_details_screen.dart`, `docs/stage0_real/*`, and snapshots.
- No `git add` or commit was run.
- Formatting was limited to `lib/src/ui/info/subject_info_screen.dart`.

## Existing Logic Preserved

`SubjectInfoScreen` still loads:

- `subject_offerings`;
- `subject_catalog`;
- `curriculum_subjects`;
- `teams`;
- `chats`.

Navigation remains:

- `Полезная` subject card -> `SubjectInfoScreen`;
- `Расписание` lesson details -> `SubjectInfoScreen`;
- `SubjectInfoScreen` chat action -> existing `TeamDetailsScreen(initialTabIndex: 1)`;
- `SubjectInfoScreen` diary action -> existing `SubjectDiaryScreen`.

No new chat creation or chat membership logic was added.

## Hero Zone

The old simple top block was replaced with a strong subject hero-card:

- large circular subject initial;
- subject title with multiline support;
- human-readable meta line;
- soft gradient/tint;
- large rounded corners;
- subtle border and shadow;
- chips for `Материалы`, `Чат`/`Чат позже`, and `Дневник`.

Zero `credits`/`hours` are hidden. Missing or technical control type is shown as `Тип контроля уточняется`.

## Quick Actions

Added compact quick actions under the hero-card:

- `Чат`;
- `Дневник`;
- `Файлы`.

Chat is enabled only when the existing team/chat is found. Diary opens the existing diary route. Files scroll to the `Полезные файлы` block.

## Technical Value Handling

User-facing display values now pass through safe getters:

- empty strings are replaced with placeholders;
- `null`, `none`, `dev`, `test`, `stage2_schedule_subject_resolver`, `stage2_*`, and `*_resolver` are not displayed as user content;
- `0 з.е.` and `0 ч.` are not displayed;
- missing description becomes `Информация по предмету будет добавлена позже.`;
- missing control form becomes `Тип контроля уточняется`;
- missing teacher becomes `Преподаватель будет указан позже.`

Technical fields are still used internally for data loading, but technical IDs are not rendered in the UI.

## Redesigned Blocks

### Краткая информация

Replaced raw text rows with a content-card and structured info tiles:

- `Описание`;
- `Как сдаётся`;
- `Что обычно важно`;
- `Сложность предмета`.

Placeholders are human-readable and avoid raw empty/technical data.

### Преподаватель

Replaced plain text with a teacher-card:

- avatar placeholder;
- teacher name or placeholder;
- `Преподаватель` subtitle;
- small difficulty status pill: `Сложность сдачи: пока нет данных`.

No reviews or student comments were added.

### Полезные файлы

Replaced text-only file lines with file-category rows:

- `Шаблоны`;
- `Примеры работ`;
- `Методички`;
- `Загруженные файлы`.

Rows include icons, titles, subtitles, and a disabled/pending visual state.

### Чат

Replaced the basic action section with a modern action-card:

- title: `Чат предмета`;
- enabled subtitle: `Обсуждения, вопросы и материалы группы`;
- disabled subtitle: `Чат пока не создан`;
- action label: `Открыть чат`.

When enabled, it opens the existing chat flow through `TeamDetailsScreen(initialTabIndex: 1)`.

### Дневник

Replaced the basic action section with a modern action-card:

- title: `Дневник предмета`;
- subtitle: `Заметки, фото конспектов и файлы по предмету`;
- action label: `Открыть дневник`.

It opens the existing `SubjectDiaryScreen`; no new general diary was added.

## Soft Help

Added a non-aggressive bottom help block:

- title: `Сложно с предметом?`;
- subtitle: `Можно разобрать задание, подготовиться к сдаче или задать вопрос.`;
- disabled inline action: `Задать вопрос`.

No payment, purchase, or advertising flow was added.

## Verification

Flutter:

- `dart format lib/src/ui/info/subject_info_screen.dart`: passed.
- `dart analyze lib/src/ui/info/subject_info_screen.dart`: no issues.
- `flutter build windows --debug`: passed.

Runtime:

- Interactive runtime UI verification was not completed because the app requires `SUPABASE_URL` and `SUPABASE_ANON_KEY` dart-defines at startup.

## Not Changed

- RLS: not changed.
- Supabase schema/tables: not changed.
- Server functions: not changed.
- Parser: not changed.
- ChatScreen: not changed.
- Routes/data loading architecture: not rewritten.
- New packages: not added.
- Assignments: not added.
- Technical IDs: not rendered.
- `Предмет связан`: not shown.
