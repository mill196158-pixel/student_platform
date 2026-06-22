-- Read-only check for VV 2024 group academic profiles and term-semester mapping.
-- This file intentionally contains SELECT statements only.

-- 1. Expected groups.
select
  id,
  name
from public.groups
where name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
order by name;

-- 2. Academic profiles for expected groups.
select
  g.id as group_id,
  g.name as group_name,
  gap.admission_year,
  gap.nominal_semesters,
  gap.active,
  gap.created_at,
  gap.updated_at
from public.groups g
left join public.group_academic_profiles gap on gap.group_id = g.id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
order by g.name;

-- 3. Term-semester rows for expected groups.
select
  g.id as group_id,
  g.name as group_name,
  ay.name as academic_year_name,
  at.name as academic_term_name,
  at.term_sequence,
  gts.academic_year_id,
  gts.academic_term_id,
  gts.semester_number,
  gts.source,
  gts.created_at,
  gts.updated_at
from public.groups g
left join public.group_term_semesters gts on gts.group_id = g.id
left join public.academic_years ay on ay.id = gts.academic_year_id
left join public.academic_terms at on at.id = gts.academic_term_id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
order by g.name, gts.semester_number nulls last;

-- 4. Summary per group: profile presence and semesters 1-4.
select
  g.name as group_name,
  (gap.group_id is not null) as has_profile,
  gap.admission_year,
  gap.nominal_semesters,
  gap.active,
  count(gts.id)::bigint as group_term_rows_count,
  array_agg(gts.semester_number order by gts.semester_number) filter (where gts.id is not null) as semester_numbers
from public.groups g
left join public.group_academic_profiles gap on gap.group_id = g.id
left join public.group_term_semesters gts on gts.group_id = g.id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
group by g.name, gap.group_id, gap.admission_year, gap.nominal_semesters, gap.active
order by g.name;

-- 5. Semester 4 must map to 2025/2026 spring 2026.
select
  g.name as group_name,
  gts.semester_number,
  ay.name as academic_year_name,
  at.name as academic_term_name,
  at.term_sequence,
  at.starts_on,
  at.ends_on,
  at.is_current
from public.group_term_semesters gts
join public.groups g on g.id = gts.group_id
join public.academic_years ay on ay.id = gts.academic_year_id
join public.academic_terms at on at.id = gts.academic_term_id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
  and gts.semester_number = 4
order by g.name;

-- 6. Duplicate group_id + semester_number rows.
select
  g.name as group_name,
  gts.group_id,
  gts.semester_number,
  count(*)::bigint as duplicate_count,
  array_agg(gts.id order by gts.id) as group_term_semester_ids
from public.group_term_semesters gts
join public.groups g on g.id = gts.group_id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
group by g.name, gts.group_id, gts.semester_number
having count(*) > 1
order by g.name, gts.semester_number;

-- 7. Old teams for these groups should still be unlinked to academic fields.
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

-- 8. Safety counts for tables that must not be populated by this seed.
select 'users' as table_name, count(*)::bigint as rows_count from public.users
union all select 'student_enrollments', count(*)::bigint from public.student_enrollments
union all select 'subject_catalog', count(*)::bigint from public.subject_catalog
union all select 'subject_aliases', count(*)::bigint from public.subject_aliases
union all select 'curriculum_subjects', count(*)::bigint from public.curriculum_subjects
union all select 'subject_offerings', count(*)::bigint from public.subject_offerings
union all select 'teams', count(*)::bigint from public.teams
union all select 'chats', count(*)::bigint from public.chats
union all select 'team_members', count(*)::bigint from public.team_members
order by table_name;
