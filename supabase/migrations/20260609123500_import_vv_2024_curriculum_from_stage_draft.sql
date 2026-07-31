-- DRAFT ONLY. Do not apply until the dry-run is reviewed and explicitly approved.
--
-- Scope:
-- - import VV 2024 curriculum from public.stage_curriculum_vv_2024 into
--   subject_catalog, subject_aliases, curriculum_subjects, and subject_offerings;
-- - do not create or update teams, chats, team_members, or chat_members;
-- - do not touch auth.users, RLS policies, public.users, or student_enrollments.

begin;

insert into public.subject_catalog (
  canonical_name,
  normalized_name
)
with stage as (
  select
    sc.*,
    regexp_replace(lower(trim(coalesce(nullif(sc.display_name, ''), nullif(sc.raw_subject_name, '')))), '\s+', ' ', 'g') as normalized_subject_name,
    coalesce(sc.is_elective_module_header, false) as is_header,
    coalesce(sc.include_in_subject_catalog, true) as include_catalog
  from public.stage_curriculum_vv_2024 sc
),
subject_candidates as (
  select
    normalized_subject_name,
    min(coalesce(nullif(display_name, ''), nullif(raw_subject_name, ''))) as canonical_name
  from stage
  where not is_header
    and include_catalog
    and normalized_subject_name is not null
  group by normalized_subject_name
)
select
  canonical_name,
  normalized_subject_name
from subject_candidates
on conflict (normalized_name) do nothing;

insert into public.subject_aliases (
  subject_id,
  alias,
  normalized_alias,
  source
)
with stage as (
  select
    sc.*,
    regexp_replace(lower(trim(coalesce(nullif(sc.display_name, ''), nullif(sc.raw_subject_name, '')))), '\s+', ' ', 'g') as normalized_subject_name,
    coalesce(sc.is_elective_module_header, false) as is_header,
    coalesce(sc.include_in_subject_catalog, true) as include_catalog
  from public.stage_curriculum_vv_2024 sc
),
alias_candidates as (
  select distinct
    normalized_subject_name,
    alias,
    regexp_replace(lower(trim(alias)), '\s+', ' ', 'g') as normalized_alias
  from (
    select normalized_subject_name, raw_subject_name as alias
    from stage
    where not is_header and include_catalog and nullif(trim(raw_subject_name), '') is not null
    union
    select normalized_subject_name, display_name as alias
    from stage
    where not is_header and include_catalog and nullif(trim(display_name), '') is not null
  ) aliases
)
select
  sc.id,
  ac.alias,
  ac.normalized_alias,
  'vv_2024_stage'
from alias_candidates ac
join public.subject_catalog sc on sc.normalized_name = ac.normalized_subject_name
on conflict (normalized_alias) do nothing;

insert into public.curriculum_subjects (
  subject_id,
  raw_subject_name,
  display_name,
  semester_number,
  hours_total,
  credits,
  subject_index,
  block_name,
  control_form,
  department,
  subject_type,
  subject_kind,
  is_elective,
  elective_module_code
)
with stage as (
  select
    sc.*,
    regexp_replace(lower(trim(coalesce(nullif(sc.display_name, ''), nullif(sc.raw_subject_name, '')))), '\s+', ' ', 'g') as normalized_subject_name,
    coalesce(sc.is_elective_module_header, false) as is_header,
    coalesce(sc.include_in_subject_catalog, true) as include_catalog
  from public.stage_curriculum_vv_2024 sc
),
curriculum_candidates as (
  select distinct
    normalized_subject_name,
    raw_subject_name,
    coalesce(nullif(display_name, ''), nullif(raw_subject_name, '')) as display_name,
    semester_number,
    hours_total,
    credits_total,
    subject_index,
    block_name,
    control_form,
    department,
    subject_type,
    subject_kind,
    coalesce(is_elective, false) as is_elective,
    elective_module_code
  from stage
  where not is_header
    and include_catalog
    and normalized_subject_name is not null
)
select
  sc.id,
  cc.raw_subject_name,
  cc.display_name,
  cc.semester_number,
  cc.hours_total,
  cc.credits_total,
  cc.subject_index,
  cc.block_name,
  cc.control_form,
  cc.department,
  cc.subject_type,
  cc.subject_kind,
  cc.is_elective,
  cc.elective_module_code
from curriculum_candidates cc
join public.subject_catalog sc on sc.normalized_name = cc.normalized_subject_name
where not exists (
  select 1
  from public.curriculum_subjects existing
  where existing.subject_id = sc.id
    and existing.raw_subject_name is not distinct from cc.raw_subject_name
    and existing.display_name = cc.display_name
    and existing.semester_number is not distinct from cc.semester_number
    and existing.hours_total is not distinct from cc.hours_total
    and existing.credits is not distinct from cc.credits_total
);

update public.curriculum_subjects cs
set
  subject_index = coalesce(cs.subject_index, mc.subject_index),
  block_name = coalesce(cs.block_name, mc.block_name),
  control_form = coalesce(cs.control_form, mc.control_form),
  department = coalesce(cs.department, mc.department),
  subject_type = coalesce(cs.subject_type, mc.subject_type),
  subject_kind = coalesce(cs.subject_kind, mc.subject_kind),
  is_elective = cs.is_elective or mc.is_elective,
  elective_module_code = coalesce(cs.elective_module_code, mc.elective_module_code)
from (
  with stage as (
    select
      sc.*,
      regexp_replace(lower(trim(coalesce(nullif(sc.display_name, ''), nullif(sc.raw_subject_name, '')))), '\s+', ' ', 'g') as normalized_subject_name,
      coalesce(sc.is_elective_module_header, false) as is_header,
      coalesce(sc.include_in_subject_catalog, true) as include_catalog
    from public.stage_curriculum_vv_2024 sc
  )
  select distinct
    normalized_subject_name,
    raw_subject_name,
    coalesce(nullif(display_name, ''), nullif(raw_subject_name, '')) as display_name,
    semester_number,
    hours_total,
    credits_total,
    subject_index,
    block_name,
    control_form,
    department,
    subject_type,
    subject_kind,
    coalesce(is_elective, false) as is_elective,
    elective_module_code
  from stage
  where not is_header
    and include_catalog
    and normalized_subject_name is not null
) mc
join public.subject_catalog sc on sc.normalized_name = mc.normalized_subject_name
where cs.subject_id = sc.id
  and cs.raw_subject_name is not distinct from mc.raw_subject_name
  and cs.display_name = mc.display_name
  and cs.semester_number is not distinct from mc.semester_number
  and cs.hours_total is not distinct from mc.hours_total
  and cs.credits is not distinct from mc.credits_total;

insert into public.subject_offerings (
  subject_id,
  curriculum_subject_id,
  group_id,
  academic_year_id,
  academic_term_id,
  semester_number,
  display_name,
  status
)
with stage as (
  select
    sc.*,
    regexp_replace(lower(trim(coalesce(nullif(sc.display_name, ''), nullif(sc.raw_subject_name, '')))), '\s+', ' ', 'g') as normalized_subject_name,
    coalesce(sc.is_elective_module_header, false) as is_header,
    coalesce(sc.include_in_subject_catalog, true) as include_catalog,
    coalesce(sc.include_in_group_offerings_default, true) as include_offering
  from public.stage_curriculum_vv_2024 sc
),
offering_candidates as (
  select distinct
    g.id as group_id,
    gts.academic_year_id,
    gts.academic_term_id,
    s.semester_number,
    sc.id as subject_id,
    cs.id as curriculum_subject_id,
    coalesce(nullif(s.display_name, ''), nullif(s.raw_subject_name, '')) as display_name
  from stage s
  join public.groups g on g.name = s.group_name
  join public.group_term_semesters gts
    on gts.group_id = g.id
   and gts.semester_number = s.semester_number
  join public.subject_catalog sc on sc.normalized_name = s.normalized_subject_name
  join public.curriculum_subjects cs
    on cs.subject_id = sc.id
   and cs.raw_subject_name is not distinct from s.raw_subject_name
   and cs.display_name = coalesce(nullif(s.display_name, ''), nullif(s.raw_subject_name, ''))
   and cs.semester_number is not distinct from s.semester_number
   and cs.hours_total is not distinct from s.hours_total
   and cs.credits is not distinct from s.credits_total
  where not s.is_header
    and s.include_catalog
    and s.include_offering
)
select
  oc.subject_id,
  oc.curriculum_subject_id,
  oc.group_id,
  oc.academic_year_id,
  oc.academic_term_id,
  oc.semester_number,
  oc.display_name,
  'active'
from offering_candidates oc
where not exists (
  select 1
  from public.subject_offerings existing
  where existing.group_id = oc.group_id
    and existing.curriculum_subject_id = oc.curriculum_subject_id
    and existing.academic_year_id = oc.academic_year_id
    and existing.academic_term_id = oc.academic_term_id
)
on conflict do nothing;

commit;
