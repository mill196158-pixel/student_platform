-- Read-only dry-run for importing VV 2024 curriculum from staging.
-- This file intentionally contains SELECT statements only.

-- 1. Summary counts and blockers.
with stage as (
  select
    sc.*,
    regexp_replace(lower(trim(coalesce(nullif(sc.display_name, ''), nullif(sc.raw_subject_name, '')))), '\s+', ' ', 'g') as normalized_subject_name,
    coalesce(sc.is_elective_module_header, false) as is_header,
    coalesce(sc.is_elective_option, false) as is_option,
    coalesce(sc.include_in_subject_catalog, true) as include_catalog,
    coalesce(sc.include_in_group_offerings_default, true) as include_offering
  from public.stage_curriculum_vv_2024 sc
),
resolved as (
  select
    s.*,
    g.id as group_id,
    gts.academic_year_id,
    gts.academic_term_id,
    existing_subject.id as existing_subject_id
  from stage s
  left join public.groups g on g.name = s.group_name
  left join public.group_term_semesters gts
    on gts.group_id = g.id
   and gts.semester_number = s.semester_number
  left join public.subject_catalog existing_subject
    on existing_subject.normalized_name = s.normalized_subject_name
),
subject_candidates as (
  select distinct
    normalized_subject_name,
    min(coalesce(nullif(display_name, ''), nullif(raw_subject_name, ''))) as canonical_name
  from resolved
  where not is_header
    and include_catalog
    and normalized_subject_name is not null
  group by normalized_subject_name
),
alias_candidates as (
  select distinct
    normalized_subject_name,
    alias,
    regexp_replace(lower(trim(alias)), '\s+', ' ', 'g') as normalized_alias
  from (
    select normalized_subject_name, raw_subject_name as alias
    from resolved
    where not is_header and include_catalog and nullif(trim(raw_subject_name), '') is not null
    union
    select normalized_subject_name, display_name as alias
    from resolved
    where not is_header and include_catalog and nullif(trim(display_name), '') is not null
  ) aliases
),
curriculum_candidates as (
  select distinct
    subject_index,
    semester_number,
    normalized_subject_name,
    coalesce(nullif(display_name, ''), nullif(raw_subject_name, '')) as display_name,
    raw_subject_name,
    credits_total,
    hours_total,
    control_form,
    block_name,
    elective_module_code,
    department,
    subject_type,
    subject_kind,
    is_elective,
    is_option
  from resolved
  where not is_header
    and include_catalog
    and normalized_subject_name is not null
),
offering_candidates as (
  select distinct
    group_id,
    group_name,
    semester_number,
    academic_year_id,
    academic_term_id,
    normalized_subject_name,
    coalesce(nullif(display_name, ''), nullif(raw_subject_name, '')) as display_name,
    subject_index,
    credits_total,
    hours_total,
    control_form,
    block_name,
    elective_module_code,
    is_option
  from resolved
  where not is_header
    and include_catalog
    and include_offering
    and normalized_subject_name is not null
),
duplicate_subject_candidates as (
  select normalized_subject_name, count(*)::bigint as candidate_rows
  from subject_candidates
  group by normalized_subject_name
  having count(*) > 1
),
duplicate_curriculum_candidates as (
  select
    subject_index,
    semester_number,
    normalized_subject_name,
    credits_total,
    hours_total,
    control_form,
    block_name,
    elective_module_code,
    count(*)::bigint as duplicate_count
  from curriculum_candidates
  group by subject_index, semester_number, normalized_subject_name, credits_total, hours_total, control_form, block_name, elective_module_code
  having count(*) > 1
),
duplicate_offering_candidates as (
  select group_id, semester_number, normalized_subject_name, count(*)::bigint as duplicate_count
  from offering_candidates
  group by group_id, semester_number, normalized_subject_name
  having count(*) > 1
),
blocked_rows as (
  select
    id,
    source_row,
    group_name,
    semester_number,
    raw_subject_name,
    display_name,
    array_remove(array[
      case when group_id is null then 'missing_group_id' end,
      case when academic_year_id is null or academic_term_id is null then 'missing_academic_year_or_term_for_group_semester' end,
      case when not is_header and include_catalog and normalized_subject_name is null then 'missing_subject_mapping' end
    ], null) as reasons
  from resolved
  where group_id is null
     or academic_year_id is null
     or academic_term_id is null
     or (not is_header and include_catalog and normalized_subject_name is null)
)
select
  (select count(*)::bigint from stage) as stage_rows_total,
  (select count(*)::bigint from subject_candidates) as subject_catalog_candidates,
  (select count(*)::bigint from subject_candidates sc left join public.subject_catalog existing on existing.normalized_name = sc.normalized_subject_name where existing.id is null) as subject_catalog_to_create,
  (select count(*)::bigint from alias_candidates) as subject_alias_candidates,
  (select count(*)::bigint from alias_candidates ac left join public.subject_aliases existing on existing.normalized_alias = ac.normalized_alias where existing.id is null) as subject_aliases_to_create,
  (select count(*)::bigint from curriculum_candidates) as curriculum_subject_candidates,
  (select count(*)::bigint from offering_candidates) as subject_offering_candidates,
  (select count(*)::bigint from blocked_rows) as blocked_rows_total,
  (select count(*)::bigint from duplicate_subject_candidates) as duplicate_subject_catalog_candidates,
  (select count(*)::bigint from duplicate_curriculum_candidates) as duplicate_curriculum_subject_candidates,
  (select count(*)::bigint from duplicate_offering_candidates) as duplicate_subject_offering_candidates,
  (select count(*)::bigint from stage where is_header) as elective_module_headers_skipped,
  (select count(*)::bigint from stage where is_option and not include_offering) as elective_options_curriculum_only,
  (select count(*)::bigint from stage where is_option and include_offering) as elective_options_with_offerings;

-- 2. Stage rows by group and semester.
select
  group_name,
  semester_number,
  count(*)::bigint as stage_rows_total,
  count(*) filter (where coalesce(is_elective_module_header, false))::bigint as elective_module_headers,
  count(*) filter (where coalesce(is_elective_option, false))::bigint as elective_options,
  count(*) filter (where coalesce(include_in_group_offerings_default, true))::bigint as default_offering_rows
from public.stage_curriculum_vv_2024
group by group_name, semester_number
order by group_name, semester_number;

-- 3. Electives by module.
select
  elective_module_code,
  semester_number,
  count(*)::bigint as rows_total,
  count(*) filter (where coalesce(is_elective_module_header, false))::bigint as module_headers,
  count(*) filter (where coalesce(is_elective_option, false))::bigint as option_rows,
  count(*) filter (where coalesce(is_elective_option, false) and coalesce(include_in_group_offerings_default, true))::bigint as options_with_offerings,
  count(*) filter (where coalesce(is_elective_option, false) and coalesce(include_in_group_offerings_default, true) = false)::bigint as options_curriculum_only,
  array_agg(distinct display_name order by display_name) filter (where coalesce(is_elective_option, false)) as option_names
from public.stage_curriculum_vv_2024
where elective_module_code is not null
group by elective_module_code, semester_number
order by semester_number, elective_module_code;

-- 4. Blocked rows.
with stage as (
  select
    sc.*,
    regexp_replace(lower(trim(coalesce(nullif(sc.display_name, ''), nullif(sc.raw_subject_name, '')))), '\s+', ' ', 'g') as normalized_subject_name,
    coalesce(sc.is_elective_module_header, false) as is_header,
    coalesce(sc.include_in_subject_catalog, true) as include_catalog
  from public.stage_curriculum_vv_2024 sc
),
resolved as (
  select
    s.*,
    g.id as group_id,
    gts.academic_year_id,
    gts.academic_term_id
  from stage s
  left join public.groups g on g.name = s.group_name
  left join public.group_term_semesters gts
    on gts.group_id = g.id
   and gts.semester_number = s.semester_number
)
select
  source_row,
  group_name,
  semester_number,
  raw_subject_name,
  display_name,
  array_remove(array[
    case when group_id is null then 'missing_group_id' end,
    case when academic_year_id is null or academic_term_id is null then 'missing_academic_year_or_term_for_group_semester' end,
    case when not is_header and include_catalog and normalized_subject_name is null then 'missing_subject_mapping' end
  ], null) as reasons
from resolved
where group_id is null
   or academic_year_id is null
   or academic_term_id is null
   or (not is_header and include_catalog and normalized_subject_name is null)
order by source_row nulls last, id;

-- 5. Current production counts for safety baseline.
select
  (select count(*) from public.subject_catalog)::bigint as subject_catalog_total,
  (select count(*) from public.subject_aliases)::bigint as subject_aliases_total,
  (select count(*) from public.curriculum_subjects)::bigint as curriculum_subjects_total,
  (select count(*) from public.subject_offerings)::bigint as subject_offerings_total,
  (select count(*) from public.teams)::bigint as teams_total,
  (select count(*) from public.chats)::bigint as chats_total,
  (select count(*) from public.team_members)::bigint as team_members_total,
  (select count(*) from public.chat_members)::bigint as chat_members_total;
