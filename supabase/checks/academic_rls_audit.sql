-- Read-only RLS/security diagnostics for academic tables and compatibility columns.
-- This file intentionally contains SELECT statements only.

-- 1. RLS status for academic tables and old tables with academic links.
with target_tables(table_name) as (
  values
    ('academic_years'),
    ('academic_terms'),
    ('group_academic_profiles'),
    ('group_term_semesters'),
    ('group_name_history'),
    ('group_naming_profiles'),
    ('subject_catalog'),
    ('subject_aliases'),
    ('subject_alias_review_queue'),
    ('curriculum_subjects'),
    ('subject_offerings'),
    ('student_enrollments'),
    ('teachers'),
    ('offering_teachers'),
    ('teacher_subjects'),
    ('teacher_offerings'),
    ('users'),
    ('groups'),
    ('teams'),
    ('chats'),
    ('assignments'),
    ('chat_files'),
    ('lessons'),
    ('subject_diary_entries')
)
select
  tt.table_name,
  n.nspname as schema_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as force_rls,
  case when c.oid is null then 'missing' else 'exists' end as table_status
from target_tables tt
left join pg_class c
  on c.relname = tt.table_name
 and c.relkind in ('r', 'p')
left join pg_namespace n
  on n.oid = c.relnamespace
 and n.nspname = 'public'
order by tt.table_name;

-- 2. Policies on academic tables and old tables with academic links.
with target_tables(table_name) as (
  values
    ('academic_years'),
    ('academic_terms'),
    ('group_academic_profiles'),
    ('group_term_semesters'),
    ('group_name_history'),
    ('group_naming_profiles'),
    ('subject_catalog'),
    ('subject_aliases'),
    ('subject_alias_review_queue'),
    ('curriculum_subjects'),
    ('subject_offerings'),
    ('student_enrollments'),
    ('teachers'),
    ('offering_teachers'),
    ('teacher_subjects'),
    ('teacher_offerings'),
    ('users'),
    ('groups'),
    ('teams'),
    ('chats'),
    ('assignments'),
    ('chat_files'),
    ('lessons'),
    ('subject_diary_entries')
)
select
  tt.table_name,
  p.policyname,
  p.roles,
  p.cmd,
  p.permissive,
  p.qual,
  p.with_check
from target_tables tt
left join pg_policies p
  on p.schemaname = 'public'
 and p.tablename = tt.table_name
order by tt.table_name, p.policyname nulls first;

-- 3. Tables without primary keys.
with target_tables(table_name) as (
  values
    ('academic_years'),
    ('academic_terms'),
    ('group_academic_profiles'),
    ('group_term_semesters'),
    ('group_name_history'),
    ('group_naming_profiles'),
    ('subject_catalog'),
    ('subject_aliases'),
    ('subject_alias_review_queue'),
    ('curriculum_subjects'),
    ('subject_offerings'),
    ('student_enrollments'),
    ('teachers'),
    ('offering_teachers'),
    ('teacher_subjects'),
    ('teacher_offerings'),
    ('users'),
    ('groups'),
    ('teams'),
    ('chats'),
    ('assignments'),
    ('chat_files'),
    ('lessons'),
    ('subject_diary_entries')
),
relations as (
  select c.oid, c.relname as table_name
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join target_tables tt on tt.table_name = c.relname
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
)
select r.table_name
from relations r
where not exists (
  select 1
  from pg_constraint con
  where con.conrelid = r.oid
    and con.contype = 'p'
)
order by r.table_name;

-- 4. Foreign keys without a covering index on the source table.
with target_tables(table_name) as (
  values
    ('academic_years'),
    ('academic_terms'),
    ('group_academic_profiles'),
    ('group_term_semesters'),
    ('group_name_history'),
    ('group_naming_profiles'),
    ('subject_catalog'),
    ('subject_aliases'),
    ('subject_alias_review_queue'),
    ('curriculum_subjects'),
    ('subject_offerings'),
    ('student_enrollments'),
    ('teachers'),
    ('offering_teachers'),
    ('teacher_subjects'),
    ('teacher_offerings'),
    ('users'),
    ('groups'),
    ('teams'),
    ('chats'),
    ('assignments'),
    ('chat_files'),
    ('lessons'),
    ('subject_diary_entries')
),
fk_columns as (
  select
    c.oid as table_oid,
    c.relname as table_name,
    con.conname as fk_name,
    confrel.relname as referenced_table,
    con.conkey,
    array_agg(att.attname order by cols.ordinality) as fk_columns
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join target_tables tt on tt.table_name = c.relname
  join pg_constraint con on con.conrelid = c.oid and con.contype = 'f'
  join pg_class confrel on confrel.oid = con.confrelid
  join unnest(con.conkey) with ordinality as cols(attnum, ordinality) on true
  join pg_attribute att on att.attrelid = c.oid and att.attnum = cols.attnum
  where n.nspname = 'public'
  group by c.oid, c.relname, con.conname, confrel.relname, con.conkey
)
select
  fk.table_name,
  fk.fk_name,
  fk.fk_columns,
  fk.referenced_table
from fk_columns fk
where not exists (
  select 1
  from pg_index i
  where i.indrelid = fk.table_oid
    and i.indisvalid
    and i.indkey::int2[] @> fk.conkey::int2[]
)
order by fk.table_name, fk.fk_name;

-- 5. Nullable academic compatibility columns in old tables.
select
  c.table_name,
  c.column_name,
  c.data_type,
  c.is_nullable
from information_schema.columns c
where c.table_schema = 'public'
  and c.table_name in (
    'users',
    'groups',
    'teams',
    'chats',
    'assignments',
    'chat_files',
    'lessons',
    'subject_diary_entries'
  )
  and c.column_name in (
    'primary_group_id',
    'group_id',
    'subject_id',
    'subject_offering_id',
    'academic_year_id',
    'academic_term_id',
    'semester_number',
    'teacher_id'
  )
order by c.table_name, c.column_name;

-- 6. Foreign keys between academic tables and linked old tables.
select
  tc.table_name,
  tc.constraint_name,
  kcu.column_name,
  ccu.table_name as referenced_table,
  ccu.column_name as referenced_column
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on kcu.constraint_schema = tc.constraint_schema
 and kcu.constraint_name = tc.constraint_name
join information_schema.constraint_column_usage ccu
  on ccu.constraint_schema = tc.constraint_schema
 and ccu.constraint_name = tc.constraint_name
where tc.table_schema = 'public'
  and tc.constraint_type = 'FOREIGN KEY'
  and (
    tc.table_name in (
      'academic_years',
      'academic_terms',
      'group_academic_profiles',
      'group_term_semesters',
      'group_name_history',
      'group_naming_profiles',
      'subject_catalog',
      'subject_aliases',
      'subject_alias_review_queue',
      'curriculum_subjects',
      'subject_offerings',
      'student_enrollments',
      'teachers',
      'offering_teachers',
      'teams',
      'chats',
      'assignments',
      'chat_files',
      'lessons',
      'subject_diary_entries',
      'users',
      'groups'
    )
    or ccu.table_name in (
      'academic_years',
      'academic_terms',
      'group_academic_profiles',
      'group_term_semesters',
      'group_name_history',
      'group_naming_profiles',
      'subject_catalog',
      'subject_aliases',
      'subject_alias_review_queue',
      'curriculum_subjects',
      'subject_offerings',
      'student_enrollments',
      'teachers',
      'offering_teachers'
    )
  )
order by tc.table_name, tc.constraint_name, kcu.ordinal_position;

-- 7. Existing public RPC/functions related to old and new academic flows.
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args,
  l.lanname as language,
  p.prosecdef as security_definer,
  p.provolatile as volatility
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_language l on l.oid = p.prolang
where n.nspname = 'public'
  and (
    p.proname ilike '%academic%'
    or p.proname ilike '%subject%'
    or p.proname ilike '%offering%'
    or p.proname ilike '%curriculum%'
    or p.proname ilike '%team%'
    or p.proname ilike '%chat%'
    or p.proname ilike '%assignment%'
    or p.proname ilike '%student%'
    or p.proname ilike '%group%'
    or p.proname ilike '%profile%'
    or p.proname in ('f_norm_subject')
  )
order by p.proname, pg_get_function_identity_arguments(p.oid);
