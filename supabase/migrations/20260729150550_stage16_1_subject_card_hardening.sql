-- Stage 16.1 hardening (LOCAL ONLY). Closes Codex P1 on foundation RPCs.
-- Depends on 20260729150500_stage16_1_subject_card_foundation.sql

-- ---------------------------------------------------------------------------
-- Enrich admin JSON (list/restore must return 16.1 fields + row versions)
-- ---------------------------------------------------------------------------
create or replace function private.stage13_4_subject_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(sc)
    || jsonb_build_object(
      'short_description', p.short_description,
      'what_to_expect', p.what_to_expect,
      'how_to_pass', p.how_to_pass,
      'useful_materials_note', p.useful_materials_note,
      'common_pitfalls', p.common_pitfalls,
      'relevance_date', p.relevance_date,
      'section_order', private.normalize_subject_section_order(p.section_order),
      'tags', coalesce(p.tags, '{}'::text[]),
      'profile_id', p.id,
      'catalog_row_version', sc.row_version,
      'profile_row_version', coalesce(p.row_version, 1),
      'related_teachers', private.stage13_4_related_teachers(sc.id)
    )
  from public.subject_catalog sc
  left join public.subject_student_profiles p on p.subject_id = sc.id
  where sc.id = p_id;
$$;

-- ---------------------------------------------------------------------------
-- Useful links validation (fail-closed)
-- ---------------------------------------------------------------------------
create or replace function private.normalize_subject_useful_links(p_links jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_elem jsonb;
  v_url text;
  v_title text;
begin
  if p_links is null then
    return '[]'::jsonb;
  end if;
  if jsonb_typeof(p_links) <> 'array' then
    raise exception 'invalid_useful_links' using errcode = '22023';
  end if;
  for v_elem in select * from jsonb_array_elements(p_links)
  loop
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'invalid_useful_links' using errcode = '22023';
    end if;
    v_url := nullif(btrim(coalesce(v_elem->>'url', '')), '');
    if v_url is null then
      raise exception 'invalid_useful_links' using errcode = '22023';
    end if;
    if v_url !~* '^https?://' then
      raise exception 'invalid_useful_links_scheme' using errcode = '22023';
    end if;
    v_title := coalesce(nullif(btrim(coalesce(v_elem->>'title', '')), ''), v_url);
    v_out := v_out || jsonb_build_array(
      jsonb_build_object('title', v_title, 'url', v_url)
    );
  end loop;
  return v_out;
end;
$$;

revoke all on function private.normalize_subject_useful_links(jsonb)
  from public, anon, authenticated;
grant execute on function private.normalize_subject_useful_links(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Hardened catalog+profile upsert
-- ---------------------------------------------------------------------------
create or replace function public.admin_upsert_subject_card(
  p_id uuid,
  p_expected_catalog_row_version integer,
  p_expected_profile_row_version integer,
  p_canonical_name text,
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
  p_relevance_date date default null,
  p_section_order jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_cat_ver integer;
  v_prof_ver integer;
  v_version integer;
  v_norm text;
  v_profile_status text;
  v_order jsonb;
  v_links jsonb;
  v_prev text;
  v_action text;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if btrim(coalesce(p_canonical_name, '')) = ''
     or p_status not in ('draft', 'published', 'archived') then
    raise exception 'invalid_subject' using errcode = '22023';
  end if;

  v_norm := private.normalize_person_name(p_canonical_name);
  v_order := private.normalize_subject_section_order(p_section_order);
  v_links := private.normalize_subject_useful_links(p_useful_links);
  v_profile_status := case
    when p_status = 'published' then 'published'
    when p_status = 'archived' then 'hidden'
    else 'draft'
  end;

  perform pg_advisory_xact_lock(('x' || substr(md5(v_norm), 1, 16))::bit(64)::bigint);
  if exists (
    select 1 from public.subject_catalog sc
    where sc.normalized_name = v_norm
      and (p_id is null or sc.id <> p_id)
  ) then
    raise exception 'duplicate_subject_name' using errcode = '23505';
  end if;

  begin
    if p_id is null then
      if coalesce(p_expected_catalog_row_version, 0) <> 0
         or coalesce(p_expected_profile_row_version, 0) <> 0 then
        raise exception 'row_version_conflict' using errcode = '40001';
      end if;
      insert into public.subject_catalog(
        canonical_name, normalized_name, description, department, control_form,
        difficulty_label, requirements, learning_outcomes, useful_links, status,
        row_version, updated_at, published_at, archived_at
      ) values (
        btrim(p_canonical_name), v_norm, p_description, p_department, p_control_form,
        p_difficulty_label, p_requirements, p_learning_outcomes, v_links, p_status,
        1, now(),
        case when p_status = 'published' then now() end,
        case when p_status = 'archived' then now() end
      ) returning id, row_version into v_id, v_cat_ver;

      insert into public.subject_student_profiles(
        subject_id, short_description, what_to_expect, how_to_pass,
        useful_materials_note, common_pitfalls, relevance_date, section_order,
        moderation_status, row_version, updated_by, updated_at
      ) values (
        v_id, p_short_description, p_what_to_expect, p_how_to_pass,
        p_useful_materials_note, p_common_pitfalls, p_relevance_date, v_order,
        v_profile_status, 1, auth.uid(), now()
      ) returning row_version into v_prof_ver;
      v_action := 'subject.create';
      v_prev := null;
    else
      select status, row_version into v_prev, v_cat_ver
      from public.subject_catalog where id = p_id for update;
      if not found then
        raise exception 'subject_not_found' using errcode = 'P0002';
      end if;
      if v_cat_ver is distinct from p_expected_catalog_row_version then
        raise exception 'row_version_conflict' using errcode = '40001';
      end if;

      update public.subject_catalog set
        canonical_name = btrim(p_canonical_name),
        normalized_name = v_norm,
        description = p_description,
        department = p_department,
        control_form = p_control_form,
        difficulty_label = p_difficulty_label,
        requirements = p_requirements,
        learning_outcomes = p_learning_outcomes,
        useful_links = v_links,
        status = p_status,
        row_version = row_version + 1,
        updated_at = now(),
        published_at = case
          when p_status = 'published' then coalesce(published_at, now())
          else published_at
        end,
        archived_at = case when p_status = 'archived' then now() else null end
      where id = p_id
      returning id, row_version into v_id, v_cat_ver;

      select row_version into v_prof_ver
      from public.subject_student_profiles where subject_id = p_id for update;
      if not found then
        if coalesce(p_expected_profile_row_version, 0) <> 0 then
          raise exception 'row_version_conflict' using errcode = '40001';
        end if;
        insert into public.subject_student_profiles(
          subject_id, short_description, what_to_expect, how_to_pass,
          useful_materials_note, common_pitfalls, relevance_date, section_order,
          moderation_status, row_version, updated_by, updated_at
        ) values (
          p_id, p_short_description, p_what_to_expect, p_how_to_pass,
          p_useful_materials_note, p_common_pitfalls, p_relevance_date, v_order,
          v_profile_status, 1, auth.uid(), now()
        ) returning row_version into v_prof_ver;
      else
        if v_prof_ver is distinct from p_expected_profile_row_version then
          raise exception 'row_version_conflict' using errcode = '40001';
        end if;
        update public.subject_student_profiles set
          short_description = p_short_description,
          what_to_expect = p_what_to_expect,
          how_to_pass = p_how_to_pass,
          useful_materials_note = p_useful_materials_note,
          common_pitfalls = p_common_pitfalls,
          relevance_date = p_relevance_date,
          section_order = v_order,
          moderation_status = v_profile_status,
          row_version = row_version + 1,
          updated_by = auth.uid(),
          updated_at = now()
        where subject_id = p_id
        returning row_version into v_prof_ver;
      end if;
      v_action := case
        when v_prev is distinct from p_status and p_status = 'archived' then 'subject.archive'
        when v_prev is distinct from p_status and p_status = 'published' then 'subject.publish'
        else 'subject.update'
      end;
    end if;
  exception when unique_violation then
    raise exception 'duplicate_subject_name' using errcode = '23505';
  end;

  select coalesce(max(version_number), 0) + 1 into v_version
  from public.subject_versions where subject_id = v_id;
  insert into public.subject_versions(subject_id, version_number, snapshot, created_by)
  values (v_id, v_version, private.stage13_4_subject_json(v_id), auth.uid());

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      v_action, 'subject', v_id::text,
      jsonb_build_object(
        'status', p_status,
        'prev_status', v_prev,
        'version_number', v_version,
        'catalog_row_version', v_cat_ver,
        'profile_row_version', v_prof_ver,
        'difficulty_label', p_difficulty_label
      )
    );
  end if;

  return jsonb_build_object(
    'id', v_id,
    'catalog_row_version', v_cat_ver,
    'profile_row_version', v_prof_ver,
    'version_number', v_version
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Legacy compatibility: route old upsert through hardened card RPC
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
  p_common_pitfalls text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cat_ver integer := 0;
  v_prof_ver integer := 0;
  v_result jsonb;
begin
  if p_id is not null then
    select coalesce(row_version, 1) into v_cat_ver
    from public.subject_catalog where id = p_id;
    if not found then
      raise exception 'subject_not_found' using errcode = 'P0002';
    end if;
    select coalesce(row_version, 1) into v_prof_ver
    from public.subject_student_profiles where subject_id = p_id;
    if not found then
      v_prof_ver := 0;
    end if;
  end if;

  v_result := public.admin_upsert_subject_card(
    p_id,
    v_cat_ver,
    v_prof_ver,
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
    null,
    '[]'::jsonb
  );
  return (v_result->>'id')::uuid;
end;
$$;

-- Restore must use full snapshot via card RPC (increments both row versions)
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
  return (v_result->>'id')::uuid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Offering teachers with concurrency + fail-loud unknown IDs
-- ---------------------------------------------------------------------------
alter table public.subject_offerings
  add column if not exists teachers_row_version integer not null default 1;

create or replace function public.admin_set_offering_teachers(
  p_subject_offering_id uuid,
  p_expected_teachers_row_version integer,
  p_teacher_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ver integer;
  v_ids uuid[];
  v_input_count integer;
  v_distinct_count integer;
  v_found_count integer;
  v_snap jsonb;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_subject_offering_id is null then
    raise exception 'invalid_offering' using errcode = '22023';
  end if;

  select teachers_row_version into v_ver
  from public.subject_offerings
  where id = p_subject_offering_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_ver is distinct from p_expected_teachers_row_version then
    raise exception 'row_version_conflict' using errcode = '40001';
  end if;

  v_ids := coalesce(p_teacher_ids, '{}');
  select coalesce(array_length(v_ids, 1), 0) into v_input_count;
  select count(distinct x) into v_distinct_count from unnest(v_ids) as x;
  if v_input_count <> v_distinct_count then
    raise exception 'duplicate_teacher_ids' using errcode = '22023';
  end if;
  select count(*) into v_found_count
  from public.teachers t
  where t.id = any(v_ids);
  if v_found_count <> v_distinct_count then
    raise exception 'unknown_teacher_id' using errcode = 'P0002';
  end if;

  delete from public.offering_teachers
  where subject_offering_id = p_subject_offering_id;

  insert into public.offering_teachers(subject_offering_id, teacher_id, role)
  select p_subject_offering_id, t.id, 'lecturer'
  from unnest(v_ids) as t(id);

  update public.subject_offerings
  set teachers_row_version = teachers_row_version + 1
  where id = p_subject_offering_id
  returning teachers_row_version into v_ver;

  select coalesce(jsonb_agg(ot.teacher_id order by ot.teacher_id), '[]'::jsonb)
  into v_snap
  from public.offering_teachers ot
  where ot.subject_offering_id = p_subject_offering_id;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'offering.teachers.set',
      'subject_offering',
      p_subject_offering_id::text,
      jsonb_build_object(
        'teacher_ids', v_snap,
        'teachers_row_version', v_ver
      )
    );
  end if;

  return jsonb_build_object(
    'subject_offering_id', p_subject_offering_id,
    'teacher_ids', v_snap,
    'teachers_row_version', v_ver
  );
end;
$$;

revoke all on function public.admin_set_offering_teachers(uuid, integer, uuid[])
  from public, anon;
grant execute on function public.admin_set_offering_teachers(uuid, integer, uuid[])
  to authenticated, service_role;

-- Drop old 2-arg signature if present
do $$
begin
  if to_regprocedure('public.admin_set_offering_teachers(uuid,uuid[])') is not null then
    revoke all on function public.admin_set_offering_teachers(uuid, uuid[])
      from public, anon, authenticated, service_role;
    drop function public.admin_set_offering_teachers(uuid, uuid[]);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Offering override upsert + restore
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
  if not exists (
    select 1 from public.subject_offerings where id = p_subject_offering_id
  ) then
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

revoke all on function public.admin_upsert_offering_student_profile(
  uuid, integer, text, text, text, text, text, text
) from public, anon;
grant execute on function public.admin_upsert_offering_student_profile(
  uuid, integer, text, text, text, text, text, text
) to authenticated, service_role;

create or replace function public.admin_list_subject_offerings(p_subject_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.stage13_4_can_read_subjects() then
    return '[]'::jsonb;
  end if;
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', so.id,
          'subject_id', so.subject_id,
          'group_id', so.group_id,
          'display_name', so.display_name,
          'status', so.status,
          'curriculum_subject_id', so.curriculum_subject_id,
          'hours_total', cs.hours_total,
          'credits', cs.credits,
          'teachers_row_version', so.teachers_row_version,
          'override_row_version', coalesce(op.row_version, 0),
          'override_status', op.moderation_status,
          'local_description', op.local_description,
          'teacher_specific_note', op.teacher_specific_note,
          'assessment_note', op.assessment_note,
          'workload_note', op.workload_note,
          'semester_tips', op.semester_tips,
          'teacher_ids', coalesce(
            (
              select jsonb_agg(ot.teacher_id order by ot.teacher_id)
              from public.offering_teachers ot
              where ot.subject_offering_id = so.id
            ),
            '[]'::jsonb
          )
        )
        order by so.created_at nulls last, so.id
      )
      from public.subject_offerings so
      left join public.curriculum_subjects cs on cs.id = so.curriculum_subject_id
      left join public.subject_offering_student_profiles op
        on op.subject_offering_id = so.id
      where so.subject_id = p_subject_id
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.admin_list_subject_offerings(uuid) from public, anon;
grant execute on function public.admin_list_subject_offerings(uuid)
  to authenticated, service_role;
