# Stage 2.0 - Schedule Subject Link Audit

Date: 2026-06-19

Scope: read-only audit of the existing schedule-to-subject link. No Flutter code, Supabase schema, RLS, migrations, import/apply scripts, git add, or commit were run.

## Preflight

- Correct project: `C:\student_platform`
- Preflight command: `git status --short`
- Working tree before this audit: dirty, with many existing modified/deleted/untracked files. Relevant already-dirty schedule/doc areas included `lib/src/ui/schedule/schedule_screen.dart`, untracked `lib/src/ui/schedule/lesson_details_screen.dart`, untracked `lib/src/ui/schedule/models/`, untracked `lib/src/ui/schedule/widgets/`, untracked `lib/src/ui/schedule/subject_diary*`, and untracked `docs/stage0_real/`.
- No `git add`, commit, or unrelated formatting was performed.

## Actual Schedule Table

The app uses the existing `public.lessons` table for schedule data. No active Flutter usage of `schedule_lessons` was found.

Flutter access path:

1. `lib/src/ui/schedule/schedule_screen.dart`
2. `ScheduleRepository.loadMonth`
3. Supabase RPC `get_my_lessons`
4. `public.lessons`
5. `Lesson.fromMap`
6. `LessonCard`
7. tap opens `LessonDetailsScreen`

Current `get_my_lessons` returns only:

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

`ScheduleScreen` also subscribes to realtime changes on `public.lessons`.

## `lessons` Columns

Live read-only schema check found these `public.lessons` columns:

- `id`
- `group_id`
- `week`
- `day`
- `date`
- `pair_num`
- `time_start`
- `time_end`
- `subject`
- `room`
- `teacher`
- `created_at`
- `subject_id`
- `subject_offering_id`
- `teacher_id`
- `academic_year_id`
- `academic_term_id`
- `semester_number`
- `raw_subject_name`
- `normalized_subject_name`
- `alias_match_status`

Field notes:

- `subject_id`: exists, but currently empty for all lessons.
- `subject_offering_id`: exists, but currently empty for all lessons.
- `curriculum_subject_id`: not present on `lessons`.
- `group_id`: exists and is filled for all lessons.
- `raw_subject_name`: exists, but currently empty.
- `normalized_subject_name`: exists, but currently empty.
- `subject`: exists and contains the raw schedule title currently used by Flutter.
- `lesson_type`: not present.
- `teacher`, `room`, `time_start`, `time_end`: present and filled.
- `starts_at`, `ends_at`: not present; current fields are `time_start`, `time_end`.

## Current Flutter Flow

`ScheduleScreen` loads a month by calling `get_my_lessons(p_from, p_days)`, keeps all lessons in memory, filters by selected day in Flutter, and sorts by pair number then start time.

`Lesson.fromMap` maps only the RPC fields listed above. The model does not include `subject_id`, `subject_offering_id`, `group_id`, `semester_number`, or normalized subject fields.

`Lesson.subject` is a display cleanup only:

- removes final `(л.)`, `(пр.)`, `(лаб.)`;
- trims whitespace.

`Lesson.type` is derived from `subjectRaw` suffix:

- `(л.)` -> lecture;
- `(пр.)` -> practice;
- `(лаб.)` -> lab;
- otherwise other.

On tap, the card opens `LessonDetailsScreen(lesson: l)`. It does not open SubjectHub. `LessonDetailsScreen` currently offers:

- quick note: `SubjectQuickNoteScreen(subjectKey: lesson.subject.trim(), date: lesson.date)`;
- diary: `SubjectDiaryScreen(subjectKey: lesson.subject.trim())`.

So the active flow still uses cleaned subject title as a diary/team lookup key, not the academic `subject_offering_id`.

## Existing Parser Or Normalizer

Existing subject normalization/matching logic was found in three places.

### Database Function `public.f_norm_subject`

Found live in Supabase.

It calls `public.f_norm_title`, then removes a trailing parenthesized lesson type suffix matching variants of:

- `л`
- `лекц...`
- `пр`
- `практ...`
- `сем...`
- `лаб...`

`public.f_norm_title` lowercases text, replaces punctuation including dash variants with spaces, collapses whitespace, and trims.

This is the best existing normalizer for schedule-title matching because it is already DB-side and is referenced by schedule checks.

### Subject/Knowledge SQL Checks

Found in:

- `supabase/checks/subject_student_knowledge_preflight.sql`
- `supabase/checks/subject_student_knowledge_checks.sql`

These checks explicitly expect schedule mapping columns on `lessons` and use:

- `coalesce(l.normalized_subject_name, public.f_norm_subject(coalesce(l.raw_subject_name, l.subject)))`
- `subject_aliases.normalized_alias`
- `alias_match_status`
- `subject_id`
- `subject_offering_id`

This looks like an existing intended schedule alias mapping design, not an active Flutter flow.

### Flutter Diary Fallback `_normalizeSubject`

Found in `lib/src/data/subject_diary_repository_supabase.dart`.

It only removes final `(л.)`, `(пр.)`, `(лаб.)` and lowercases. It is used by diary fallback logic to find teams/lessons by subject name. This is weaker than `public.f_norm_subject` and is not a complete academic subject resolver.

### Import Script `normalizeName`

Found in `scripts/import_academic_batch.js`.

It lowercases and collapses whitespace for curriculum import, then creates `subject_catalog`, `subject_aliases`, `curriculum_subjects`, and `subject_offerings`. It is not a schedule parser and does not remove lesson-type suffixes.

## Live Link Coverage

Read-only Supabase checks:

- total `lessons`: 176
- with `subject_id`: 0
- with `subject_offering_id`: 0
- without either link: 176
- with `group_id`: 176
- with `teacher`: 176
- with `room`: 176
- with `time_start`: 176
- with `time_end`: 176
- with `alias_match_status`: 176
- lesson date range: 2025-09-01 to 2025-11-20
- lesson groups: `1-См(ВВ)-2`, `2-См(ВВ)-2`
- `lessons.semester_number`: currently null for all checked grouped rows

Alias/read-only matching by `public.f_norm_subject` and `subject_aliases`:

- alias single-subject matches: 130 lessons
- alias no matches: 46 lessons
- alias ambiguous matches: 0 lessons

Read-only matching to any `subject_offerings` by matched subject and lesson `group_id`:

- single offering matches: 96 lessons
- no offering match: 80 lessons
- ambiguous offering matches: 0 lessons

Read-only matching to the current AcademicContext semester only:

- current active term: `весна 2026`
- current semester: 4
- current offerings per group: 2
- current-semester schedule offering matches: 0 lessons
- current-semester no offering matches: 176 lessons

This is expected from the dates and curriculum state: schedule rows are dated September-November 2025 and match semester 3 subjects for part of the data, while AcademicContext currently resolves to semester 4.

## Raw Titles Not Matched

Typical raw schedule titles with no alias match:

- `Инженерно-технологическая реконструкция систем водоотведения (л.)`
- `Инженерно-технологическая реконструкция систем водоотведения (пр.)`

These normalize to:

- `инженерно технологическая реконструкция систем водоотведения`

No matching `subject_aliases.normalized_alias` was found for that normalized title. Related offerings found in the catalog include `Инженерно-технологическая реконструкция систем водоснабжения`, which is not the same title and should not be guessed as a match without review.

Titles with alias match but no offering match:

- `Моделирование систем водоснабжения и водоотведения (л.)`
- `Моделирование систем водоснабжения и водоотведения (пр.)`

Titles with alias and any-semester offering match:

- `Надежность систем водоснабжения и водоотведения (л.)`
- `Надежность систем водоснабжения и водоотведения (пр.)`
- `Организация эксплуатации систем и сооружений водоснабжения и водоотведения (л.)`
- `Организация эксплуатации систем и сооружений водоснабжения и водоотведения (пр.)`

For the matched offerings above, the offering semester is 3, not current semester 4.

## Can The Link Be Done Without Migration?

Yes, a minimal read-only link can be done without creating tables or changing schema, because:

- `lessons` already exists and is the active schedule table;
- `lessons.subject_id` and `lessons.subject_offering_id` already exist;
- `subject_aliases` already exists;
- `public.f_norm_subject` already exists;
- `AcademicContextService` already provides active `group_id` and current semester context in Flutter;
- a resolver can query `subject_offerings` for the active group and selected semester, normalize the lesson title the same way, and resolve an offering in memory.

However, current-semester-only resolution would not link the existing September-November 2025 lessons because they belong to older schedule dates and appear to align with semester 3, while AcademicContext is now semester 4. A safe resolver needs a reviewed rule for determining the lesson semester, for example by `lessons.academic_term_id`/`semester_number` if populated later, or by lesson date -> `academic_terms` -> `group_term_semesters`.

## Minimal Next Fix

Recommended next small step: Variant C with one guard from Variant B.

Create a read-only `ScheduleSubjectResolver` in Flutter that:

- does not write to DB;
- does not create subjects or aliases;
- does not use the raw subject title as the canonical key;
- normalizes lesson titles using the same rules as `public.f_norm_subject` or calls a reviewed read-only RPC that applies it;
- resolves against `subject_aliases` and `subject_offerings` for the lesson's group and inferred semester;
- returns a `subject_offering_id` only when exactly one offering matches;
- marks unmatched lessons as "requires linking";
- allows `ScheduleScreen` tap to open SubjectHub only when a single `subject_offering_id` is resolved.

If a persistent DB link is desired later, it should be a separate reviewed backfill/migration step. This audit did not write any backfill, migration, schema, or RLS.
