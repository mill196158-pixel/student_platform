# Stage 1 Academic Context

Stage 1 goal: add the first safe read-only academic context for the existing Flutter frontend without changing Supabase schema, RLS, imports, Auth users, chat logic, or team creation.

## Created Service

Created:

- `lib/src/data/academic_context_service.dart`

The file contains minimal read-only models:

- `AcademicContext`
- `ActiveEnrollment`
- `CurrentGroup`
- `CurrentSemester`
- `AcademicContextService`

## Tables Read

`AcademicContextService.load()` reads only through the normal Flutter Supabase client:

- `auth.currentUser`
- `public.users`
- `public.student_enrollments`
- `public.groups`
- `public.group_term_semesters`
- nested `public.academic_terms` fields through the `group_term_semesters` relation

No inserts, updates, deletes, upserts, migrations, RLS changes, import scripts, service role keys, or `auth.users` writes are used.

## Current Semester Rule

The service chooses current semester in this order:

1. Prefer a `group_term_semesters` row whose related `academic_terms.is_current = true`.
2. If none is marked current, prefer the row whose related `academic_terms.starts_on` / `ends_on` contains today's date.
3. If dates are missing or no row matches, fall back to the maximum `semester_number` because the query orders semesters descending.

This fallback is read-only and must be revisited when RLS/security work defines a stable academic context RPC.

## UI Entry Point

Connected in:

- `lib/src/ui/learning/learning_screen.dart`

Stage 1 initially showed a compact inline block. Stage 1.1 changed this to a less intrusive info icon in the Learning header.

Pressing the `i` icon opens a bottom sheet with:

- `Группа: ...`
- `Семестр: ...`
- `Источник: student_enrollments / group_term_semesters`

If the context cannot be loaded, the UI shows:

- `Учебный контекст не найден`

The context details are no longer always visible on the screen.

The old hardcoded `getCurrentGroupCodeSync() => '1-См(ВВ)-1'` was removed from the Learning screen. Existing team loading still uses the existing `LearningCubit` and `get_my_teams` flow; Stage 1 does not rewrite team/chat behavior.

## RLS Risk

Live Stage 0 check showed:

- `users`: RLS enabled
- `student_enrollments`: RLS disabled
- `groups`: RLS disabled
- `group_term_semesters`: RLS disabled
- `academic_terms`: RLS disabled

Because these academic tables currently have RLS disabled, the new reads may work now but are not production-safe as a final security model. When RLS is enabled later, the service can fail for normal users unless policies or a reviewed read-only RPC are provided.

## Not Changed

- Supabase schema: unchanged
- RLS: unchanged
- Migrations: none
- Import/apply scripts: not run
- Auth users: not touched
- Teams/chats creation: unchanged
- Chat module: unchanged
- Assignments/files/friends/direct chats: unchanged

## Verification

- `flutter analyze` was run for the full project. It still fails on pre-existing errors outside Stage 1 in `lib/src/ui/schedule/diary_entry_details_screen.dart`.
- Focused analyze was run for the Stage 1 Dart files: `lib/src/data/academic_context_service.dart` and `lib/src/ui/learning/learning_screen.dart`.
- Focused analyze found no Stage 1 warnings/errors. Remaining messages are existing `withOpacity` deprecation infos in `learning_screen.dart`.
- Snapshot script was run after Stage 1 and updated `docs/_snapshots/`.

## Stage 1.1 Runtime Smoke

- The user reported that the app was launched and checked.
- The agent did not rerun `flutter run` because the user said the runtime steps could be skipped.
- Stage 1.1 UI adjustment: the AcademicContext details now open through an info icon instead of occupying inline screen space.
- Focused analyze after the UI adjustment found no new Stage 1.1 errors.
- Supabase schema, RLS, Auth users, imports, chat module, and team/chat flow were not changed.

## Next Step

The next safe stage is to introduce a reviewed academic context data contract:

- either RLS policies that allow users to read only their active enrollment/group/term context;
- or a security-reviewed read-only RPC that returns the same context without exposing broader academic tables.

Only after that should Learning teams, schedule, diary, assignments, and subject cards be progressively aligned to `subject_offering_id`.
