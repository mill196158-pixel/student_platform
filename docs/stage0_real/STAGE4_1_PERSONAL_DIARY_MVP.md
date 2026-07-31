# Stage 4.1 - Personal Diary MVP

Date: 2026-06-19

Scope: create the personal current-semester diary entry point and screen, and move new subject diary flows toward `author_id + subject_offering_id`.

No Supabase schema, RLS, migrations, assignments, ChatScreen, legacy diary migration, `git add`, or commit were performed.

## Summary

Stage 4.1 adds a personal diary page:

- profile card: `Мой дневник`;
- route: `/my-diary`;
- screen: `PersonalDiaryScreen`;
- service: `PersonalDiaryService`;
- current-semester subject aggregation from `subject_offerings`;
- diary counts and latest real entries from `subject_diary_entries` / `subject_diary_files`;
- subject diary transitions using `SubjectDiaryArgs` and `subject_offering_id` where available.

## New Personal Diary Flow

Entry point:

1. `ProfileScreen`
2. `Учёба`
3. `Мой дневник`
4. `/my-diary`
5. `PersonalDiaryScreen`

The profile card is placed after `Текущий семестр` and before `Карта СПБГАСУ`.

`PersonalDiaryScreen` shows:

- hero-card with group/current semester;
- semester selector when the group has offerings for multiple semesters;
- subject count;
- total diary entry count;
- total file/photo count;
- `Последние записи`;
- `Дневники предметов` when subjects exist;
- empty state for missing entries.

Add flow:

- `Добавить запись` opens an internal chooser, not a permanently visible subject list.
- `По предмету`: choose any subject offering available for the active group, including old semesters, then choose a date in the calendar.
- `По расписанию`: choose a linked lesson from `lessons`; the note receives `lessonId`, lesson date, and `subject_offering_id`.

## Data Source

`PersonalDiaryService` loads:

1. `AcademicContextService.load()`.
2. Active user from Supabase Auth.
3. Active group and current/default semester.
4. Available semesters from `subject_offerings` for the active group.
5. Selected-semester `subject_offerings`; default is the current semester.
6. Current user's diary entries where:
   - `author_id = auth.uid()`;
   - `subject_offering_id in selected_semester_offerings`;
   - entry is real: text is not empty or `files_count > 0`.
7. File counts by `subject_diary_files.entry_id`.

The service does not prefetch file bytes. It reads metadata only.

## Subject Diary Args

Added `SubjectDiaryArgs` in the subject diary model layer.

Fields:

- `subjectOfferingId`
- `subjectId`
- `subjectTitle`
- `groupId`
- `semesterNumber`
- `lessonId`
- `date`
- `legacySubjectKey`

New logic:

- `subjectOfferingId` is the primary key when present.
- `subjectKey` remains legacy fallback.
- old `SubjectDiaryScreen(subjectKey: ...)` calls remain supported.

## Subject Diary Changes

`SubjectDiaryScreen` now accepts either:

- legacy `subjectKey`; or
- `SubjectDiaryArgs`.

When args have `subjectOfferingId`, the screen loads entries through the new offering-aware path.

Updated child flows:

- inline note sheet passes `SubjectDiaryArgs`;
- day screen `SubjectQuickNoteScreen` accepts `SubjectDiaryArgs`;
- photo-conspect screen accepts `SubjectDiaryArgs`;
- file upload from subject diary passes `SubjectDiaryArgs`.

## Repository Changes

`SubjectDiaryRepository` gained `listByArgs(...)` and optional `SubjectDiaryArgs` parameters on add methods.

`SubjectDiaryRepositorySupabase` now:

- keeps the legacy `subjectKey` RPC path as fallback;
- resolves offering context from `subject_offerings`;
- resolves `team_id` through `teams.subject_offering_id` first;
- falls back to existing subject-name/team resolution if needed;
- creates new offering-aware rows directly in `subject_diary_entries`;
- writes:
  - `team_id`;
  - `author_id = auth.uid()`;
  - `lesson_id` when present;
  - `entry_date`;
  - `text`;
  - `subject_offering_id`;
  - `subject_id`;
  - `group_id`;
  - `academic_year_id`;
  - `academic_term_id`;
  - `semester_number`.

Live schema does not contain `title`, `content`, `entry_type`, or `visibility`, so those were not written.

Files/photo-conspects continue to use:

- Yandex S3 upload path;
- `subject_diary_files.entry_id`;
- `uploaded_by = auth.uid()` through existing `add_subject_diary_file` RPC.

## Updated Transitions

Updated to pass `subject_offering_id` when available:

- `SubjectInfoScreen` -> `SubjectDiaryScreen(args: ...)`
- `LessonDetailsScreen` -> `SubjectQuickNoteScreen(args: ...)`
- `LessonDetailsScreen` -> `SubjectDiaryScreen(args: ...)`
- `PersonalDiaryScreen` -> `SubjectDiaryScreen(args: ...)`

Legacy transitions still work through `SubjectDiaryScreen(subjectKey: ...)`.

The personal diary page does not expose all subjects as a main visible list. Subjects without entries are only used inside the add-entry chooser.

## Empty Entries

The personal diary does not create entries.

Aggregation filters empty-like rows:

- no text;
- no files.

If the selected semester has no subject offerings, the subject block is hidden instead of showing a noisy empty `Предметы семестра` message. When subject offerings exist, they are shown under `Дневники предметов`.

Subject diary file/photo flows may still create an empty entry first as the container for file upload, but the new offering-aware path creates that entry with `subject_offering_id` and other academic fields.

## Assignments

Assignments were not connected.

Not touched:

- `assignments`;
- `assignment_votes`;
- `assignment_done`;
- chat assignment cards;
- assignment voting/completion logic.

Stage 4.2 remains: connect learning/chat assignments into the personal diary as a separate stage.

## Verification

Author model verification:

- existing `add_subject_diary_entry` writes `auth.uid()` into `author_id`;
- existing `add_subject_diary_file` writes `auth.uid()` into `uploaded_by`;
- all checked live diary entries matched both `public.users.id` and `auth.users.id`;
- RLS insert policy requires `author_id = auth.uid()` and team membership.

Focused analyze:

- command: `dart analyze` on changed diary/profile/service/navigation files;
- result: no errors;
- remaining issues: 63 warnings/infos, mostly existing `withOpacity`, unused old diary helpers, and old repository type-check warnings.

IDE lints:

- no linter errors reported for changed files.

Build:

- `flutter build windows --debug`: passed.

Runtime UI:

- not run in this environment because valid local `SUPABASE_URL` and `SUPABASE_ANON_KEY` dart-defines are not available and should not be guessed or exposed.

Test diary row:

- no test diary row was created through UI/repository in this run because there was no authenticated runtime session available.
- no SQL seed was used, per constraint to avoid unnecessary data writes.

## Files Changed

Flutter:

- `lib/main.dart`
- `lib/src/data/personal_diary_service.dart`
- `lib/src/data/subject_diary_repository_supabase.dart`
- `lib/src/ui/profile/personal_diary_screen.dart`
- `lib/src/ui/profile/profile_screen.dart`
- `lib/src/ui/info/subject_info_screen.dart`
- `lib/src/ui/schedule/lesson_details_screen.dart`
- `lib/src/ui/schedule/subject_diary/models.dart`
- `lib/src/ui/schedule/subject_diary/repo.dart`
- `lib/src/ui/schedule/subject_diary/screens/photo_conspect_screen.dart`
- `lib/src/ui/schedule/subject_diary/screens/quick_note_screen.dart`
- `lib/src/ui/schedule/subject_diary_screen.dart`

Docs:

- `docs/stage0_real/STAGE4_1_PERSONAL_DIARY_MVP.md`
- `docs/stage0_real/WORKLOG.md`
- `docs/stage0_real/STAGE0_REAL_INDEX.md`
- `docs/stage0_real/08_NEXT_STAGE_PLAN.md`

Snapshot:

- `docs/_snapshots/*` after snapshot run.

## Stage 4.2

Stage 4.2 should connect assignments from learning/chat into the personal diary after deciding how assignments map to `subject_offering_id`.

Keep separate:

- assignment aggregation;
- assignment completion status;
- chat assignment cards;
- assignment votes;
- any RLS/schema adjustments.
