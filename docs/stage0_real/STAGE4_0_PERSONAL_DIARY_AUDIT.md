# Stage 4.0 - Personal Diary Audit

Date: 2026-06-19

Scope: read-only audit of the existing subject diary before designing the personal current-semester diary.

No Flutter code, Supabase schema, RLS, migrations, assignments, ChatScreen, import/apply scripts, `git add`, commit, or data changes were performed.

## 1. Audit Goal

The goal is to understand the existing subject diary well enough to reuse it safely later.

The next feature must be a personal student diary opened from profile, but Stage 4.0 does not implement it. The future personal diary should aggregate current-semester subject diaries and keep the existing subject diary as the subject-level workspace.

## 2. What Already Exists

The app already has a subject diary with:

- a subject diary screen grouped by day;
- a day screen for one subject/date;
- text notes;
- photo-conspects;
- attached files;
- "all notes", "all conspects", and "all files" aggregate views inside one subject diary;
- realtime reload subscriptions on `subject_diary_entries` and `subject_diary_files`;
- edit/delete for notes and files;
- Yandex S3 upload/delete for diary files.

Current frontend API is name-based:

- `SubjectDiaryScreen(subjectKey: ...)`;
- `SubjectQuickNoteScreen(subjectKey: ..., date: ...)`;
- `SubjectPhotoConspectScreen(subjectKey: ..., date: ...)`;
- `SubjectDiaryRepository.listBySubject(subjectKey)`.

There is no explicit `subject_offering_id` parameter in the subject diary screens yet.

## 3. Found Flutter Files

Subject diary core:

- `lib/src/ui/schedule/subject_diary/subject_diary.dart`
- `lib/src/ui/schedule/subject_diary/models.dart`
- `lib/src/ui/schedule/subject_diary/repo.dart`
- `lib/src/ui/schedule/subject_diary/widgets.dart`
- `lib/src/ui/schedule/subject_diary_screen.dart`
- `lib/src/ui/schedule/subject_diary/screens/quick_note_screen.dart`
- `lib/src/ui/schedule/subject_diary/screens/photo_conspect_screen.dart`
- `lib/src/ui/schedule/diary_entry_details_screen.dart`
- `lib/src/data/subject_diary_repository_supabase.dart`

Entry points into the diary:

- `lib/src/ui/schedule/lesson_details_screen.dart`
- `lib/src/ui/info/subject_info_screen.dart`

Related academic/profile/navigation files:

- `lib/src/ui/info/info_screen.dart`
- `lib/src/ui/profile/profile_screen.dart`
- `lib/main.dart`
- `lib/src/ui/schedule/models/lesson.dart`
- `lib/src/ui/schedule/schedule_screen.dart`

Assignments audited read-only for later Stage 4.2:

- `lib/src/ui/learning/data/supabase_learning_repository.dart`
- `lib/src/ui/learning/state/team_cubit.dart`
- `lib/src/ui/learning/tabs/assignments/assignments_tab.dart`
- `lib/src/ui/learning/tabs/chat/assignment_bubble.dart`
- `lib/src/ui/learning/tabs/chat_tab.dart`
- `lib/src/ui/learning/tabs/chat/composer/chat_composer_bar.dart`

## 4. Found Supabase Tables

Diary tables:

- `public.subject_diary_entries`
- `public.subject_diary_files`

Academic context tables checked:

- `public.lessons`
- `public.subject_offerings`
- `public.subject_catalog`
- `public.student_enrollments`
- `public.users`
- `public.teams`
- `public.chats`

Assignments tables checked for later integration:

- `public.assignments`
- `public.assignment_done`
- `public.assignment_votes`
- `public.chat_files`

Important schema difference from the requested expected names:

- `subject_diary_entries` has `author_id`, not `user_id`.
- `subject_diary_files` has `uploaded_by`, not `user_id`.
- `subject_diary_entries` has `entry_date` and `text`.
- `subject_diary_entries` does not have `title`, `content`, `note`, `entry_type`, `date`, or `visibility` in the live schema.
- `subject_diary_files` has `yandex_key`, `file_url`, `mime`, `size_bytes`, `thumb_url`.
- `subject_diary_files` does not have `storage_path`, `filename`, `mime_type`, or `size` under those exact names.

Live columns confirmed for `subject_diary_entries`:

- `id`
- `team_id`
- `author_id`
- `lesson_id`
- `entry_date`
- `text`
- `files_count`
- `created_at`
- `updated_at`
- `group_id`
- `subject_id`
- `subject_offering_id`
- `academic_year_id`
- `academic_term_id`
- `semester_number`

Live columns confirmed for `subject_diary_files`:

- `id`
- `entry_id`
- `uploaded_by`
- `yandex_key`
- `file_url`
- `mime`
- `size_bytes`
- `thumb_url`
- `created_at`

## 5. Current Subject Diary Flow

From a lesson:

1. `LessonDetailsScreen` receives a `Lesson`.
2. The "Добавить запись по предмету" action opens `SubjectQuickNoteScreen`.
3. It passes `subjectKey: lesson.subject.trim()` and `date: lesson.date`.
4. The "Дневник предмета" action opens `SubjectDiaryScreen`.
5. It passes only `subjectKey: lesson.subject.trim()`.

From subject info:

1. `SubjectInfoScreen` is opened with `subjectOfferingId`, and optionally `subjectId`, `lessonId`, `groupId`, `semesterNumber`.
2. `_SubjectInfoRepository` loads `subject_offerings`, `subject_catalog`, `curriculum_subjects`, `teams`, and `chats` by `subjectOfferingId`.
3. The diary action opens `SubjectDiaryScreen(subjectKey: data.displayTitle)`.
4. The `subjectOfferingId` is not passed into the diary screen.

From schedule/Useful:

- `ScheduleScreen` enriches lessons with `group_id`, `subject_id`, `subject_offering_id`, `academic_year_id`, `academic_term_id`, `semester_number`, and `alias_match_status`.
- Linked lesson details can open `SubjectInfoScreen`.
- `InfoScreen` opens `SubjectInfoScreen` from current-semester `subject_offerings`.
- The diary itself still receives a display title only.

No direct route was found in `GoRouter` for the subject diary. The subject diary is opened through `MaterialPageRoute`.

## 6. Diary Entry Linkage

Current Flutter write path:

- `addText` resolves a `team_id` from `subjectKey`.
- It tries `get_my_teams` and compares normalized team name to normalized subject key.
- It falls back to `get_my_lessons` and then `teams.group_name` + normalized team name.
- It optionally finds a `lesson_id` from `get_my_lessons` for the same date and normalized subject.
- It calls `add_subject_diary_entry(p_team_id, p_lesson_id, p_entry_date, p_text)`.

Current Flutter read path:

- `listBySubject(subjectKey)` resolves a `team_id`.
- It calls `get_my_subject_diary(p_team_id, p_from, p_limit)`.
- It then calls `get_subject_diary_files(p_entry_id)` for each entry.
- It skips entries with no text and no files.

Live DB linkage result:

- Entries are personal by `author_id`.
- Files are personal by `uploaded_by`.
- Entries are still operationally tied to `team_id`.
- Existing entries do not have `subject_id`.
- Existing entries do not have `subject_offering_id`.
- Existing entries do not have `group_id`.
- Existing entries do not have `semester_number`.
- One existing entry has `lesson_id`, but that linked lesson also has no `subject_offering_id`.

This means the existing diary is currently team/name-driven in practice, even though the table has nullable academic columns for the future.

## 7. Files And Photo-Conspects

Photo-conspects and files are implemented through one file table:

- images are detected by MIME prefix `image/`;
- non-image files are shown as document files;
- Yandex S3 object key format is `diaries/{teamId}/{userId}/{yyyymmdd}/{random}_{safeName}`;
- `add_subject_diary_file` stores `yandex_key`, `file_url`, `mime`, `size_bytes`, and optional `thumb_url`;
- UI prefetches `file_url` bytes for image previews and opening files;
- delete paths remove DB rows and try to delete Yandex S3 objects.

Live data:

- `subject_diary_files`: 7 rows.
- All 7 files have `entry_id`.
- All 7 files have `uploaded_by`.
- The observed files are image files (`image/png`).
- `thumb_url` is not filled for the observed rows.

## 8. Routes And Navigation

Existing route style:

- Profile uses GoRouter for `/exams`.
- Subject diary screens use `MaterialPageRoute`.
- Subject info uses `MaterialPageRoute`.
- Team/chat opening from subject info reuses `TeamDetailsScreen(initialTabIndex: 1)`.

Relevant routes in `lib/main.dart`:

- `/profile`
- `/edit-profile`
- `/exams`

There is no `/my-diary` route yet.

Stage 4.1 can use either:

- a new GoRouter route opened from profile, consistent with `/exams`; or
- a local `MaterialPageRoute`, consistent with subject diary screens.

Because the entry point is profile and profile already uses `context.push('/exams')`, a GoRouter route for a future `MyDiaryScreen` is the cleaner fit.

## 9. Where To Add "My Diary" In Profile

`ProfileScreen` has a section titled `Учёба`.

Current order:

1. `_ExamsBanner(onTap: () => context.push('/exams'))`
2. `_MapBanner(...)`

`_ExamsBanner` displays:

- title: `Текущий семестр`
- subtitle: `Зачёты, экзамены и учебный план`
- icon: `Icons.school_outlined`
- soft primary gradient
- rounded card with chevron

Best future placement:

- add `MyDiaryBanner` directly after `_ExamsBanner` and before `_MapBanner`;
- keep the same height/radius/chevron pattern;
- use a different soft color, for example blue/indigo or amber, so it is visually adjacent but distinct;
- title: `Мой дневник`;
- subtitle: `Заметки и конспекты по предметам`;
- icon: `Icons.menu_book_outlined` or `Icons.auto_stories_outlined`;
- navigation: `context.push('/my-diary')` if Stage 4.1 adds a route.

No button was added in Stage 4.0.

## 10. Proposed MVP Stage 4.1

Screen: `Мой дневник`.

Entry point:

- Profile -> `Учёба` -> `Мой дневник`.

Data source:

1. Load current auth user.
2. Load active `student_enrollments`.
3. Load active group and current semester from `group_term_semesters`.
4. Load current-semester `subject_offerings` for the active group.
5. For each offering, find the existing team/chat by `teams.subject_offering_id` where available.
6. For legacy diary rows, read by team only if a safe team/offering match exists.
7. Aggregate existing non-empty diary entries only.

MVP content:

- hero-card with current semester, subject count, entry count, and file/photo count if available;
- current-semester subject list;
- per-subject count of entries;
- per-subject last entry date/preview metadata without exposing full private text;
- per-subject file/photo count;
- quick action to open the existing subject diary;
- `Последние записи` sorted by `entry_date`/`created_at`;
- empty state: `Записей пока нет. Открой предмет или занятие и добавь первую заметку.`

Important implementation constraint:

- Do not create empty diary rows for aggregation.
- Do not replace the subject diary.
- Treat the personal diary as an aggregator.
- Prefer `subject_offering_id` for new code, but account for existing rows that only have `team_id`.

## 11. What Not To Do In Stage 4.1

Do not add:

- assignments;
- chat assignment cards;
- assignment voting;
- PDF export;
- past semester archive;
- gamification;
- paid archive;
- complex statistics;
- new tables;
- schema changes;
- RLS changes;
- ChatScreen changes;
- subject diary rewrite.

## 12. Stage 4.2: Assignments From Chat/Learning

Assignments should stay out of Stage 4.1.

Current assignment state:

- Flutter loads assignments through `get_team_assignments(p_team_id)`.
- New assignments are proposed through `propose_assignment`.
- Publishing uses `publish_assignment`.
- Completion uses `set_assignment_done`.
- Votes are written directly to `assignment_votes` with `assignment_id`, `user_id`, and `value = 1`, with RPC fallback.
- `assignments` has nullable `subject_offering_id`, `group_id`, `subject_id`, `academic_year_id`, `academic_term_id`, and `semester_number`.

Live assignment data:

- `assignments`: 1 row.
- `assignments.subject_offering_id`: 0/1 filled.
- `assignment_done`: 0 rows.
- `assignment_votes`: 2 rows.

Stage 4.2 can add assignments later only after the diary aggregator is stable. The likely path is to aggregate assignments by offering/team and personal completion status, but current assignment rows are not offering-linked yet.

## 13. Risks

No `subject_offering_id` in existing diary rows:

- Existing entries cannot be directly grouped by current-semester offering.
- For Stage 4.1, entries may need to be associated through `team_id`, then `teams.subject_offering_id`, or by carefully matching legacy `team.name + group_name` to academic subjects.

Legacy teams without `subject_offering_id`:

- The observed diary teams have `teams.subject_offering_id = null`.
- One legacy team can be matched to a semester 3 offering by normalized subject/group.
- Two observed diary teams matched a canonical subject but had no matching offering for the group.

Subject name mixing:

- Current diary screens pass `subjectKey` as display text.
- If the same canonical subject appears in multiple groups/semesters, name-based lookup can mix or miss records.

Entries without group/semester:

- Existing diary rows have no `group_id` or `semester_number`.
- Current semester aggregation cannot rely on those columns yet.

Lesson linkage is partial:

- 1/4 entries has `lesson_id`.
- That linked lesson has no `subject_offering_id`.

Privacy/RLS:

- `subject_diary_entries` and `subject_diary_files` have RLS enabled.
- `get_my_subject_diary` is `SECURITY DEFINER` and executable by `anon` and `authenticated`.
- Security behavior should be reviewed before broadening diary reads.

Files:

- File URLs point to external Yandex S3.
- Personal diary should count files/photos but should avoid prefetching all file bytes on the aggregate screen.
- Open/download should remain inside the subject diary/detail flow at first.

Empty entries:

- `_ensureEntryFor` creates an empty text row before attaching files.
- `listBySubject` skips empty rows, but live DB already has one empty-like entry with no files.
- Personal diary must not create more empty rows and should filter empty rows.

Assignments:

- Assignment rows are currently team-centric and not `subject_offering_id`-linked.
- Do not mix assignment logic into Stage 4.1.

## 14. Can Stage 4.1 Start Safely?

Yes, Stage 4.1 can start as a conservative read-only personal diary aggregator if it does not change the subject diary write path yet.

Safe Stage 4.1 boundary:

- add profile entry point;
- add `Мой дневник` screen;
- load current semester and current subject offerings;
- count and show existing non-empty diary data;
- open existing subject diary for the chosen subject;
- avoid assignments and writes.

Main blocker to avoid:

- Do not assume `subject_diary_entries.subject_offering_id` is populated. It exists in schema but is empty in current data.

Recommended design decision for Stage 4.1:

- Use `subject_offering_id` as the target identity for the personal diary screen.
- For existing diary rows, bridge via team only when the team/offering relation is explicit or safely resolvable.
- Document unresolved legacy diary rows instead of silently mixing them into the wrong subject.

## 15. Read-Only Live DB Snapshot

Project checked through Supabase MCP: `gwdanmwluhrcfxbnplwd`.

Counts:

- `subject_diary_entries`: 4
- entries with `author_id`: 4
- entries without `author_id`: 0
- entries with `subject_id`: 0
- entries with `subject_offering_id`: 0
- entries without `subject_offering_id`: 4
- entries with `lesson_id`: 1
- entries with `group_id`: 0
- entries with `semester_number`: 0
- entries with `semester_number = 4`: 0
- empty-like entries with no text and no files: 1
- distinct diary authors: 2
- distinct diary teams: 3
- `subject_diary_files`: 7
- files with `entry_id`: 7
- files with `uploaded_by`: 7

Per-team diary summary:

- `Моделирование систем водоснабжения и водоотведения`: 2 entries, 0 files, no team `subject_offering_id`.
- `Инженерно-технологическая реконструкция систем водоотведения`: 1 entry, 7 files, no team `subject_offering_id`.
- `Организация эксплуатации систем и сооружений водоснабжения и водоотведения`: 1 entry, 0 files, no team `subject_offering_id`, 1 entry has `lesson_id`.

Safe examples were checked only by metadata: text length, booleans for IDs, dates, MIME and sizes. Full personal note text was not copied into this document.

## 16. Preflight Dirty Tree Notes

Preflight command: `git status --short`.

Working tree was already heavily dirty before Stage 4.0.

Related files that were audited but not modified:

- `lib/src/ui/schedule/subject_diary_screen.dart`
- `lib/src/ui/schedule/subject_diary/*`
- `lib/src/data/subject_diary_repository_supabase.dart`
- `lib/src/ui/schedule/lesson_details_screen.dart`
- `lib/src/ui/info/subject_info_screen.dart`
- `lib/src/ui/profile/profile_screen.dart`
- `lib/src/ui/learning/*`

Files/areas to avoid touching in Stage 4.0:

- all Flutter code;
- all Supabase SQL/migrations/RLS;
- `ChatScreen`/chat module;
- assignments code;
- platform files (`android/*`, `ios/*`, `macos/*`);
- backup/vendor/deleted legacy files;
- assets/lottie;
- old root SQL files;
- unrelated docs outside the requested Stage 0 REAL updates.

Only Stage 0 REAL audit documentation should change in this stage.
