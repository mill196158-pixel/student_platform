-- Stage 16.1 subject card foundation (LOCAL ONLY — do not remote apply).
-- Extends profiles with relevance_date/section_order/row_version,
-- offering override row_version, get_subject_card, admin upsert concurrency.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.subject_student_profiles
  add column if not exists relevance_date date null,
  add column if not exists section_order jsonb not null default '[]'::jsonb,
  add column if not exists row_version integer not null default 1;

alter table public.subject_catalog
  add column if not exists row_version integer not null default 1;

alter table public.subject_offering_student_profiles
  add column if not exists row_version integer not null default 1;

alter table public.subject_offering_student_profiles
  add column if not exists version_number integer not null default 1;

create table if not exists public.subject_offering_profile_versions (
  id uuid primary key default gen_random_uuid(),
  subject_offering_id uuid not null
    references public.subject_offerings(id) on delete cascade,
  version_number integer not null,
  snapshot jsonb not null,
  created_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (subject_offering_id, version_number)
);

alter table public.subject_offering_profile_versions enable row level security;
alter table public.subject_offering_profile_versions force row level security;
revoke all on table public.subject_offering_profile_versions from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Section order helper (SPEC allowlist)
-- ---------------------------------------------------------------------------
create or replace function private.normalize_subject_section_order(p_raw jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_allow text[] := array[
    'short_description','description','learning_outcomes','what_to_expect',
    'how_to_pass','requirements','useful_materials_note','useful_links',
    'common_pitfalls','teachers','hours_credits','relevance_date',
    'teacher_specific_note','assessment_note','workload_note'
  ];
  v_out text[] := '{}';
  v_seen text[] := '{}';
  v_key text;
begin
  if p_raw is null then
    return to_jsonb(v_allow);
  end if;
  if jsonb_typeof(p_raw) <> 'array' then
    raise exception 'invalid_section_order' using errcode = '22023';
  end if;
  if jsonb_array_length(p_raw) = 0 then
    return to_jsonb(v_allow);
  end if;
  for v_key in
    select jsonb_array_elements_text(p_raw)
  loop
    if v_key is null or btrim(v_key) = '' then
      raise exception 'invalid_section_order' using errcode = '22023';
    end if;
    if not (v_key = any(v_allow)) then
      raise exception 'unknown_section_order_key' using errcode = '22023';
    end if;
    if v_key = any(v_seen) then
      raise exception 'duplicate_section_order_key' using errcode = '22023';
    end if;
    v_out := v_out || v_key;
    v_seen := v_seen || v_key;
  end loop;
  foreach v_key in array v_allow loop
    if not (v_key = any(v_seen)) then
      v_out := v_out || v_key;
    end if;
  end loop;
  return to_jsonb(v_out);
end;
$$;

revoke all on function private.normalize_subject_section_order(jsonb)
  from public, anon, authenticated;
grant execute on function private.normalize_subject_section_order(jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- Blank → NULL
-- ---------------------------------------------------------------------------
create or replace function private.null_if_blank(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(coalesce(p, '')), '');
$$;

revoke all on function private.null_if_blank(text) from public, anon, authenticated;
grant execute on function private.null_if_blank(text) to service_role;

-- ---------------------------------------------------------------------------
-- Mobile: get_subject_card (merged, access-checked)
-- ---------------------------------------------------------------------------
create or replace function public.get_subject_card(p_subject_offering_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_offering public.subject_offerings%rowtype;
  v_cat public.subject_catalog%rowtype;
  v_prof public.subject_student_profiles%rowtype;
  v_o_prof public.subject_offering_student_profiles%rowtype;
  v_cs public.curriculum_subjects%rowtype;
  v_desc text;
  v_how text;
  v_hours numeric;
  v_credits numeric;
  v_teachers jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_subject_offering_id is null then
    raise exception 'invalid_offering' using errcode = '22023';
  end if;

  select * into v_offering
  from public.subject_offerings so
  where so.id = p_subject_offering_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- Access: active enrollment in offering's group.
  if not exists (
    select 1
    from public.student_enrollments se
    where se.user_id = v_uid
      and se.group_id = v_offering.group_id
      and se.status = 'active'
      and se.ended_at is null
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_cat
  from public.subject_catalog
  where id = v_offering.subject_id
    and status = 'published';
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_prof
  from public.subject_student_profiles
  where subject_id = v_offering.subject_id
    and moderation_status = 'published';
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_o_prof
  from public.subject_offering_student_profiles
  where subject_offering_id = p_subject_offering_id
    and moderation_status = 'published';

  if v_offering.curriculum_subject_id is not null then
    select * into v_cs
    from public.curriculum_subjects
    where id = v_offering.curriculum_subject_id;
  end if;

  v_desc := coalesce(
    private.null_if_blank(v_o_prof.local_description),
    private.null_if_blank(v_cat.description)
  );
  v_how := coalesce(
    private.null_if_blank(v_o_prof.semester_tips),
    private.null_if_blank(v_prof.how_to_pass)
  );
  v_hours := v_cs.hours_total;
  v_credits := v_cs.credits;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'full_name', coalesce(nullif(btrim(t.full_name), ''), 'Преподаватель')
      )
      order by t.full_name
    ),
    '[]'::jsonb
  )
  into v_teachers
  from public.offering_teachers ot
  join public.teachers t on t.id = ot.teacher_id
  where ot.subject_offering_id = p_subject_offering_id;

  return jsonb_build_object(
    'subject_id', v_offering.subject_id,
    'subject_offering_id', p_subject_offering_id,
    'canonical_name', v_cat.canonical_name,
    'department', v_cat.department,
    'control_form', v_cat.control_form,
    'requirements', v_cat.requirements,
    'learning_outcomes', v_cat.learning_outcomes,
    'useful_links', coalesce(v_cat.useful_links, '[]'::jsonb),
    'short_description', v_prof.short_description,
    'what_to_expect', v_prof.what_to_expect,
    'useful_materials_note', v_prof.useful_materials_note,
    'common_pitfalls', v_prof.common_pitfalls,
    'relevance_date', v_prof.relevance_date,
    'section_order', private.normalize_subject_section_order(v_prof.section_order),
    'description', v_desc,
    'how_to_pass', v_how,
    'teacher_specific_note', private.null_if_blank(v_o_prof.teacher_specific_note),
    'assessment_note', private.null_if_blank(v_o_prof.assessment_note),
    'workload_note', private.null_if_blank(v_o_prof.workload_note),
    'hours_total', v_hours,
    'credits', v_credits,
    'hours_credits_available', (v_offering.curriculum_subject_id is not null),
    'teachers', coalesce(v_teachers, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_subject_card(uuid) from public, anon;
grant execute on function public.get_subject_card(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Admin: catalog+profile upsert with expected row versions (16.1 fields)
-- Keeps legacy admin_upsert_subject; new RPC for concurrent edits.
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
  v_profile_status := case
    when p_status = 'published' then 'published'
    when p_status = 'archived' then 'hidden'
    else 'draft'
  end;

  if p_id is null then
    insert into public.subject_catalog(
      canonical_name, normalized_name, description, department, control_form,
      difficulty_label, requirements, learning_outcomes, useful_links, status,
      row_version, updated_at, published_at, archived_at
    ) values (
      btrim(p_canonical_name), v_norm, p_description, p_department, p_control_form,
      p_difficulty_label, p_requirements, p_learning_outcomes,
      coalesce(p_useful_links, '[]'::jsonb), p_status,
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
  else
    select row_version into v_cat_ver
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
      useful_links = coalesce(p_useful_links, '[]'::jsonb),
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
  end if;

  select coalesce(max(version_number), 0) + 1 into v_version
  from public.subject_versions where subject_id = v_id;
  insert into public.subject_versions(subject_id, version_number, snapshot, created_by)
  values (
    v_id,
    v_version,
    jsonb_build_object(
      'subject_id', v_id,
      'canonical_name', btrim(p_canonical_name),
      'description', p_description,
      'department', p_department,
      'control_form', p_control_form,
      'requirements', p_requirements,
      'learning_outcomes', p_learning_outcomes,
      'useful_links', coalesce(p_useful_links, '[]'::jsonb),
      'status', p_status,
      'short_description', p_short_description,
      'what_to_expect', p_what_to_expect,
      'how_to_pass', p_how_to_pass,
      'useful_materials_note', p_useful_materials_note,
      'common_pitfalls', p_common_pitfalls,
      'relevance_date', p_relevance_date,
      'section_order', v_order,
      'catalog_row_version', v_cat_ver,
      'profile_row_version', v_prof_ver
    ),
    auth.uid()
  );

  return jsonb_build_object(
    'id', v_id,
    'catalog_row_version', v_cat_ver,
    'profile_row_version', v_prof_ver,
    'version_number', v_version
  );
end;
$$;

revoke all on function public.admin_upsert_subject_card(
  uuid, integer, integer, text, text, text, text, text, text, text, jsonb, text,
  text, text, text, text, text, date, jsonb
) from public, anon;
grant execute on function public.admin_upsert_subject_card(
  uuid, integer, integer, text, text, text, text, text, text, text, jsonb, text,
  text, text, text, text, text, date, jsonb
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Admin: set offering teachers by IDs (transactional replace)
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_offering_teachers(
  p_subject_offering_id uuid,
  p_teacher_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[] := coalesce(p_teacher_ids, '{}');
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_subject_offering_id is null then
    raise exception 'invalid_offering' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.subject_offerings where id = p_subject_offering_id
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  delete from public.offering_teachers
  where subject_offering_id = p_subject_offering_id;

  insert into public.offering_teachers(subject_offering_id, teacher_id, role)
  select p_subject_offering_id, t.id, 'lecturer'
  from unnest(v_ids) as t(id)
  where exists (select 1 from public.teachers x where x.id = t.id);

  return jsonb_build_object(
    'subject_offering_id', p_subject_offering_id,
    'teacher_ids', coalesce(
      (select jsonb_agg(ot.teacher_id) from public.offering_teachers ot
       where ot.subject_offering_id = p_subject_offering_id),
      '[]'::jsonb
    )
  );
end;
$$;

revoke all on function public.admin_set_offering_teachers(uuid, uuid[])
  from public, anon;
grant execute on function public.admin_set_offering_teachers(uuid, uuid[])
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Card write lockdown.
--
-- The card tables keep their pre-existing SELECT grants and published-only read
-- policies from the Stage 13 line, because the new 16.1 columns are
-- student-facing card copy. WRITES must go through the RPCs above so
-- row_version, section_order validation and snapshots cannot be bypassed.
--
-- Load (hours_total / credits) is intentionally NOT stored here: the single
-- source of truth is curriculum_subjects, reached through the offering, and it
-- is surfaced only by get_subject_card.
-- ---------------------------------------------------------------------------
revoke insert, update, delete on table public.subject_student_profiles
  from public, anon, authenticated;
revoke insert, update, delete on table public.subject_offering_student_profiles
  from public, anon, authenticated;
revoke insert, update, delete on table public.subject_catalog
  from public, anon, authenticated;

grant select, insert, update, delete on table public.subject_student_profiles
  to service_role;
grant select, insert, update, delete on table public.subject_offering_student_profiles
  to service_role;
