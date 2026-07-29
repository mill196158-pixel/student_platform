-- Stage 16.1 P1 round-3: legacy field preserve + revoke direct client use,
-- restore expected versions. LOCAL ONLY.

-- ---------------------------------------------------------------------------
-- Legacy upsert: never wipe relevance_date/section_order.
-- Direct authenticated client execute is revoked (Admin uses card RPC).
-- Import SECURITY DEFINER owner may still call this; when expected versions
-- are null it uses locked current versions (server-side, after FOR UPDATE).
-- When expected versions are provided they are enforced (stale → conflict).
-- ---------------------------------------------------------------------------
create or replace function public.admin_upsert_subject(
  p_id uuid default null,
  p_canonical_name text default '',
  p_description text default null,
  p_department text default null,
  p_control_form text default null,
  p_difficulty_label text default null,
  p_requirements text default null,
  p_learning_outcomes text default null,
  p_useful_links jsonb default '[]'::jsonb,
  p_status text default 'draft',
  p_short_description text default null,
  p_what_to_expect text default null,
  p_how_to_pass text default null,
  p_useful_materials_note text default null,
  p_common_pitfalls text default null,
  p_expected_catalog_row_version integer default null,
  p_expected_profile_row_version integer default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cat_ver integer := 0;
  v_prof_ver integer := 0;
  v_relevance date;
  v_section_order jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  if p_id is not null then
    select coalesce(row_version, 1) into v_cat_ver
    from public.subject_catalog where id = p_id for update;
    if not found then
      raise exception 'subject_not_found' using errcode = 'P0002';
    end if;

    select coalesce(row_version, 1), relevance_date, section_order
    into v_prof_ver, v_relevance, v_section_order
    from public.subject_student_profiles
    where subject_id = p_id
    for update;
    if not found then
      v_prof_ver := 0;
      v_relevance := null;
      v_section_order := '[]'::jsonb;
    end if;

    if p_expected_catalog_row_version is not null
       and v_cat_ver is distinct from p_expected_catalog_row_version then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
    if p_expected_profile_row_version is not null
       and v_prof_ver is distinct from p_expected_profile_row_version then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
  else
    if coalesce(p_expected_catalog_row_version, 0) <> 0
       or coalesce(p_expected_profile_row_version, 0) <> 0 then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
  end if;

  v_result := public.admin_upsert_subject_card(
    p_id,
    coalesce(p_expected_catalog_row_version, v_cat_ver),
    coalesce(p_expected_profile_row_version, v_prof_ver),
    p_canonical_name,
    p_description,
    p_department,
    p_control_form,
    p_difficulty_label,
    p_requirements,
    p_learning_outcomes,
    p_useful_links,
    p_status,
    p_short_description,
    p_what_to_expect,
    p_how_to_pass,
    p_useful_materials_note,
    p_common_pitfalls,
    v_relevance,
    coalesce(v_section_order, '[]'::jsonb)
  );
  return (v_result->>'id')::uuid;
end;
$$;

do $$
begin
  if to_regprocedure(
    'public.admin_upsert_subject(uuid,text,text,text,text,text,text,text,jsonb,text,text,text,text,text,text)'
  ) is not null then
    revoke all on function public.admin_upsert_subject(
      uuid, text, text, text, text, text, text, text, jsonb, text,
      text, text, text, text, text
    ) from public, anon, authenticated, service_role;
    drop function public.admin_upsert_subject(
      uuid, text, text, text, text, text, text, text, jsonb, text,
      text, text, text, text, text
    );
  end if;
end $$;

revoke all on function public.admin_upsert_subject(
  uuid, text, text, text, text, text, text, text, jsonb, text,
  text, text, text, text, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.admin_upsert_subject(
  uuid, text, text, text, text, text, text, text, jsonb, text,
  text, text, text, text, text, integer, integer
) to service_role;

-- Status change preserves 16.1 fields; requires expected versions.
create or replace function public.admin_set_subject_status(
  p_id uuid,
  p_status text,
  p_expected_catalog_row_version integer,
  p_expected_profile_row_version integer
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.subject_catalog%rowtype;
  p public.subject_student_profiles%rowtype;
  v_result jsonb;
  v_prof_found boolean := false;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into r from public.subject_catalog where id = p_id for update;
  if not found then
    raise exception 'subject_not_found' using errcode = 'P0002';
  end if;
  select * into p from public.subject_student_profiles
  where subject_id = p_id for update;
  v_prof_found := found;

  if r.row_version is distinct from p_expected_catalog_row_version then
    raise exception 'row_version_conflict' using errcode = '40001';
  end if;
  if not v_prof_found then
    if coalesce(p_expected_profile_row_version, 0) <> 0 then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
  elsif p.row_version is distinct from p_expected_profile_row_version then
    raise exception 'row_version_conflict' using errcode = '40001';
  end if;

  v_result := public.admin_upsert_subject_card(
    r.id,
    p_expected_catalog_row_version,
    coalesce(p_expected_profile_row_version, 0),
    r.canonical_name,
    r.description,
    r.department,
    r.control_form,
    r.difficulty_label,
    r.requirements,
    r.learning_outcomes,
    coalesce(r.useful_links, '[]'::jsonb),
    p_status,
    case when v_prof_found then p.short_description end,
    case when v_prof_found then p.what_to_expect end,
    case when v_prof_found then p.how_to_pass end,
    case when v_prof_found then p.useful_materials_note end,
    case when v_prof_found then p.common_pitfalls end,
    case when v_prof_found then p.relevance_date end,
    case when v_prof_found then coalesce(p.section_order, '[]'::jsonb)
         else '[]'::jsonb end
  );
  return (v_result->>'id')::uuid;
end;
$$;

do $$
begin
  if to_regprocedure('public.admin_set_subject_status(uuid,text)') is not null then
    revoke all on function public.admin_set_subject_status(uuid, text)
      from public, anon, authenticated, service_role;
    drop function public.admin_set_subject_status(uuid, text);
  end if;
end $$;

revoke all on function public.admin_set_subject_status(uuid, text, integer, integer)
  from public, anon;
grant execute on function public.admin_set_subject_status(uuid, text, integer, integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Restore with required expected versions
-- ---------------------------------------------------------------------------
create or replace function public.admin_restore_subject_version(
  p_id uuid,
  p_version_number integer,
  p_expected_catalog_row_version integer,
  p_expected_profile_row_version integer
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s jsonb;
  v_result jsonb;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select snapshot into s
  from public.subject_versions
  where subject_id = p_id and version_number = p_version_number;
  if s is null then
    raise exception 'version_not_found' using errcode = 'P0002';
  end if;

  v_result := public.admin_upsert_subject_card(
    p_id,
    p_expected_catalog_row_version,
    p_expected_profile_row_version,
    coalesce(s->>'canonical_name', ''),
    s->>'description',
    s->>'department',
    s->>'control_form',
    s->>'difficulty_label',
    s->>'requirements',
    s->>'learning_outcomes',
    coalesce(s->'useful_links', '[]'::jsonb),
    coalesce(s->>'status', 'draft'),
    s->>'short_description',
    s->>'what_to_expect',
    s->>'how_to_pass',
    s->>'useful_materials_note',
    s->>'common_pitfalls',
    nullif(s->>'relevance_date', '')::date,
    coalesce(s->'section_order', '[]'::jsonb)
  );

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'subject.restore',
      'subject_catalog',
      p_id::text,
      jsonb_build_object(
        'restored_version_number', p_version_number,
        'catalog_row_version', v_result->'catalog_row_version',
        'profile_row_version', v_result->'profile_row_version',
        'version_number', v_result->'version_number'
      )
    );
  end if;

  return (v_result->>'id')::uuid;
end;
$$;

do $$
begin
  if to_regprocedure('public.admin_restore_subject_version(uuid,integer)') is not null then
    revoke all on function public.admin_restore_subject_version(uuid, integer)
      from public, anon, authenticated, service_role;
    drop function public.admin_restore_subject_version(uuid, integer);
  end if;
end $$;

revoke all on function public.admin_restore_subject_version(uuid, integer, integer, integer)
  from public, anon;
grant execute on function public.admin_restore_subject_version(uuid, integer, integer, integer)
  to authenticated, service_role;

create or replace function public.admin_restore_offering_student_profile(
  p_subject_offering_id uuid,
  p_version_number integer,
  p_expected_row_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s jsonb;
  v_result jsonb;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  perform 1
  from public.subject_offerings
  where id = p_subject_offering_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select snapshot into s
  from public.subject_offering_profile_versions
  where subject_offering_id = p_subject_offering_id
    and version_number = p_version_number;
  if s is null then
    raise exception 'version_not_found' using errcode = 'P0002';
  end if;

  v_result := public.admin_upsert_offering_student_profile(
    p_subject_offering_id,
    p_expected_row_version,
    s->>'local_description',
    s->>'teacher_specific_note',
    s->>'assessment_note',
    s->>'workload_note',
    s->>'semester_tips',
    coalesce(s->>'moderation_status', 'draft')
  );

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'offering_profile.restore',
      'subject_offering_student_profile',
      coalesce(v_result->>'id', p_subject_offering_id::text),
      jsonb_build_object(
        'subject_offering_id', p_subject_offering_id,
        'restored_version_number', p_version_number,
        'new_row_version', v_result->'row_version',
        'new_version_number', v_result->'version_number'
      )
    );
  end if;

  return v_result || jsonb_build_object(
    'restored_from_version', p_version_number
  );
end;
$$;

do $$
begin
  if to_regprocedure(
    'public.admin_restore_offering_student_profile(uuid,integer)'
  ) is not null then
    revoke all on function public.admin_restore_offering_student_profile(uuid, integer)
      from public, anon, authenticated, service_role;
    drop function public.admin_restore_offering_student_profile(uuid, integer);
  end if;
end $$;

revoke all on function public.admin_restore_offering_student_profile(uuid, integer, integer)
  from public, anon;
grant execute on function public.admin_restore_offering_student_profile(uuid, integer, integer)
  to authenticated, service_role;
