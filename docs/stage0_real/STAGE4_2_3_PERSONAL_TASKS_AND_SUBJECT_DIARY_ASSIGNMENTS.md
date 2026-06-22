# Stage 4.2.3 - Personal Tasks And Subject Diary Assignments

Date: 2026-06-20

## Scope

Stage 4.2.3 refines `Мой дневник` and connects assignment/task context into `Дневник предмета`.

Changed Flutter files:

- `lib/src/data/personal_diary_service.dart`
- `lib/src/ui/profile/personal_diary_screen.dart`
- `lib/src/ui/schedule/subject_diary_screen.dart`

Created SQL files:

- `supabase/stage4_2_3_personal_diary_tasks.sql`
- `supabase/stage4_2_3_personal_diary_tasks_rollback.sql`

## My Diary Design

The hero-card no longer shows overloaded counters such as subject count, entry count, file count, assignment count, completed count, and remaining count.

It now shows:

- current semester;
- record book number when `AcademicContext.recordBookNumber` is present;
- short description: `Личные записи, задания и материалы по предметам семестра.`

The record book number comes from the existing `AcademicContextService`, which reads `public.users.login`. Existing project docs state that `login` is the student's record book number. Passwords and auth credentials are not shown.

Counts remain inside relevant sections:

- `Ближайшие задания` shows group assignment and active personal task counts;
- subject cards show records, files, group assignments, and personal tasks.

`Дневники с записями` was renamed to `Предметы семестра`, and the list now keeps all subjects for the current semester instead of hiding empty subjects.

## Search

`Мой дневник` now has a local search field under the hero-card.

It filters already loaded:

- subjects;
- latest entries;
- published group assignments;
- personal tasks.

`Дневник предмета` now has a compact search field under the subject header.

It filters already loaded:

- diary entries;
- entry files;
- published group assignments;
- personal tasks.

## Personal Tasks

Personal student tasks are separate from group assignments.

Storage model:

- table: `public.personal_diary_tasks`;
- `author_id` stores the owner;
- `subject_offering_id` is nullable;
- tasks without `subject_offering_id` are shown as general tasks;
- statuses: `todo`, `in_progress`, `done`;
- `completed_at` is set when status becomes `done` and cleared when status moves away from `done`.

RLS in the SQL file is self-only:

- users select only their own tasks;
- users insert only their own tasks;
- users update only their own tasks;
- users delete only their own tasks.

Important separation:

- personal tasks do not create rows in `messages`;
- personal tasks do not create or update rows in `assignments`;
- personal tasks do not participate in assignment voting;
- personal tasks do not appear in team assignment tabs.

## Creation Flow

The `+` button in `Мой дневник` opens `Добавить в дневник`.

Available actions:

- `Личная задача` opens a form with title, optional description, optional subject, and optional deadline;
- `Заметка` uses the existing quick note flow;
- `Фото-конспект` uses the existing dated subject flow;
- `Файл / запись по расписанию` uses the existing lesson-based flow.

The `+` button in `Дневник предмета` opens the subject add sheet and includes `Личная задача`. Tasks created from a subject diary automatically receive that subject's `subject_offering_id`.

## Subject Diary

`Дневник предмета` now uses the subject title as the header title and `Дневник предмета` as a subtitle.

The subject diary shows:

- `Задания`: published group assignments for the current `subject_offering_id` and personal tasks for the same `subject_offering_id`;
- `Записи`: notes, photo conspects, and files.

Draft group assignments are still excluded because the service queries only `assignments.status = 'published'`.

Legacy assignments without `subject_offering_id` are not shown because the service requires an offering id.

## Supabase Application Status

The SQL and rollback files were created locally.

Remote application through Supabase MCP was attempted with both `execute_sql` and `apply_migration`, but the MCP server returned permission errors. Even read-only `to_regclass` verification was denied.

Therefore:

- local SQL files exist;
- remote schema application was not confirmed;
- runtime creation/status checks for `personal_diary_tasks` require applying `supabase/stage4_2_3_personal_diary_tasks.sql` with sufficient project permissions.

## Verification

Focused analyze:

- command: `dart analyze lib/src/data/personal_diary_service.dart lib/src/ui/profile/personal_diary_screen.dart lib/src/ui/schedule/subject_diary_screen.dart`
- result: exit code 0;
- remaining items: 22 existing `withOpacity` info diagnostics in `subject_diary_screen.dart`;
- no errors or warnings from the Stage 4.2.3 logic.

Build:

- command: `flutter build windows --debug`
- result: passed;
- output: `build\windows\x64\runner\Debug\student_platform.exe`

Runtime UI was not driven interactively by the agent.

## Follow-Up UI Fix

Date: 2026-06-20

Follow-up fixes after runtime feedback:

- status update snackbars were removed from delayed status refresh paths, so the UI no longer shows `Не удалось...` before the status catches up;
- `Ближайшие задания` now uses compact expandable groups instead of rendering all cards directly in the feed;
- active upcoming items and completed items are separate collapsed groups;
- tapping a group assignment card in `Дневник предмета` now opens a details sheet;
- the `Выполнить` / `Снять` action is only on the explicit button, not on the whole assignment card;
- the personal task form dropdown now uses readable dark text, white dropdown background, `isExpanded`, and a capped menu height;
- personal task bottom sheets now have max-height constraints and scroll content for smaller screens.

Follow-up verification:

- focused analyze for `personal_diary_screen.dart` and `subject_diary_screen.dart`: exit code 0;
- `flutter build windows --debug`: passed.

## Follow-Up: Compact Subjects And Optimistic Status

Date: 2026-06-20

Additional runtime fixes:

- `Активные дневники` and `Предметы семестра` are separate expandable sections;
- `Активные дневники` shows subjects with diary records/files;
- `Предметы семестра` shows all current-semester subjects;
- status changes in `Мой дневник` update immediately through local optimistic overrides;
- status changes in `Дневник предмета` update immediately through local optimistic overrides;
- server persistence still runs in the background and the screen reloads quietly afterwards.

Verification:

- focused analyze for `personal_diary_screen.dart` and `subject_diary_screen.dart`: exit code 0;
- `flutter build windows --debug`: passed.

## Follow-Up: Local Task Fallback And Diary Calendar

Date: 2026-06-20

Additional runtime fixes:

- personal task creation now has a local `shared_preferences` fallback when Supabase insert into `personal_diary_tasks` fails;
- local fallback tasks use `local-` ids and are displayed together with server tasks;
- local fallback task status changes are persisted locally;
- this prevents silent failure while the remote `personal_diary_tasks` SQL still needs to be applied with sufficient Supabase permissions;
- the `+` sheet in `Мой дневник` now includes `Календарь дневника`;
- the diary calendar shows dates with latest diary entries, published group assignment deadlines, and personal task deadlines;
- selecting an event opens the subject diary, group assignment details, or personal task details.

Verification:

- focused analyze for `personal_diary_service.dart` and `personal_diary_screen.dart`: no issues found;
- `flutter build windows --debug`: passed.

## Follow-Up: Calendar Event Dots

Date: 2026-06-20

Additional runtime fixes:

- `Календарь дневника` now includes linked schedule lessons/pairs;
- assignment events include only not-done published group assignments;
- personal task events use personal task due dates;
- entry events use latest diary entry dates;
- the calendar opens on the nearest event day instead of an empty current month;
- day markers are colored by event type: lessons, assignments, personal tasks, and diary entries;
- the `+` sheet is scrollable and height-limited to avoid bottom overflow.

Verification:

- focused analyze for `personal_diary_screen.dart`: no issues found;
- `flutter build windows --debug`: passed.

## Not Done

- No PDF export.
- No gamification.
- No chat creation flow changes.
- No assignment bubble changes.
- No draft assignment diary display.
- No legacy null-`subject_offering_id` assignment display.
- No git add.
- No commit.
