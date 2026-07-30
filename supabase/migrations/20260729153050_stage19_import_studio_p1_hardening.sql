-- Stage 19 Import Studio — P1 hardening (Codex CHANGES_REQUESTED round 2).
--
-- 1) Applied batch_key replay requires matching payload_hash.
-- 2) Dry-run mapped payloads align with Stage 13 delegated import contracts.
-- 3) admin_import_studio_apply fails closed when delegated apply reports errors/conflicts.

begin;

-- ---------------------------------------------------------------------------
-- Template columns: teachers accept spreadsheet aliases; mapped output uses
-- Stage 13 public-contact fields (contacts_public / public_email).
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_template(p_domain text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_domain
    when 'teachers' then array[
      'teacher_id', 'full_name', 'email', 'public_email', 'department',
      'position', 'academic_degree', 'about_text', 'website', 'office',
      'telegram'
    ]
    when 'subjects' then array[
      'subject_id', 'canonical_name', 'description', 'department', 'control_form',
      'difficulty_label', 'requirements', 'learning_outcomes', 'short_description',
      'what_to_expect', 'how_to_pass', 'useful_materials_note', 'useful_links',
      'common_pitfalls'
    ]
    when 'students' then array['login', 'name', 'surname', 'group_name']
    when 'groups' then array['name']
    when 'curriculum' then array[
      'group_name', 'subject_name', 'semester_number', 'credits',
      'hours_total', 'control_form', 'block_name', 'subject_index'
    ]
    when 'terms' then array[
      'academic_year_name', 'name', 'term_in_year', 'starts_on', 'ends_on'
    ]
    else array[]::text[]
  end;
$$;

-- ---------------------------------------------------------------------------
-- Row validator: mapped_payload must match delegated Stage 13 apply contracts.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_validate_row(
  p_domain text,
  p_row jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row jsonb := coalesce(p_row, '{}'::jsonb);
  v_allowed text[] := private.import_studio_template(p_domain);
  v_errors text[] := '{}'::text[];
  v_mapped jsonb := '{}'::jsonb;
  v_key text;
  v_bad text;
  v_class text := 'new';
  v_teacher uuid;
  v_subject uuid;
  v_user uuid;
  v_group uuid;
  v_num numeric;
  v_start date;
  v_end date;
  v_term integer;
  v_email text;
  v_contacts jsonb := '{}'::jsonb;
  v_links jsonb;
begin
  perform private.import_studio_assert_implemented(p_domain);

  if jsonb_typeof(v_row) <> 'object' then
    return jsonb_build_object(
      'classification', 'error',
      'mapped', '{}'::jsonb,
      'errors', to_jsonb(array['row_not_object']),
      'dedupe_key', null
    );
  end if;

  select string_agg(t.key, ',' order by t.key)
  into v_bad
  from jsonb_object_keys(v_row) as t(key)
  where not (t.key = any (v_allowed))
    and t.key <> 'contacts_public';
  if v_bad is not null then
    v_errors := array_append(v_errors, 'unknown_columns:' || v_bad);
  end if;

  if p_domain = 'teachers' then
    -- Canonical ID wins when present (no name-only match when ID is supplied).
    if nullif(btrim(coalesce(v_row ->> 'teacher_id', '')), '') is not null then
      begin
        select t.id into v_teacher
        from public.teachers t
        where t.id = (btrim(v_row ->> 'teacher_id'))::uuid;
        if v_teacher is null then
          v_errors := array_append(v_errors, 'teacher_id_not_found');
        else
          v_class := 'update';
          v_key := v_teacher::text;
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_teacher_id');
      end;
    else
      v_key := private.import_studio_norm(v_row ->> 'full_name');
      if v_key is null then
        v_errors := array_append(v_errors, 'full_name_required');
      else
        v_key := private.normalize_person_name(v_row ->> 'full_name');
        select t.id into v_teacher
        from public.teachers t
        where t.normalized_name = v_key
        limit 1;
        if v_teacher is not null then
          v_class := 'update';
        end if;
      end if;
    end if;

    if jsonb_typeof(v_row -> 'contacts_public') = 'object' then
      v_contacts := v_row -> 'contacts_public';
    else
      v_contacts := jsonb_strip_nulls(jsonb_build_object(
        'public_email', coalesce(
          nullif(btrim(v_row ->> 'public_email'), ''),
          nullif(btrim(v_row ->> 'email'), '')
        ),
        'website', nullif(btrim(v_row ->> 'website'), ''),
        'office', nullif(btrim(v_row ->> 'office'), ''),
        'telegram', nullif(btrim(v_row ->> 'telegram'), '')
      ));
    end if;

    v_email := nullif(btrim(v_contacts ->> 'public_email'), '');
    if v_email is not null
       and v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' then
      v_errors := array_append(v_errors, 'invalid_public_email');
    end if;

    -- Forward teacher_id + flat public_email for Stage 13 dry-run/apply match.
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'teacher_id', nullif(btrim(coalesce(v_row ->> 'teacher_id', '')), ''),
      'full_name', nullif(btrim(coalesce(v_row ->> 'full_name', '')), ''),
      'department', nullif(btrim(coalesce(v_row ->> 'department', '')), ''),
      'position', nullif(btrim(coalesce(v_row ->> 'position', '')), ''),
      'academic_degree', nullif(btrim(coalesce(v_row ->> 'academic_degree', '')), ''),
      'about_text', nullif(btrim(coalesce(v_row ->> 'about_text', '')), ''),
      'public_email', v_email,
      'contacts_public', case
        when v_contacts = '{}'::jsonb then null
        else v_contacts
      end
    ));

  elsif p_domain = 'subjects' then
    v_key := private.import_studio_norm(v_row ->> 'canonical_name');
    if v_key is null then
      v_errors := array_append(v_errors, 'canonical_name_required');
    else
      select sc.id into v_subject
      from public.subject_catalog sc
      where private.import_studio_norm(sc.normalized_name) = v_key
         or private.import_studio_norm(sc.canonical_name) = v_key
      limit 1;
      if v_subject is not null then
        v_class := 'update';
      end if;
    end if;

    v_links := case
      when jsonb_typeof(v_row -> 'useful_links') = 'array' then v_row -> 'useful_links'
      else '[]'::jsonb
    end;

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'subject_id', nullif(btrim(coalesce(v_row ->> 'subject_id', '')), ''),
      'canonical_name', nullif(btrim(coalesce(v_row ->> 'canonical_name', '')), ''),
      'description', nullif(btrim(coalesce(v_row ->> 'description', '')), ''),
      'department', nullif(btrim(coalesce(v_row ->> 'department', '')), ''),
      'control_form', nullif(btrim(coalesce(v_row ->> 'control_form', '')), ''),
      'difficulty_label', nullif(btrim(coalesce(v_row ->> 'difficulty_label', '')), ''),
      'requirements', nullif(btrim(coalesce(v_row ->> 'requirements', '')), ''),
      'learning_outcomes', nullif(btrim(coalesce(v_row ->> 'learning_outcomes', '')), ''),
      'short_description', nullif(btrim(coalesce(v_row ->> 'short_description', '')), ''),
      'what_to_expect', nullif(btrim(coalesce(v_row ->> 'what_to_expect', '')), ''),
      'how_to_pass', nullif(btrim(coalesce(v_row ->> 'how_to_pass', '')), ''),
      'useful_materials_note', nullif(btrim(coalesce(v_row ->> 'useful_materials_note', '')), ''),
      'common_pitfalls', nullif(btrim(coalesce(v_row ->> 'common_pitfalls', '')), ''),
      'useful_links', v_links
    ));

  elsif p_domain = 'students' then
    v_key := lower(btrim(coalesce(v_row ->> 'login', '')));
    if v_key = '' then
      v_key := null;
      v_errors := array_append(v_errors, 'login_required');
    else
      select u.id into v_user
      from public.users u
      where lower(u.login) = v_key
      limit 1;
      if v_user is null then
        v_errors := array_append(v_errors, 'user_not_found');
      else
        v_class := 'update';
      end if;
    end if;
    if nullif(btrim(coalesce(v_row ->> 'group_name', '')), '') is not null then
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
      limit 1;
      if v_group is null then
        v_errors := array_append(v_errors, 'group_not_found');
      end if;
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'login', v_key,
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), ''),
      'surname', nullif(btrim(coalesce(v_row ->> 'surname', '')), ''),
      'group_name', nullif(btrim(coalesce(v_row ->> 'group_name', '')), '')
    ));

  elsif p_domain = 'groups' then
    v_key := private.import_studio_norm(v_row ->> 'name');
    if v_key is null then
      v_errors := array_append(v_errors, 'name_required');
    else
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = v_key
      limit 1;
      if v_group is not null then
        v_class := 'update';
      end if;
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), '')
    ));

  elsif p_domain = 'curriculum' then
    v_key := private.import_studio_norm(
      coalesce(v_row ->> 'group_name', '') || '|' ||
      coalesce(v_row ->> 'subject_name', '') || '|' ||
      coalesce(v_row ->> 'semester_number', '')
    );
    if private.import_studio_norm(v_row ->> 'group_name') is null then
      v_errors := array_append(v_errors, 'group_name_required');
    else
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
      limit 1;
      if v_group is null then
        v_errors := array_append(v_errors, 'group_not_found');
      end if;
    end if;
    if private.import_studio_norm(v_row ->> 'subject_name') is null then
      v_errors := array_append(v_errors, 'subject_name_required');
    else
      select sc.id into v_subject
      from public.subject_catalog sc
      where private.import_studio_norm(sc.normalized_name)
              = private.import_studio_norm(v_row ->> 'subject_name')
         or private.import_studio_norm(sc.canonical_name)
              = private.import_studio_norm(v_row ->> 'subject_name')
      limit 1;
      if v_subject is null then
        v_errors := array_append(v_errors, 'subject_not_found');
      end if;
    end if;
    begin
      v_num := nullif(btrim(coalesce(v_row ->> 'semester_number', '')), '')::numeric;
    exception when others then
      v_num := null;
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end;
    if v_num is null then
      v_errors := array_append(v_errors, 'semester_number_required');
    elsif v_num <> trunc(v_num) or v_num < 1 or v_num > 12 then
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'group_id', v_group,
      'subject_id', v_subject,
      'semester_number', v_num,
      'credits', nullif(btrim(coalesce(v_row ->> 'credits', '')), ''),
      'hours_total', nullif(btrim(coalesce(v_row ->> 'hours_total', '')), ''),
      'control_form', nullif(btrim(coalesce(v_row ->> 'control_form', '')), ''),
      'block_name', nullif(btrim(coalesce(v_row ->> 'block_name', '')), ''),
      'subject_index', nullif(btrim(coalesce(v_row ->> 'subject_index', '')), '')
    ));

  else
    v_key := private.import_studio_norm(
      coalesce(v_row ->> 'academic_year_name', '') || '|' || coalesce(v_row ->> 'name', '')
    );

    if v_row ? 'is_current' then
      v_errors := array_append(v_errors, 'current_term_flip_forbidden');
    end if;

    if private.import_studio_norm(v_row ->> 'name') is null then
      v_errors := array_append(v_errors, 'name_required');
    end if;
    if private.import_studio_norm(v_row ->> 'academic_year_name') is null then
      v_errors := array_append(v_errors, 'academic_year_name_required');
    end if;

    begin
      v_term := nullif(btrim(coalesce(v_row ->> 'term_in_year', '')), '')::integer;
    exception when others then
      v_term := null;
    end;
    if v_term is null or v_term not in (1, 2) then
      v_errors := array_append(v_errors, 'invalid_term_in_year');
    end if;

    begin
      v_start := nullif(btrim(coalesce(v_row ->> 'starts_on', '')), '')::date;
      v_end := nullif(btrim(coalesce(v_row ->> 'ends_on', '')), '')::date;
    exception when others then
      v_start := null;
      v_end := null;
      v_errors := array_append(v_errors, 'invalid_dates');
    end;
    if v_start is null or v_end is null then
      v_errors := array_append(v_errors, 'dates_required');
    elsif v_end < v_start then
      v_errors := array_append(v_errors, 'ends_before_starts');
    end if;

    if (v_start is not null
        and v_start between date '2026-08-01' and date '2026-12-31')
       or (
         coalesce(v_row ->> 'name', '') ilike '%2026%'
         and (
           coalesce(v_row ->> 'name', '') ilike '%осен%'
           or coalesce(v_row ->> 'name', '') ilike '%autumn%'
           or coalesce(v_row ->> 'name', '') ilike '%fall%'
         )
       ) then
      v_errors := array_append(v_errors, 'autumn_2026_forbidden');
    end if;

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'academic_year_name', nullif(btrim(coalesce(v_row ->> 'academic_year_name', '')), ''),
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), ''),
      'term_in_year', v_term,
      'starts_on', v_start,
      'ends_on', v_end
    ));
  end if;

  if coalesce(array_length(v_errors, 1), 0) > 0 then
    v_class := 'error';
  end if;

  return jsonb_build_object(
    'classification', v_class,
    'mapped', v_mapped,
    'errors', to_jsonb(v_errors),
    'dedupe_key', v_key,
    'matched_teacher_id', v_teacher,
    'matched_subject_id', v_subject,
    'matched_user_id', v_user,
    'matched_group_id', v_group
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Dry run: applied batch_key replay only when payload_hash matches.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_start_dry_run(
  p_domain text,
  p_rows jsonb,
  p_file_name text default '',
  p_batch_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_domain text := private.import_studio_assert_domain(
    nullif(btrim(coalesce(p_domain, '')), '')
  );
  v_rows jsonb := coalesce(p_rows, '[]'::jsonb);
  v_hash text;
  v_key text;
  v_batch public.import_studio_batches;
  v_row jsonb;
  v_result jsonb;
  v_n integer := 0;
  v_errors integer := 0;
  v_new integer := 0;
  v_update integer := 0;
  v_duplicate integer := 0;
  v_seen text[] := '{}'::text[];
  v_dedupe text;
  v_class text;
begin
  v_uid := private.import_studio_require_read(v_domain);

  if jsonb_typeof(v_rows) <> 'array' then
    raise exception 'invalid_rows' using errcode = '22023';
  end if;
  if jsonb_array_length(v_rows) = 0 then
    raise exception 'empty_rows' using errcode = '22023';
  end if;
  if jsonb_array_length(v_rows) > 5000 then
    raise exception 'too_many_rows' using errcode = '22023';
  end if;

  v_hash := md5(v_domain || ':' || v_rows::text);
  v_key := coalesce(nullif(btrim(coalesce(p_batch_key, '')), ''), v_hash);
  if char_length(v_key) > 120 then
    raise exception 'invalid_batch_key' using errcode = '22023';
  end if;

  select * into v_batch
  from public.import_studio_batches b
  where b.created_by = v_uid
    and b.domain = v_domain
    and b.batch_key = v_key
  for update;

  if found then
    if v_batch.status = 'applied' then
      if v_batch.payload_hash is distinct from v_hash then
        raise exception 'batch_key_payload_mismatch' using errcode = '22023';
      end if;
      return private.import_studio_batch_json(v_batch.id)
        || jsonb_build_object('already_applied', true);
    end if;
    delete from public.import_studio_rows where batch_id = v_batch.id;
    update public.import_studio_batches b set
      status = 'dry_run',
      file_name = left(coalesce(p_file_name, ''), 260),
      payload_hash = v_hash,
      created_by = v_uid,
      created_at = now(),
      applied_by = null,
      applied_at = null,
      delegated_result = '{}'::jsonb
    where b.id = v_batch.id
    returning * into v_batch;
  else
    insert into public.import_studio_batches (
      domain, status, batch_key, file_name, payload_hash, created_by
    ) values (
      v_domain, 'dry_run', v_key, left(coalesce(p_file_name, ''), 260), v_hash, v_uid
    )
    returning * into v_batch;
  end if;

  for v_row in select value from jsonb_array_elements(v_rows) loop
    v_n := v_n + 1;
    v_result := private.import_studio_validate_row(v_domain, v_row);
    v_class := v_result ->> 'classification';
    v_dedupe := v_result ->> 'dedupe_key';

    if v_dedupe is not null and v_dedupe = any (v_seen) then
      v_class := 'duplicate';
    elsif v_dedupe is not null then
      v_seen := array_append(v_seen, v_dedupe);
    end if;

    insert into public.import_studio_rows (
      batch_id, row_number, classification, source_payload, mapped_payload,
      validation, error_text, dedupe_key, matched_teacher_id, matched_subject_id,
      matched_user_id, matched_group_id
    ) values (
      v_batch.id,
      v_n,
      v_class,
      v_row,
      coalesce(v_result -> 'mapped', '{}'::jsonb),
      jsonb_build_object('errors', coalesce(v_result -> 'errors', '[]'::jsonb)),
      left(
        nullif(
          (
            select string_agg(e.value #>> '{}', ',')
            from jsonb_array_elements(coalesce(v_result -> 'errors', '[]'::jsonb)) as e(value)
          ),
          ''
        ),
        500
      ),
      v_dedupe,
      nullif(v_result ->> 'matched_teacher_id', '')::uuid,
      nullif(v_result ->> 'matched_subject_id', '')::uuid,
      nullif(v_result ->> 'matched_user_id', '')::uuid,
      nullif(v_result ->> 'matched_group_id', '')::uuid
    );

    if v_class = 'error' then
      v_errors := v_errors + 1;
    elsif v_class = 'duplicate' then
      v_duplicate := v_duplicate + 1;
    elsif v_class = 'update' then
      v_update := v_update + 1;
    else
      v_new := v_new + 1;
    end if;
  end loop;

  update public.import_studio_batches b set
    row_count = v_n,
    error_count = v_errors,
    summary = jsonb_build_object(
      'total', v_n,
      'new', v_new,
      'update', v_update,
      'duplicate', v_duplicate,
      'error', v_errors,
      'payload_hash', v_hash
    )
  where b.id = v_batch.id
  returning * into v_batch;

  perform private.admin_write_audit(
    'import_studio.dry_run',
    'import_studio_batch',
    v_batch.id::text,
    jsonb_build_object(
      'domain', v_domain,
      'batch_key', v_key,
      'row_count', v_n,
      'error_count', v_errors,
      'file_name', left(coalesce(p_file_name, ''), 260)
    )
  );

  return private.import_studio_batch_json(v_batch.id)
    || jsonb_build_object('already_applied', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- Apply: inspect delegated Stage 13 result; fail closed on errors/conflicts.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_apply(
  p_batch_id uuid,
  p_confirm_batch_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_batch public.import_studio_batches;
  v_before jsonb;
  v_rows jsonb;
  v_fn text;
  v_signature text;
  v_result jsonb := '{}'::jsonb;
  v_errors integer := 0;
  v_conflicts integer := 0;
  v_failed boolean := false;
  v_fail_detail text := '';
begin
  select * into v_batch
  from public.import_studio_batches
  where id = p_batch_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_uid := private.import_studio_require_apply(v_batch.domain);
  perform private.import_studio_assert_owner(v_batch, v_uid);

  if nullif(btrim(coalesce(p_confirm_batch_key, '')), '') is distinct from v_batch.batch_key then
    raise exception 'batch_key_confirmation_mismatch' using errcode = '22023';
  end if;

  if v_batch.status = 'applied' then
    return private.import_studio_batch_json(p_batch_id)
      || jsonb_build_object('already_applied', true, 'idempotent_replay', true);
  end if;
  if v_batch.status <> 'dry_run' then
    raise exception 'batch_not_appliable' using errcode = '55000';
  end if;
  if not private.import_studio_supports_apply(v_batch.domain) then
    raise exception 'apply_not_supported_for_domain_%', v_batch.domain
      using errcode = '0A000';
  end if;
  if v_batch.error_count > 0 then
    raise exception 'batch_has_errors' using errcode = 'P0001';
  end if;
  if v_batch.row_count = 0 then
    raise exception 'empty_batch' using errcode = '22023';
  end if;

  v_before := private.import_studio_term_fingerprint();

  select coalesce(jsonb_agg(r.mapped_payload order by r.row_number), '[]'::jsonb)
  into v_rows
  from public.import_studio_rows r
  where r.batch_id = p_batch_id
    and r.classification in ('new', 'update');

  if jsonb_array_length(v_rows) = 0 then
    raise exception 'nothing_to_apply' using errcode = '22023';
  end if;

  v_fn := case v_batch.domain
    when 'teachers' then 'public.admin_teacher_import_apply'
    when 'subjects' then 'public.admin_subject_import_apply'
    else 'public.admin_student_import_apply'
  end;
  v_signature := v_fn || '(jsonb)';

  if to_regprocedure(v_signature) is null then
    raise exception 'domain_apply_rpc_missing_%', v_fn using errcode = '55000';
  end if;

  -- Nested subtransaction: roll back delegated domain mutations on failure,
  -- then persist failed status + audit outside the nested block.
  begin
    execute format('select %s($1)', v_fn) into v_result using v_rows;

    v_errors := coalesce((v_result ->> 'error')::integer, 0);
    v_conflicts := coalesce((v_result ->> 'conflict')::integer, 0);

    if v_errors > 0 or v_conflicts > 0 then
      raise exception 'delegated_apply_failed_inner'
        using errcode = 'P0001',
              detail = format('errors=%s conflicts=%s', v_errors, v_conflicts);
    end if;

    perform private.import_studio_assert_term_safety(v_before);
  exception
    when others then
      v_failed := true;
      v_fail_detail := coalesce(nullif(SQLERRM, ''), 'delegated_apply_failed');
      if v_result is null or v_result = '{}'::jsonb then
        v_result := jsonb_build_object(
          'error', greatest(v_errors, 1),
          'conflict', v_conflicts,
          'exception', v_fail_detail
        );
      else
        v_result := v_result || jsonb_build_object('exception', v_fail_detail);
      end if;
  end;

  if v_failed then
    update public.import_studio_batches b set
      status = 'failed',
      delegated_result = coalesce(v_result, '{}'::jsonb)
    where b.id = p_batch_id;

    perform private.admin_write_audit(
      'import_studio.apply_refused',
      'import_studio_batch',
      p_batch_id::text,
      jsonb_build_object(
        'domain', v_batch.domain,
        'delegated_to', v_fn,
        'error', coalesce((v_result ->> 'error')::integer, v_errors),
        'conflict', coalesce((v_result ->> 'conflict')::integer, v_conflicts),
        'delegated_result', coalesce(v_result, '{}'::jsonb)
      )
    );

    return private.import_studio_batch_json(p_batch_id)
      || jsonb_build_object(
        'ok', false,
        'already_applied', false,
        'delegated_apply_failed', true,
        'detail', v_fail_detail
      );
  end if;

  update public.import_studio_batches b set
    status = 'applied',
    applied_by = v_uid,
    applied_at = now(),
    delegated_result = coalesce(v_result, '{}'::jsonb)
  where b.id = p_batch_id
  returning * into v_batch;

  perform private.admin_write_audit(
    'import_studio.apply',
    'import_studio_batch',
    p_batch_id::text,
    jsonb_build_object(
      'domain', v_batch.domain,
      'row_count', v_batch.row_count,
      'delegated_to', v_fn
    )
  );

  return private.import_studio_batch_json(p_batch_id)
    || jsonb_build_object('ok', true, 'already_applied', false);
end;
$$;

commit;
