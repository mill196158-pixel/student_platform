# 05 Supabase Live Schema Check

Live Supabase schema was checked read-only through MCP.

## Project

- Project ref: `gwdanmwluhrcfxbnplwd`
- Project name: `mill196158@gmail.com's Project`
- Status: `ACTIVE_HEALTHY`
- Region: `eu-central-1`
- PostgreSQL: `17.4.1.074`

No personal rows, emails, names, record-book numbers, service role keys, or auth tokens were printed.

## Confirmed Row Counts

| Table | Row count | RLS |
|---|---:|---|
| `users` | 34 | enabled, 6 policies |
| `groups` | 2 | disabled |
| `student_enrollments` | 29 | disabled |
| `academic_years` | 2 | disabled |
| `academic_terms` | 4 | disabled |
| `group_academic_profiles` | 2 | disabled |
| `group_term_semesters` | 8 | disabled |
| `subject_catalog` | 27 | disabled |
| `subject_aliases` | 27 | disabled |
| `curriculum_subjects` | 31 | disabled |
| `subject_offerings` | 54 | disabled |
| `teams` | 12 | enabled, 1 policy |
| `team_members` | 190 | enabled, 1 policy |
| `chats` | 16 | enabled, 1 policy |
| `chat_members` | 198 | enabled, 4 policies |
| `messages` | 174 | enabled, 4 policies |
| `chat_files` | 36 | enabled, 4 policies |
| `assignments` | 1 | enabled, 5 policies |
| `assignment_votes` | 2 | enabled, 7 policies |
| `assignment_done` | 0 | enabled, 4 policies |
| `lessons` | 176 | disabled |
| `subject_diary_entries` | 4 | enabled, 4 policies |
| `subject_diary_files` | 7 | enabled, 3 policies |
| `friends` | 3 | enabled, 3 policies |
| `friend_requests` | 0 | enabled, 3 policies |
| `stage_students_vv_2024` | 29 | enabled, 0 policies |
| `stage_curriculum_vv_2024` | 66 | enabled, 0 policies |
| `stage_student_auth_credentials_vv_2024` | 29 | enabled, 0 policies |

## Confirmed Tables And Columns

MCP `list_tables(verbose=true)` confirmed columns and foreign keys for key tables, including:

- `teams.subject_offering_id`, `teams.group_id`, `teams.subject_id`, `teams.academic_year_id`, `teams.academic_term_id`, `teams.semester_number`
- `chats.subject_offering_id`
- `assignments.subject_offering_id`
- `chat_files.subject_offering_id`
- `lessons.subject_offering_id`
- `subject_diary_entries.subject_offering_id`
- academic tables: `academic_years`, `academic_terms`, `group_academic_profiles`, `group_term_semesters`, `student_enrollments`, `subject_catalog`, `subject_aliases`, `curriculum_subjects`, `subject_offerings`, `teachers`, `offering_teachers`

## Confirmed RPCs

Found live public RPC names used by Flutter:

- `add_subject_diary_entry`
- `get_chat_messages`
- `get_chat_messages_for_team`
- `get_dm_peer_profile`
- `get_last_message_row`
- `get_my_classmates`
- `get_my_lessons`
- `get_my_profile`
- `get_my_subject_diary`
- `get_my_teams`
- `get_team_assignments`
- `get_unread_in_chat`
- `get_user_profile`
- `join_team_by_code`
- `mark_chat_read`
- `pin_message`
- `propose_assignment`
- `publish_assignment`
- `remove_assignment`
- `rpc_get_my_subjects_v2`
- `rpc_vote_subject_difficulty_v2`
- `search_users_global`
- `send_chat_message`
- `send_chat_message_for_login`
- `set_assignment_done`
- `update_assignment`

## Import State

Live DB confirms that VV 2024 data appears to have moved beyond staging:

- staging rows exist;
- `users`, `student_enrollments`, academic catalog/offering rows exist;
- current team/chat/membership rows exist.

This confirms the later docs are closer to reality than the older staging-only docs.

## Security Risk

Supabase advisory reported RLS disabled on 31 public tables, including academic structure tables and `lessons`. Stage 0 REAL did not apply remediation SQL because changing RLS/policies is explicitly forbidden in this phase.

Next security work must design and test policies before enabling RLS broadly, because enabling RLS without policies can break the app.

## Manual Check SQL

For repeatable manual verification, use:

`docs/stage0_real/supabase_manual_check_stage0_real.sql`

## Stage 1 Read-Only Context Risk

Stage 1 added Flutter reads for:

- `users`
- `student_enrollments`
- `groups`
- `group_term_semesters`
- `academic_terms`

Live RLS state from Stage 0:

- `users`: RLS enabled, policies present
- `student_enrollments`: RLS disabled
- `groups`: RLS disabled
- `group_term_semesters`: RLS disabled
- `academic_terms`: RLS disabled

This means the new read-only context can work against the current live DB, but it is not a final security model. Future RLS work must add policies or a reviewed read-only RPC before relying on this path in production.
