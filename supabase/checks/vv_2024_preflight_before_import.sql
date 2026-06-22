-- Read-only preflight checks before importing VV 2024 CSV files into staging.
-- This file intentionally contains SELECT statements only.

-- 1. Staging tables exist.
with expected(table_name) as (
  values
    ('stage_students_vv_2024'),
    ('stage_curriculum_vv_2024')
)
select
  e.table_name,
  case when t.table_name is null then 'missing' else 'exists' end as table_status
from expected e
left join information_schema.tables t
  on t.table_schema = 'public'
 and t.table_name = e.table_name
order by e.table_name;

-- 2. Staging table row counts before import.
select 'stage_students_vv_2024' as table_name, count(*)::bigint as rows_count
from public.stage_students_vv_2024
union all
select 'stage_curriculum_vv_2024', count(*)::bigint
from public.stage_curriculum_vv_2024
order by table_name;

-- 3. RLS status for staging and academic tables.
with expected(table_name) as (
  values
    ('stage_students_vv_2024'),
    ('stage_curriculum_vv_2024'),
    ('academic_years'),
    ('academic_terms'),
    ('group_academic_profiles'),
    ('group_term_semesters'),
    ('group_name_history'),
    ('group_naming_profiles'),
    ('student_enrollments'),
    ('subject_catalog'),
    ('subject_aliases'),
    ('subject_alias_review_queue'),
    ('curriculum_subjects'),
    ('subject_offerings'),
    ('teachers'),
    ('offering_teachers')
)
select
  e.table_name,
  n.nspname as schema_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as force_rls,
  case when c.oid is null then 'missing' else 'exists' end as table_status
from expected e
left join pg_class c
  on c.relname = e.table_name
 and c.relkind in ('r', 'p')
left join pg_namespace n
  on n.oid = c.relnamespace
 and n.nspname = 'public'
order by e.table_name;

-- 4. Required FK index coverage for academic import path.
with required_indexes(table_name, columns) as (
  values
    ('group_academic_profiles', array['group_id']),
    ('group_term_semesters', array['group_id']),
    ('group_term_semesters', array['academic_year_id']),
    ('group_term_semesters', array['academic_term_id']),
    ('subject_aliases', array['subject_id']),
    ('curriculum_subjects', array['subject_id']),
    ('subject_offerings', array['group_id']),
    ('subject_offerings', array['subject_id']),
    ('subject_offerings', array['academic_year_id']),
    ('subject_offerings', array['academic_term_id']),
    ('subject_offerings', array['curriculum_subject_id']),
    ('student_enrollments', array['user_id']),
    ('student_enrollments', array['group_id']),
    ('student_enrollments', array['created_by']),
    ('student_enrollments', array['transferred_from_enrollment_id']),
    ('offering_teachers', array['subject_offering_id']),
    ('offering_teachers', array['teacher_id']),
    ('subject_alias_review_queue', array['group_id']),
    ('subject_alias_review_queue', array['academic_year_id']),
    ('subject_alias_review_queue', array['resolved_subject_id']),
    ('subject_alias_review_queue', array['resolved_by'])
),
required_attnums as (
  select
    ri.table_name,
    ri.columns,
    c.oid as table_oid,
    array_agg(a.attnum order by u.ordinality)::int2[] as attnums
  from required_indexes ri
  join pg_class c on c.relname = ri.table_name
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  join unnest(ri.columns) with ordinality as u(column_name, ordinality) on true
  join pg_attribute a
    on a.attrelid = c.oid
   and a.attname = u.column_name
   and a.attnum > 0
   and not a.attisdropped
  group by ri.table_name, ri.columns, c.oid
)
select
  ra.table_name,
  ra.columns,
  exists (
    select 1
    from pg_index i
    where i.indrelid = ra.table_oid
      and i.indisvalid
      and i.indkey::int2[] @> ra.attnums
  ) as has_covering_index
from required_attnums ra
order by ra.table_name, array_to_string(ra.columns, ',');

-- 5. Academic years expected for VV 2024 curriculum import.
select
  name,
  start_year,
  starts_on,
  ends_on,
  is_current
from public.academic_years
where name in ('2024/2025', '2025/2026')
   or start_year in (2024, 2025)
order by start_year, name;

-- 6. Academic terms expected for 2024/2025 and 2025/2026.
select
  ay.name as academic_year_name,
  ay.start_year,
  at.term_in_year,
  at.term_sequence,
  at.name as academic_term_name,
  at.preload_starts_on,
  at.starts_on,
  at.ends_on,
  at.is_current
from public.academic_terms at
join public.academic_years ay on ay.id = at.academic_year_id
where ay.name in ('2024/2025', '2025/2026')
   or ay.start_year in (2024, 2025)
order by ay.start_year, at.term_sequence, at.term_in_year;

-- 7. Expected old groups, if they already exist.
select
  id,
  name
from public.groups
where name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
order by name;

-- 8. Duplicate groups by name for VV 2024 group names.
select
  name,
  count(*)::bigint as duplicate_count,
  array_agg(id order by id) as group_ids
from public.groups
where name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
group by name
having count(*) > 1
order by name;

-- 9. Existing old teams for VV 2024 group names.
select
  t.id,
  t.name,
  t.group_name,
  t.group_id,
  g.name as linked_group_name,
  t.subject_id,
  t.subject_offering_id,
  t.academic_year_id,
  t.academic_term_id,
  t.semester_number,
  t.created_at
from public.teams t
left join public.groups g on g.id = t.group_id
where t.group_name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
   or g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
order by coalesce(g.name, t.group_name), t.name, t.created_at;
