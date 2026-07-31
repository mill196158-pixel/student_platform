-- Read-only post-check after an approved VV 2024 curriculum import.
-- This file intentionally contains SELECT statements only.

-- 1. Production counts for imported curriculum tables.
select
  (select count(*) from public.subject_catalog)::bigint as subject_catalog_total,
  (select count(*) from public.subject_aliases)::bigint as subject_aliases_total,
  (select count(*) from public.curriculum_subjects)::bigint as curriculum_subjects_total,
  (select count(*) from public.subject_offerings)::bigint as subject_offerings_total;

-- 2. Subject offerings by group and semester.
select
  g.name as group_name,
  so.group_id,
  so.semester_number,
  count(*)::bigint as subject_offerings_total
from public.subject_offerings so
join public.groups g on g.id = so.group_id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
group by g.name, so.group_id, so.semester_number
order by g.name, so.semester_number;

-- 3. Duplicate offerings for same group, semester, and subject.
select
  so.group_id,
  g.name as group_name,
  so.semester_number,
  so.subject_id,
  sc.canonical_name,
  count(*)::bigint as duplicate_count
from public.subject_offerings so
join public.groups g on g.id = so.group_id
join public.subject_catalog sc on sc.id = so.subject_id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
group by so.group_id, g.name, so.semester_number, so.subject_id, sc.canonical_name
having count(*) > 1
order by g.name, so.semester_number, sc.canonical_name;

-- 4. Broken required links.
select
  so.id,
  so.display_name,
  so.subject_id,
  so.curriculum_subject_id,
  so.group_id,
  so.academic_year_id,
  so.academic_term_id,
  array_remove(array[
    case when so.subject_id is null then 'missing_subject_id' end,
    case when so.group_id is null then 'missing_group_id' end,
    case when so.academic_year_id is null then 'missing_academic_year_id' end,
    case when so.academic_term_id is null then 'missing_academic_term_id' end,
    case when sc.id is null then 'subject_id_not_found' end,
    case when g.id is null then 'group_id_not_found' end,
    case when ay.id is null then 'academic_year_id_not_found' end,
    case when at.id is null then 'academic_term_id_not_found' end
  ], null) as issues
from public.subject_offerings so
left join public.subject_catalog sc on sc.id = so.subject_id
left join public.groups g on g.id = so.group_id
left join public.academic_years ay on ay.id = so.academic_year_id
left join public.academic_terms at on at.id = so.academic_term_id
where so.subject_id is null
   or so.group_id is null
   or so.academic_year_id is null
   or so.academic_term_id is null
   or sc.id is null
   or g.id is null
   or ay.id is null
   or at.id is null
order by so.created_at, so.id;

-- 5. VV 2024 stage rows that did not resolve to an offering when expected.
with stage as (
  select
    sc.*,
    regexp_replace(lower(trim(coalesce(nullif(sc.display_name, ''), nullif(sc.raw_subject_name, '')))), '\s+', ' ', 'g') as normalized_subject_name,
    coalesce(sc.is_elective_module_header, false) as is_header,
    coalesce(sc.include_in_subject_catalog, true) as include_catalog,
    coalesce(sc.include_in_group_offerings_default, true) as include_offering
  from public.stage_curriculum_vv_2024 sc
),
resolved as (
  select
    s.id as stage_id,
    s.source_row,
    s.group_name,
    s.semester_number,
    s.raw_subject_name,
    s.display_name,
    g.id as group_id,
    subject.id as subject_id,
    cs.id as curriculum_subject_id,
    gts.academic_year_id,
    gts.academic_term_id,
    so.id as subject_offering_id
  from stage s
  left join public.groups g on g.name = s.group_name
  left join public.group_term_semesters gts
    on gts.group_id = g.id
   and gts.semester_number = s.semester_number
  left join public.subject_catalog subject on subject.normalized_name = s.normalized_subject_name
  left join public.curriculum_subjects cs
    on cs.subject_id = subject.id
   and cs.raw_subject_name = s.raw_subject_name
   and cs.display_name = coalesce(nullif(s.display_name, ''), nullif(s.raw_subject_name, ''))
   and cs.semester_number is not distinct from s.semester_number
   and cs.hours_total is not distinct from s.hours_total
   and cs.credits is not distinct from s.credits_total
  left join public.subject_offerings so
    on so.group_id = g.id
   and so.curriculum_subject_id = cs.id
   and so.academic_year_id = gts.academic_year_id
   and so.academic_term_id = gts.academic_term_id
  where not s.is_header
    and s.include_catalog
    and s.include_offering
)
select *
from resolved
where subject_offering_id is null
order by source_row nulls last, stage_id;

-- 6. Safety counts for tables that curriculum import must not change.
select
  (select count(*) from public.teams)::bigint as teams_total,
  (select count(*) from public.chats)::bigint as chats_total,
  (select count(*) from public.team_members)::bigint as team_members_total,
  (select count(*) from public.chat_members)::bigint as chat_members_total,
  (select count(*) from auth.users)::bigint as auth_users_total;
