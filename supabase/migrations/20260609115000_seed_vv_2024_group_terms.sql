-- Seed VV 2024 group academic profiles and term-semester mapping.
-- Scope: public.group_academic_profiles and public.group_term_semesters only.
-- This migration does not transfer students or curriculum data and does not
-- create users, groups, teams, chats, memberships, subjects, or offerings.

with vv_groups as (
  select id, name
  from public.groups
  where name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
)
insert into public.group_academic_profiles(
  group_id,
  admission_year,
  nominal_semesters,
  active,
  updated_at
)
select
  id,
  2024,
  4,
  true,
  now()
from vv_groups
on conflict (group_id) do update
set
  admission_year = excluded.admission_year,
  nominal_semesters = excluded.nominal_semesters,
  active = excluded.active,
  updated_at = now();

with vv_groups as (
  select id, name
  from public.groups
  where name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
),
term_map as (
  select *
  from (
    values
      ('2024/2025', 20241, 1),
      ('2024/2025', 20242, 2),
      ('2025/2026', 20251, 3),
      ('2025/2026', 20252, 4)
  ) as v(academic_year_name, term_sequence, semester_number)
),
resolved_terms as (
  select
    ay.id as academic_year_id,
    at.id as academic_term_id,
    tm.semester_number
  from term_map tm
  join public.academic_years ay on ay.name = tm.academic_year_name
  join public.academic_terms at
    on at.academic_year_id = ay.id
   and at.term_sequence = tm.term_sequence
)
insert into public.group_term_semesters(
  group_id,
  academic_year_id,
  academic_term_id,
  semester_number,
  source,
  updated_at
)
select
  vg.id,
  rt.academic_year_id,
  rt.academic_term_id,
  rt.semester_number,
  'import',
  now()
from vv_groups vg
cross join resolved_terms rt
on conflict (group_id, academic_term_id) do update
set
  academic_year_id = excluded.academic_year_id,
  semester_number = excluded.semester_number,
  source = excluded.source,
  updated_at = now();
