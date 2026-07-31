# 06 Existing Features Map

| Feature | Exists? | Files | Tables / RPCs | What works / appears implemented | Do not touch | Needs verification |
|---|---|---|---|---|---|---|
| Auth | Yes | `main.dart`, `authenticate_screen.dart`, `login_screen.dart`, `register_screen.dart`, `change_password_screen.dart`, `auth_service.dart` | Supabase Auth, `users`, `get_my_profile` | Login, register, password change gate. | Auth flow and Dart define config. | Exact register policy and production auth expectations. |
| Profile | Yes | `profile_screen.dart`, `edit_profile_screen.dart`, `profile_repository.dart` | `users`, storage `avatars`, `unread_total`, `get_profile_counters` | Profile view/edit, avatar upload, logout. | Existing `users` model and avatar bucket usage. | RLS behavior for user profile reads/updates. |
| Bottom navigation | Yes | `navigation_screen.dart` | None directly | Home, Useful, Learning, Schedule, Profile tabs; haptics. | Tab structure unless Stage 1 requires planned UI change. | Whether `/exams` should be linked more prominently. |
| Groups | Partial | `exams_screen.dart`, `my_friends_screen.dart`, `academic_context_service.dart`, docs | `groups`, `student_enrollments`, `group_term_semesters` | Study plan/friends can resolve active group from enrollments; Stage 1 adds a read-only context for Learning. | Legacy `users.group_name` compatibility. | RLS/policy behavior for academic context reads. |
| Teams | Yes | `learning_screen.dart`, `learning_cubit.dart`, `supabase_learning_repository.dart` | `get_my_teams`, `teams`, `team_members` | Lists teams and refreshes on membership changes. | Existing team/chat UI. | Move source from legacy group code to active enrollment/offerings. |
| Team details | Yes | `team_details_screen.dart` | Through `TeamCubit` | Assignments/Chat/Files tabs. | Current mature UI shell. | Academic-v2 routing by `subject_offering_id`. |
| Chat | Yes | `tabs/chat_tab.dart`, `tabs/chat/*`, `state/team_cubit.dart`, `data/supabase_learning_repository.dart` | `messages`, `chat_files`, `chats`, `message_reactions`, chat RPCs | Text/file messages, replies, pins, reactions, deletion, drafts/cache. | Chat behavior and caches unless focused chat task. | RPC compatibility and stale FAQ details. |
| Direct messages | Yes | `my_chats_screen.dart`, `direct_chat_screen.dart`, `dm_api.dart`, `core/*` | `chats`, `chat_members`, `messages`, `dm_pairs`, DM RPCs | DM list/open/send/read state. | DM chat IDs and existing RPCs. | Exact DM RLS and unread behavior. |
| Messages | Yes | Chat modules | `messages`, `message_reactions`, `chat_reads` | Message rendering, polling/realtime, pins/reactions. | Message schema compatibility fields. | Cleanup duplicated legacy fields only in later stage. |
| Files | Yes | `files_tab.dart`, chat attachments/files widgets, `file_service.dart` | `chat_files`, save/upload RPCs, external file service | Chat/team files and file opening/downloading. | Existing file table links and cache. | Storage backend boundaries: Supabase storage vs external S3/Yandex. |
| Assignments | Yes | `assignments_tab.dart`, `assignment_details_screen.dart`, `team_cubit.dart` | `assignments`, `assignment_votes`, `assignment_done`, assignment RPCs | Create/propose/publish/vote/done/update/remove through RPCs. | Existing team assignment flow. | Link to `subject_offering_id` for new academic screens. |
| Deadlines | Partial | Assignment model/screens | `assignments.due_at`, `due_text` | Due text/time exists in assignment data. | Existing assignment UI. | Whether deadline UX is complete. |
| Schedule | Yes | `schedule_screen.dart`, `lesson_details_screen.dart` | `get_my_lessons`, `lessons` realtime | Calendar and lesson details. | Existing lesson UI. | RLS is disabled on `lessons`; academic offering links exist. |
| Diary | Yes | `subject_diary_screen.dart`, `subject_diary/*`, `subject_diary_repository_supabase.dart` | `subject_diary_entries`, `subject_diary_files`, diary RPCs | Text notes, conspects/files, delete/update/list. | Repository abstraction and S3 file handling. | RLS and offering-driven subject lookup. |
| Friends | Yes | `my_friends_screen.dart`, `friend_profile_screen.dart` | `friends`, `friend_requests`, `users`, `student_enrollments`, `get_my_classmates`, `search_users_global` | Friends, requests, classmates, search, profile navigation. | Existing friend graph tables. | Exact RLS and global search policy. |
| Useful | Partial | `info_screen.dart` | None | Placeholder empty state. | No DB table currently wired. | Decide whether to implement `useful_materials`. |
| Study plan | Yes | `exams_screen.dart` | `student_enrollments`, `group_term_semesters`, `group_academic_profiles`, `subject_offerings`, `curriculum_subjects`, `subject_catalog`, `rpc_get_my_subjects_v2` | Academic-v2 subject plan and fallback query. | Existing academic-v2 logic. | UI route/discovery and RLS for public academic tables. |
| Import students | Not in Flutter; scripts exist | `scripts/import_academic_batch.js`, `scripts/create_vv_2024_auth_users.js`, docs, supabase migrations/checks | Staging/import tables | CLI/runbook exists; live DB shows import data. | Do not run import/apply scripts in Stage 0. | Review before any future import. |
| Roles | Partial | Auth/profile/docs/RLS | `users.role` | `student/starosta/teacher/admin` role column exists. | Role meanings and policies. | Admin policy design before RLS work. |
| Storage | Yes | Profile + diary/file services | Supabase `avatars`, S3/Yandex for diary/files | Avatars and file handling. | Do not expose secrets. | Bucket policies and Yandex config source. |
| Realtime | Yes | Learning/chat/files/schedule/friends/diary | Multiple channels | Several modules subscribe to table changes. | Existing channel names. | Realtime enabled/allowed for each table. |
| Local cache | Yes | `GlobalCache`, `SharedPreferences`, chat memory cache | Local only | Chat files/drafts/team caches. | Existing cache keys. | Cache invalidation and logout behavior. |
| Draft messages | Yes | `GlobalCache`, `chat_tab.dart` | Local only | Draft text/files persisted. | Existing draft persistence. | Edge cases around file loss. |
| Haptics | Yes | `navigation_screen.dart`, platform files | Local/platform | Light vibration on tab change. | Platform permissions/settings. | Device-specific behavior. |
| Fullscreen images | Yes | `fullscreen_image.dart`, file bubbles | Local/file URLs | Image gallery/viewer. | Existing viewer. | Cross-platform file opening. |
| Deletion | Yes | Chat/diary/assignments | `messages`, `chat_files`, diary RPCs, assignment RPCs | Message deletion, diary deletion, assignment removal. | Current behavior: chat files are detached, not deleted. | Docs are stale; server-side delete semantics. |
| Reply navigation | Yes | `chat_tab.dart`, `message_bubble.dart` | Local message list | Tap reply preview scrolls to original. | Existing scroll controllers. | Long chat performance. |

## Overall

The strongest reusable areas are auth, navigation, profile, learning/team details, chat, files, assignments, schedule, diary, friends, and study plan. The riskiest area is not missing UI; it is the mismatch between academic-v2 schema/docs and legacy/team-centric frontend code plus disabled RLS on academic tables.

## Stage 1 Update

| Feature | Stage 1 status | Files | Tables | What changed | Still pending |
|---|---|---|---|---|---|
| Academic context | Added read-only | `lib/src/data/academic_context_service.dart`, `lib/src/ui/learning/learning_screen.dart` | `users`, `student_enrollments`, `groups`, `group_term_semesters`, `academic_terms` | Learning now shows group/semester/source from active enrollment context. | Security-reviewed RLS/RPC contract. |
| Learning group source | Partially aligned | `learning_screen.dart` | Same as above plus existing `get_my_teams` | Hardcoded `1-См(ВВ)-1` helper removed. | Team list itself still uses existing team-centric RPC flow. |
