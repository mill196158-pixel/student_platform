# 04 Supabase Code Usage Map

Supabase usage was collected from `lib/**/*.dart` and `docs/_snapshots/*`. This is code usage, not proof that every table exists; live DB confirmation is in `05_SUPABASE_LIVE_SCHEMA_CHECK.md`.

| Resource | FOUND_CODE | File | Operations | Purpose | Comment |
|---|---:|---|---|---|---|
| Supabase Auth | Yes | `main.dart`, auth/profile/chat files | sign in, sign out, update password, current user/session | Authentication and current user identity | Uses Dart defines for URL/anon key. |
| storage bucket `avatars` | Yes | `edit_profile_screen.dart`, `profile_repository.dart` | upload, get public URL | Profile avatars | Supabase storage is used only for avatars in scanned code. |
| external S3/Yandex storage | Yes | `subject_diary_repository_supabase.dart`, services | upload/download/delete through S3 client | Diary files and possibly chat file backend | Not Supabase Storage. |
| `users` | Yes | Auth, profile, chat, friends, learning | select/update | Profile, login lookup, avatars, status, display names | Live row count: 34. |
| `profiles` | No | Not found | None | Not used | Code uses `users` instead. |
| `groups` | Yes, mostly docs/code terms | Study plan/friends through enrollments | indirect | Group identity | Live row count: 2; RLS disabled. |
| `student_enrollments` | Yes | `my_friends_screen.dart`, `exams_screen.dart` | select | Active group/classmates/study plan | Live row count: 29; RLS disabled. |
| `academic_years` | No direct Flutter query | Schema/docs only | None directly | Academic calendar | Live row count: 2; RLS disabled. |
| `academic_terms` | No direct Flutter query | Schema/docs only | None directly | Academic terms | Live row count: 4; RLS disabled. |
| `group_academic_profiles` | Yes | `exams_screen.dart` | select | Nominal semesters | Live row count: 2; RLS disabled. |
| `group_term_semesters` | Yes | `exams_screen.dart` | select | Current/available semesters | Live row count: 8; RLS disabled. |
| `subject_catalog` | Yes | `exams_screen.dart` fallback join | select via nested relation | Canonical subject names | Live row count: 27; RLS disabled. |
| `subject_aliases` | No direct Flutter query | Docs/schema | None | Subject aliases | Live row count: 27; RLS disabled. |
| `curriculum_subjects` | Yes | `exams_screen.dart` fallback join | select via nested relation | Curriculum metadata | Live row count: 31; RLS disabled. |
| `subject_offerings` | Yes | `exams_screen.dart` | select | Study plan and subject instances | Live row count: 54; RLS disabled. |
| `teams` | Yes | Learning/chat/forward/diary | select via RPC/direct | Team workspaces | Live row count: 12. |
| `team_members` | Yes | Learning/team cubit/diary | select, realtime | Membership, learning refresh | Live row count: 190. |
| `chats` | Yes | Learning/chat/my chats/files | select/update | Team/DM chat containers | Live row count: 16. |
| `chat_members` | Yes | My chats | select | DM/team chat membership | Live row count: 198. |
| `messages` | Yes | Chat modules | select/update/delete, realtime | Chat messages | Live row count: 174. |
| `chat_files` | Yes | Chat/files modules | select/insert/update/delete-ish, realtime | Chat and team files | Live row count: 36. |
| `message_reactions` | Yes | Chat repository/cubit | select/realtime | Message reactions | Live table exists; list_tables row estimate was 1. |
| `chat_reads` | Yes | My chats / DM | upsert/select via RPC | Read/unread tracking | Live row count from list_tables: 26. |
| `dm_pairs` | Indirect | DB schema, DM RPCs | RPC-backed | Direct chat pair uniqueness | Live row count from list_tables: 0. |
| `lessons` | Yes | Schedule | realtime, RPC output table | Schedule | Live row count: 176; RLS disabled. |
| `schedule_lessons` | No | Not found | None | Not used | Current table appears to be `lessons`. |
| `assignments` | Yes | TeamCubit/realtime/RPCs | realtime, RPC-backed writes | Assignments | Live row count: 1. |
| `assignment_votes` | Yes | TeamCubit | upsert/realtime | Assignment voting | Live row count: 2. |
| `assignment_user_statuses` | No | Not found | None | Not used | Current table appears to be `assignment_done`. |
| `assignment_done` | Yes | TeamCubit | realtime/RPC-backed | Assignment completion | Live row count: 0. |
| `subject_diary_entries` | Yes | Subject diary | select/update/delete via RPC/direct, realtime | Diary entries | Live row count: 4. |
| `diary_files` | No | Not found | None | Not used | Current table appears to be `subject_diary_files`. |
| `subject_diary_files` | Yes | Subject diary repo/screens | select/update/delete via RPC/direct, realtime | Diary attached files | Live row count: 7. |
| `friends` | Yes | Friends screens | select/insert/delete, realtime | Friend graph | Live row count: 3. |
| `friend_requests` | Yes | Friends screens | select/insert/delete, realtime | Friend requests | Live row count: 0. |
| `useful_materials` | No | Not found | None | Useful tab not implemented | Useful screen is placeholder. |
| `feedback` | No | Not found | None | Not used | No Flutter usage found. |
| `chat_threads` | No | Not found | None | Not used | Current chat tables are `chats` and `messages`. |
| `chat_messages` | No | Not found | None | Not used | Current table is `messages`. |
| `learning_test_sets` | No | Not found | None | Not used | No usage found. |
| `engineering_calculation_runs` | No | Not found | None | Not used | No usage found. |

## RPCs Found In Flutter

Found in code and/or snapshot:

- Auth/profile: `get_my_profile`, `get_user_profile`, `get_profile_counters`, `unread_total`
- Teams/chat: `get_my_teams`, `join_team_by_code`, `get_chat_messages_for_team`, `send_chat_message`, `send_chat_message_for_login`, `get_chat_messages`, `ensure_dm_chat`, `send_message_in_chat_with_files`, `mark_chat_read`, `get_dm_peer_profile`, `get_last_message_row`, `get_unread_in_chat`, `get_unread_meta`, `toggle_message_reaction`, `pin_message`, `save_chat_file`
- Assignments: `get_team_assignments`, `propose_assignment`, `vote_assignment`, `publish_assignment`, `set_assignment_done`, `update_assignment`, `remove_assignment`
- Schedule/diary: `get_my_lessons`, `get_my_subject_diary`, `add_subject_diary_entry`, `delete_subject_diary_entry`, `update_subject_diary_text`, `remove_subject_diary_file`, `get_subject_diary_files`, `add_subject_diary_file`
- Friends: `get_my_classmates`, `search_users_global`
- Academic study plan: `rpc_get_my_subjects_v2`, `rpc_vote_subject_difficulty_v2`

## Realtime Channels Found

- `public:team_members:*`
- `public:messages`
- `public:message_reactions`
- `public:assignments`
- `public:assignment_votes`
- `public:assignment_done`
- `public:chat_files`
- `public:lessons`
- `public:subject_diary_entries`
- `public:subject_diary_files`
- `public:friend_requests:*`
- `public:friends:*`
- DM message channels

## Notes

Some usage appears in `lib/all_dart_code.txt`, which is an existing generated/text aggregate in the workspace. The active code map focuses on `lib/src/**` and `lib/main.dart`.

## Stage 1 Update

New read-only usage added in `lib/src/data/academic_context_service.dart`:

| Resource | FOUND_CODE | File | Operations | Purpose | Comment |
|---|---:|---|---|---|---|
| `users` | Yes | `academic_context_service.dart` | select `id` by auth uid | Confirm public user row | RLS enabled in live DB. |
| `student_enrollments` | Yes | `academic_context_service.dart` | select active enrollment by `user_id`, `status`, `ended_at is null` | Source of truth for active group | RLS disabled in live DB. |
| `groups` | Yes | `academic_context_service.dart` | select `id,name` by enrollment group id | Display current group name | RLS disabled in live DB. |
| `group_term_semesters` | Yes | `academic_context_service.dart` | select semester rows by group id | Current semester detection | RLS disabled in live DB. |
| `academic_terms` | Yes | `academic_context_service.dart` | nested select `is_current`, `starts_on`, `ends_on` | Prefer active/current term before max semester fallback | RLS disabled in live DB. |

No new RPC, storage, auth write, insert, update, delete, or upsert usage was added.
