# Stage 2.1 - Test Subject Schedule Link

Date: 2026-06-19

Scope: create an idempotent dev/test seed for checking the chain:

`study plan -> subject_offering -> lessons -> LessonDetails -> SubjectHub/team/chat`

No Flutter code, RLS, policies, migrations, auth users, parser rewrite, legacy cleanup, or chat module changes were made.

## Files

- Seed: `supabase/dev_seed_test_schedule_subject_link.sql`
- Rollback: `supabase/dev_seed_test_schedule_subject_link_rollback.sql`
- This report: `docs/stage0_real/STAGE2_1_TEST_SUBJECT_SCHEDULE_LINK.md`

The seed was applied through Supabase MCP `execute_sql`. The rollback was created but not applied.

## Preflight

- Correct project: `C:\student_platform`
- Branch expected by docs/request: `refactor/chat-tab`
- Working tree before Stage 2.1: already dirty with many unrelated modified/deleted/untracked files.
- No `git add`, commit, or unrelated formatting was run.

## Live Schema Facts

Actual schedule table remains `public.lessons`.

Important `lessons` fields:

- `id`
- `group_id`
- `date`
- `pair_num`
- `time_start`
- `time_end`
- `subject`
- `room`
- `teacher`
- `subject_id`
- `subject_offering_id`
- `academic_year_id`
- `academic_term_id`
- `semester_number`
- `raw_subject_name`
- `normalized_subject_name`
- `alias_match_status`

There is no `lesson_type`, `starts_at`, or `ends_at` column. The seed uses `time_start` and `time_end`; lesson type remains encoded in the raw/display subject title for this test.

Existing team/chat automation:

- `trg_teams_after_insert` creates a `team_main` chat and adds members from legacy `users.group_name`.
- `trg_team_members_after_insert_add_to_chat` adds inserted team members to the main chat.
- The seed also idempotently ensures `team_members`, `chat_members`, and `chats.subject_offering_id` so the test data is complete even if a trigger path is skipped.

## Current Semester

The current term for both target groups is semester 4, `весна 2026`.

| Group | group_id | semester | academic_year_id | academic_term_id |
|---|---|---:|---|---|
| `1-См(ВВ)-2` | `a652632a-1d95-495f-abdc-23eda79ee7a1` | 4 | `b3d28bc9-6c27-4758-ab7b-35d292131d8f` | `0b7e5ce5-826c-48bf-bc2b-6907073889f5` |
| `2-См(ВВ)-2` | `09f0c211-9570-43cf-8417-366a83c536d6` | 4 | `b3d28bc9-6c27-4758-ab7b-35d292131d8f` | `0b7e5ce5-826c-48bf-bc2b-6907073889f5` |

## Test Subjects And Offerings

Created test subjects:

- `Тест 1`
- `Тест 2`
- `Проверка 1`
- `Проверка 2`

Test marker:

- `subject_catalog.description = 'stage2_1_test_schedule_subject_link'`
- `subject_aliases.source = 'stage2_1_test_schedule_subject_link'`
- `curriculum_subjects.subject_index` starts with `STAGE2.1-TEST-`
- `teams.description` contains `stage2_1_test_schedule_subject_link`

Created `subject_offering_id` values:

| Group | Subject | subject_id | subject_offering_id | team_id | chat_id |
|---|---|---|---|---|---|
| `1-См(ВВ)-2` | `Тест 1` | `995cc6cd-3879-42f8-920f-ccc5a85efe93` | `cbb94b65-5eab-49dd-ba68-376204364a79` | `b47d5f24-4041-4d6f-a84a-4bb9e67e3b7d` | `485014d8-f3d4-4012-96c5-a1f8f26b45b7` |
| `1-См(ВВ)-2` | `Тест 2` | `f479500d-24d9-4e19-a392-c36e3c8f078c` | `006161e3-0800-48e9-8aad-1647f1b12bbd` | `cf11524c-0787-4aaa-baf8-89e6f01a87b6` | `8b7022f8-143d-430b-bb2f-570b422e590d` |
| `2-См(ВВ)-2` | `Проверка 1` | `96a7eacd-95f9-4c0d-89f5-7a409f3e348e` | `f9eb2899-e24d-4981-8597-abaad7092401` | `72d9eb3c-2a58-451b-9714-21f61c7e5a33` | `3d35d870-d495-45e7-afa1-62fb1a1cfc19` |
| `2-См(ВВ)-2` | `Проверка 2` | `3e6a814f-65ba-4ada-bbb3-6d140fc28dbd` | `c62045c0-0f41-4d72-a226-0b266851250f` | `9e9eb9b0-9947-4e19-8599-ba4249a2acc0` | `ea283a30-7843-4f3a-ab90-3b953ad89fbd` |

## Lessons

Created 8 lessons total. All 8 have:

- `subject_id` filled;
- `subject_offering_id` filled;
- `academic_year_id` filled;
- `academic_term_id` filled;
- `semester_number = 4`;
- `alias_match_status = 'matched'`.

Per group/date:

| Group | Date | Lessons |
|---|---|---:|
| `1-См(ВВ)-2` | 2026-06-19 | 2 |
| `1-См(ВВ)-2` | 2026-06-21 | 2 |
| `2-См(ВВ)-2` | 2026-06-19 | 2 |
| `2-См(ВВ)-2` | 2026-06-21 | 2 |

Lesson variants:

- `Тест 1 (сем.)`
- `Тест 2 (л.)`
- `Тест 1, практика Teams TEST-1`
- `Тест 2 (лаб.)`
- `Проверка 1 (сем.)`
- `Проверка 2 (л.)`
- `Проверка 1, практика Teams TEST-A`
- `Проверка 2 (лаб.)`

## Normalization Check

The test confirms the intended identity rule at the DB data level:

| Group | Subject | Lesson variants | distinct subject_offering_id count |
|---|---|---|---:|
| `1-См(ВВ)-2` | `Тест 1` | `Тест 1 (сем.)` / `Тест 1, практика Teams TEST-1` | 1 |
| `1-См(ВВ)-2` | `Тест 2` | `Тест 2 (л.)` / `Тест 2 (лаб.)` | 1 |
| `2-См(ВВ)-2` | `Проверка 1` | `Проверка 1 (сем.)` / `Проверка 1, практика Teams TEST-A` | 1 |
| `2-См(ВВ)-2` | `Проверка 2` | `Проверка 2 (л.)` / `Проверка 2 (лаб.)` | 1 |

The seed also inserted aliases for the requested variants and two extra exact Teams+practice variants used by the actual test lessons:

- `Тест 1, практика Teams TEST-1`
- `Проверка 1, практика Teams TEST-A`

## Teams And Chats

Created/verified:

- 4 teams, one per test `subject_offering_id`;
- 4 `team_main` chats, one per team;
- each chat has `subject_offering_id` filled.

Membership:

| Group | Team | Active students | team_members total | active students in team | chat_members total | active students in chat |
|---|---|---:|---:|---:|---:|---:|
| `1-См(ВВ)-2` | `Тест 1` | 17 | 19 | 17 | 19 | 17 |
| `1-См(ВВ)-2` | `Тест 2` | 17 | 19 | 17 | 19 | 17 |
| `2-См(ВВ)-2` | `Проверка 1` | 12 | 14 | 12 | 14 | 12 |
| `2-См(ВВ)-2` | `Проверка 2` | 12 | 14 | 12 | 14 | 12 |

Note: existing `trg_teams_after_insert` adds members by legacy `users.group_name`, so each test team/chat also has 2 legacy/non-active-by-enrollment members. The seed did not remove them because legacy cleanup is out of scope.

## Flutter Status

No Flutter UI was changed in Stage 2.1.

Current `get_my_lessons` still returns only:

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

So the test lessons should be visible in schedule for users of the target groups when selecting 2026-06-19 or 2026-06-21, but `LessonDetailsScreen` cannot yet display or use `subject_id` / `subject_offering_id` because the RPC/model do not return those fields.

## Stage 2.2

Recommended next small stage:

- extend the read path so `get_my_lessons` or a new read-only schedule RPC returns `subject_id`, `subject_offering_id`, `group_id`, `academic_term_id`, and `semester_number`;
- extend `Lesson` with those fields;
- add a minimal debug/info block in `LessonDetailsScreen`: `Предмет связан: subject_offering_id = ...`;
- then route linked lessons to SubjectHub/team/chat using `subject_offering_id`.

Do not rewrite the chat module for this step.
