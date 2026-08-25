-- Academic-process calendar identity, immutable versioning, and apply-disabled
-- dry-run foundation.
--
-- This migration does not publish calendars, create academic terms, create
-- group semesters, create offerings, or create teams/chats.

begin;

create table if not exists public.academic_process_calendars (
  id uuid primary key default gen_random_uuid(),
  academic_year_id uuid not null
    references public.academic_years(id) on delete restrict,
  audience_kind text not null,
  educational_program_id uuid null
    references public.educational_programs(id) on delete restrict,
  curriculum_plan_id uuid null
    references public.curriculum_plans(id) on delete restrict,
  group_id uuid null references public.groups(id) on delete restrict,
  title text not null,
  created_by uuid null references public.users(id) on delete set null,
  updated_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version integer not null default 1,
  constraint academic_process_calendars_audience_kind_check
    check (audience_kind in ('global', 'program', 'plan', 'group')),
  constraint academic_process_calendars_audience_shape_check
    check (
      (
        audience_kind = 'global'
        and educational_program_id is null
        and curriculum_plan_id is null
        and group_id is null
      )
      or (
        audience_kind = 'program'
        and educational_program_id is not null
        and curriculum_plan_id is null
        and group_id is null
      )
      or (
        audience_kind = 'plan'
        and educational_program_id is null
        and curriculum_plan_id is not null
        and group_id is null
      )
      or (
        audience_kind = 'group'
        and educational_program_id is null
        and curriculum_plan_id is null
        and group_id is not null
      )
    ),
  constraint academic_process_calendars_title_check
    check (btrim(title) <> ''),
  constraint academic_process_calendars_row_version_check
    check (row_version > 0)
);

create unique index if not exists academic_process_calendar_audience_unique
  on public.academic_process_calendars(
    academic_year_id,
    audience_kind,
    coalesce(
      educational_program_id,
      '00000000-0000-0000-0000-000000000000'::uuid
    ),
    coalesce(
      curriculum_plan_id,
      '00000000-0000-0000-0000-000000000000'::uuid
    ),
    coalesce(group_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

create table if not exists public.academic_process_calendar_versions (
  id uuid primary key default gen_random_uuid(),
  calendar_id uuid not null
    references public.academic_process_calendars(id) on delete restrict,
  version_number integer not null,
  supersedes_version_id uuid null
    references public.academic_process_calendar_versions(id) on delete restrict,
  version_label text not null,
  status text not null default 'draft',
  source_file_name text null,
  source_mime_type text null,
  source_sha256 text null,
  source_verified boolean not null default false,
  parser_contract_version text not null,
  reviewed_by uuid null references public.users(id) on delete set null,
  reviewed_at timestamptz null,
  published_by uuid null references public.users(id) on delete set null,
  published_at timestamptz null,
  archived_at timestamptz null,
  created_by uuid null references public.users(id) on delete set null,
  updated_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version integer not null default 1,
  constraint academic_process_calendar_versions_number_check
    check (version_number > 0),
  constraint academic_process_calendar_versions_label_check
    check (btrim(version_label) <> ''),
  constraint academic_process_calendar_versions_status_check
    check (status in ('draft', 'reviewed', 'published', 'archived')),
  constraint academic_process_calendar_versions_source_sha_check
    check (
      source_sha256 is null
      or source_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint academic_process_calendar_versions_parser_check
    check (parser_contract_version = 'academic-process-calendar-v1'),
  constraint academic_process_calendar_versions_review_check
    check (
      status = 'draft'
      or (reviewed_by is not null and reviewed_at is not null)
    ),
  constraint academic_process_calendar_versions_publish_check
    check (
      status not in ('published', 'archived')
      or (published_by is not null and published_at is not null)
    ),
  constraint academic_process_calendar_versions_row_version_check
    check (row_version > 0),
  constraint academic_process_calendar_versions_number_unique
    unique (calendar_id, version_number)
);

create unique index if not exists academic_process_calendar_one_published_idx
  on public.academic_process_calendar_versions(calendar_id)
  where status = 'published';

comment on column public.academic_process_calendar_versions.source_verified is
  'True only after trusted server intake hashes original bytes. Browser metadata '
  'and local SHA-256 never set this flag.';

create table if not exists public.academic_process_periods (
  id uuid primary key default gen_random_uuid(),
  calendar_version_id uuid not null
    references public.academic_process_calendar_versions(id) on delete restrict,
  period_key text not null,
  period_type text not null,
  course_number integer not null,
  term_in_year integer not null,
  semester_number integer generated always as (
    ((course_number - 1) * 2) + term_in_year
  ) stored,
  starts_on date not null,
  ends_on date not null,
  source_page integer null,
  source_region jsonb null,
  source_note text null,
  reviewed_by uuid not null references public.users(id) on delete restrict,
  reviewed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint academic_process_periods_key_check
    check (btrim(period_key) <> ''),
  constraint academic_process_periods_type_check
    check (
      period_type in (
        'study', 'session', 'practice', 'holidays', 'gia', 'other'
      )
    ),
  constraint academic_process_periods_course_check
    check (course_number between 1 and 10),
  constraint academic_process_periods_term_check
    check (term_in_year in (1, 2)),
  constraint academic_process_periods_dates_check
    check (ends_on >= starts_on),
  constraint academic_process_periods_source_page_check
    check (source_page is null or source_page > 0),
  constraint academic_process_periods_key_unique
    unique (calendar_version_id, period_key)
);

create index if not exists academic_process_periods_lookup_idx
  on public.academic_process_periods(
    calendar_version_id,
    course_number,
    semester_number,
    starts_on,
    ends_on
  );

-- ---------------------------------------------------------------------------
-- Immutability and overlap contracts.
-- ---------------------------------------------------------------------------

create or replace function private.academic_process_periods_conflict(
  p_left text,
  p_right text
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_left = p_right then true
    when p_left = 'study'
      then p_right in ('session', 'holidays', 'gia')
    when p_left = 'session'
      then p_right in ('study', 'holidays', 'gia')
    when p_left = 'practice'
      then p_right in ('holidays', 'gia')
    when p_left = 'holidays'
      then p_right in ('study', 'session', 'practice', 'gia')
    when p_left = 'gia'
      then p_right in ('study', 'session', 'practice', 'holidays')
    when p_left = 'other' then false
    else true
  end;
$$;

revoke all on function private.academic_process_periods_conflict(text, text)
  from public, anon, authenticated;
grant execute on function private.academic_process_periods_conflict(text, text)
  to service_role;

comment on function private.academic_process_periods_conflict(text, text) is
  'Inclusive date overlap matrix. Equal period types always conflict. '
  'Study/session may overlap practice; other is advisory and may overlap.';

create or replace function private.guard_academic_process_calendar_series()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Lock every version before deciding. This serializes a series mutation with
  -- a concurrent publication: either the metadata mutation commits first and
  -- is part of that publication, or publication wins and this mutation fails.
  perform v.id
  from public.academic_process_calendar_versions v
  where v.calendar_id = old.id
  order by v.id
  for update;

  if exists (
      select 1
      from public.academic_process_calendar_versions v
      where v.calendar_id = old.id
        and v.status in ('published', 'archived')
    ) then
      raise exception 'published_calendar_series_is_immutable'
        using errcode = '55000';
    end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;

revoke all on function private.guard_academic_process_calendar_series()
  from public, anon, authenticated;
grant execute on function private.guard_academic_process_calendar_series()
  to service_role;

drop trigger if exists guard_academic_process_calendar_series
  on public.academic_process_calendars;
create trigger guard_academic_process_calendar_series
before update or delete on public.academic_process_calendars
for each row execute function private.guard_academic_process_calendar_series();

create or replace function private.guard_academic_process_calendar_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and old.status in ('published', 'archived') then
    raise exception 'published_calendar_version_is_immutable'
      using errcode = '55000';
  end if;

  if tg_op = 'UPDATE' and old.status = 'published' then
    if new.status <> 'archived'
       or (
         to_jsonb(new)
           - array[
             'status', 'archived_at', 'updated_at', 'updated_by', 'row_version'
           ]
       ) is distinct from (
         to_jsonb(old)
           - array[
             'status', 'archived_at', 'updated_at', 'updated_by', 'row_version'
           ]
       )
       or new.row_version <> old.row_version + 1
       or new.archived_at is null then
      raise exception 'published_calendar_version_is_immutable'
        using errcode = '55000';
    end if;
  elsif tg_op = 'UPDATE' and old.status = 'archived' then
    raise exception 'archived_calendar_version_is_immutable'
      using errcode = '55000';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end
$$;

revoke all on function private.guard_academic_process_calendar_version()
  from public, anon, authenticated;
grant execute on function private.guard_academic_process_calendar_version()
  to service_role;

drop trigger if exists guard_academic_process_calendar_version
  on public.academic_process_calendar_versions;
create trigger guard_academic_process_calendar_version
before update or delete on public.academic_process_calendar_versions
for each row execute function private.guard_academic_process_calendar_version();

create or replace function private.guard_academic_process_period_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parent record;
begin
  -- UPDATE checks and locks both parents. Checking NEW alone would allow a row
  -- to be moved out of an immutable published version into a draft version.
  -- The parent locks also serialize period edits with concurrent publication.
  for v_parent in
    select v.id, v.status
    from public.academic_process_calendar_versions v
    where v.id = any(
      case
        when tg_op = 'INSERT' then array[new.calendar_version_id]
        when tg_op = 'DELETE' then array[old.calendar_version_id]
        else array[old.calendar_version_id, new.calendar_version_id]
      end
    )
    order by v.id
    for update
  loop
    if v_parent.status in ('published', 'archived') then
      raise exception 'published_calendar_periods_are_immutable'
        using errcode = '55000';
    end if;
  end loop;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;

revoke all on function private.guard_academic_process_period_mutation()
  from public, anon, authenticated;
grant execute on function private.guard_academic_process_period_mutation()
  to service_role;

drop trigger if exists guard_academic_process_period_mutation
  on public.academic_process_periods;
create trigger guard_academic_process_period_mutation
before insert or update or delete on public.academic_process_periods
for each row execute function private.guard_academic_process_period_mutation();

-- ---------------------------------------------------------------------------
-- RLS / direct DML boundary.
-- ---------------------------------------------------------------------------

alter table public.academic_process_calendars enable row level security;
alter table public.academic_process_calendars force row level security;
alter table public.academic_process_calendar_versions enable row level security;
alter table public.academic_process_calendar_versions force row level security;
alter table public.academic_process_periods enable row level security;
alter table public.academic_process_periods force row level security;

revoke all on table public.academic_process_calendars
  from public, anon, authenticated;
revoke all on table public.academic_process_calendar_versions
  from public, anon, authenticated;
revoke all on table public.academic_process_periods
  from public, anon, authenticated;
grant all on table public.academic_process_calendars to service_role;
grant all on table public.academic_process_calendar_versions to service_role;
grant all on table public.academic_process_periods to service_role;

-- ---------------------------------------------------------------------------
-- Audience resolution. No group-name inference and no silent filtering.
-- ---------------------------------------------------------------------------

create or replace function private.academic_process_audience_errors(
  p_calendar_id uuid,
  p_course_number integer,
  p_semester_number integer
)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_calendar public.academic_process_calendars%rowtype;
  v_start_year integer;
  v_expected_admission integer;
  v_errors text[] := '{}';
  v_target_count integer := 0;
begin
  select c.*
    into v_calendar
  from public.academic_process_calendars c
  where c.id = p_calendar_id;

  if v_calendar.id is null then
    return array['calendar_not_found'];
  end if;
  select ay.start_year
    into v_start_year
  from public.academic_years ay
  where ay.id = v_calendar.academic_year_id;
  v_expected_admission := v_start_year - p_course_number + 1;

  case v_calendar.audience_kind
    when 'plan' then
      select count(*)
        into v_target_count
      from public.curriculum_plans cp
      where cp.id = v_calendar.curriculum_plan_id
        and cp.status in ('reviewed', 'active')
        and cp.admission_year = v_expected_admission
        and cp.nominal_semesters >= p_semester_number;
      if v_target_count = 0 then
        v_errors := array_append(
          v_errors,
          'plan_audience_not_compatible_with_course_or_semester'
        );
      end if;

    when 'group' then
      select count(*)
        into v_target_count
      from public.group_academic_profiles gap
      join public.curriculum_plans cp
        on cp.id = gap.curriculum_plan_id
      where gap.group_id = v_calendar.group_id
        and gap.active
        and gap.admission_year = v_expected_admission
        and gap.nominal_semesters >= p_semester_number
        and cp.status in ('reviewed', 'active')
        and cp.admission_year = gap.admission_year
        and cp.nominal_semesters >= p_semester_number;
      if v_target_count = 0 then
        v_errors := array_append(
          v_errors,
          'group_audience_not_compatible_with_course_or_semester'
        );
      end if;

    when 'program' then
      select count(*)
        into v_target_count
      from public.curriculum_plans cp
      where cp.educational_program_id = v_calendar.educational_program_id
        and cp.admission_year = v_expected_admission
        and cp.status in ('reviewed', 'active');
      if v_target_count = 0 then
        v_errors := array_append(v_errors, 'program_has_no_resolved_plans');
      end if;
      if exists (
        select 1
        from public.curriculum_plans cp
        where cp.educational_program_id = v_calendar.educational_program_id
          and cp.admission_year = v_expected_admission
          and cp.status in ('reviewed', 'active')
          and cp.nominal_semesters < p_semester_number
      ) then
        v_errors := array_append(
          v_errors,
          'program_plan_nominal_semesters_exceeded'
        );
      end if;
      if exists (
        select 1
        from public.group_academic_profiles gap
        join public.curriculum_plans cp on cp.id = gap.curriculum_plan_id
        where gap.active
          and gap.admission_year = v_expected_admission
          and cp.educational_program_id = v_calendar.educational_program_id
          and (
            gap.nominal_semesters < p_semester_number
            or cp.nominal_semesters < p_semester_number
          )
      ) then
        v_errors := array_append(
          v_errors,
          'program_group_nominal_semesters_exceeded'
        );
      end if;

    when 'global' then
      select count(*)
        into v_target_count
      from public.group_academic_profiles gap
      where gap.active
        and gap.admission_year = v_expected_admission;
      if v_target_count = 0 then
        select count(*)
          into v_target_count
        from public.curriculum_plans cp
        where cp.admission_year = v_expected_admission
          and cp.status in ('reviewed', 'active');
      end if;
      if v_target_count = 0 then
        v_errors := array_append(v_errors, 'global_audience_has_no_targets');
      end if;
      if exists (
        select 1
        from public.group_academic_profiles gap
        where gap.active
          and gap.admission_year = v_expected_admission
          and gap.curriculum_plan_id is null
      ) then
        v_errors := array_append(
          v_errors,
          'global_audience_contains_unresolved_group_plan'
        );
      end if;
      if exists (
        select 1
        from public.group_academic_profiles gap
        left join public.curriculum_plans cp
          on cp.id = gap.curriculum_plan_id
        where gap.active
          and gap.admission_year = v_expected_admission
          and (
            gap.nominal_semesters < p_semester_number
            or cp.id is null
            or cp.status not in ('reviewed', 'active')
            or cp.admission_year <> gap.admission_year
            or cp.nominal_semesters < p_semester_number
          )
      ) then
        v_errors := array_append(
          v_errors,
          'global_group_not_compatible_with_semester'
        );
      end if;
      if exists (
        select 1
        from public.curriculum_plans cp
        where cp.admission_year = v_expected_admission
          and cp.status in ('reviewed', 'active')
          and cp.nominal_semesters < p_semester_number
      ) then
        v_errors := array_append(
          v_errors,
          'global_plan_nominal_semesters_exceeded'
        );
      end if;
  end case;

  return v_errors;
end
$$;

revoke all on function private.academic_process_audience_errors(
  uuid, integer, integer
) from public, anon, authenticated;
grant execute on function private.academic_process_audience_errors(
  uuid, integer, integer
) to service_role;

-- ---------------------------------------------------------------------------
-- Admin metadata RPCs.
-- ---------------------------------------------------------------------------

create or replace function public.admin_list_academic_process_calendars(
  p_academic_year_id uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not (
      private.academic_ingestion_has_permission('academic.read')
      or private.academic_ingestion_has_permission('terms.manage')
    ) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', c.id,
            'academic_year_id', c.academic_year_id,
            'academic_year_name', ay.name,
            'audience_kind', c.audience_kind,
            'educational_program_id', c.educational_program_id,
            'curriculum_plan_id', c.curriculum_plan_id,
            'group_id', c.group_id,
            'title', c.title,
            'row_version', c.row_version,
            'versions', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'id', v.id,
                    'version_number', v.version_number,
                    'supersedes_version_id', v.supersedes_version_id,
                    'version_label', v.version_label,
                    'status', v.status,
                    'source_file_name', v.source_file_name,
                    'source_mime_type', v.source_mime_type,
                    'source_sha256', v.source_sha256,
                    'source_verified', v.source_verified,
                    'parser_contract_version', v.parser_contract_version,
                    'row_version', v.row_version,
                    'created_at', v.created_at
                  )
                  order by v.version_number desc
                )
                from public.academic_process_calendar_versions v
                where v.calendar_id = c.id
              ),
              '[]'::jsonb
            )
          )
          order by ay.start_year desc, c.title
        )
        from public.academic_process_calendars c
        join public.academic_years ay on ay.id = c.academic_year_id
        where p_academic_year_id is null
          or c.academic_year_id = p_academic_year_id
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_upsert_academic_process_calendar(
  p_id uuid default null,
  p_academic_year_id uuid default null,
  p_audience_kind text default '',
  p_educational_program_id uuid default null,
  p_curriculum_plan_id uuid default null,
  p_group_id uuid default null,
  p_title text default '',
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
  v_action text;
begin
  if not private.academic_ingestion_has_permission('terms.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_academic_year_id is null
     or not exists (
       select 1 from public.academic_years ay
       where ay.id = p_academic_year_id
     )
     or p_audience_kind not in ('global', 'program', 'plan', 'group')
     or nullif(btrim(p_title), '') is null
     or not (
       (
         p_audience_kind = 'global'
         and p_educational_program_id is null
         and p_curriculum_plan_id is null
         and p_group_id is null
       )
       or (
         p_audience_kind = 'program'
         and p_educational_program_id is not null
         and p_curriculum_plan_id is null
         and p_group_id is null
         and exists (
           select 1 from public.educational_programs ep
           where ep.id = p_educational_program_id
         )
       )
       or (
         p_audience_kind = 'plan'
         and p_educational_program_id is null
         and p_curriculum_plan_id is not null
         and p_group_id is null
         and exists (
           select 1 from public.curriculum_plans cp
           where cp.id = p_curriculum_plan_id
             and cp.status in ('reviewed', 'active')
         )
       )
       or (
         p_audience_kind = 'group'
         and p_educational_program_id is null
         and p_curriculum_plan_id is null
         and p_group_id is not null
         and exists (
           select 1
           from public.group_academic_profiles gap
           join public.curriculum_plans cp
             on cp.id = gap.curriculum_plan_id
           where gap.group_id = p_group_id
             and gap.active
             and cp.status in ('reviewed', 'active')
             and cp.admission_year = gap.admission_year
         )
       )
     ) then
    raise exception 'invalid_academic_process_calendar'
      using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.academic_process_calendars(
      academic_year_id,
      audience_kind,
      educational_program_id,
      curriculum_plan_id,
      group_id,
      title,
      created_by,
      updated_by
    )
    values (
      p_academic_year_id,
      p_audience_kind,
      p_educational_program_id,
      p_curriculum_plan_id,
      p_group_id,
      btrim(p_title),
      auth.uid(),
      auth.uid()
    )
    returning id into v_id;
    v_action := 'academic_process_calendar.create';
  else
    select c.row_version
      into v_current_version
    from public.academic_process_calendars c
    where c.id = p_id
    for update;
    if v_current_version is null then
      raise exception 'academic_process_calendar_not_found'
        using errcode = 'P0002';
    end if;
    if p_expected_row_version is null
       or p_expected_row_version <> v_current_version then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;

    update public.academic_process_calendars
    set academic_year_id = p_academic_year_id,
        audience_kind = p_audience_kind,
        educational_program_id = p_educational_program_id,
        curriculum_plan_id = p_curriculum_plan_id,
        group_id = p_group_id,
        title = btrim(p_title),
        updated_by = auth.uid(),
        updated_at = now(),
        row_version = row_version + 1
    where id = p_id
    returning id into v_id;
    v_action := 'academic_process_calendar.update';
  end if;

  perform private.admin_write_audit(
    v_action,
    'academic_process_calendar',
    v_id::text,
    jsonb_build_object(
      'academic_year_id', p_academic_year_id,
      'audience_kind', p_audience_kind
    )
  );
  return v_id;
exception
  when unique_violation then
    raise exception 'academic_process_calendar_audience_conflict'
      using errcode = '23505';
end
$$;

create or replace function public.admin_create_academic_process_calendar_version(
  p_calendar_id uuid,
  p_version_label text,
  p_source_file_name text default null,
  p_source_mime_type text default null,
  p_source_sha256 text default null,
  p_parser_contract_version text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_number integer;
  v_supersedes uuid;
begin
  if not private.academic_ingestion_has_permission('terms.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (
       select 1 from public.academic_process_calendars c
       where c.id = p_calendar_id
     )
     or nullif(btrim(p_version_label), '') is null
     or p_parser_contract_version is distinct from
       'academic-process-calendar-v1'
     or (
       p_source_sha256 is not null
       and lower(btrim(p_source_sha256)) !~ '^[0-9a-f]{64}$'
     ) then
    raise exception 'invalid_academic_process_calendar_version'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('academic_process_calendar:' || p_calendar_id::text, 0)
  );
  select v.id, v.version_number
    into v_supersedes, v_number
  from public.academic_process_calendar_versions v
  where v.calendar_id = p_calendar_id
  order by v.version_number desc
  limit 1;
  v_number := coalesce(v_number, 0) + 1;

  insert into public.academic_process_calendar_versions(
    calendar_id,
    version_number,
    supersedes_version_id,
    version_label,
    status,
    source_file_name,
    source_mime_type,
    source_sha256,
    source_verified,
    parser_contract_version,
    created_by,
    updated_by
  )
  values (
    p_calendar_id,
    v_number,
    v_supersedes,
    btrim(p_version_label),
    'draft',
    nullif(btrim(p_source_file_name), ''),
    nullif(lower(btrim(p_source_mime_type)), ''),
    nullif(lower(btrim(p_source_sha256)), ''),
    false,
    p_parser_contract_version,
    auth.uid(),
    auth.uid()
  )
  returning id into v_id;

  perform private.admin_write_audit(
    'academic_process_calendar.version_create',
    'academic_process_calendar_version',
    v_id::text,
    jsonb_build_object(
      'calendar_id', p_calendar_id,
      'version_number', v_number,
      'supersedes_version_id', v_supersedes,
      'source_verified', false
    )
  );
  return v_id;
end
$$;

-- ---------------------------------------------------------------------------
-- Apply-disabled dry-run. Semester is derived server-side only.
-- ---------------------------------------------------------------------------

create or replace function public.admin_academic_process_calendar_dry_run(
  p_calendar_version_id uuid,
  p_parser_contract_version text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version public.academic_process_calendar_versions%rowtype;
  v_calendar public.academic_process_calendars%rowtype;
  v_year public.academic_years%rowtype;
  v_row jsonb;
  v_previous jsonb;
  v_row_number integer := 0;
  v_period_key text;
  v_period_type text;
  v_course integer;
  v_term integer;
  v_semester integer;
  v_starts date;
  v_ends date;
  v_errors text[];
  v_warnings text[];
  v_seen_keys text[] := '{}';
  v_seen_rows jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
  v_error_count integer := 0;
begin
  if not private.academic_ingestion_has_permission('terms.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 5000 then
    raise exception 'invalid_academic_process_rows'
      using errcode = '22023';
  end if;

  select *
    into v_version
  from public.academic_process_calendar_versions v
  where v.id = p_calendar_version_id;
  if v_version.id is null then
    raise exception 'academic_process_calendar_version_not_found'
      using errcode = 'P0002';
  end if;
  if v_version.status <> 'draft' then
    raise exception 'academic_process_calendar_version_not_draft'
      using errcode = 'P0001';
  end if;
  if p_parser_contract_version is distinct from
       v_version.parser_contract_version
     or p_parser_contract_version is distinct from
       'academic-process-calendar-v1' then
    raise exception 'unsupported_or_mismatched_parser_contract'
      using errcode = '22023';
  end if;

  select *
    into v_calendar
  from public.academic_process_calendars c
  where c.id = v_version.calendar_id;
  select *
    into v_year
  from public.academic_years ay
  where ay.id = v_calendar.academic_year_id;

  for v_row in
    select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    v_row_number := v_row_number + 1;
    v_errors := '{}';
    v_warnings := '{}';
    v_period_key :=
      nullif(btrim(coalesce(v_row ->> 'period_key', '')), '');
    v_period_type :=
      nullif(btrim(coalesce(v_row ->> 'period_type', '')), '');
    v_course := null;
    v_term := null;
    v_semester := null;
    v_starts := null;
    v_ends := null;

    if v_period_key is null then
      v_errors := array_append(v_errors, 'period_key_required');
    elsif v_period_key = any(v_seen_keys) then
      v_errors := array_append(v_errors, 'duplicate_period_key');
    else
      v_seen_keys := array_append(v_seen_keys, v_period_key);
    end if;
    if v_period_type not in (
      'study', 'session', 'practice', 'holidays', 'gia', 'other'
    ) then
      v_errors := array_append(v_errors, 'invalid_period_type');
    elsif v_period_type = 'other'
       and nullif(btrim(coalesce(v_row ->> 'source_note', '')), '') is null then
      v_errors := array_append(v_errors, 'other_period_note_required');
    end if;

    begin
      v_course := (v_row ->> 'course_number')::integer;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_course_number');
    end;
    if v_course is null or v_course not between 1 and 10 then
      v_errors := array_append(v_errors, 'invalid_course_number');
    end if;

    begin
      v_term := (v_row ->> 'term_in_year')::integer;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_term_in_year');
    end;
    if v_term is null or v_term not in (1, 2) then
      v_errors := array_append(v_errors, 'invalid_term_in_year');
    end if;

    if v_course between 1 and 10 and v_term in (1, 2) then
      v_semester := ((v_course - 1) * 2) + v_term;
      v_errors := v_errors || private.academic_process_audience_errors(
        v_calendar.id,
        v_course,
        v_semester
      );
    end if;

    begin
      v_starts := (v_row ->> 'starts_on')::date;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_starts_on');
    end;
    begin
      v_ends := (v_row ->> 'ends_on')::date;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_ends_on');
    end;
    if v_starts is null then
      v_errors := array_append(v_errors, 'starts_on_required');
    end if;
    if v_ends is null then
      v_errors := array_append(v_errors, 'ends_on_required');
    end if;
    if v_starts is not null and v_ends is not null then
      if v_ends < v_starts then
        v_errors := array_append(v_errors, 'period_end_before_start');
      end if;
      if v_starts < v_year.starts_on or v_ends > v_year.ends_on then
        v_errors := array_append(v_errors, 'period_outside_academic_year');
      end if;
    end if;

    if v_course is not null
       and v_term is not null
       and v_starts is not null
       and v_ends is not null
       and v_period_type is not null then
      for v_previous in
        select value from jsonb_array_elements(v_seen_rows)
      loop
        if (v_previous ->> 'course_number')::integer = v_course
           and (v_previous ->> 'term_in_year')::integer = v_term
           and (v_previous ->> 'starts_on')::date <= v_ends
           and v_starts <= (v_previous ->> 'ends_on')::date
           and private.academic_process_periods_conflict(
             v_period_type,
             v_previous ->> 'period_type'
           ) then
          v_errors := array_append(
            v_errors,
            'period_overlap:' || (v_previous ->> 'period_key')
          );
        end if;
      end loop;
      v_seen_rows := v_seen_rows || jsonb_build_array(
        jsonb_build_object(
          'period_key', v_period_key,
          'period_type', v_period_type,
          'course_number', v_course,
          'term_in_year', v_term,
          'starts_on', v_starts,
          'ends_on', v_ends
        )
      );
    end if;

    if cardinality(v_errors) > 0 then
      v_error_count := v_error_count + 1;
    end if;
    v_items := v_items || jsonb_build_array(
      jsonb_build_object(
        'row_number', v_row_number,
        'period_key', v_period_key,
        'derived_semester_number', v_semester,
        'classification',
          case when cardinality(v_errors) = 0 then 'new' else 'error' end,
        'errors', to_jsonb(v_errors),
        'warnings', to_jsonb(v_warnings),
        'payload', v_row
      )
    );
  end loop;

  return jsonb_build_object(
    'ok', v_row_number > 0 and v_error_count = 0,
    'apply_enabled', false,
    'publish_enabled', false,
    'apply_blocker', 'calendar_foundation_dry_run_only',
    'calendar_version_id', p_calendar_version_id,
    'parser_contract_version', p_parser_contract_version,
    'summary', jsonb_build_object(
      'total', v_row_number,
      'new', v_row_number - v_error_count,
      'error', v_error_count
    ),
    'items', v_items
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Function grants.
-- ---------------------------------------------------------------------------

revoke all on function public.admin_list_academic_process_calendars(uuid)
  from public, anon, authenticated;
grant execute on function public.admin_list_academic_process_calendars(uuid)
  to authenticated;

revoke all on function public.admin_upsert_academic_process_calendar(
  uuid, uuid, text, uuid, uuid, uuid, text, integer
) from public, anon, authenticated;
grant execute on function public.admin_upsert_academic_process_calendar(
  uuid, uuid, text, uuid, uuid, uuid, text, integer
) to authenticated;

revoke all on function public.admin_create_academic_process_calendar_version(
  uuid, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.admin_create_academic_process_calendar_version(
  uuid, text, text, text, text, text
) to authenticated;

revoke all on function public.admin_academic_process_calendar_dry_run(
  uuid, text, jsonb
) from public, anon, authenticated;
grant execute on function public.admin_academic_process_calendar_dry_run(
  uuid, text, jsonb
) to authenticated;

commit;
