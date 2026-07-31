-- Stage 0 REAL manual Supabase check.
-- Read-only only: SELECT / information_schema / pg_catalog.
-- Do not paste or export personal rows. Review aggregate results only.

-- 1. Public tables and approximate row estimates.
select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.reltuples::bigint as approximate_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('r', 'p')
order by c.relname;

-- 2. Columns.
select
  table_schema,
  table_name,
  ordinal_position,
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
order by table_name, ordinal_position;

-- 3. Foreign keys.
select
  tc.constraint_name,
  tc.table_schema,
  tc.table_name,
  kcu.column_name,
  ccu.table_schema as foreign_table_schema,
  ccu.table_name as foreign_table_name,
  ccu.column_name as foreign_column_name
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name
 and tc.table_schema = kcu.table_schema
join information_schema.constraint_column_usage ccu
  on ccu.constraint_name = tc.constraint_name
 and ccu.table_schema = tc.table_schema
where tc.constraint_type = 'FOREIGN KEY'
  and tc.table_schema = 'public'
order by tc.table_name, tc.constraint_name, kcu.column_name;

-- 4. Indexes.
select
  schemaname,
  tablename,
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
order by tablename, indexname;

-- 5. Exact aggregate counts for key tables only. No personal columns are selected.
select 'users' as table_name, count(*)::bigint as row_count from public.users union all
select 'groups', count(*)::bigint from public.groups union all
select 'student_enrollments', count(*)::bigint from public.student_enrollments union all
select 'academic_years', count(*)::bigint from public.academic_years union all
select 'academic_terms', count(*)::bigint from public.academic_terms union all
select 'group_academic_profiles', count(*)::bigint from public.group_academic_profiles union all
select 'group_term_semesters', count(*)::bigint from public.group_term_semesters union all
select 'subject_catalog', count(*)::bigint from public.subject_catalog union all
select 'subject_aliases', count(*)::bigint from public.subject_aliases union all
select 'curriculum_subjects', count(*)::bigint from public.curriculum_subjects union all
select 'subject_offerings', count(*)::bigint from public.subject_offerings union all
select 'teams', count(*)::bigint from public.teams union all
select 'team_members', count(*)::bigint from public.team_members union all
select 'chats', count(*)::bigint from public.chats union all
select 'chat_members', count(*)::bigint from public.chat_members union all
select 'messages', count(*)::bigint from public.messages union all
select 'chat_files', count(*)::bigint from public.chat_files union all
select 'assignments', count(*)::bigint from public.assignments union all
select 'assignment_votes', count(*)::bigint from public.assignment_votes union all
select 'assignment_done', count(*)::bigint from public.assignment_done union all
select 'lessons', count(*)::bigint from public.lessons union all
select 'subject_diary_entries', count(*)::bigint from public.subject_diary_entries union all
select 'subject_diary_files', count(*)::bigint from public.subject_diary_files union all
select 'friends', count(*)::bigint from public.friends union all
select 'friend_requests', count(*)::bigint from public.friend_requests union all
select 'stage_students_vv_2024', count(*)::bigint from public.stage_students_vv_2024 union all
select 'stage_curriculum_vv_2024', count(*)::bigint from public.stage_curriculum_vv_2024 union all
select 'stage_student_auth_credentials_vv_2024', count(*)::bigint from public.stage_student_auth_credentials_vv_2024
order by table_name;

-- 6. RLS state and policy counts.
select
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  count(p.polname)::int as policy_count
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_policy p on p.polrelid = c.oid
where n.nspname = 'public'
  and c.relkind in ('r', 'p')
group by c.relname, c.relrowsecurity
order by c.relname;

-- 7. Policies.
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'public'
order by tablename, policyname;

-- 8. Public RPC/function names used by Flutter.
select
  p.proname as function_name,
  pg_get_function_arguments(p.oid) as arguments,
  pg_get_function_result(p.oid) as result_type
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'get_my_teams',
    'join_team_by_code',
    'get_chat_messages_for_team',
    'send_chat_message',
    'send_chat_message_for_login',
    'get_team_assignments',
    'propose_assignment',
    'publish_assignment',
    'set_assignment_done',
    'update_assignment',
    'remove_assignment',
    'pin_message',
    'get_my_lessons',
    'get_my_subject_diary',
    'add_subject_diary_entry',
    'get_my_profile',
    'get_user_profile',
    'get_my_classmates',
    'search_users_global',
    'get_chat_messages',
    'mark_chat_read',
    'get_dm_peer_profile',
    'get_last_message_row',
    'get_unread_in_chat',
    'rpc_get_my_subjects_v2',
    'rpc_vote_subject_difficulty_v2'
  )
order by p.proname;
