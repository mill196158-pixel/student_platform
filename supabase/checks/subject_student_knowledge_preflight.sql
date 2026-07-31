-- Subject student knowledge preflight.
--
-- Run before applying 20260609133000_create_subject_student_knowledge.sql.
-- This file does not mutate data or schema.

select
  'target_objects_existing' as check_name,
  n.nspname as schema_name,
  c.relname as object_name,
  c.relkind as object_kind
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'subject_student_profiles',
    'subject_offering_student_profiles',
    'subject_difficulty_votes',
    'subject_difficulty_stats_global',
    'subject_difficulty_stats_by_offering'
  )
order by c.relname;

select
  'target_functions_existing' as check_name,
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'rpc_vote_subject_difficulty_v2',
    'rpc_get_my_subjects_v2',
    'f_norm_subject'
  )
order by p.proname;

select
  'required_tables_present' as check_name,
  required.table_name,
  to_regclass('public.' || required.table_name) is not null as is_present
from (
  values
    ('subject_catalog'),
    ('subject_aliases'),
    ('subject_alias_review_queue'),
    ('curriculum_subjects'),
    ('subject_offerings'),
    ('student_enrollments'),
    ('groups'),
    ('group_term_semesters'),
    ('teams'),
    ('chats'),
    ('lessons'),
    ('assignments'),
    ('subject_diary_entries'),
    ('users')
) as required(table_name);

select
  'lessons_schedule_mapping_columns' as check_name,
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'lessons'
  and column_name in (
    'subject',
    'raw_subject_name',
    'normalized_subject_name',
    'subject_id',
    'subject_offering_id',
    'alias_match_status',
    'group_id',
    'semester_number'
  )
order by ordinal_position;

select
  'group_academic_profiles_program_columns' as check_name,
  column_name,
  data_type
from information_schema.columns
where table_schema = 'public'
  and table_name = 'group_academic_profiles'
  and column_name in ('direction', 'program_profile');

select
  'current_semester_coverage' as check_name,
  count(distinct so.group_id) as groups_with_offerings,
  count(distinct gts.group_id) as groups_with_group_term_semesters,
  count(distinct so.group_id) filter (where gts.group_id is null) as offering_groups_without_semester_rows
from public.subject_offerings so
left join public.group_term_semesters gts on gts.group_id = so.group_id;

select
  'active_enrollment_coverage' as check_name,
  count(*) as active_enrollments_count,
  count(distinct user_id) as active_students_count,
  count(distinct group_id) as active_groups_count
from public.student_enrollments
where status = 'active'
  and ended_at is null;

select
  'team_chat_offering_links' as check_name,
  count(*) filter (where t.subject_offering_id is not null) as teams_with_subject_offering_id,
  count(*) filter (where t.subject_offering_id is not null and ch.id is not null) as teams_with_main_chat,
  count(*) filter (where t.subject_offering_id is null) as legacy_teams_without_subject_offering_id
from public.teams t
left join public.chats ch
  on ch.team_id = t.id
 and ch.type = 'team_main';
