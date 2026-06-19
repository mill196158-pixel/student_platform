# 03 Flutter Code Map

Flutter code was inspected read-only. No Flutter files were changed.

| Screen / module | File | Connected in UI? | What it does | Tables / RPCs used | Reuse? | Comment |
|---|---|---:|---|---|---:|---|
| App entry / router | `lib/main.dart` | Yes | Initializes Supabase, global cache, diary repository, GoRouter. | Auth session, `users` through downstream screens. | Yes | Primary app entry appears to be `StudentPlatformApp`, not `lib/src/app.dart`. |
| Legacy app shell | `lib/src/app.dart` | Unknown / likely legacy | Session-gated MaterialApp with password check. | `users.must_change_password`. | Maybe | Similar logic exists in router/screens; avoid changing until entrypoint is clarified. |
| Splash | `lib/src/ui/splash/splash_screen.dart` | Yes via `/splash` | Routes to login/home/change-password. | Supabase auth, `users`. | Yes | Connected by GoRouter. |
| Auth / login | `lib/src/ui/authentication/authenticate_screen.dart`, `screens/login_screen.dart`, `screens/register_screen.dart`, `screens/change_password_screen.dart` | Yes | Login, register, forced password change. | Supabase Auth, `get_my_profile`, `users.must_change_password`. | Yes | Uses `AuthEmailAdapter` and technical email flow. |
| Bottom navigation | `lib/src/ui/navigation/navigation_screen.dart` | Yes via `/home` | Five tabs: Home, Useful, Learning, Schedule, Profile; haptics on tab change. | None directly. | Yes | This is the current app shell. |
| Home | `lib/src/ui/home/home_screen.dart` | Yes | Simple welcome screen. | None. | Partial | Placeholder-level. |
| Useful materials | `lib/src/ui/info/info_screen.dart` | Yes | Empty state for useful information. | None. | Partial | No `useful_materials` DB integration found. |
| Learning / teams | `lib/src/ui/learning/learning_screen.dart` | Yes | Lists teams, supports grid/list and manage teams. | `get_my_teams`, realtime `team_members`; Stage 1 also reads academic context through `AcademicContextService`. | Yes | Stage 1 removed the hardcoded learning group helper, but team/chat flow remains team-centric. |
| Team details | `lib/src/ui/learning/team_details_screen.dart` | Yes from Learning | Tabs: Assignments, Chat, Files. | Through `TeamCubit` and repository. | Yes | Default tab is Chat (`initialTabIndex = 1`). |
| Assignments | `lib/src/ui/learning/tabs/assignments_tab.dart`, `tabs/assignments/*`, `state/team_cubit.dart` | Yes | Assignment list, details, voting/publish/update/remove. | `get_team_assignments`, `propose_assignment`, `publish_assignment`, `set_assignment_done`, `update_assignment`, `remove_assignment`, `assignment_votes`, realtime `assignments`, `assignment_votes`, `assignment_done`. | Yes | Current flow is team-centric but DB has `subject_offering_id` columns. |
| Team chat | `lib/src/ui/learning/tabs/chat_tab.dart`, `tabs/chat/*`, `state/team_cubit.dart`, `data/supabase_learning_repository.dart` | Yes | Team chat, replies, pins, files, draft/cache, message deletion. | `chats`, `messages`, `chat_files`, `message_reactions`, `get_chat_messages_for_team`, `send_chat_message`, `send_chat_message_for_login`, `pin_message`. | Yes | Mature module; docs need freshness fixes. |
| Files tab | `lib/src/ui/learning/tabs/files_tab.dart` | Yes | Shows chat/team files and listens to realtime. | `chat_files`, `chats`, realtime `chat_files`, auth current user. | Yes | Team/chat file model exists. |
| Direct chats / my chats | `lib/src/ui/chats/my_chats_screen.dart`, `direct_chat_screen.dart`, `core/*`, `data/dm_api.dart` | Yes from Profile/Friends | Lists team and DM chats, opens unified/direct chats, polling/realtime helpers. | `chat_members`, `chats`, `messages`, `users`, `chat_files`, `chat_reads`, many chat RPCs. | Yes | Feature-rich; row counts confirm chat data exists. |
| Friends | `lib/src/ui/friends/my_friends_screen.dart`, `friend_profile_screen.dart` | Yes from Profile | Friends list, classmates, requests, profile navigation. | `friends`, `friend_requests`, `users`, `student_enrollments`, `get_my_classmates`, `get_user_profile`, `search_users_global`. | Yes | Uses active enrollments for classmates. |
| Profile | `lib/src/ui/profile/profile_screen.dart`, `edit_profile_screen.dart`, `profile_repository.dart` | Yes | Profile view/edit, avatar upload, counters, logout. | `users`, Supabase Auth, storage bucket `avatars`, `unread_total`. | Yes | Do not expose keys; avatar storage in Supabase bucket. |
| Schedule | `lib/src/ui/schedule/schedule_screen.dart`, `lesson_details_screen.dart`, `models/*`, `widgets/*` | Yes | Calendar/schedule by month/day and lesson details. | `get_my_lessons`, realtime `lessons`. | Yes | Live DB has `lessons=176`; table RLS currently disabled. |
| Subject diary | `lib/src/ui/schedule/subject_diary_screen.dart`, `subject_diary/*`, `lib/src/data/subject_diary_repository_supabase.dart` | Yes from schedule/details | Subject diary entries, text/conspects/files, S3 uploads. | `subject_diary_entries`, `subject_diary_files`, `get_my_subject_diary`, `add_subject_diary_entry`, diary file RPCs, `get_my_teams`, `get_my_lessons`, `teams`. | Yes | Uses Yandex S3 config and Supabase metadata. |
| Study plan / exams | `lib/src/ui/exams/exams_screen.dart` | Yes via `/exams` and likely Profile | Study plan, subject cards, difficulty voting. | `student_enrollments`, `group_term_semesters`, `group_academic_profiles`, `subject_offerings`, `curriculum_subjects`, `subject_catalog`, `rpc_get_my_subjects_v2`, `rpc_vote_subject_difficulty_v2`. | Yes | This is the strongest existing academic-v2 frontend code. |
| Admin/import screens | Not found in `lib/src/ui` | No | No Flutter import/admin UI found. | Import scripts are in `scripts/`, SQL in `supabase/`. | No | Keep import/admin outside Flutter for now. |

## Code Summary

The app is not a blank skeleton. It already has navigation, auth, profile, learning/team details, team chat, DM chat, assignments, files, schedule, subject diary, friends, and study plan screens. Academic-v2 integration exists in the study plan and database schema, while learning/team/chat flows remain mostly team-centric and partly legacy-compatible.

## Stage 1 Update

| Screen / module | File | Connected in UI? | What changed | Tables used | Comment |
|---|---|---:|---|---|---|
| Academic context service | `lib/src/data/academic_context_service.dart` | Indirect | Added read-only models and loader for current user's academic context. | `users`, `student_enrollments`, `groups`, `group_term_semesters`, `academic_terms` | No writes, no RPCs, no service role. |
| Learning / teams | `lib/src/ui/learning/learning_screen.dart` | Yes | Removed hardcoded `getCurrentGroupCodeSync() => 1-См(ВВ)-1`; shows group/semester/source block from AcademicContext. | Reads via `AcademicContextService`; team list still uses existing `get_my_teams`. | Existing team/chat flow was preserved. |
