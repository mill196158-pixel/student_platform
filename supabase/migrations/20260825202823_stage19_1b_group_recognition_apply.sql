-- Stage 19.1b Slice 2: durable review decisions and atomic group apply.
-- This migration intentionally creates only groups, aliases, academic
-- identities and academic profiles. It never calls admin_upsert_group and
-- never creates accounts, enrollments, offerings, spaces, teams or chats.

begin;

alter table public.group_recognition_previews
  drop constraint if exists group_recognition_previews_parser_check;
alter table public.group_recognition_previews
  add constraint group_recognition_previews_parser_check
  check (parser_version in ('group-name-v1', 'group-name-v2'));

alter table public.group_recognition_previews
  add column if not exists decision_revision integer not null default 0
    check (decision_revision >= 0),
  add column if not exists decision_hash text not null
    default encode(extensions.digest('[]', 'sha256'), 'hex')
    check (decision_hash ~ '^[0-9a-f]{64}$');

create table public.group_recognition_decisions (
  id uuid primary key default gen_random_uuid(),
  preview_id uuid not null
    references public.group_recognition_previews(id) on delete cascade,
  preview_row_id uuid not null
    references public.group_recognition_preview_rows(id) on delete cascade,
  action text not null check (
    action in ('reuse_group', 'add_alias', 'create_group')
  ),
  selected_group_id uuid null references public.groups(id) on delete restrict,
  selected_plan_id uuid null
    references public.curriculum_plans(id) on delete restrict,
  distinct_discriminator text not null default '',
  distinct_reason text null,
  decision_snapshot jsonb not null,
  created_by uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint group_recognition_decisions_row_unique
    unique(preview_id, preview_row_id),
  constraint group_recognition_decisions_shape_check check (
    (
      action in ('reuse_group', 'add_alias')
      and selected_group_id is not null
    )
    or (
      action = 'create_group'
      and selected_group_id is null
    )
  )
);

create index group_recognition_decisions_preview_idx
  on public.group_recognition_decisions(preview_id, preview_row_id);

create table public.group_recognition_results (
  id uuid primary key default gen_random_uuid(),
  preview_id uuid not null
    references public.group_recognition_previews(id) on delete restrict,
  preview_row_id uuid not null
    references public.group_recognition_preview_rows(id) on delete restrict,
  action text not null,
  group_id uuid not null references public.groups(id) on delete restrict,
  alias_outcome text not null check (
    alias_outcome in ('existing', 'created', 'not_requested')
  ),
  identity_outcome text not null check (
    identity_outcome in ('existing', 'created')
  ),
  profile_outcome text not null check (
    profile_outcome in ('created', 'retained', 'plan_bound')
  ),
  curriculum_plan_id uuid not null
    references public.curriculum_plans(id) on delete restrict,
  result_snapshot jsonb not null,
  applied_by uuid not null references public.users(id) on delete restrict,
  applied_at timestamptz not null default now(),
  constraint group_recognition_results_row_unique
    unique(preview_id, preview_row_id)
);

create index group_recognition_results_preview_idx
  on public.group_recognition_results(preview_id, preview_row_id);

alter table public.group_recognition_decisions enable row level security;
alter table public.group_recognition_decisions force row level security;
alter table public.group_recognition_results enable row level security;
alter table public.group_recognition_results force row level security;

revoke all on table
  public.group_recognition_decisions,
  public.group_recognition_results
from public, anon, authenticated;
grant select, insert, update, delete on table
  public.group_recognition_decisions
to service_role;
grant select, insert on table public.group_recognition_results to service_role;

create or replace function private.group_recognition_results_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'group_recognition_result_immutable' using errcode = '55000';
end;
$$;

create trigger group_recognition_results_immutable
before update or delete on public.group_recognition_results
for each row execute function private.group_recognition_results_immutable();

revoke all on function private.group_recognition_results_immutable()
  from public, anon, authenticated;
grant execute on function private.group_recognition_results_immutable()
  to service_role;

-- Human-readable and drift-sensitive snapshots. Exact-name/alias resolution is
-- recorded separately from parser/program/identity/profile/plan compatibility.
create or replace function private.group_recognition_fact_snapshot(
  p_preview_row_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with r as (
    select *
    from public.group_recognition_preview_rows
    where id = p_preview_row_id
  ),
  alias_groups as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'alias_id', a.id,
        'alias_key', a.alias_key,
        'alias_status', a.status,
        'alias_source', a.source,
        'group_id', g.id,
        'group_name', g.name,
        'group_name_key', private.group_recognition_name_key(g.name),
        'identity', (
          select jsonb_build_object(
            'educational_program_id', i.educational_program_id,
            'admission_year', i.admission_year,
            'parallel_number', i.parallel_number,
            'distinct_discriminator', i.distinct_discriminator,
            'distinct_reason', i.distinct_reason,
            'row_version', i.row_version
          )
          from public.group_academic_identities i
          where i.group_id = g.id
        ),
        'profile', (
          select jsonb_build_object(
            'admission_year', gap.admission_year,
            'nominal_semesters', gap.nominal_semesters,
            'active', gap.active,
            'curriculum_plan_id', gap.curriculum_plan_id
          )
          from public.group_academic_profiles gap
          where gap.group_id = g.id
        ),
        'max_term_semester', coalesce((
          select max(gts.semester_number)
          from public.group_term_semesters gts
          where gts.group_id = g.id
        ), 0),
        'label', coalesce((
          select concat_ws(
            ' · ',
            g.name,
            ep.direction_code || ' ' || ep.profile_name,
            case ep.study_form
              when 'full_time' then 'очная'
              when 'part_time' then 'очно-заочная'
              when 'extramural' then 'заочная'
              else ep.study_form
            end,
            'приём ' || i.admission_year::text,
            cp.version_label,
            cp.status,
            cp.nominal_semesters::text || ' сем.'
          )
          from public.group_academic_identities i
          join public.educational_programs ep
            on ep.id = i.educational_program_id
          left join public.group_academic_profiles gap
            on gap.group_id = i.group_id
          left join public.curriculum_plans cp
            on cp.id = gap.curriculum_plan_id
          where i.group_id = g.id
        ), g.name)
      ) order by a.id
    ), '[]'::jsonb) value
    from r
    join public.group_name_aliases a
      on a.alias_key = r.normalized_group_name
    join public.groups g on g.id = a.group_id
  ),
  program as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'alias_id', a.id,
        'alias_status', a.status,
        'alias_row_version', a.row_version,
        'program_id', ep.id,
        'direction_code', ep.direction_code,
        'direction_name', ep.direction_name,
        'profile_name', ep.profile_name,
        'qualification', ep.qualification,
        'study_form', ep.study_form,
        'program_status', ep.status,
        'program_row_version', ep.row_version
      ) order by a.id
    ), '[]'::jsonb) value
    from r
    join public.educational_program_aliases a
      on a.alias_key = r.program_alias_key
    join public.educational_programs ep
      on ep.id = a.educational_program_id
  ),
  semantic_groups as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'group_id', g.id,
        'group_name', g.name,
        'identity', jsonb_build_object(
          'educational_program_id', i.educational_program_id,
          'admission_year', i.admission_year,
          'parallel_number', i.parallel_number,
          'distinct_discriminator', i.distinct_discriminator,
          'distinct_reason', i.distinct_reason,
          'row_version', i.row_version
        ),
        'profile', case when gap.group_id is null then null else
          jsonb_build_object(
            'admission_year', gap.admission_year,
            'nominal_semesters', gap.nominal_semesters,
            'active', gap.active,
            'curriculum_plan_id', gap.curriculum_plan_id
          )
        end,
        'max_term_semester', coalesce((
          select max(gts.semester_number)
          from public.group_term_semesters gts
          where gts.group_id = g.id
        ), 0)
      ) order by g.id
    ), '[]'::jsonb) value
    from r
    join public.group_academic_identities i
      on i.educational_program_id = r.matched_educational_program_id
     and i.admission_year = r.derived_admission_year
     and i.parallel_number = r.parallel_number
    join public.groups g on g.id = i.group_id
    left join public.group_academic_profiles gap on gap.group_id = g.id
  ),
  plans as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'plan_id', cp.id,
        'plan_code', cp.plan_code,
        'version_label', cp.version_label,
        'educational_program_id', cp.educational_program_id,
        'admission_year', cp.admission_year,
        'nominal_semesters', cp.nominal_semesters,
        'status', cp.status,
        'row_version', cp.row_version,
        'label', concat_ws(
          ' · ',
          ep.direction_code,
          ep.profile_name,
          case ep.study_form
            when 'full_time' then 'очная'
            when 'part_time' then 'очно-заочная'
            when 'extramural' then 'заочная'
            else ep.study_form
          end,
          'приём ' || cp.admission_year::text,
          cp.version_label,
          cp.status,
          cp.nominal_semesters::text || ' сем.'
        )
      ) order by cp.id
    ), '[]'::jsonb) value
    from r
    join public.curriculum_plans cp
      on cp.educational_program_id = r.matched_educational_program_id
     and cp.admission_year = r.derived_admission_year
     and cp.status in ('reviewed', 'active')
    join public.educational_programs ep
      on ep.id = cp.educational_program_id
    where r.course_number <= ((cp.nominal_semesters + 1) / 2)
  )
  select jsonb_build_object(
    'alias_groups', (select value from alias_groups),
    'program_candidates', (select value from program),
    'semantic_groups', (select value from semantic_groups),
    'plans', (select value from plans)
  );
$$;

revoke all on function private.group_recognition_fact_snapshot(uuid)
  from public, anon, authenticated;
grant execute on function private.group_recognition_fact_snapshot(uuid)
  to service_role;

create or replace function private.group_recognition_refresh_preview_v2(
  p_preview_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_program_id uuid;
  v_program_count integer;
  v_program_active boolean;
  v_alias_groups uuid[];
  v_semantic_all uuid[];
  v_semantic_groups uuid[];
  v_plans uuid[];
  v_snapshot jsonb;
  v_class text;
  v_warnings jsonb;
  v_group uuid;
  v_profile public.group_academic_profiles%rowtype;
  v_identity public.group_academic_identities%rowtype;
  v_plan public.curriculum_plans%rowtype;
  v_max_semester integer;
  v_compatible boolean;
  v_profile_found boolean;
  v_plan_found boolean;
begin
  for r in
    select *
    from public.group_recognition_preview_rows
    where preview_id = p_preview_id
    order by id
    for update
  loop
    if r.classification = 'parser_blocked' then
      continue;
    end if;

    select count(*), min(a.educational_program_id::text)::uuid,
           bool_and(a.status = 'active' and ep.status = 'active')
      into v_program_count, v_program_id, v_program_active
    from public.educational_program_aliases a
    join public.educational_programs ep on ep.id = a.educational_program_id
    where a.alias_key = r.program_alias_key;

    if v_program_count <> 1 then
      update public.group_recognition_preview_rows
      set classification = case when v_program_count = 0
            then 'program_unregistered' else 'conflict' end,
          matched_educational_program_id = null,
          candidate_group_ids = '{}'::uuid[],
          candidate_plan_ids = '{}'::uuid[],
          warnings = jsonb_build_array(case when v_program_count = 0
            then 'program_alias_not_reviewed'
            else 'program_alias_conflict' end)
      where id = r.id;
      continue;
    end if;

    update public.group_recognition_preview_rows
    set matched_educational_program_id = v_program_id
    where id = r.id;

    select coalesce(array_agg(a.group_id order by a.group_id), '{}'::uuid[])
      into v_alias_groups
    from public.group_name_aliases a
    where a.alias_key = r.normalized_group_name and a.status = 'active';

    select coalesce(array_agg(i.group_id order by i.group_id), '{}'::uuid[])
      into v_semantic_all
    from public.group_academic_identities i
    where i.educational_program_id = v_program_id
      and i.admission_year = r.derived_admission_year
      and i.parallel_number = r.parallel_number;

    select coalesce(array_agg(cp.id order by cp.id), '{}'::uuid[])
      into v_plans
    from public.curriculum_plans cp
    where cp.educational_program_id = v_program_id
      and cp.admission_year = r.derived_admission_year
      and cp.status in ('reviewed', 'active')
      and r.course_number <= ((cp.nominal_semesters + 1) / 2);

    -- A semantic match is actionable only when at least one selected-plan path
    -- satisfies the same reuse matrix enforced again by apply.
    select coalesce(array_agg(i.group_id order by i.group_id), '{}'::uuid[])
      into v_semantic_groups
    from public.group_academic_identities i
    left join public.group_academic_profiles gap on gap.group_id = i.group_id
    where i.group_id = any(v_semantic_all)
      and (gap.group_id is null or (
        gap.active
        and gap.admission_year = r.derived_admission_year
      ))
      and exists (
        select 1
        from public.curriculum_plans cp
        where cp.id = any(v_plans)
          and (
            gap.group_id is null
            or (
              cp.nominal_semesters = gap.nominal_semesters
              and (
                gap.curriculum_plan_id is null
                or gap.curriculum_plan_id = cp.id
              )
            )
          )
          and coalesce((
            select max(gts.semester_number)
            from public.group_term_semesters gts
            where gts.group_id = i.group_id
          ), 0) <= cp.nominal_semesters
      );

    v_class := null;
    v_warnings := '[]'::jsonb;
    if not v_program_active then
      v_class := 'conflict';
      v_warnings := '["educational_program_not_active"]'::jsonb;
    elsif cardinality(v_alias_groups) > 1 then
      v_class := 'conflict';
      v_warnings := '["group_alias_collision"]'::jsonb;
    elsif cardinality(v_plans) = 0 then
      v_class := 'no_plan';
      v_warnings := '["matching_reviewed_plan_not_found"]'::jsonb;
    elsif cardinality(v_alias_groups) = 1 then
      v_group := v_alias_groups[1];
      v_compatible := true;
      select * into v_identity
      from public.group_academic_identities where group_id = v_group;
      if found and (
        v_identity.educational_program_id <> v_program_id
        or v_identity.admission_year <> r.derived_admission_year
        or v_identity.parallel_number <> r.parallel_number
      ) then
        v_compatible := false;
        v_warnings := v_warnings || '["group_identity_conflict"]'::jsonb;
      end if;
      select * into v_profile
      from public.group_academic_profiles where group_id = v_group;
      v_profile_found := found;
      if v_profile_found then
        if not v_profile.active
           or v_profile.admission_year <> r.derived_admission_year then
          v_compatible := false;
          v_warnings := v_warnings || '["group_profile_conflict"]'::jsonb;
        end if;
        if v_profile.curriculum_plan_id is not null
           and not (v_profile.curriculum_plan_id = any(v_plans)) then
          v_compatible := false;
          v_warnings := v_warnings || '["group_plan_conflict"]'::jsonb;
        end if;
      end if;
      select coalesce(max(semester_number), 0) into v_max_semester
      from public.group_term_semesters where group_id = v_group;
      if v_profile.curriculum_plan_id is not null then
        select * into v_plan from public.curriculum_plans
        where id = v_profile.curriculum_plan_id;
      else
        select * into v_plan from public.curriculum_plans
        where id = v_plans[1];
      end if;
      v_plan_found := found;
      if cardinality(v_plans) > 1 and v_profile.curriculum_plan_id is null then
        v_compatible := false;
        v_warnings := v_warnings || '["multiple_plan_versions_require_choice"]'::jsonb;
      elsif v_profile_found and v_plan_found
            and v_profile.nominal_semesters <> v_plan.nominal_semesters then
        v_compatible := false;
        v_warnings := v_warnings || '["group_nominal_semesters_conflict"]'::jsonb;
      elsif v_plan_found and v_max_semester > v_plan.nominal_semesters then
        v_compatible := false;
        v_warnings := v_warnings || '["group_semester_exceeds_plan"]'::jsonb;
      end if;
      if v_compatible then
        select case when a.source = 'current_name'
                    then 'exact_group' else 'exact_alias' end
          into v_class
        from public.group_name_aliases a
        where a.alias_key = r.normalized_group_name
          and a.status = 'active'
        limit 1;
      else
        v_class := 'conflict';
      end if;
    elsif cardinality(v_semantic_groups) > 0 then
      v_class := 'semantic_duplicate';
    elsif cardinality(v_semantic_all) > 0 then
      v_class := 'conflict';
      v_warnings := '["semantic_candidates_incompatible"]'::jsonb;
    elsif cardinality(v_plans) > 1 then
      v_class := 'ambiguous_plan';
      v_warnings := '["multiple_plan_versions_require_choice"]'::jsonb;
    else
      v_class := 'new_candidate';
    end if;

    update public.group_recognition_preview_rows
    set classification = v_class,
        candidate_group_ids = case
          when cardinality(v_alias_groups) > 0 then v_alias_groups
          else v_semantic_groups
        end,
        candidate_plan_ids = v_plans,
        warnings = v_warnings
    where id = r.id;

    v_snapshot := private.group_recognition_fact_snapshot(r.id);
    update public.group_recognition_preview_rows
    set evidence = evidence || jsonb_build_object(
      'group_match_kind', case
        when cardinality(v_alias_groups) = 1 then 'name_or_alias'
        when cardinality(v_semantic_groups) > 0 then 'semantic'
        else 'none'
      end,
      'candidate_snapshot', v_snapshot
    )
    where id = r.id;
  end loop;

  update public.group_recognition_previews p
  set parser_version = 'group-name-v2',
      summary = jsonb_build_object(
        'total', (select count(*) from public.group_recognition_preview_rows r
                  where r.preview_id = p.id),
        'exact', (select count(*) from public.group_recognition_preview_rows r
                  where r.preview_id = p.id
                    and r.classification in ('exact_group', 'exact_alias')),
        'new_candidate', (select count(*) from public.group_recognition_preview_rows r
                  where r.preview_id = p.id
                    and r.classification = 'new_candidate'),
        'needs_decision', (select count(*) from public.group_recognition_preview_rows r
                  where r.preview_id = p.id
                    and r.classification in (
                      'exact_group', 'exact_alias', 'semantic_duplicate',
                      'new_candidate', 'ambiguous_plan'
                    )),
        'blocked', (select count(*) from public.group_recognition_preview_rows r
                  where r.preview_id = p.id
                    and r.classification not in (
                      'exact_group', 'exact_alias', 'semantic_duplicate',
                      'new_candidate', 'ambiguous_plan'
                    )),
        'apply_enabled', false
      )
  where p.id = p_preview_id;
end;
$$;

revoke all on function private.group_recognition_refresh_preview_v2(uuid)
  from public, anon, authenticated;
grant execute on function private.group_recognition_refresh_preview_v2(uuid)
  to service_role;

alter function public.admin_group_recognition_start_preview(
  uuid, jsonb, text, text, text
) rename to admin_group_recognition_start_preview_slice1;

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
  v_result jsonb;
  v_preview_id uuid;
  v_parser text;
begin
  v_result := public.admin_group_recognition_start_preview_slice1(
    p_academic_year_id,
    p_rows,
    p_file_name,
    case when nullif(btrim(p_idempotency_key), '') is null then null
         else 'slice2|' || p_idempotency_key end,
    p_source_sha256
  );
  v_preview_id := (v_result ->> 'preview_id')::uuid;
  select parser_version into v_parser
  from public.group_recognition_previews
  where id = v_preview_id
  for update;
  if v_parser = 'group-name-v1' then
    perform private.group_recognition_refresh_preview_v2(v_preview_id);
  end if;
  return public.admin_group_recognition_get_preview(v_preview_id)
    || jsonb_build_object(
      'idempotent_replay', coalesce((v_result ->> 'idempotent_replay')::boolean, false)
    );
end;
$$;

create or replace function private.group_recognition_confirmation_token(
  p_preview_id uuid,
  p_payload_hash text,
  p_decision_revision integer,
  p_decision_hash text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.digest(convert_to(
    'GROUP_APPLY|' || p_preview_id::text || '|' || p_payload_hash || '|'
      || p_decision_revision::text || '|' || p_decision_hash,
    'UTF8'
  ), 'sha256'), 'hex');
$$;

revoke all on function private.group_recognition_confirmation_token(
  uuid, text, integer, text
) from public, anon, authenticated;
grant execute on function private.group_recognition_confirmation_token(
  uuid, text, integer, text
) to service_role;

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
  p public.group_recognition_previews%rowtype;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not private.academic_ingestion_has_permission('groups.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into p from public.group_recognition_previews
  where id = p_preview_id and created_by = v_uid;
  if not found then
    raise exception 'group_recognition_preview_not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'preview_id', p.id,
    'academic_year_id', p.academic_year_id,
    'parser_version', p.parser_version,
    'payload_hash', p.normalized_payload_hash,
    'expires_at', p.expires_at,
    'status', p.status,
    'row_version', p.row_version,
    'decision_revision', p.decision_revision,
    'decision_hash', p.decision_hash,
    'confirmation_token', private.group_recognition_confirmation_token(
      p.id, p.normalized_payload_hash, p.decision_revision, p.decision_hash
    ),
    'summary', p.summary,
    'apply_enabled', p.status = 'preview'
      and p.expires_at > now()
      and not exists (
        select 1 from public.group_recognition_preview_rows r
        where r.preview_id = p.id
          and r.classification not in (
            'exact_group', 'exact_alias', 'semantic_duplicate',
            'new_candidate', 'ambiguous_plan'
          )
      )
      and (
        select count(*) from public.group_recognition_decisions d
        where d.preview_id = p.id
      ) = (
        select count(*) from public.group_recognition_preview_rows r
        where r.preview_id = p.id
          and r.classification in (
            'exact_group', 'exact_alias', 'semantic_duplicate',
            'new_candidate', 'ambiguous_plan'
          )
      ),
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
        'matched_educational_program_id', r.matched_educational_program_id,
        'evidence', r.evidence,
        'warnings', r.warnings,
        'row_version', r.row_version,
        'decision', case when d.id is null then null else jsonb_build_object(
          'id', d.id,
          'action', d.action,
          'selected_group_id', d.selected_group_id,
          'selected_plan_id', d.selected_plan_id,
          'distinct_discriminator', d.distinct_discriminator,
          'distinct_reason', d.distinct_reason
        ) end
      ) order by r.source_row_key, r.id)
      from public.group_recognition_preview_rows r
      left join public.group_recognition_decisions d
        on d.preview_id = r.preview_id and d.preview_row_id = r.id
      where r.preview_id = p.id
    ), '[]'::jsonb),
    'results', coalesce((
      select jsonb_agg(result_snapshot order by preview_row_id)
      from public.group_recognition_results
      where preview_id = p.id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_group_recognition_save_decisions(
  p_preview_id uuid,
  p_expected_preview_row_version integer,
  p_expected_payload_hash text,
  p_decisions jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  p public.group_recognition_previews%rowtype;
  j jsonb;
  r public.group_recognition_preview_rows%rowtype;
  v_action text;
  v_group uuid;
  v_plan uuid;
  v_discriminator text;
  v_reason text;
  v_hash text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not private.academic_ingestion_has_permission('groups.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_decisions, '[]'::jsonb)) <> 'array' then
    raise exception 'invalid_decisions' using errcode = '22023';
  end if;
  if jsonb_array_length(p_decisions) <> (
    select count(distinct value ->> 'preview_row_id')
    from jsonb_array_elements(p_decisions)
  ) then
    raise exception 'duplicate_decision_ids' using errcode = '22023';
  end if;

  select * into p from public.group_recognition_previews
  where id = p_preview_id for update;
  if not found or p.created_by <> v_uid then
    raise exception 'group_recognition_preview_not_found' using errcode = 'P0002';
  end if;
  if p.status <> 'preview' or p.expires_at <= now() then
    raise exception 'group_recognition_preview_stale' using errcode = '40001';
  end if;
  if p.row_version <> p_expected_preview_row_version
     or p.normalized_payload_hash <> p_expected_payload_hash then
    raise exception 'group_recognition_preview_stale' using errcode = '40001';
  end if;

  perform 1 from public.group_recognition_preview_rows
  where preview_id = p.id order by id for update;

  for j in select value from jsonb_array_elements(p_decisions)
  loop
    select * into r
    from public.group_recognition_preview_rows
    where id = nullif(j ->> 'preview_row_id', '')::uuid
      and preview_id = p.id;
    if not found then
      raise exception 'decision_row_not_found' using errcode = '22023';
    end if;
    if r.classification not in (
      'exact_group', 'exact_alias', 'semantic_duplicate',
      'new_candidate', 'ambiguous_plan'
    ) then
      raise exception 'blocked_row_has_decision' using errcode = '22023';
    end if;
    v_action := j ->> 'action';
    v_group := nullif(j ->> 'selected_group_id', '')::uuid;
    v_plan := nullif(j ->> 'selected_plan_id', '')::uuid;
    v_discriminator := lower(btrim(coalesce(
      j ->> 'distinct_discriminator', ''
    )));
    v_reason := nullif(btrim(j ->> 'distinct_reason'), '');

    if r.classification in ('exact_group', 'exact_alias') and not (
      v_action = 'reuse_group'
      and cardinality(r.candidate_group_ids) = 1
      and v_group = r.candidate_group_ids[1]
      and v_discriminator = '' and v_reason is null
    ) then
      raise exception 'invalid_exact_group_decision' using errcode = '22023';
    elsif r.classification = 'semantic_duplicate' and not (
      (
        v_action in ('reuse_group', 'add_alias')
        and v_group = any(r.candidate_group_ids)
        and v_discriminator = '' and v_reason is null
      )
      or (
        v_action = 'create_group'
        and v_group is null
        and v_discriminator ~ '^[[:alnum:]_-]{1,80}$'
        and char_length(v_reason) >= 8
      )
    ) then
      raise exception 'invalid_semantic_duplicate_decision'
        using errcode = '22023';
    elsif r.classification = 'new_candidate' and not (
      v_action = 'create_group' and v_group is null
      and v_discriminator = '' and v_reason is null
      and cardinality(r.candidate_plan_ids) = 1
    ) then
      raise exception 'invalid_new_group_decision' using errcode = '22023';
    elsif r.classification = 'ambiguous_plan' and not (
      v_action = 'create_group' and v_group is null
      and v_discriminator = '' and v_reason is null
      and v_plan = any(r.candidate_plan_ids)
    ) then
      raise exception 'invalid_ambiguous_plan_decision' using errcode = '22023';
    end if;

    if v_plan is null then
      if v_action in ('reuse_group', 'add_alias') then
        select gap.curriculum_plan_id into v_plan
        from public.group_academic_profiles gap where gap.group_id = v_group;
      end if;
      if v_plan is null and cardinality(r.candidate_plan_ids) = 1 then
        v_plan := r.candidate_plan_ids[1];
      end if;
    end if;
    if v_action in ('reuse_group', 'add_alias')
       and exists (
         select 1
         from public.group_academic_profiles gap
         where gap.group_id = v_group
           and gap.curriculum_plan_id is not null
           and gap.curriculum_plan_id <> v_plan
       ) then
      raise exception 'exact_group_plan_is_fixed' using errcode = '22023';
    end if;
    if v_plan is null or not (v_plan = any(r.candidate_plan_ids)) then
      raise exception 'decision_plan_required' using errcode = '22023';
    end if;
    if v_action in ('reuse_group', 'add_alias')
       and not exists (
         select 1
         from public.curriculum_plans cp
         left join public.group_academic_profiles gap
           on gap.group_id = v_group
         where cp.id = v_plan
           and coalesce((
             select max(gts.semester_number)
             from public.group_term_semesters gts
             where gts.group_id = v_group
           ), 0) <= cp.nominal_semesters
           and (
             gap.group_id is null
             or (
               gap.active
               and gap.admission_year = r.derived_admission_year
               and gap.nominal_semesters = cp.nominal_semesters
               and (
                 gap.curriculum_plan_id is null
                 or gap.curriculum_plan_id = cp.id
               )
             )
           )
       ) then
      raise exception 'reused_group_plan_incompatible'
        using errcode = '22023';
    end if;
  end loop;

  delete from public.group_recognition_decisions where preview_id = p.id;
  for j in select value from jsonb_array_elements(p_decisions)
  loop
    select * into r from public.group_recognition_preview_rows
    where id = (j ->> 'preview_row_id')::uuid and preview_id = p.id;
    v_action := j ->> 'action';
    v_group := nullif(j ->> 'selected_group_id', '')::uuid;
    v_plan := nullif(j ->> 'selected_plan_id', '')::uuid;
    v_discriminator := lower(btrim(coalesce(
      j ->> 'distinct_discriminator', ''
    )));
    v_reason := nullif(btrim(j ->> 'distinct_reason'), '');
    if v_plan is null then
      if v_action in ('reuse_group', 'add_alias') then
        select gap.curriculum_plan_id into v_plan
        from public.group_academic_profiles gap where gap.group_id = v_group;
      end if;
      if v_plan is null and cardinality(r.candidate_plan_ids) = 1 then
        v_plan := r.candidate_plan_ids[1];
      end if;
    end if;
    insert into public.group_recognition_decisions(
      preview_id, preview_row_id, action, selected_group_id,
      selected_plan_id, distinct_discriminator, distinct_reason,
      decision_snapshot, created_by
    ) values (
      p.id, r.id, v_action, v_group, v_plan, v_discriminator, v_reason,
      private.group_recognition_fact_snapshot(r.id), v_uid
    );
  end loop;

  select encode(extensions.digest(convert_to(coalesce(jsonb_agg(
    jsonb_build_object(
      'preview_row_id', d.preview_row_id,
      'action', d.action,
      'selected_group_id', d.selected_group_id,
      'selected_plan_id', d.selected_plan_id,
      'distinct_discriminator', d.distinct_discriminator,
      'distinct_reason', d.distinct_reason
    ) order by d.preview_row_id
  ), '[]'::jsonb)::text, 'UTF8'), 'sha256'), 'hex')
  into v_hash
  from public.group_recognition_decisions d where d.preview_id = p.id;

  update public.group_recognition_previews
  set decision_revision = decision_revision + 1,
      decision_hash = v_hash,
      row_version = row_version + 1
  where id = p.id;

  perform private.admin_write_audit(
    'group_recognition.decisions_replace',
    'group_recognition_preview',
    p.id::text,
    jsonb_build_object(
      'decision_count', jsonb_array_length(p_decisions),
      'decision_hash', v_hash,
      'decision_revision', p.decision_revision + 1
    )
  );
  return public.admin_group_recognition_get_preview(p.id);
end;
$$;

create or replace function public.admin_group_recognition_apply(
  p_preview_id uuid,
  p_expected_preview_row_version integer,
  p_expected_payload_hash text,
  p_expected_decision_revision integer,
  p_expected_decision_hash text,
  p_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  p public.group_recognition_previews%rowtype;
  d record;
  r public.group_recognition_preview_rows%rowtype;
  cp public.curriculum_plans%rowtype;
  i public.group_academic_identities%rowtype;
  gap public.group_academic_profiles%rowtype;
  v_current_snapshot jsonb;
  v_group uuid;
  v_alias_outcome text;
  v_identity_outcome text;
  v_profile_outcome text;
  v_max_semester integer;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not private.academic_ingestion_has_permission('groups.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into p from public.group_recognition_previews
  where id = p_preview_id for update;
  if not found or p.created_by <> v_uid then
    raise exception 'group_recognition_preview_not_found' using errcode = 'P0002';
  end if;
  if p.normalized_payload_hash <> p_expected_payload_hash
     or p.decision_revision <> p_expected_decision_revision
     or p.decision_hash <> p_expected_decision_hash
     or p_confirmation <> private.group_recognition_confirmation_token(
       p.id, p.normalized_payload_hash, p.decision_revision, p.decision_hash
     ) then
    raise exception 'group_recognition_confirmation_stale' using errcode = '40001';
  end if;
  if p.status = 'applied' then
    return public.admin_group_recognition_get_preview(p.id)
      || jsonb_build_object('idempotent_replay', true);
  end if;
  if p.status <> 'preview' or p.expires_at <= now()
     or p.row_version <> p_expected_preview_row_version then
    raise exception 'group_recognition_preview_stale' using errcode = '40001';
  end if;
  if exists (
    select 1 from public.group_recognition_preview_rows
    where preview_id = p.id
      and classification not in (
        'exact_group', 'exact_alias', 'semantic_duplicate',
        'new_candidate', 'ambiguous_plan'
      )
  ) or (
    select count(*) from public.group_recognition_decisions
    where preview_id = p.id
  ) <> (
    select count(*) from public.group_recognition_preview_rows
    where preview_id = p.id
      and classification in (
        'exact_group', 'exact_alias', 'semantic_duplicate',
        'new_candidate', 'ambiguous_plan'
      )
  ) then
    raise exception 'group_recognition_incomplete_or_blocked'
      using errcode = '22023';
  end if;

  perform 1 from public.group_recognition_preview_rows
    where preview_id = p.id order by id for update;
  perform 1 from public.group_recognition_decisions
    where preview_id = p.id order by preview_row_id for update;
  perform 1 from public.groups
    where id in (select unnest(candidate_group_ids)
                 from public.group_recognition_preview_rows
                 where preview_id = p.id)
    order by id for update;
  perform 1 from public.curriculum_plans
    where id in (select selected_plan_id
                 from public.group_recognition_decisions
                 where preview_id = p.id)
    order by id for update;

  for d in
    select * from public.group_recognition_decisions
    where preview_id = p.id order by preview_row_id
  loop
    select * into r from public.group_recognition_preview_rows
    where id = d.preview_row_id;
    v_current_snapshot := private.group_recognition_fact_snapshot(r.id);
    if v_current_snapshot is distinct from d.decision_snapshot then
      raise exception 'group_recognition_facts_stale' using errcode = '40001';
    end if;
    select * into cp from public.curriculum_plans where id = d.selected_plan_id;
    if not found or cp.status not in ('reviewed', 'active')
       or cp.educational_program_id <> r.matched_educational_program_id
       or cp.admission_year <> r.derived_admission_year
       or r.course_number > ((cp.nominal_semesters + 1) / 2) then
      raise exception 'group_recognition_plan_stale' using errcode = '40001';
    end if;

    v_alias_outcome := 'not_requested';
    if d.action = 'create_group' then
      begin
        insert into public.groups(name) values (r.raw_group_name)
        returning id into v_group;
        insert into public.group_name_aliases(
          group_id, alias_raw, alias_key, source, status,
          reviewed_by, reviewed_at
        ) values (
          v_group, r.raw_group_name, r.normalized_group_name,
          'import_review', 'active', v_uid, now()
        );
        v_alias_outcome := 'created';
      exception when unique_violation then
        raise exception 'group_recognition_unique_conflict'
          using errcode = '23505';
      end;
    else
      v_group := d.selected_group_id;
      if d.action = 'add_alias' then
        begin
          insert into public.group_name_aliases(
            group_id, alias_raw, alias_key, source, status,
            reviewed_by, reviewed_at
          ) values (
            v_group, r.raw_group_name, r.normalized_group_name,
            'import_review', 'active', v_uid, now()
          );
          v_alias_outcome := 'created';
        exception when unique_violation then
          raise exception 'group_recognition_alias_conflict'
            using errcode = '23505';
        end;
      elsif exists (
        select 1 from public.group_name_aliases
        where alias_key = r.normalized_group_name
          and group_id = v_group and status = 'active'
      ) then
        v_alias_outcome := 'existing';
      end if;
    end if;

    select * into i from public.group_academic_identities
    where group_id = v_group for update;
    if found then
      if i.educational_program_id <> r.matched_educational_program_id
         or i.admission_year <> r.derived_admission_year
         or i.parallel_number <> r.parallel_number
         or i.distinct_discriminator <> d.distinct_discriminator then
        raise exception 'group_recognition_identity_conflict'
          using errcode = '40001';
      end if;
      v_identity_outcome := 'existing';
    else
      begin
        insert into public.group_academic_identities(
          group_id, educational_program_id, admission_year, parallel_number,
          distinct_discriminator, distinct_reason, reviewed_by, reviewed_at
        ) values (
          v_group, r.matched_educational_program_id, r.derived_admission_year,
          r.parallel_number, d.distinct_discriminator, d.distinct_reason,
          v_uid, now()
        );
        v_identity_outcome := 'created';
      exception when unique_violation then
        raise exception 'group_recognition_identity_unique_conflict'
          using errcode = '23505';
      end;
    end if;

    select coalesce(max(semester_number), 0) into v_max_semester
    from public.group_term_semesters where group_id = v_group;
    if v_max_semester > cp.nominal_semesters then
      raise exception 'group_semester_exceeds_curriculum_plan'
        using errcode = '22023';
    end if;
    select * into gap from public.group_academic_profiles
    where group_id = v_group for update;
    if not found then
      insert into public.group_academic_profiles(
        group_id, admission_year, nominal_semesters, active,
        curriculum_plan_id, created_at, updated_at
      ) values (
        v_group, r.derived_admission_year, cp.nominal_semesters, true,
        cp.id, now(), now()
      );
      v_profile_outcome := 'created';
    else
      if not gap.active
         or gap.admission_year <> r.derived_admission_year
         or gap.nominal_semesters <> cp.nominal_semesters then
        raise exception 'group_recognition_profile_conflict'
          using errcode = '40001';
      end if;
      if gap.curriculum_plan_id is null then
        update public.group_academic_profiles
        set curriculum_plan_id = cp.id, updated_at = now()
        where group_id = v_group and curriculum_plan_id is null;
        v_profile_outcome := 'plan_bound';
      elsif gap.curriculum_plan_id = cp.id then
        v_profile_outcome := 'retained';
      else
        raise exception 'group_recognition_plan_replacement_forbidden'
          using errcode = '40001';
      end if;
    end if;

    v_result := jsonb_build_object(
      'preview_row_id', r.id,
      'source_row_key', r.source_row_key,
      'action', d.action,
      'group_id', v_group,
      'group_name', r.raw_group_name,
      'alias_outcome', v_alias_outcome,
      'identity_outcome', v_identity_outcome,
      'profile_outcome', v_profile_outcome,
      'curriculum_plan_id', cp.id,
      'plan_label', concat_ws(
        ' · ', cp.plan_code, cp.version_label, cp.status,
        cp.nominal_semesters::text || ' сем.'
      )
    );
    insert into public.group_recognition_results(
      preview_id, preview_row_id, action, group_id, alias_outcome,
      identity_outcome, profile_outcome, curriculum_plan_id,
      result_snapshot, applied_by
    ) values (
      p.id, r.id, d.action, v_group, v_alias_outcome,
      v_identity_outcome, v_profile_outcome, cp.id, v_result, v_uid
    );
  end loop;

  update public.group_recognition_previews
  set status = 'applied', applied_at = now(), row_version = row_version + 1
  where id = p.id;
  perform private.admin_write_audit(
    'group_recognition.apply',
    'group_recognition_preview',
    p.id::text,
    jsonb_build_object(
      'payload_hash', p.normalized_payload_hash,
      'decision_revision', p.decision_revision,
      'decision_hash', p.decision_hash,
      'result_count', (select count(*) from public.group_recognition_results
                       where preview_id = p.id)
    )
  );
  return public.admin_group_recognition_get_preview(p.id)
    || jsonb_build_object('idempotent_replay', false);
end;
$$;

revoke all on function public.admin_group_recognition_start_preview(
  uuid, jsonb, text, text, text
) from public, anon, authenticated;
revoke all on function public.admin_group_recognition_start_preview_slice1(
  uuid, jsonb, text, text, text
) from public, anon, authenticated;
revoke all on function public.admin_group_recognition_get_preview(uuid)
  from public, anon, authenticated;
revoke all on function public.admin_group_recognition_save_decisions(
  uuid, integer, text, jsonb
) from public, anon, authenticated;
revoke all on function public.admin_group_recognition_apply(
  uuid, integer, text, integer, text, text
) from public, anon, authenticated;

grant execute on function public.admin_group_recognition_start_preview(
  uuid, jsonb, text, text, text
) to authenticated;
grant execute on function public.admin_group_recognition_get_preview(uuid)
  to authenticated;
grant execute on function public.admin_group_recognition_save_decisions(
  uuid, integer, text, jsonb
) to authenticated;
grant execute on function public.admin_group_recognition_apply(
  uuid, integer, text, integer, text, text
) to authenticated;

commit;
