-- Academic ingestion identity foundation.
--
-- This migration intentionally does NOT parse files, apply curricula, create
-- offerings, change the current term, or create teams/chats. It establishes
-- the identities required to keep curricula for different programs, study
-- forms, admission cohorts, and source versions from being merged together.

begin;

-- ---------------------------------------------------------------------------
-- 1. First-class educational program and curriculum-plan identities.
-- ---------------------------------------------------------------------------

create table if not exists public.educational_programs (
  id uuid primary key default gen_random_uuid(),
  direction_code text not null,
  direction_name text not null,
  profile_name text not null,
  qualification text not null,
  study_form text not null,
  identity_key text not null,
  status text not null default 'draft',
  created_by uuid null references public.users(id) on delete set null,
  updated_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version integer not null default 1,
  constraint educational_programs_direction_code_check
    check (btrim(direction_code) <> ''),
  constraint educational_programs_direction_name_check
    check (btrim(direction_name) <> ''),
  constraint educational_programs_profile_name_check
    check (btrim(profile_name) <> ''),
  constraint educational_programs_qualification_check
    check (btrim(qualification) <> ''),
  constraint educational_programs_study_form_check
    check (study_form in ('full_time', 'part_time', 'extramural', 'mixed')),
  constraint educational_programs_status_check
    check (status in ('draft', 'active', 'archived')),
  constraint educational_programs_row_version_check
    check (row_version > 0),
  constraint educational_programs_identity_key_unique unique (identity_key)
);

create index if not exists educational_programs_status_idx
  on public.educational_programs(status, updated_at desc);

create table if not exists public.curriculum_plans (
  id uuid primary key default gen_random_uuid(),
  educational_program_id uuid not null
    references public.educational_programs(id) on delete restrict,
  admission_year integer not null,
  plan_code text not null,
  version_label text not null,
  plan_code_key text generated always as (
    lower(regexp_replace(btrim(plan_code), '\s+', ' ', 'g'))
  ) stored,
  version_key text generated always as (
    lower(regexp_replace(btrim(version_label), '\s+', ' ', 'g'))
  ) stored,
  nominal_semesters integer not null,
  status text not null default 'draft',
  source_title text null,
  source_file_name text null,
  source_mime_type text null,
  source_sha256 text null,
  source_verified boolean not null default false,
  parser_contract_version text null,
  reviewed_by uuid null references public.users(id) on delete set null,
  reviewed_at timestamptz null,
  created_by uuid null references public.users(id) on delete set null,
  updated_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version integer not null default 1,
  constraint curriculum_plans_admission_year_check
    check (admission_year between 2000 and 2100),
  constraint curriculum_plans_code_check
    check (btrim(plan_code) <> ''),
  constraint curriculum_plans_version_check
    check (btrim(version_label) <> ''),
  constraint curriculum_plans_nominal_semesters_check
    check (nominal_semesters > 0 and nominal_semesters <= 20),
  constraint curriculum_plans_status_check
    check (status in ('draft', 'reviewed', 'active', 'archived')),
  constraint curriculum_plans_source_sha256_check
    check (
      source_sha256 is null
      or source_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint curriculum_plans_review_check
    check (
      status = 'draft'
      or (reviewed_by is not null and reviewed_at is not null)
    ),
  constraint curriculum_plans_row_version_check
    check (row_version > 0),
  constraint curriculum_plans_identity_unique
    unique (
      educational_program_id,
      admission_year,
      plan_code_key,
      version_key
    )
);

create index if not exists curriculum_plans_program_idx
  on public.curriculum_plans(educational_program_id, admission_year, status);

comment on column public.curriculum_plans.source_verified is
  'True only after a trusted server-side intake verifies the original bytes. '
  'Client-provided metadata never sets this flag.';

-- ---------------------------------------------------------------------------
-- 2. Backward-compatible links. Existing legacy rows remain NULL.
-- ---------------------------------------------------------------------------

alter table public.group_academic_profiles
  add column if not exists curriculum_plan_id uuid null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'group_academic_profiles_curriculum_plan_fk'
      and conrelid = 'public.group_academic_profiles'::regclass
  ) then
    alter table public.group_academic_profiles
      add constraint group_academic_profiles_curriculum_plan_fk
      foreign key (curriculum_plan_id)
      references public.curriculum_plans(id)
      on delete restrict
      not valid;
    alter table public.group_academic_profiles
      validate constraint group_academic_profiles_curriculum_plan_fk;
  end if;
end
$$;

alter table public.curriculum_subjects
  add column if not exists curriculum_plan_id uuid null,
  add column if not exists source_occurrence_key text null,
  add column if not exists source_page integer null,
  add column if not exists source_region jsonb null,
  add column if not exists source_parser_version text null,
  add column if not exists reviewed_by uuid null,
  add column if not exists reviewed_at timestamptz null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'curriculum_subjects_curriculum_plan_fk'
      and conrelid = 'public.curriculum_subjects'::regclass
  ) then
    alter table public.curriculum_subjects
      add constraint curriculum_subjects_curriculum_plan_fk
      foreign key (curriculum_plan_id)
      references public.curriculum_plans(id)
      on delete restrict
      not valid;
    alter table public.curriculum_subjects
      validate constraint curriculum_subjects_curriculum_plan_fk;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'curriculum_subjects_reviewed_by_fk'
      and conrelid = 'public.curriculum_subjects'::regclass
  ) then
    alter table public.curriculum_subjects
      add constraint curriculum_subjects_reviewed_by_fk
      foreign key (reviewed_by)
      references public.users(id)
      on delete set null
      not valid;
    alter table public.curriculum_subjects
      validate constraint curriculum_subjects_reviewed_by_fk;
  end if;
end
$$;

alter table public.curriculum_subjects
  drop constraint if exists curriculum_subjects_plan_occurrence_check;

alter table public.curriculum_subjects
  add constraint curriculum_subjects_plan_occurrence_check
  check (
    curriculum_plan_id is null
    or (
      source_occurrence_key is not null
      and btrim(source_occurrence_key) <> ''
      and semester_number is not null
    )
  ) not valid;

alter table public.curriculum_subjects
  validate constraint curriculum_subjects_plan_occurrence_check;

alter table public.curriculum_subjects
  drop constraint if exists curriculum_subjects_source_page_check;

alter table public.curriculum_subjects
  add constraint curriculum_subjects_source_page_check
  check (source_page is null or source_page > 0) not valid;

alter table public.curriculum_subjects
  validate constraint curriculum_subjects_source_page_check;

-- The old index was not a reliable plan-local identity: nullable module_number
-- allowed duplicates, while subject+semester could not distinguish separate
-- elective positions. New plan-backed rows use an immutable occurrence key.
drop index if exists public.curriculum_subjects_plan_subject_unique;

create unique index if not exists curriculum_subjects_plan_occurrence_unique
  on public.curriculum_subjects(curriculum_plan_id, source_occurrence_key)
  where curriculum_plan_id is not null;

create index if not exists group_academic_profiles_curriculum_plan_idx
  on public.group_academic_profiles(curriculum_plan_id)
  where curriculum_plan_id is not null;

-- ---------------------------------------------------------------------------
-- 3. RLS and direct-access boundary.
-- ---------------------------------------------------------------------------

alter table public.educational_programs enable row level security;
alter table public.educational_programs force row level security;
alter table public.curriculum_plans enable row level security;
alter table public.curriculum_plans force row level security;

revoke all on table public.educational_programs
  from public, anon, authenticated;
revoke all on table public.curriculum_plans
  from public, anon, authenticated;
grant all on table public.educational_programs to service_role;
grant all on table public.curriculum_plans to service_role;

-- Plan identity and assignment changes must go through audited RPCs. Existing
-- read grants/policies remain intact for mobile compatibility.
revoke insert, update, delete on table public.curriculum_subjects
  from public, anon, authenticated;
revoke insert, update, delete on table public.group_academic_profiles
  from public, anon, authenticated;
grant insert, update, delete on table public.curriculum_subjects
  to service_role;
grant insert, update, delete on table public.group_academic_profiles
  to service_role;

-- ---------------------------------------------------------------------------
-- 4. Permission helpers.
-- ---------------------------------------------------------------------------

create or replace function private.academic_ingestion_has_permission(
  p_permission text
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ok boolean := false;
begin
  if auth.uid() is null or nullif(btrim(p_permission), '') is null then
    return false;
  end if;

  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)')
      is not null then
    execute 'select private.has_admin_permission($1,$2,$3,$4)'
      into v_ok
      using auth.uid(), p_permission, 'global', null::uuid;
  end if;

  return coalesce(v_ok, false);
end
$$;

revoke all on function private.academic_ingestion_has_permission(text)
  from public, anon, authenticated;
grant execute on function private.academic_ingestion_has_permission(text)
  to service_role;

create or replace function private.academic_ingestion_norm(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(btrim(coalesce(p_value, '')), '\s+', ' ', 'g'));
$$;

revoke all on function private.academic_ingestion_norm(text)
  from public, anon, authenticated;
grant execute on function private.academic_ingestion_norm(text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 5. Admin read/write RPCs. No direct table DML is exposed to Web Admin.
-- ---------------------------------------------------------------------------

create or replace function public.admin_list_educational_programs()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not (
      private.academic_ingestion_has_permission('subjects.read')
      or private.academic_ingestion_has_permission('subjects.write')
    ) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', ep.id,
            'direction_code', ep.direction_code,
            'direction_name', ep.direction_name,
            'profile_name', ep.profile_name,
            'qualification', ep.qualification,
            'study_form', ep.study_form,
            'status', ep.status,
            'row_version', ep.row_version,
            'updated_at', ep.updated_at
          )
          order by ep.direction_code, ep.profile_name, ep.study_form
        )
        from public.educational_programs ep
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_upsert_educational_program(
  p_id uuid default null,
  p_direction_code text default '',
  p_direction_name text default '',
  p_profile_name text default '',
  p_qualification text default '',
  p_study_form text default '',
  p_status text default 'draft',
  p_expected_row_version integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_identity_key text;
  v_current_version integer;
  v_action text;
begin
  if not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if nullif(btrim(p_direction_code), '') is null
     or nullif(btrim(p_direction_name), '') is null
     or nullif(btrim(p_profile_name), '') is null
     or nullif(btrim(p_qualification), '') is null
     or p_study_form not in ('full_time', 'part_time', 'extramural', 'mixed')
     or p_status not in ('draft', 'active', 'archived') then
    raise exception 'invalid_educational_program' using errcode = '22023';
  end if;

  v_identity_key := concat_ws(
    '|',
    private.academic_ingestion_norm(p_direction_code),
    private.academic_ingestion_norm(p_profile_name),
    private.academic_ingestion_norm(p_qualification),
    p_study_form
  );
  perform pg_advisory_xact_lock(hashtextextended(v_identity_key, 0));

  if p_id is null then
    insert into public.educational_programs(
      direction_code,
      direction_name,
      profile_name,
      qualification,
      study_form,
      identity_key,
      status,
      created_by,
      updated_by
    )
    values (
      btrim(p_direction_code),
      btrim(p_direction_name),
      btrim(p_profile_name),
      btrim(p_qualification),
      p_study_form,
      v_identity_key,
      p_status,
      auth.uid(),
      auth.uid()
    )
    returning id into v_id;
    v_action := 'educational_program.create';
  else
    select row_version
      into v_current_version
    from public.educational_programs
    where id = p_id
    for update;

    if v_current_version is null then
      raise exception 'educational_program_not_found' using errcode = 'P0002';
    end if;
    if p_expected_row_version is null
       or p_expected_row_version <> v_current_version then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;

    update public.educational_programs
    set direction_code = btrim(p_direction_code),
        direction_name = btrim(p_direction_name),
        profile_name = btrim(p_profile_name),
        qualification = btrim(p_qualification),
        study_form = p_study_form,
        identity_key = v_identity_key,
        status = p_status,
        updated_by = auth.uid(),
        updated_at = now(),
        row_version = row_version + 1
    where id = p_id
    returning id into v_id;
    v_action := 'educational_program.update';
  end if;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)')
      is not null then
    perform private.admin_write_audit(
      v_action,
      'educational_program',
      v_id::text,
      jsonb_build_object(
        'direction_code', btrim(p_direction_code),
        'study_form', p_study_form,
        'status', p_status
      )
    );
  end if;

  return v_id;
exception
  when unique_violation then
    raise exception 'educational_program_identity_conflict'
      using errcode = '23505';
end
$$;

create or replace function public.admin_list_curriculum_plans(
  p_educational_program_id uuid default null,
  p_admission_year integer default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not (
      private.academic_ingestion_has_permission('subjects.read')
      or private.academic_ingestion_has_permission('subjects.write')
    ) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', cp.id,
            'educational_program_id', cp.educational_program_id,
            'direction_code', ep.direction_code,
            'direction_name', ep.direction_name,
            'profile_name', ep.profile_name,
            'qualification', ep.qualification,
            'study_form', ep.study_form,
            'admission_year', cp.admission_year,
            'plan_code', cp.plan_code,
            'version_label', cp.version_label,
            'nominal_semesters', cp.nominal_semesters,
            'status', cp.status,
            'source_title', cp.source_title,
            'source_file_name', cp.source_file_name,
            'source_mime_type', cp.source_mime_type,
            'source_sha256', cp.source_sha256,
            'source_verified', cp.source_verified,
            'parser_contract_version', cp.parser_contract_version,
            'reviewed_by', cp.reviewed_by,
            'reviewed_at', cp.reviewed_at,
            'row_version', cp.row_version,
            'updated_at', cp.updated_at
          )
          order by cp.admission_year desc, cp.plan_code, cp.version_label
        )
        from public.curriculum_plans cp
        join public.educational_programs ep
          on ep.id = cp.educational_program_id
        where (
          p_educational_program_id is null
          or cp.educational_program_id = p_educational_program_id
        )
          and (
            p_admission_year is null
            or cp.admission_year = p_admission_year
          )
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_upsert_curriculum_plan(
  p_id uuid default null,
  p_educational_program_id uuid default null,
  p_admission_year integer default null,
  p_plan_code text default '',
  p_version_label text default '',
  p_nominal_semesters integer default null,
  p_status text default 'draft',
  p_source_title text default null,
  p_source_file_name text default null,
  p_source_mime_type text default null,
  p_source_sha256 text default null,
  p_parser_contract_version text default null,
  p_expected_row_version integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_current_version integer;
  v_current_status text;
  v_reviewed_by uuid;
  v_reviewed_at timestamptz;
  v_action text;
begin
  if not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_educational_program_id is null
     or not exists (
       select 1
       from public.educational_programs ep
       where ep.id = p_educational_program_id
     )
     or p_admission_year is null
     or p_admission_year not between 2000 and 2100
     or nullif(btrim(p_plan_code), '') is null
     or nullif(btrim(p_version_label), '') is null
     or p_nominal_semesters is null
     or p_nominal_semesters not between 1 and 20
     or p_status not in ('draft', 'reviewed', 'active', 'archived')
     or p_parser_contract_version is distinct from 'curriculum-document-v1'
     or (
       p_source_sha256 is not null
       and lower(btrim(p_source_sha256)) !~ '^[0-9a-f]{64}$'
     ) then
    raise exception 'invalid_curriculum_plan' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      concat_ws(
        '|',
        p_educational_program_id::text,
        p_admission_year::text,
        private.academic_ingestion_norm(p_plan_code),
        private.academic_ingestion_norm(p_version_label)
      ),
      0
    )
  );

  if p_status <> 'draft' then
    v_reviewed_by := auth.uid();
    v_reviewed_at := now();
  end if;

  if p_id is null then
    insert into public.curriculum_plans(
      educational_program_id,
      admission_year,
      plan_code,
      version_label,
      nominal_semesters,
      status,
      source_title,
      source_file_name,
      source_mime_type,
      source_sha256,
      source_verified,
      parser_contract_version,
      reviewed_by,
      reviewed_at,
      created_by,
      updated_by
    )
    values (
      p_educational_program_id,
      p_admission_year,
      btrim(p_plan_code),
      btrim(p_version_label),
      p_nominal_semesters,
      p_status,
      nullif(btrim(p_source_title), ''),
      nullif(btrim(p_source_file_name), ''),
      nullif(lower(btrim(p_source_mime_type)), ''),
      nullif(lower(btrim(p_source_sha256)), ''),
      false,
      nullif(btrim(p_parser_contract_version), ''),
      v_reviewed_by,
      v_reviewed_at,
      auth.uid(),
      auth.uid()
    )
    returning id into v_id;
    v_action := 'curriculum_plan.create';
  else
    select row_version, status
      into v_current_version, v_current_status
    from public.curriculum_plans
    where id = p_id
    for update;

    if v_current_version is null then
      raise exception 'curriculum_plan_not_found' using errcode = 'P0002';
    end if;
    if p_expected_row_version is null
       or p_expected_row_version <> v_current_version then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
    if v_current_status = 'active'
       and p_status = 'draft' then
      raise exception 'active_plan_cannot_return_to_draft'
        using errcode = 'P0001';
    end if;

    update public.curriculum_plans
    set educational_program_id = p_educational_program_id,
        admission_year = p_admission_year,
        plan_code = btrim(p_plan_code),
        version_label = btrim(p_version_label),
        nominal_semesters = p_nominal_semesters,
        status = p_status,
        source_title = nullif(btrim(p_source_title), ''),
        source_file_name = nullif(btrim(p_source_file_name), ''),
        source_mime_type = nullif(lower(btrim(p_source_mime_type)), ''),
        source_sha256 = nullif(lower(btrim(p_source_sha256)), ''),
        -- A client metadata edit can never claim trusted byte verification.
        source_verified = false,
        parser_contract_version =
          nullif(btrim(p_parser_contract_version), ''),
        reviewed_by = case
          when p_status = 'draft' then null
          else coalesce(v_reviewed_by, reviewed_by)
        end,
        reviewed_at = case
          when p_status = 'draft' then null
          else coalesce(v_reviewed_at, reviewed_at)
        end,
        updated_by = auth.uid(),
        updated_at = now(),
        row_version = row_version + 1
    where id = p_id
    returning id into v_id;
    v_action := 'curriculum_plan.update';
  end if;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)')
      is not null then
    perform private.admin_write_audit(
      v_action,
      'curriculum_plan',
      v_id::text,
      jsonb_build_object(
        'educational_program_id', p_educational_program_id,
        'admission_year', p_admission_year,
        'plan_code', btrim(p_plan_code),
        'version_label', btrim(p_version_label),
        'status', p_status,
        'source_verified', false
      )
    );
  end if;

  return v_id;
exception
  when unique_violation then
    raise exception 'curriculum_plan_identity_conflict'
      using errcode = '23505';
end
$$;

create or replace function public.admin_assign_group_curriculum_plan(
  p_group_id uuid,
  p_curriculum_plan_id uuid,
  p_expected_plan_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_plan uuid;
  v_group_admission_year integer;
  v_group_nominal_semesters integer;
  v_plan_admission_year integer;
  v_plan_nominal_semesters integer;
  v_plan_status text;
begin
  if not private.academic_ingestion_has_permission('groups.write')
     or not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select
    gap.curriculum_plan_id,
    gap.admission_year,
    gap.nominal_semesters
    into
      v_current_plan,
      v_group_admission_year,
      v_group_nominal_semesters
  from public.group_academic_profiles gap
  where gap.group_id = p_group_id
  for update;

  if not found then
    raise exception 'group_academic_profile_not_found' using errcode = 'P0002';
  end if;
  if v_current_plan is distinct from p_expected_plan_id then
    raise exception 'group_curriculum_plan_conflict' using errcode = '40001';
  end if;

  select cp.admission_year, cp.nominal_semesters, cp.status
    into v_plan_admission_year, v_plan_nominal_semesters, v_plan_status
  from public.curriculum_plans cp
  where cp.id = p_curriculum_plan_id;

  if v_plan_admission_year is null then
    raise exception 'curriculum_plan_not_found' using errcode = 'P0002';
  end if;
  if v_plan_status not in ('reviewed', 'active') then
    raise exception 'curriculum_plan_not_reviewed' using errcode = 'P0001';
  end if;
  if v_plan_admission_year <> v_group_admission_year then
    raise exception 'curriculum_plan_admission_year_mismatch'
      using errcode = '22023';
  end if;
  if v_plan_nominal_semesters <> v_group_nominal_semesters then
    raise exception 'curriculum_plan_nominal_semesters_mismatch'
      using errcode = '22023';
  end if;
  if exists (
    select 1
    from public.group_term_semesters gts
    where gts.group_id = p_group_id
      and gts.semester_number > v_plan_nominal_semesters
  ) then
    raise exception 'group_semester_exceeds_curriculum_plan'
      using errcode = '22023';
  end if;

  update public.group_academic_profiles
  set curriculum_plan_id = p_curriculum_plan_id,
      updated_at = now()
  where group_id = p_group_id;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)')
      is not null then
    perform private.admin_write_audit(
      'group.curriculum_plan_assign',
      'group',
      p_group_id::text,
      jsonb_build_object(
        'old_curriculum_plan_id', v_current_plan,
        'new_curriculum_plan_id', p_curriculum_plan_id
      )
    );
  end if;

  return p_curriculum_plan_id;
end
$$;

-- ---------------------------------------------------------------------------
-- 6. Plan-aware dry-run v1. It never writes target academic data.
-- ---------------------------------------------------------------------------

create or replace function public.admin_curriculum_plan_import_dry_run(
  p_curriculum_plan_id uuid,
  p_parser_contract_version text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.curriculum_plans%rowtype;
  v_row jsonb;
  v_row_number integer := 0;
  v_occurrence_key text;
  v_subject_name text;
  v_subject_index text;
  v_semester integer;
  v_hours integer;
  v_credits numeric;
  v_source_page integer;
  v_match_subject uuid;
  v_match_curriculum uuid;
  v_errors text[];
  v_warnings text[];
  v_seen text[] := '{}';
  v_classification text;
  v_items jsonb := '[]'::jsonb;
  v_new integer := 0;
  v_update integer := 0;
  v_duplicate integer := 0;
  v_error integer := 0;
begin
  if not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 5000
     or nullif(btrim(p_parser_contract_version), '') is null then
    raise exception 'invalid_curriculum_plan_import_payload'
      using errcode = '22023';
  end if;

  select *
    into v_plan
  from public.curriculum_plans
  where id = p_curriculum_plan_id;

  if v_plan.id is null then
    raise exception 'curriculum_plan_not_found' using errcode = 'P0002';
  end if;
  if v_plan.status <> 'draft' then
    raise exception 'curriculum_plan_not_draft' using errcode = 'P0001';
  end if;
  if v_plan.parser_contract_version is null
     or v_plan.parser_contract_version <> 'curriculum-document-v1'
     or p_parser_contract_version <> v_plan.parser_contract_version then
    raise exception 'unsupported_or_mismatched_parser_contract'
      using errcode = '22023';
  end if;

  for v_row in
    select value
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    v_row_number := v_row_number + 1;
    v_errors := '{}';
    v_warnings := '{}';
    v_match_subject := null;
    v_match_curriculum := null;
    v_semester := null;
    v_hours := null;
    v_credits := null;
    v_source_page := null;

    v_occurrence_key :=
      nullif(btrim(coalesce(v_row ->> 'source_occurrence_key', '')), '');
    v_subject_name :=
      nullif(btrim(coalesce(v_row ->> 'subject_name', '')), '');
    v_subject_index :=
      nullif(btrim(coalesce(v_row ->> 'subject_index', '')), '');

    if v_occurrence_key is null then
      v_errors := array_append(v_errors, 'source_occurrence_key_required');
    elsif v_occurrence_key = any(v_seen) then
      v_errors := array_append(v_errors, 'duplicate_occurrence_in_payload');
    else
      v_seen := array_append(v_seen, v_occurrence_key);
    end if;
    if v_subject_name is null then
      v_errors := array_append(v_errors, 'subject_name_required');
    end if;
    if v_subject_index is null then
      v_warnings := array_append(v_warnings, 'subject_index_missing');
    end if;

    begin
      v_semester := nullif(btrim(v_row ->> 'semester_number'), '')::integer;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end;
    if v_semester is null then
      v_errors := array_append(v_errors, 'semester_number_required');
    elsif v_semester < 1 or v_semester > v_plan.nominal_semesters then
      v_errors := array_append(v_errors, 'semester_outside_plan');
    end if;

    begin
      v_hours := nullif(btrim(v_row ->> 'hours_total'), '')::integer;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_hours_total');
    end;
    if v_hours is not null and v_hours < 0 then
      v_errors := array_append(v_errors, 'invalid_hours_total');
    end if;

    begin
      v_credits :=
        replace(nullif(btrim(v_row ->> 'credits'), ''), ',', '.')::numeric;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_credits');
    end;
    if v_credits is not null and v_credits < 0 then
      v_errors := array_append(v_errors, 'invalid_credits');
    end if;

    begin
      v_source_page :=
        nullif(btrim(v_row ->> 'source_page'), '')::integer;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_source_page');
    end;
    if v_source_page is not null and v_source_page < 1 then
      v_errors := array_append(v_errors, 'invalid_source_page');
    end if;
    if jsonb_typeof(coalesce(v_row -> 'source_region', '{}'::jsonb))
        <> 'object' then
      v_errors := array_append(v_errors, 'invalid_source_region');
    end if;

    if v_subject_name is not null then
      select sc.id
        into v_match_subject
      from public.subject_catalog sc
      where private.academic_ingestion_norm(sc.canonical_name)
              = private.academic_ingestion_norm(v_subject_name)
         or private.academic_ingestion_norm(sc.normalized_name)
              = private.academic_ingestion_norm(v_subject_name)
      order by sc.created_at
      limit 1;
    end if;

    if v_occurrence_key is not null then
      select cs.id
        into v_match_curriculum
      from public.curriculum_subjects cs
      where cs.curriculum_plan_id = p_curriculum_plan_id
        and cs.source_occurrence_key = v_occurrence_key
      limit 1;
    end if;

    v_classification := case
      when cardinality(v_errors) > 0
        and 'duplicate_occurrence_in_payload' = any(v_errors)
        then 'duplicate'
      when cardinality(v_errors) > 0 then 'error'
      when v_match_curriculum is not null then 'update'
      else 'new'
    end;

    case v_classification
      when 'new' then v_new := v_new + 1;
      when 'update' then v_update := v_update + 1;
      when 'duplicate' then v_duplicate := v_duplicate + 1;
      else v_error := v_error + 1;
    end case;

    v_items := v_items || jsonb_build_array(
      jsonb_build_object(
        'row_number', v_row_number,
        'classification', v_classification,
        'source_occurrence_key', v_occurrence_key,
        'matched_subject_id', v_match_subject,
        'matched_curriculum_subject_id', v_match_curriculum,
        'errors', to_jsonb(v_errors),
        'warnings', to_jsonb(v_warnings),
        'payload', v_row
      )
    );
  end loop;

  return jsonb_build_object(
    'ok', v_error = 0 and v_duplicate = 0 and v_row_number > 0,
    'apply_enabled', false,
    'apply_blocker', 'foundation_dry_run_only',
    'curriculum_plan_id', p_curriculum_plan_id,
    'parser_contract_version', btrim(p_parser_contract_version),
    'summary', jsonb_build_object(
      'total', v_row_number,
      'new', v_new,
      'update', v_update,
      'duplicate', v_duplicate,
      'error', v_error
    ),
    'items', v_items
  );
end
$$;

-- ---------------------------------------------------------------------------
-- 7. Function grants.
-- ---------------------------------------------------------------------------

revoke all on function public.admin_list_educational_programs()
  from public, anon, authenticated;
grant execute on function public.admin_list_educational_programs()
  to authenticated;

revoke all on function public.admin_upsert_educational_program(
  uuid, text, text, text, text, text, text, integer
) from public, anon, authenticated;
grant execute on function public.admin_upsert_educational_program(
  uuid, text, text, text, text, text, text, integer
) to authenticated;

revoke all on function public.admin_list_curriculum_plans(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.admin_list_curriculum_plans(uuid, integer)
  to authenticated;

revoke all on function public.admin_upsert_curriculum_plan(
  uuid, uuid, integer, text, text, integer, text, text, text, text, text,
  text, integer
) from public, anon, authenticated;
grant execute on function public.admin_upsert_curriculum_plan(
  uuid, uuid, integer, text, text, integer, text, text, text, text, text,
  text, integer
) to authenticated;

revoke all on function public.admin_assign_group_curriculum_plan(
  uuid, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.admin_assign_group_curriculum_plan(
  uuid, uuid, uuid
) to authenticated;

revoke all on function public.admin_curriculum_plan_import_dry_run(
  uuid, text, jsonb
) from public, anon, authenticated;
grant execute on function public.admin_curriculum_plan_import_dry_run(
  uuid, text, jsonb
) to authenticated;

commit;
