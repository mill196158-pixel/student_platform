-- Stage 19.1c: student-sourced group create/reuse with admission-year isolation.
--
-- A group appears when a real student is imported (or later from a schedule).
-- Identity is program + admission year + parallel, never the display name.
-- Course + selected academic year derive the usual admission year.
-- A record-book/login prefix like 26… is the usual confirmation of that year.
-- If the prefix and the course-derived year disagree (rare: admitted onto
-- course 2 in the current year), the row fails closed and is never merged
-- into the other cohort. This migration does not create Auth accounts and
-- never calls admin_upsert_group. Spaces appear only via existing enroll.

begin;

create or replace function private.student_import_record_book_year(p_login text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when v_prefix is null then null
    when (2000 + v_prefix) between 2000 and 2100 then 2000 + v_prefix
    else null
  end
  from (
    select nullif(
      (regexp_match(
        lower(btrim(coalesce(p_login, ''))),
        '^([0-9]{2})[-./]?[0-9]'
      ))[1],
      ''
    )::integer as v_prefix
  ) parsed;
$$;

revoke all on function private.student_import_record_book_year(text)
  from public, anon, authenticated;
grant execute on function private.student_import_record_book_year(text)
  to service_role;

create or replace function private.student_import_payload_hash(
  p_academic_year_id uuid,
  p_rows jsonb
)
returns text
language sql
immutable
set search_path = ''
as $$
  select md5(
    coalesce(p_academic_year_id::text, '')
    || chr(31)
    || coalesce(p_rows, '[]'::jsonb)::text
  );
$$;

revoke all on function private.student_import_payload_hash(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function private.student_import_payload_hash(uuid, jsonb)
  to service_role;

create or replace function private.student_import_resolve_group(
  p_academic_year_id uuid,
  p_group_name text,
  p_login text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_year public.academic_years%rowtype;
  v_parsed jsonb;
  v_name_key text;
  v_program_key text;
  v_parallel integer;
  v_course integer;
  v_derived integer;
  v_record_book integer;
  v_admission integer;
  v_program uuid;
  v_program_status text;
  v_group_ids uuid[] := '{}'::uuid[];
  v_plan_ids uuid[] := '{}'::uuid[];
  v_identity_years integer[] := '{}'::integer[];
  v_warnings jsonb := '[]'::jsonb;
  v_error text;
  v_action text;
begin
  if p_academic_year_id is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'academic_year_required',
      'warnings', v_warnings
    );
  end if;

  select * into v_year
  from public.academic_years ay
  where ay.id = p_academic_year_id;
  if not found then
    return jsonb_build_object(
      'ok', false,
      'error', 'academic_year_not_found',
      'warnings', v_warnings
    );
  end if;

  if nullif(btrim(coalesce(p_group_name, '')), '') is null then
    return jsonb_build_object(
      'ok', true,
      'error', null,
      'warnings', v_warnings,
      'group_action', null,
      'will_create', false
    );
  end if;

  v_parsed := private.parse_academic_group_name(p_group_name, 'group-name-v1');
  v_name_key := v_parsed ->> 'normalized_group_name';
  v_program_key := v_parsed ->> 'program_alias_key';
  v_parallel := nullif(v_parsed ->> 'parallel_number', '')::integer;
  v_course := nullif(v_parsed ->> 'course_number', '')::integer;
  v_derived := case
    when v_course is null then null
    else v_year.start_year - v_course + 1
  end;
  v_record_book := private.student_import_record_book_year(p_login);

  if coalesce((v_parsed ->> 'ok')::boolean, false) is false then
    return jsonb_build_object(
      'ok', false,
      'error', coalesce(v_parsed ->> 'error', 'group_name_shape_unrecognized'),
      'warnings', jsonb_build_array(v_parsed ->> 'error'),
      'normalized_group_name', v_name_key,
      'derived_admission_year', v_derived,
      'record_book_admission_year', v_record_book,
      'parser', v_parsed
    );
  end if;

  if v_record_book is null then
    v_warnings := v_warnings || jsonb_build_array('record_book_year_absent');
  elsif v_derived is not null and v_record_book <> v_derived then
    return jsonb_build_object(
      'ok', false,
      'error', 'record_book_admission_mismatch',
      'warnings', jsonb_build_array('record_book_admission_mismatch'),
      'normalized_group_name', v_name_key,
      'parallel_number', v_parallel,
      'course_number', v_course,
      'program_alias_key', v_program_key,
      'derived_admission_year', v_derived,
      'record_book_admission_year', v_record_book,
      'academic_year_start', v_year.start_year,
      'parser', v_parsed
    );
  end if;

  v_admission := v_derived;

  select a.educational_program_id, ep.status
    into v_program, v_program_status
  from public.educational_program_aliases a
  join public.educational_programs ep on ep.id = a.educational_program_id
  where a.alias_key = v_program_key
    and a.status = 'active';

  select coalesce(array_agg(distinct g.id order by g.id), '{}'::uuid[]),
         coalesce(
           array_agg(distinct i.admission_year)
             filter (where i.admission_year is not null),
           '{}'::integer[]
         )
    into v_group_ids, v_identity_years
  from public.groups g
  left join public.group_name_aliases a
    on a.group_id = g.id
   and a.status = 'active'
   and a.alias_key = v_name_key
  left join public.group_academic_identities i on i.group_id = g.id
  where private.group_recognition_name_key(g.name) = v_name_key
     or a.group_id is not null;

  if cardinality(v_group_ids) > 1 then
    v_error := 'group_alias_collision';
  elsif cardinality(v_group_ids) = 1 then
    if cardinality(v_identity_years) = 0 then
      v_error := 'group_identity_missing';
    elsif v_identity_years[1] is distinct from v_admission then
      v_error := 'group_admission_year_conflict';
    else
      v_action := 'reuse';
    end if;
  end if;

  if v_error is null and v_action is null then
    if v_program is null then
      v_error := 'program_alias_not_reviewed';
    elsif v_program_status is distinct from 'active' then
      v_error := 'educational_program_not_active';
    else
      select coalesce(array_agg(i.group_id order by i.group_id), '{}'::uuid[])
        into v_group_ids
      from public.group_academic_identities i
      where i.educational_program_id = v_program
        and i.admission_year = v_admission
        and i.parallel_number = v_parallel
        and i.distinct_discriminator = '';

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

      if cardinality(v_group_ids) > 1 then
        v_error := 'group_identity_collision';
      elsif cardinality(v_group_ids) = 1 then
        v_action := 'reuse';
      elsif cardinality(v_plan_ids) > 1 then
        v_error := 'multiple_plan_versions_require_choice';
      elsif cardinality(v_plan_ids) = 0 then
        v_error := 'matching_reviewed_plan_not_found';
      else
        v_action := 'create';
      end if;
    end if;
  elsif v_action = 'reuse' then
    select coalesce(array_agg(cp.id order by
      case cp.status when 'active' then 0 else 1 end,
      cp.version_label,
      cp.id
    ), '{}'::uuid[])
      into v_plan_ids
    from public.group_academic_profiles gap
    join public.curriculum_plans cp on cp.id = gap.curriculum_plan_id
    where gap.group_id = v_group_ids[1]
      and gap.active
      and cp.status in ('reviewed', 'active');
    if cardinality(v_plan_ids) = 0 and v_program is not null then
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
      if cardinality(v_plan_ids) = 0 then
        v_error := 'matching_reviewed_plan_not_found';
        v_action := null;
      elsif cardinality(v_plan_ids) > 1 then
        v_error := 'multiple_plan_versions_require_choice';
        v_action := null;
      end if;
    end if;
  end if;

  if v_error is not null then
    return jsonb_build_object(
      'ok', false,
      'error', v_error,
      'warnings', v_warnings || jsonb_build_array(v_error),
      'normalized_group_name', v_name_key,
      'parallel_number', v_parallel,
      'course_number', v_course,
      'program_alias_key', v_program_key,
      'educational_program_id', v_program,
      'derived_admission_year', v_derived,
      'record_book_admission_year', v_record_book,
      'admission_year', v_admission,
      'group_ids', to_jsonb(v_group_ids),
      'plan_ids', to_jsonb(v_plan_ids),
      'academic_year_start', v_year.start_year,
      'parser', v_parsed
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'error', null,
    'warnings', v_warnings,
    'normalized_group_name', v_name_key,
    'parallel_number', v_parallel,
    'course_number', v_course,
    'program_alias_key', v_program_key,
    'educational_program_id', v_program,
    'derived_admission_year', v_derived,
    'record_book_admission_year', v_record_book,
    'admission_year', v_admission,
    'group_id', case
      when cardinality(v_group_ids) = 1 then v_group_ids[1]
      else null
    end,
    'group_ids', to_jsonb(v_group_ids),
    'plan_id', case
      when cardinality(v_plan_ids) = 1 then v_plan_ids[1]
      else null
    end,
    'plan_ids', to_jsonb(v_plan_ids),
    'will_create', v_action = 'create',
    'group_action', v_action,
    'cache_key', concat_ws(
      ':',
      coalesce(v_program::text, ''),
      coalesce(v_admission::text, ''),
      coalesce(v_parallel::text, ''),
      coalesce(v_name_key, '')
    ),
    'academic_year_start', v_year.start_year,
    'parser', v_parsed
  );
end;
$$;

revoke all on function private.student_import_resolve_group(uuid, text, text)
  from public, anon, authenticated;
grant execute on function private.student_import_resolve_group(uuid, text, text)
  to service_role;

create or replace function private.student_import_classify_rows(
  p_academic_year_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_row jsonb;
  v_n integer := 0;
  v_items jsonb := '[]'::jsonb;
  v_login text;
  v_seen text[] := '{}';
  v_match uuid;
  v_class text;
  v_error text;
  v_resolved jsonb;
  v_warnings jsonb;
  v_cache jsonb := '{}'::jsonb;
  v_cache_key text;
  v_can_groups boolean := private.stage13_5_can('groups.write');
begin
  if p_academic_year_id is null
     or not exists (
       select 1 from public.academic_years ay where ay.id = p_academic_year_id
     ) then
    raise exception 'academic_year_required' using errcode = '22023';
  end if;

  for v_row in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    v_n := v_n + 1;
    v_login := lower(btrim(coalesce(v_row ->> 'login', '')));
    v_match := null;
    v_class := null;
    v_error := null;
    v_resolved := null;
    v_warnings := '[]'::jsonb;
    v_cache_key := null;

    if v_login = '' then
      v_class := 'error';
      v_error := 'login_required';
    elsif v_login = any(v_seen) then
      v_class := 'duplicate';
      v_error := 'duplicate_in_file';
    else
      select u.id into v_match
      from public.users u
      where lower(u.login) = v_login
        and private.stage13_5_is_student_account(u.id)
      limit 1;
      if v_match is null then
        v_class := 'error';
        if exists (
          select 1 from public.users u where lower(u.login) = v_login
        ) then
          v_error := 'not_a_student';
        else
          v_error := 'auth_user_missing';
        end if;
      elsif nullif(btrim(coalesce(v_row ->> 'group_name', '')), '') is null then
        v_class := 'update';
      else
        v_resolved := private.student_import_resolve_group(
          p_academic_year_id,
          v_row ->> 'group_name',
          v_login
        );
        v_warnings := coalesce(v_resolved -> 'warnings', '[]'::jsonb);
        v_cache_key := nullif(v_resolved ->> 'cache_key', '');
        if coalesce((v_resolved ->> 'ok')::boolean, false) is false then
          v_class := 'error';
          v_error := v_resolved ->> 'error';
        elsif coalesce((v_resolved ->> 'will_create')::boolean, false)
          and v_cache_key is not null
          and v_cache ? v_cache_key then
          v_class := 'update';
          v_resolved := v_resolved
            || jsonb_build_object(
              'will_create', false,
              'group_action', 'reuse',
              'same_file_pending_create', true
            );
        elsif coalesce((v_resolved ->> 'will_create')::boolean, false)
          and not v_can_groups then
          v_class := 'error';
          v_error := 'groups_write_required';
        else
          v_class := 'update';
          if coalesce((v_resolved ->> 'will_create')::boolean, false)
             and v_cache_key is not null then
            v_cache := v_cache || jsonb_build_object(v_cache_key, true);
          end if;
        end if;
      end if;
    end if;

    if v_login <> '' then
      v_seen := array_append(v_seen, v_login);
    end if;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'row_number', v_n,
      'classification', v_class,
      'matched_user_id', v_match,
      'error_text', v_error,
      'payload', v_row,
      'warnings', v_warnings,
      'group_resolution', v_resolved
    ));
  end loop;

  return jsonb_build_object(
    'rows', v_n,
    'items', v_items,
    'academic_year_id', p_academic_year_id
  );
end;
$$;

revoke all on function private.student_import_classify_rows(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function private.student_import_classify_rows(uuid, jsonb)
  to service_role;

create or replace function public.admin_student_import_dry_run(
  p_academic_year_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.stage13_5_can('students.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return private.student_import_classify_rows(p_academic_year_id, p_rows);
end;
$$;

create or replace function public.admin_student_import_apply(
  p_academic_year_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_hash text := private.student_import_payload_hash(p_academic_year_id, p_rows);
  v_batch uuid;
  v_dry jsonb;
  v_item jsonb;
  v_resolved jsonb;
  v_updated integer := 0;
  v_created integer := 0;
  v_reused integer := 0;
  v_errors integer := 0;
  v_conflicts integer := 0;
  v_user uuid;
  v_group uuid;
  v_plan uuid;
  v_name text;
  v_ok boolean;
begin
  if not private.stage13_5_can('students.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_uid is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select tb.id into v_batch
  from public.admin_term_ops_batches tb
  where tb.created_by = v_uid
    and tb.operation = 'student_import'
    and tb.status = 'applied'
    and tb.payload_hash = v_hash
  order by tb.created_at desc
  limit 1;
  if v_batch is not null then
    return jsonb_build_object(
      'batch_id', v_batch,
      'idempotent_replay', true,
      'summary', (
        select summary from public.admin_term_ops_batches where id = v_batch
      )
    );
  end if;

  v_dry := private.student_import_classify_rows(p_academic_year_id, p_rows);

  begin
    insert into public.admin_term_ops_batches(
      created_by, operation, status, payload_hash, summary
    ) values (
      v_uid, 'student_import', 'applied', v_hash,
      v_dry || jsonb_build_object(
        'payload_hash', v_hash,
        'academic_year_id', p_academic_year_id
      )
    )
    returning id into v_batch;
  exception when unique_violation then
    select tb.id into v_batch
    from public.admin_term_ops_batches tb
    where tb.created_by = v_uid
      and tb.operation = 'student_import'
      and tb.status = 'applied'
      and tb.payload_hash = v_hash
    order by tb.created_at desc
    limit 1;
    return jsonb_build_object(
      'batch_id', v_batch,
      'idempotent_replay', true,
      'summary', (
        select summary from public.admin_term_ops_batches where id = v_batch
      )
    );
  end;

  perform 1
  from public.academic_years ay
  where ay.id = p_academic_year_id
  for update;

  for v_item in
    select value
    from jsonb_array_elements(coalesce(v_dry -> 'items', '[]'::jsonb))
  loop
    insert into public.admin_term_ops_rows(
      batch_id, row_number, classification, payload, error_text
    ) values (
      v_batch,
      (v_item ->> 'row_number')::integer,
      v_item ->> 'classification',
      coalesce(v_item -> 'payload', '{}'::jsonb)
        || jsonb_build_object('group_resolution', v_item -> 'group_resolution'),
      v_item ->> 'error_text'
    );

    if v_item ->> 'classification' = 'duplicate' then
      v_conflicts := v_conflicts + 1;
      continue;
    end if;
    if v_item ->> 'classification' is distinct from 'update' then
      v_errors := v_errors + 1;
      continue;
    end if;

    v_user := nullif(v_item ->> 'matched_user_id', '')::uuid;
    v_ok := false;
    v_resolved := null;
    v_group := null;
    v_plan := null;
    begin
      perform public.admin_upsert_student_profile(
        v_user,
        v_item -> 'payload' ->> 'name',
        v_item -> 'payload' ->> 'surname',
        null
      );

      if nullif(btrim(coalesce(v_item -> 'payload' ->> 'group_name', '')), '')
         is not null then
        v_resolved := private.student_import_resolve_group(
          p_academic_year_id,
          v_item -> 'payload' ->> 'group_name',
          v_item -> 'payload' ->> 'login'
        );
        if coalesce((v_resolved ->> 'ok')::boolean, false) is false then
          raise exception '%', v_resolved ->> 'error' using errcode = 'P0001';
        end if;
        if coalesce((v_resolved ->> 'will_create')::boolean, false)
           and not private.stage13_5_can('groups.write') then
          raise exception 'groups_write_required' using errcode = '42501';
        end if;

        v_group := nullif(v_resolved ->> 'group_id', '')::uuid;
        v_plan := nullif(v_resolved ->> 'plan_id', '')::uuid;
        v_name := btrim(v_item -> 'payload' ->> 'group_name');

        if v_group is null and coalesce((v_resolved ->> 'will_create')::boolean, false) then
          insert into public.groups(name)
          values (v_name)
          returning id into v_group;
          insert into public.group_name_aliases(
            group_id, alias_raw, alias_key, source, status,
            reviewed_by, reviewed_at
          ) values (
            v_group,
            v_name,
            v_resolved ->> 'normalized_group_name',
            'import_review',
            'active',
            v_uid,
            now()
          );
          insert into public.group_academic_identities(
            group_id, educational_program_id, admission_year, parallel_number,
            reviewed_by, reviewed_at
          ) values (
            v_group,
            (v_resolved ->> 'educational_program_id')::uuid,
            (v_resolved ->> 'admission_year')::integer,
            (v_resolved ->> 'parallel_number')::integer,
            v_uid,
            now()
          );
          insert into public.group_academic_profiles(
            group_id, admission_year, nominal_semesters, active,
            curriculum_plan_id, created_at, updated_at
          )
          select
            v_group,
            (v_resolved ->> 'admission_year')::integer,
            cp.nominal_semesters,
            true,
            cp.id,
            now(),
            now()
          from public.curriculum_plans cp
          where cp.id = v_plan;
          if not found then
            raise exception 'matching_reviewed_plan_not_found'
              using errcode = 'P0002';
          end if;
        elsif v_group is not null then
          if exists (
            select 1
            from public.group_academic_identities i
            where i.group_id = v_group
              and i.admission_year is distinct from
                (v_resolved ->> 'admission_year')::integer
          ) then
            raise exception 'group_admission_year_conflict'
              using errcode = '40001';
          end if;
        else
          raise exception 'group_not_resolved' using errcode = 'P0002';
        end if;

        perform public.admin_assign_student_group(v_user, v_group);
      end if;
      v_ok := true;
      if v_resolved is not null
         and coalesce((v_resolved ->> 'will_create')::boolean, false) then
        v_created := v_created + 1;
      elsif v_group is not null then
        v_reused := v_reused + 1;
      end if;
    exception when others then
      v_ok := false;
      update public.admin_term_ops_rows
      set classification = 'error',
          error_text = sqlerrm
      where batch_id = v_batch
        and row_number = (v_item ->> 'row_number')::integer;
      v_errors := v_errors + 1;
    end;

    if v_ok then
      v_updated := v_updated + 1;
    end if;
  end loop;

  update public.admin_term_ops_batches
  set summary = v_dry || jsonb_build_object(
    'payload_hash', v_hash,
    'academic_year_id', p_academic_year_id,
    'updated', v_updated,
    'groups_created', v_created,
    'groups_reused', v_reused,
    'conflict', v_conflicts,
    'error', v_errors
  )
  where id = v_batch;

  return jsonb_build_object(
    'batch_id', v_batch,
    'idempotent_replay', false,
    'updated', v_updated,
    'groups_created', v_created,
    'groups_reused', v_reused,
    'conflict', v_conflicts,
    'error', v_errors
  );
end;
$$;

-- Legacy signature: profile-only stays available. Any group name now requires
-- the academic-year overload so different admission years cannot be guessed.
create or replace function public.admin_student_import_dry_run(p_rows jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row jsonb;
  v_n integer := 0;
  v_items jsonb := '[]'::jsonb;
  v_login text;
  v_seen text[] := '{}';
  v_match uuid;
  v_class text;
  v_error text;
begin
  if not private.stage13_5_can('students.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  for v_row in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    v_n := v_n + 1;
    v_login := lower(btrim(coalesce(v_row ->> 'login', '')));
    v_match := null;
    v_class := null;
    v_error := null;
    if v_login = '' then
      v_class := 'error';
      v_error := 'login_required';
    elsif v_login = any(v_seen) then
      v_class := 'duplicate';
      v_error := 'duplicate_in_file';
    else
      select u.id into v_match
      from public.users u
      where lower(u.login) = v_login
        and private.stage13_5_is_student_account(u.id)
      limit 1;
      if v_match is null then
        v_class := 'error';
        if exists (
          select 1 from public.users u where lower(u.login) = v_login
        ) then
          v_error := 'not_a_student';
        else
          v_error := 'auth_user_missing';
        end if;
      elsif nullif(btrim(coalesce(v_row ->> 'group_name', '')), '') is not null then
        v_class := 'error';
        v_error := 'academic_year_required';
      else
        v_class := 'update';
      end if;
    end if;
    if v_login <> '' then
      v_seen := array_append(v_seen, v_login);
    end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'row_number', v_n,
      'classification', v_class,
      'matched_user_id', v_match,
      'error_text', v_error,
      'payload', v_row
    ));
  end loop;
  return jsonb_build_object('rows', v_n, 'items', v_items);
end;
$$;

create or replace function public.admin_student_import_apply(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  dry jsonb;
  b uuid;
  item jsonb;
  updated integer := 0;
  errors integer := 0;
  conflicts integer := 0;
  v_payload_hash text := md5(coalesce(p_rows, '[]'::jsonb)::text);
  matched uuid;
begin
  if not private.stage13_5_can('students.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  dry := public.admin_student_import_dry_run(p_rows);
  if exists (
    select 1
    from jsonb_array_elements(coalesce(dry -> 'items', '[]'::jsonb)) item
    where item ->> 'error_text' = 'academic_year_required'
  ) then
    raise exception 'student_import_requires_academic_year'
      using errcode = '22023';
  end if;
  select tb.id into b from public.admin_term_ops_batches tb
  where tb.created_by = auth.uid() and tb.operation = 'student_import'
    and tb.status = 'applied' and tb.payload_hash = v_payload_hash
  order by tb.created_at desc limit 1;
  if b is not null then
    return jsonb_build_object('batch_id', b, 'idempotent_replay', true,
      'summary', (select summary from public.admin_term_ops_batches where id = b));
  end if;
  begin
    insert into public.admin_term_ops_batches(
      created_by, operation, status, payload_hash, summary
    ) values (
      auth.uid(), 'student_import', 'applied', v_payload_hash,
      dry || jsonb_build_object('payload_hash', v_payload_hash)
    )
    returning id into b;
  exception when unique_violation then
    select tb.id into b from public.admin_term_ops_batches tb
    where tb.created_by = auth.uid() and tb.operation = 'student_import'
      and tb.status = 'applied' and tb.payload_hash = v_payload_hash
    order by tb.created_at desc limit 1;
    return jsonb_build_object('batch_id', b, 'idempotent_replay', true,
      'summary', (select summary from public.admin_term_ops_batches where id = b));
  end;

  for item in select value from jsonb_array_elements(coalesce(dry->'items', '[]'::jsonb))
  loop
    insert into public.admin_term_ops_rows(
      batch_id, row_number, classification, payload, error_text
    ) values (
      b, (item->>'row_number')::integer, item->>'classification',
      coalesce(item->'payload', '{}'::jsonb), item->>'error_text'
    );
    if item->>'classification' = 'update' then
      matched := nullif(item->>'matched_user_id', '')::uuid;
      perform public.admin_upsert_student_profile(
        matched, item->'payload'->>'name', item->'payload'->>'surname', null
      );
      updated := updated + 1;
    elsif item->>'classification' = 'duplicate' then
      conflicts := conflicts + 1;
    else
      errors := errors + 1;
    end if;
  end loop;

  update public.admin_term_ops_batches
  set summary = dry || jsonb_build_object(
    'payload_hash', v_payload_hash, 'updated', updated,
    'conflict', conflicts, 'error', errors
  ) where id = b;

  return jsonb_build_object(
    'batch_id', b, 'idempotent_replay', false, 'updated', updated,
    'conflict', conflicts, 'error', errors
  );
end;
$$;

revoke all on function public.admin_student_import_dry_run(uuid, jsonb)
  from public, anon, authenticated;
revoke all on function public.admin_student_import_apply(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.admin_student_import_dry_run(uuid, jsonb)
  to authenticated, service_role;
grant execute on function public.admin_student_import_apply(uuid, jsonb)
  to authenticated, service_role;

commit;
