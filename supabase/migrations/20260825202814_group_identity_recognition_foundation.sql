-- Stage 19.1b Slice 1: deterministic group identity recognition.
--
-- This migration is deliberately preview-only. It does not create groups,
-- accounts, enrollments, plans, offerings, teams, chats, or schedules.

begin;

create or replace function private.group_recognition_program_alias_key(
  p_value text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    regexp_replace(
      replace(lower(btrim(coalesce(p_value, ''))), 'ё', 'е'),
      '[^[:alnum:]]',
      '',
      'g'
    ),
    ''
  );
$$;

create or replace function private.group_recognition_name_key(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    regexp_replace(
      translate(
        replace(lower(btrim(coalesce(p_value, ''))), 'ё', 'е'),
        '‐‑‒–—−',
        '------'
      ),
      '[[:space:]()]',
      '',
      'g'
    ),
    ''
  );
$$;

create or replace function private.parse_academic_group_name(
  p_value text,
  p_parser_version text default 'group-name-v1'
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_key text;
  v_validation_key text;
  v_validation_match text[];
  v_middle text;
  v_match text[];
begin
  if p_parser_version <> 'group-name-v1' then
    return jsonb_build_object(
      'ok', false,
      'error', 'unsupported_parser_version',
      'parser_version', p_parser_version
    );
  end if;

  v_validation_key := regexp_replace(
    translate(
      replace(lower(btrim(coalesce(p_value, ''))), 'ё', 'е'),
      '‐‑‒–—−',
      '------'
    ),
    '[[:space:]]',
    '',
    'g'
  );
  v_key := private.group_recognition_name_key(p_value);
  if v_key is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'group_name_required',
      'parser_version', p_parser_version
    );
  end if;

  v_validation_match := regexp_match(
    v_validation_key,
    '^([1-9][0-9]*)-([^-]+)-([1-9][0-9]*)$'
  );
  if v_validation_match is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'group_name_shape_unrecognized',
      'normalized_group_name', v_key,
      'parser_version', p_parser_version
    );
  end if;
  v_middle := v_validation_match[2];
  if not (
    v_middle ~ '^[[:alnum:]]+$'
    or v_middle ~ '^[[:alnum:]]+\([[:alnum:]]+\)$'
  ) then
    return jsonb_build_object(
      'ok', false,
      'error', 'group_name_contains_unapproved_punctuation',
      'normalized_group_name', v_key,
      'parser_version', p_parser_version
    );
  end if;

  v_match := regexp_match(
    v_key,
    '^([1-9][0-9]*)-([^-]+)-([1-9][0-9]*)$'
  );
  if v_match is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'group_name_shape_unrecognized',
      'normalized_group_name', v_key,
      'parser_version', p_parser_version
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'normalized_group_name', v_key,
    'parallel_number', v_match[1]::integer,
    'program_alias_key',
      private.group_recognition_program_alias_key(v_match[2]),
    'course_number', v_match[3]::integer,
    'parser_version', p_parser_version
  );
end;
$$;

revoke all on function private.group_recognition_program_alias_key(text)
  from public, anon, authenticated;
revoke all on function private.group_recognition_name_key(text)
  from public, anon, authenticated;
revoke all on function private.parse_academic_group_name(text, text)
  from public, anon, authenticated;
grant execute on function private.group_recognition_program_alias_key(text)
  to service_role;
grant execute on function private.group_recognition_name_key(text)
  to service_role;
grant execute on function private.parse_academic_group_name(text, text)
  to service_role;

create table if not exists public.educational_program_aliases (
  id uuid primary key default gen_random_uuid(),
  educational_program_id uuid not null
    references public.educational_programs(id) on delete restrict,
  alias_raw text not null,
  alias_key text not null,
  status text not null default 'active'
    check (status in ('active', 'archived')),
  reviewed_by uuid not null references public.users(id) on delete restrict,
  reviewed_at timestamptz not null default now(),
  row_version integer not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint educational_program_aliases_key_unique unique(alias_key),
  constraint educational_program_aliases_key_canonical check (
    alias_key = private.group_recognition_program_alias_key(alias_raw)
  )
);

create index if not exists educational_program_aliases_program_idx
  on public.educational_program_aliases(educational_program_id, status);

create table if not exists public.group_name_aliases (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete restrict,
  alias_raw text not null,
  alias_key text not null,
  source text not null
    check (source in ('current_name', 'import_review', 'manual')),
  status text not null default 'active'
    check (status in ('active', 'archived')),
  reviewed_by uuid null references public.users(id) on delete restrict,
  reviewed_at timestamptz null,
  row_version integer not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_name_aliases_key_unique unique(alias_key),
  constraint group_name_aliases_key_canonical check (
    alias_key = private.group_recognition_name_key(alias_raw)
  ),
  constraint group_name_aliases_review_check check (
    source = 'current_name'
    or (reviewed_by is not null and reviewed_at is not null)
  )
);

create index if not exists group_name_aliases_group_idx
  on public.group_name_aliases(group_id, status);

create table if not exists public.group_academic_identities (
  group_id uuid primary key references public.groups(id) on delete restrict,
  educational_program_id uuid not null
    references public.educational_programs(id) on delete restrict,
  admission_year integer not null check (admission_year between 2000 and 2100),
  parallel_number integer not null check (parallel_number > 0),
  distinct_discriminator text not null default '',
  distinct_reason text null,
  reviewed_by uuid not null references public.users(id) on delete restrict,
  reviewed_at timestamptz not null default now(),
  row_version integer not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_academic_identities_semantic_unique unique(
    educational_program_id,
    admission_year,
    parallel_number,
    distinct_discriminator
  ),
  constraint group_academic_identities_distinct_check check (
    distinct_discriminator = btrim(distinct_discriminator)
    and (
      (distinct_discriminator = '' and distinct_reason is null)
      or (
        distinct_discriminator <> ''
        and nullif(btrim(distinct_reason), '') is not null
      )
    )
  )
);

create index if not exists group_academic_identities_lookup_idx
  on public.group_academic_identities(
    educational_program_id,
    admission_year,
    parallel_number
  );

-- Register only unambiguous existing current names. Normalized collisions stay
-- intentionally unresolved instead of choosing an arbitrary group.
with candidates as (
  select
    g.id as group_id,
    g.name as alias_raw,
    private.group_recognition_name_key(g.name) as alias_key
  from public.groups g
),
unambiguous as (
  select alias_key
  from candidates
  where alias_key is not null
  group by alias_key
  having count(*) = 1
)
insert into public.group_name_aliases(
  group_id, alias_raw, alias_key, source, status
)
select c.group_id, c.alias_raw, c.alias_key, 'current_name', 'active'
from candidates c
join unambiguous u using(alias_key)
on conflict (alias_key) do nothing;

create table if not exists public.group_recognition_previews (
  id uuid primary key default gen_random_uuid(),
  academic_year_id uuid not null
    references public.academic_years(id) on delete restrict,
  file_name text not null default '',
  source_sha256 text null,
  parser_version text not null,
  normalized_payload_hash text not null,
  status text not null default 'preview'
    check (status in ('preview', 'applied', 'expired', 'cancelled')),
  expires_at timestamptz not null,
  created_by uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  applied_at timestamptz null,
  row_version integer not null default 1 check (row_version > 0),
  idempotency_key text not null,
  summary jsonb not null default '{}'::jsonb,
  constraint group_recognition_previews_owner_key_unique
    unique(created_by, idempotency_key),
  constraint group_recognition_previews_hash_check
    check (normalized_payload_hash ~ '^[0-9a-f]{64}$'),
  constraint group_recognition_previews_parser_check
    check (parser_version = 'group-name-v1')
);

create table if not exists public.group_recognition_preview_rows (
  id uuid primary key default gen_random_uuid(),
  preview_id uuid not null
    references public.group_recognition_previews(id) on delete cascade,
  source_row_key text not null,
  raw_group_name text not null,
  normalized_group_name text null,
  parallel_number integer null,
  program_alias_key text null,
  course_number integer null,
  derived_admission_year integer null,
  classification text not null check (
    classification in (
      'exact_group',
      'exact_alias',
      'semantic_duplicate',
      'new_candidate',
      'ambiguous_plan',
      'no_plan',
      'program_unregistered',
      'parser_blocked',
      'conflict'
    )
  ),
  candidate_group_ids uuid[] not null default '{}'::uuid[],
  candidate_plan_ids uuid[] not null default '{}'::uuid[],
  matched_educational_program_id uuid null
    references public.educational_programs(id) on delete restrict,
  evidence jsonb not null default '{}'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  row_version integer not null default 1 check (row_version > 0),
  constraint group_recognition_preview_rows_source_unique
    unique(preview_id, source_row_key)
);

create index if not exists group_recognition_preview_rows_preview_idx
  on public.group_recognition_preview_rows(preview_id, classification);

alter table public.educational_program_aliases enable row level security;
alter table public.educational_program_aliases force row level security;
alter table public.group_name_aliases enable row level security;
alter table public.group_name_aliases force row level security;
alter table public.group_academic_identities enable row level security;
alter table public.group_academic_identities force row level security;
alter table public.group_recognition_previews enable row level security;
alter table public.group_recognition_previews force row level security;
alter table public.group_recognition_preview_rows enable row level security;
alter table public.group_recognition_preview_rows force row level security;

revoke all on table
  public.educational_program_aliases,
  public.group_name_aliases,
  public.group_academic_identities,
  public.group_recognition_previews,
  public.group_recognition_preview_rows
from public, anon, authenticated;
grant select, insert, update, delete on table
  public.educational_program_aliases,
  public.group_name_aliases,
  public.group_academic_identities,
  public.group_recognition_previews,
  public.group_recognition_preview_rows
to service_role;

create or replace function public.admin_group_recognition_list_academic_years()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (
    private.academic_ingestion_has_permission('groups.write')
    or private.academic_ingestion_has_permission('students.write')
    or private.academic_ingestion_has_permission('academic.read')
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ay.id,
      'name', ay.name,
      'start_year', ay.start_year,
      'is_current', ay.is_current
    ) order by ay.start_year desc)
    from public.academic_years ay
  ), '[]'::jsonb);
end;
$$;

-- Forward declaration used by start_preview for idempotent replay. Replaced
-- with the complete owner-scoped reader below.
create or replace function public.admin_group_recognition_get_preview(
  p_preview_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  raise exception 'group_recognition_preview_reader_not_ready'
    using errcode = '55000';
end;
$$;

create or replace function public.admin_group_recognition_start_preview(
  p_academic_year_id uuid,
  p_rows jsonb,
  p_file_name text default '',
  p_idempotency_key text default null,
  p_source_sha256 text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_year public.academic_years%rowtype;
  v_preview_id uuid;
  v_existing_payload_hash text;
  v_idempotency_key text;
  v_payload_hash text;
  v_row jsonb;
  v_source_key text;
  v_group_name text;
  v_parsed jsonb;
  v_name_key text;
  v_program_key text;
  v_parallel integer;
  v_course integer;
  v_admission integer;
  v_program uuid;
  v_program_status text;
  v_group_ids uuid[];
  v_plan_ids uuid[];
  v_alias_source text;
  v_class text;
  v_warnings jsonb;
  v_evidence jsonb;
  v_row_number integer := 0;
  v_total integer := 0;
  v_blocked integer := 0;
  v_exact integer := 0;
  v_new integer := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not (
    private.academic_ingestion_has_permission('groups.write')
    or private.academic_ingestion_has_permission('students.write')
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) = 0
     or jsonb_array_length(p_rows) > 5000 then
    raise exception 'invalid_group_recognition_payload'
      using errcode = '22023';
  end if;
  if p_source_sha256 is not null
     and lower(btrim(p_source_sha256)) !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_source_sha256' using errcode = '22023';
  end if;

  select * into v_year
  from public.academic_years ay
  where ay.id = p_academic_year_id;
  if not found then
    raise exception 'academic_year_not_found' using errcode = 'P0002';
  end if;

  v_payload_hash := encode(extensions.digest(convert_to(
    jsonb_build_object(
      'academic_year_id', p_academic_year_id,
      'parser_version', 'group-name-v1',
      'rows', p_rows
    )::text,
    'UTF8'
  ), 'sha256'), 'hex');
  v_idempotency_key := coalesce(
    nullif(btrim(p_idempotency_key), ''),
    v_payload_hash
  );

  -- Serialize same-owner/same-key requests before read-before-insert so a
  -- concurrent retry observes the durable preview instead of a unique error.
  perform pg_advisory_xact_lock(hashtextextended(
    'group-recognition-preview|' || v_uid::text || '|' || v_idempotency_key,
    0
  ));

  select p.id, p.normalized_payload_hash
    into v_preview_id, v_existing_payload_hash
  from public.group_recognition_previews p
  where p.created_by = v_uid
    and p.idempotency_key = v_idempotency_key;
  if v_preview_id is not null then
    if v_existing_payload_hash <> v_payload_hash then
      raise exception 'idempotency_key_payload_mismatch'
        using errcode = '22023';
    end if;
    return public.admin_group_recognition_get_preview(v_preview_id)
      || jsonb_build_object('idempotent_replay', true);
  end if;

  insert into public.group_recognition_previews(
    academic_year_id,
    file_name,
    source_sha256,
    parser_version,
    normalized_payload_hash,
    expires_at,
    created_by,
    idempotency_key
  ) values (
    p_academic_year_id,
    left(coalesce(p_file_name, ''), 260),
    lower(btrim(p_source_sha256)),
    'group-name-v1',
    v_payload_hash,
    now() + interval '30 minutes',
    v_uid,
    v_idempotency_key
  )
  returning id into v_preview_id;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := v_row_number + 1;
    v_total := v_total + 1;
    v_source_key := coalesce(
      nullif(btrim(v_row ->> 'source_row_key'), ''),
      v_row_number::text
    );
    v_group_name := btrim(coalesce(
      v_row ->> 'group_name',
      v_row ->> 'name',
      ''
    ));
    v_parsed := private.parse_academic_group_name(
      v_group_name,
      'group-name-v1'
    );
    v_name_key := v_parsed ->> 'normalized_group_name';
    v_program_key := v_parsed ->> 'program_alias_key';
    v_parallel := nullif(v_parsed ->> 'parallel_number', '')::integer;
    v_course := nullif(v_parsed ->> 'course_number', '')::integer;
    v_admission := case
      when v_course is null then null
      else v_year.start_year - v_course + 1
    end;
    v_program := null;
    v_program_status := null;
    v_group_ids := '{}'::uuid[];
    v_plan_ids := '{}'::uuid[];
    v_alias_source := null;
    v_warnings := '[]'::jsonb;
    v_evidence := jsonb_build_object(
      'academic_year_start', v_year.start_year,
      'parser', v_parsed
    );

    if coalesce((v_parsed ->> 'ok')::boolean, false) is false then
      v_class := 'parser_blocked';
      v_warnings := jsonb_build_array(v_parsed ->> 'error');
    else
      select array_agg(a.group_id order by a.group_id), min(a.source)
        into v_group_ids, v_alias_source
      from public.group_name_aliases a
      where a.alias_key = v_name_key
        and a.status = 'active';
      v_group_ids := coalesce(v_group_ids, '{}'::uuid[]);

      select a.educational_program_id, ep.status
        into v_program, v_program_status
      from public.educational_program_aliases a
      join public.educational_programs ep
        on ep.id = a.educational_program_id
      where a.alias_key = v_program_key
        and a.status = 'active';

      if cardinality(v_group_ids) = 1 then
        v_class := case
          when v_alias_source = 'current_name' then 'exact_group'
          else 'exact_alias'
        end;
      elsif cardinality(v_group_ids) > 1 then
        v_class := 'conflict';
        v_warnings := jsonb_build_array('group_alias_collision');
      elsif v_program is null then
        v_class := 'program_unregistered';
        v_warnings := jsonb_build_array('program_alias_not_reviewed');
      elsif v_program_status <> 'active' then
        v_class := 'conflict';
        v_warnings := jsonb_build_array('educational_program_not_active');
      else
        select coalesce(array_agg(i.group_id order by i.group_id), '{}'::uuid[])
          into v_group_ids
        from public.group_academic_identities i
        where i.educational_program_id = v_program
          and i.admission_year = v_admission
          and i.parallel_number = v_parallel;

        select coalesce(array_agg(cp.id order by
          case cp.status when 'active' then 0 else 1 end,
          cp.version_label,
          cp.id
        ), '{}'::uuid[])
          into v_plan_ids
        from public.curriculum_plans cp
        where cp.educational_program_id = v_program
          and cp.admission_year = v_admission
          and cp.status in ('reviewed', 'active')
          and v_course <= ((cp.nominal_semesters + 1) / 2);

        if cardinality(v_group_ids) > 0 then
          v_class := 'semantic_duplicate';
        elsif cardinality(v_plan_ids) > 1 then
          v_class := 'ambiguous_plan';
          v_warnings := jsonb_build_array('multiple_plan_versions_require_choice');
        elsif cardinality(v_plan_ids) = 0 then
          v_class := 'no_plan';
          v_warnings := jsonb_build_array('matching_reviewed_plan_not_found');
        else
          v_class := 'new_candidate';
        end if;
      end if;
    end if;

    if v_class in ('exact_group', 'exact_alias') then
      v_exact := v_exact + 1;
    elsif v_class = 'new_candidate' then
      v_new := v_new + 1;
    else
      v_blocked := v_blocked + 1;
    end if;

    v_evidence := v_evidence || jsonb_build_object(
      'program_status', v_program_status,
      'alias_source', v_alias_source
    );

    insert into public.group_recognition_preview_rows(
      preview_id,
      source_row_key,
      raw_group_name,
      normalized_group_name,
      parallel_number,
      program_alias_key,
      course_number,
      derived_admission_year,
      classification,
      candidate_group_ids,
      candidate_plan_ids,
      matched_educational_program_id,
      evidence,
      warnings
    ) values (
      v_preview_id,
      v_source_key,
      v_group_name,
      v_name_key,
      v_parallel,
      v_program_key,
      v_course,
      v_admission,
      v_class,
      v_group_ids,
      v_plan_ids,
      v_program,
      v_evidence,
      v_warnings
    );
  end loop;

  update public.group_recognition_previews
  set summary = jsonb_build_object(
    'total', v_total,
    'exact', v_exact,
    'new_candidate', v_new,
    'blocked', v_blocked,
    'apply_enabled', false
  )
  where id = v_preview_id;

  perform private.admin_write_audit(
    'group_recognition.preview',
    'group_recognition_preview',
    v_preview_id::text,
    jsonb_build_object(
      'academic_year_id', p_academic_year_id,
      'payload_hash', v_payload_hash,
      'summary', jsonb_build_object(
        'total', v_total,
        'exact', v_exact,
        'new_candidate', v_new,
        'blocked', v_blocked
      )
    )
  );

  return public.admin_group_recognition_get_preview(v_preview_id)
    || jsonb_build_object('idempotent_replay', false);
end;
$$;

create or replace function public.admin_group_recognition_get_preview(
  p_preview_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_preview public.group_recognition_previews%rowtype;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not (
    private.academic_ingestion_has_permission('groups.write')
    or private.academic_ingestion_has_permission('students.write')
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_preview
  from public.group_recognition_previews p
  where p.id = p_preview_id
    and p.created_by = v_uid;
  if not found then
    raise exception 'group_recognition_preview_not_found'
      using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'preview_id', v_preview.id,
    'academic_year_id', v_preview.academic_year_id,
    'parser_version', v_preview.parser_version,
    'payload_hash', v_preview.normalized_payload_hash,
    'expires_at', v_preview.expires_at,
    'status', v_preview.status,
    'row_version', v_preview.row_version,
    'summary', v_preview.summary,
    'apply_enabled', false,
    'apply_blocker', 'group_recognition_foundation_preview_only',
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'row_id', r.id,
        'source_row_key', r.source_row_key,
        'raw_group_name', r.raw_group_name,
        'normalized_group_name', r.normalized_group_name,
        'parallel_number', r.parallel_number,
        'program_alias_key', r.program_alias_key,
        'course_number', r.course_number,
        'derived_admission_year', r.derived_admission_year,
        'classification', r.classification,
        'candidate_group_ids', r.candidate_group_ids,
        'candidate_plan_ids', r.candidate_plan_ids,
        'matched_educational_program_id',
          r.matched_educational_program_id,
        'evidence', r.evidence,
        'warnings', r.warnings,
        'row_version', r.row_version
      ) order by r.source_row_key, r.id)
      from public.group_recognition_preview_rows r
      where r.preview_id = v_preview.id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_group_recognition_apply(
  p_preview_id uuid,
  p_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not private.academic_ingestion_has_permission('groups.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  raise exception 'group_recognition_foundation_preview_only'
    using errcode = '0A000';
end;
$$;

revoke all on function public.admin_group_recognition_list_academic_years()
  from public, anon, authenticated;
revoke all on function public.admin_group_recognition_start_preview(
  uuid, jsonb, text, text, text
) from public, anon, authenticated;
revoke all on function public.admin_group_recognition_get_preview(uuid)
  from public, anon, authenticated;
revoke all on function public.admin_group_recognition_apply(uuid, text)
  from public, anon, authenticated;

grant execute on function public.admin_group_recognition_list_academic_years()
  to authenticated;
grant execute on function public.admin_group_recognition_start_preview(
  uuid, jsonb, text, text, text
) to authenticated;
grant execute on function public.admin_group_recognition_get_preview(uuid)
  to authenticated;
grant execute on function public.admin_group_recognition_apply(uuid, text)
  to authenticated;

commit;
