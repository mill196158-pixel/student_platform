-- Stage 16.1 P1 round-2: offering race-safety, version list/restore, restore audit.
-- LOCAL ONLY. Do not apply remotely without owner authorization.

-- ---------------------------------------------------------------------------
-- Race-safe offering override upsert (lock parent subject_offerings first)
-- ---------------------------------------------------------------------------
create or replace function public.admin_upsert_offering_student_profile(
  p_subject_offering_id uuid,
  p_expected_row_version integer,
  p_local_description text default null,
  p_teacher_specific_note text default null,
  p_assessment_note text default null,
  p_workload_note text default null,
  p_semester_tips text default null,
  p_moderation_status text default 'draft'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ver integer;
  v_version integer;
  v_id uuid;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_moderation_status not in ('draft', 'published', 'hidden') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  -- Stable parent row lock serializes concurrent first-insert races.
  perform 1
  from public.subject_offerings
  where id = p_subject_offering_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select id, row_version into v_id, v_ver
  from public.subject_offering_student_profiles
  where subject_offering_id = p_subject_offering_id
  for update;

  if not found then
    if coalesce(p_expected_row_version, 0) <> 0 then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
    begin
      insert into public.subject_offering_student_profiles(
        subject_offering_id, local_description, teacher_specific_note,
        assessment_note, workload_note, semester_tips, moderation_status,
        row_version, version_number, updated_by, updated_at
      ) values (
        p_subject_offering_id,
        private.null_if_blank(p_local_description),
        private.null_if_blank(p_teacher_specific_note),
        private.null_if_blank(p_assessment_note),
        private.null_if_blank(p_workload_note),
        private.null_if_blank(p_semester_tips),
        p_moderation_status,
        1, 1, auth.uid(), now()
      ) returning id, row_version, version_number into v_id, v_ver, v_version;
    exception
      when unique_violation then
        raise exception 'row_version_conflict' using errcode = '40001';
    end;
  else
    if v_ver is distinct from p_expected_row_version then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
    update public.subject_offering_student_profiles set
      local_description = private.null_if_blank(p_local_description),
      teacher_specific_note = private.null_if_blank(p_teacher_specific_note),
      assessment_note = private.null_if_blank(p_assessment_note),
      workload_note = private.null_if_blank(p_workload_note),
      semester_tips = private.null_if_blank(p_semester_tips),
      moderation_status = p_moderation_status,
      row_version = row_version + 1,
      version_number = version_number + 1,
      updated_by = auth.uid(),
      updated_at = now()
    where subject_offering_id = p_subject_offering_id
    returning id, row_version, version_number into v_id, v_ver, v_version;
  end if;

  insert into public.subject_offering_profile_versions(
    subject_offering_id, version_number, snapshot, created_by
  ) values (
    p_subject_offering_id,
    v_version,
    jsonb_build_object(
      'id', v_id,
      'subject_offering_id', p_subject_offering_id,
      'local_description', private.null_if_blank(p_local_description),
      'teacher_specific_note', private.null_if_blank(p_teacher_specific_note),
      'assessment_note', private.null_if_blank(p_assessment_note),
      'workload_note', private.null_if_blank(p_workload_note),
      'semester_tips', private.null_if_blank(p_semester_tips),
      'moderation_status', p_moderation_status,
      'row_version', v_ver
    ),
    auth.uid()
  );

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'offering_profile.upsert',
      'subject_offering_student_profile',
      v_id::text,
      jsonb_build_object(
        'subject_offering_id', p_subject_offering_id,
        'row_version', v_ver,
        'version_number', v_version
      )
    );
  end if;

  return jsonb_build_object(
    'id', v_id,
    'subject_offering_id', p_subject_offering_id,
    'row_version', v_ver,
    'version_number', v_version
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Offering profile version history + restore
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_offering_profile_versions(
  p_subject_offering_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.stage13_4_can_read_subjects() then
    return '[]'::jsonb;
  end if;
  if not exists (
    select 1 from public.subject_offerings where id = p_subject_offering_id
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'version_number', v.version_number,
          'created_at', v.created_at,
          'created_by', v.created_by,
          'snapshot', v.snapshot
        )
        order by v.version_number desc
      )
      from public.subject_offering_profile_versions v
      where v.subject_offering_id = p_subject_offering_id
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.admin_list_offering_profile_versions(uuid)
  from public, anon;
grant execute on function public.admin_list_offering_profile_versions(uuid)
  to authenticated, service_role;

create or replace function public.admin_restore_offering_student_profile(
  p_subject_offering_id uuid,
  p_version_number integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s jsonb;
  v_current integer;
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

  select coalesce(row_version, 0) into v_current
  from public.subject_offering_student_profiles
  where subject_offering_id = p_subject_offering_id
  for update;
  if not found then
    v_current := 0;
  end if;

  v_result := public.admin_upsert_offering_student_profile(
    p_subject_offering_id,
    v_current,
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

revoke all on function public.admin_restore_offering_student_profile(uuid, integer)
  from public, anon;
grant execute on function public.admin_restore_offering_student_profile(uuid, integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Catalog restore audit: distinct restore action with source version_number
-- ---------------------------------------------------------------------------
create or replace function public.admin_restore_subject_version(
  p_id uuid,
  p_version_number integer
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s jsonb;
  v_cat_ver integer;
  v_prof_ver integer;
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

  select coalesce(row_version, 1) into v_cat_ver
  from public.subject_catalog where id = p_id for update;
  if not found then
    raise exception 'subject_not_found' using errcode = 'P0002';
  end if;
  select coalesce(row_version, 1) into v_prof_ver
  from public.subject_student_profiles where subject_id = p_id for update;
  if not found then v_prof_ver := 0; end if;

  v_result := public.admin_upsert_subject_card(
    p_id,
    v_cat_ver,
    v_prof_ver,
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
