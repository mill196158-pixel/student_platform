-- Stage 19.1a curriculum-plan persistence role-play.
-- ROLLBACK-SAFE: all fixtures and applies are inside this transaction.

begin;

create temporary table academic_plan_persistence_results(
  scenario text primary key,
  passed boolean not null,
  detail text not null default ''
) on commit drop;

create or replace function pg_temp.assert_result(
  p_scenario text,
  p_passed boolean,
  p_detail text default ''
)
returns void
language plpgsql
as $$
begin
  insert into academic_plan_persistence_results values (
    p_scenario, coalesce(p_passed, false), coalesce(p_detail, '')
  );
end;
$$;

create or replace function pg_temp.as_user(p_user_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_user_id, 'role', 'authenticated')::text,
    true
  );
end;
$$;

create or replace function pg_temp.curriculum_row(
  p_source_subject_key text,
  p_occurrence_key text,
  p_subject_name text,
  p_subject_id uuid,
  p_semester integer,
  p_owner boolean,
  p_hours integer,
  p_credits numeric,
  p_assessments jsonb default '[]'::jsonb
)
returns jsonb
language sql
as $$
  select jsonb_build_object(
    'source_subject_key', p_source_subject_key,
    'source_occurrence_key', p_occurrence_key,
    'subject_name', p_subject_name,
    'reviewed_subject_id', p_subject_id,
    'subject_index', p_source_subject_key,
    'block_name', 'Блок 1',
    'semester_number', p_semester,
    'is_aggregate_owner', p_owner,
    'hours_total', p_hours,
    'credits', p_credits,
    'assessments', p_assessments,
    'reviewer_confirmed', true,
    'source_reviewed', true,
    'source_page', 1,
    'source_region', jsonb_build_object(
      'left', 1, 'top', 1, 'right', 10, 'bottom', 10
    ),
    'workload', jsonb_build_object('source_column_1', p_semester * 10),
    'source_parser_version', 'local-layout-v2',
    'blocking_issues', '[]'::jsonb,
    'unresolved_assessments', '[]'::jsonb
  );
$$;

create or replace function pg_temp.authenticated_dml_blocked(p_sql text)
returns boolean
language plpgsql
as $$
begin
  execute 'set local role authenticated';
  begin
    execute p_sql;
    execute 'reset role';
    return false;
  exception when insufficient_privilege then
    execute 'reset role';
    return true;
  end;
end;
$$;

do $$
declare
  v_admin uuid;
  v_other_admin uuid;
  v_program_full uuid;
  v_program_extra uuid;
  v_plan_full uuid;
  v_plan_extra uuid;
  v_subject uuid;
  v_ambiguous_subject uuid;
  v_legacy_before bigint;
  v_preview_full jsonb;
  v_preview_extra jsonb;
  v_apply_full jsonb;
  v_apply_extra jsonb;
  v_replay jsonb;
  v_duplicate jsonb;
  v_ambiguous jsonb;
  v_stale jsonb;
  v_omit_preview jsonb;
  v_omit_result jsonb;
  v_security_preview jsonb;
  v_hash_preview jsonb;
  v_bad_parser jsonb;
  v_bad_workload jsonb;
  v_stale_blocked boolean := false;
  v_confirmation_blocked boolean := false;
  v_cross_owner_blocked boolean := false;
  v_expired_blocked boolean := false;
  v_hash_blocked boolean := false;
  v_wrong_version_blocked boolean := false;
  v_plan_version integer;
  v_rows jsonb;
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(
      a.user_id, 'subjects.write', 'global', null
    )
  limit 1;
  if v_admin is null then
    raise exception 'roleplay_requires_subjects_write_admin';
  end if;
  perform pg_temp.as_user(v_admin);

  select count(*) into v_legacy_before
  from public.curriculum_subjects
  where curriculum_plan_id is null;

  insert into public.subject_catalog(canonical_name, normalized_name)
  values (
    'Stage 19.1a Roleplay Subject',
    'stage 19.1a roleplay subject'
  )
  returning id into v_subject;

  insert into public.subject_catalog(canonical_name, normalized_name)
  values (
    'Stage 19.1a Ambiguous Other',
    'stage 19.1a ambiguous other'
  )
  returning id into v_ambiguous_subject;
  insert into public.subject_aliases(
    subject_id, alias, normalized_alias, source
  ) values (
    v_ambiguous_subject,
    'Stage 19.1a Roleplay Subject',
    'stage 19.1a roleplay subject',
    'stage19_1a_roleplay'
  );

  v_program_full := public.admin_upsert_educational_program(
    p_direction_code => '19.1A',
    p_direction_name => 'Roleplay',
    p_profile_name => 'Persistence',
    p_qualification => 'test',
    p_study_form => 'full_time',
    p_status => 'draft'
  );
  v_program_extra := public.admin_upsert_educational_program(
    p_direction_code => '19.1A',
    p_direction_name => 'Roleplay',
    p_profile_name => 'Persistence',
    p_qualification => 'test',
    p_study_form => 'extramural',
    p_status => 'draft'
  );
  v_plan_full := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program_full,
    p_admission_year => 2026,
    p_plan_code => '19.1A-FULL',
    p_version_label => 'v2',
    p_nominal_semesters => 8,
    p_status => 'draft',
    p_parser_contract_version => 'curriculum-document-v2'
  );
  v_plan_extra := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program_extra,
    p_admission_year => 2026,
    p_plan_code => '19.1A-EXTRA',
    p_version_label => 'v2',
    p_nominal_semesters => 10,
    p_status => 'draft',
    p_parser_contract_version => 'curriculum-document-v2'
  );

  v_rows := jsonb_build_array(
    pg_temp.curriculum_row(
      'Б1.О.01', 'Б1.О.01|s1', 'Stage 19.1a Roleplay Subject',
      v_subject, 1, true, 108, 3,
      jsonb_build_array(
        jsonb_build_object(
          'type', 'exam', 'semester_number', 1, 'reviewer_confirmed', true
        ),
        jsonb_build_object(
          'type', 'course_work', 'semester_number', 1,
          'reviewer_confirmed', true
        )
      )
    ),
    pg_temp.curriculum_row(
      'Б1.О.01', 'Б1.О.01|s2', 'Stage 19.1a Roleplay Subject',
      v_subject, 2, false, null, null,
      jsonb_build_array(jsonb_build_object(
        'type', 'credit', 'semester_number', 2, 'reviewer_confirmed', true
      ))
    )
  );

  v_preview_full := public.admin_curriculum_plan_import_dry_run(
    v_plan_full, 'curriculum-document-v2', v_rows,
    'full.pdf', 'application/pdf', repeat('a', 64), true
  );
  v_apply_full := public.admin_curriculum_plan_import_apply(
    (v_preview_full ->> 'preview_id')::uuid,
    '19.1A-FULL'
  );
  perform pg_temp.assert_result(
    'same subject has separate occurrences',
    (v_apply_full -> 'summary' ->> 'inserted')::integer = 2
      and (
        select count(*) = 2
        from public.curriculum_subjects cs
        where cs.curriculum_plan_id = v_plan_full
          and cs.subject_id = v_subject
      )
  );
  perform pg_temp.assert_result(
    'exactly one aggregate owner and no duplicated workload',
    (
      select count(*) filter (where is_aggregate_owner) = 1
        and count(*) filter (
          where not is_aggregate_owner
            and (hours_total is not null or credits is not null)
        ) = 0
      from public.curriculum_subjects cs
      where cs.curriculum_plan_id = v_plan_full
        and cs.source_subject_key = 'Б1.О.01'
    )
  );
  perform pg_temp.assert_result(
    'display helper projects aggregate workload',
    (
      select count(*) = 2
        and min(display_hours_total) = 108
        and max(display_credits) = 3
      from public.curriculum_subject_occurrence_display cs
      where cs.curriculum_plan_id = v_plan_full
        and cs.source_subject_key = 'Б1.О.01'
    )
  );
  perform pg_temp.assert_result(
    'semester workload survives preview and apply',
    (
      select count(*) = 2
        and min((workload ->> 'source_column_1')::integer) = 10
        and max((workload ->> 'source_column_1')::integer) = 20
      from public.curriculum_subjects cs
      where cs.curriculum_plan_id = v_plan_full
        and cs.source_subject_key = 'Б1.О.01'
    )
  );
  perform pg_temp.assert_result(
    'multiple assessment types survive preview and apply',
    (
      select assessment_types = array['course_work', 'exam']::text[]
      from public.curriculum_subjects cs
      where cs.curriculum_plan_id = v_plan_full
        and cs.source_occurrence_key = 'Б1.О.01|s1'
    )
  );

  select row_version into v_plan_version
  from public.curriculum_plans where id = v_plan_extra;
  begin
    perform public.admin_curriculum_plan_import_dry_run_v2(
      v_plan_extra, v_plan_version + 1, 'curriculum-document-v2',
      jsonb_build_array(pg_temp.curriculum_row(
        'Б1.О.99', 'Б1.О.99|s1', 'Stage 19.1a Roleplay Subject',
        v_subject, 1, true, 36, 1
      )), true
    );
  exception when serialization_failure then
    v_wrong_version_blocked := true;
  end;
  perform pg_temp.assert_result(
    'v2 dry-run rejects an incorrect expected row version',
    v_wrong_version_blocked
  );

  v_replay := public.admin_curriculum_plan_import_apply(
    (v_preview_full ->> 'preview_id')::uuid,
    '19.1A-FULL'
  );
  perform pg_temp.assert_result(
    'applied preview replay is idempotent',
    (v_replay ->> 'idempotent_replay')::boolean
      and (v_replay -> 'summary' ->> 'inserted')::integer = 2
  );

  v_preview_extra := public.admin_curriculum_plan_import_dry_run(
    v_plan_extra, 'curriculum-document-v2',
    jsonb_build_array(v_rows -> 0),
    'extra.pdf', 'application/pdf', null, true
  );
  v_apply_extra := public.admin_curriculum_plan_import_apply(
    (v_preview_extra ->> 'preview_id')::uuid,
    '19.1A-EXTRA'
  );
  perform pg_temp.assert_result(
    'full-time and extramural source keys are isolated',
    (v_apply_extra -> 'summary' ->> 'inserted')::integer = 1
      and (
        select count(*) = 2
        from public.curriculum_subjects cs
        where cs.source_occurrence_key = 'Б1.О.01|s1'
          and cs.curriculum_plan_id in (v_plan_full, v_plan_extra)
      )
  );

  v_duplicate := public.admin_curriculum_plan_import_dry_run(
    v_plan_extra, 'curriculum-document-v2',
    jsonb_build_array(pg_temp.curriculum_row(
      'Б1.О.02', 'Б1.О.02|s2', 'Stage 19.1a Roleplay Subject',
      v_subject, 2, true, 72, 2,
      jsonb_build_array(
        jsonb_build_object(
          'type', 'credit', 'semester_number', 2, 'reviewer_confirmed', true
        ),
        jsonb_build_object(
          'type', 'credit', 'semester_number', 2, 'reviewer_confirmed', true
        )
      )
    )), '', null, null, true
  );
  perform pg_temp.assert_result(
    'duplicate assessments are blocked',
    not (v_duplicate ->> 'apply_enabled')::boolean
      and (v_duplicate -> 'summary' ->> 'blocked')::integer = 1
  );

  v_ambiguous := public.admin_curriculum_plan_import_dry_run(
    v_plan_extra, 'curriculum-document-v2',
    jsonb_build_array(
      pg_temp.curriculum_row(
        'Б1.О.03', 'Б1.О.03|s3', 'Stage 19.1a Roleplay Subject',
        null, 3, true, 72, 2, '[]'::jsonb
      ) - 'reviewed_subject_id'
    ), '', null, null, true
  );
  perform pg_temp.assert_result(
    'ambiguous catalog match is blocked',
    not (v_ambiguous ->> 'apply_enabled')::boolean
      and (
        v_ambiguous -> 'items' -> 0 -> 'errors'
      ) ? 'subject_match_ambiguous'
  );

  select row_version into v_plan_version
  from public.curriculum_plans where id = v_plan_extra;
  v_stale := public.admin_curriculum_plan_import_dry_run(
    v_plan_extra, 'curriculum-document-v2',
    jsonb_build_array(pg_temp.curriculum_row(
      'Б1.О.04', 'Б1.О.04|s4', 'Stage 19.1a Roleplay Subject',
      v_subject, 4, true, 72, 2, '[]'::jsonb
    )), '', null, null, true
  );
  update public.curriculum_plans
  set row_version = row_version + 1
  where id = v_plan_extra;
  begin
    perform public.admin_curriculum_plan_import_apply(
      (v_stale ->> 'preview_id')::uuid,
      '19.1A-EXTRA'
    );
  exception when serialization_failure then
    v_stale_blocked := true;
  end;
  perform pg_temp.assert_result(
    'stale preview is rejected cleanly',
    v_stale_blocked
  );

  select row_version into v_plan_version
  from public.curriculum_plans where id = v_plan_full;
  v_omit_preview := public.admin_curriculum_plan_import_dry_run(
    v_plan_full, 'curriculum-document-v2',
    jsonb_build_array(v_rows -> 0), '', null, null, true
  );
  v_omit_result := public.admin_curriculum_plan_import_apply(
    (v_omit_preview ->> 'preview_id')::uuid,
    '19.1A-FULL'
  );
  perform pg_temp.assert_result(
    'omitted existing occurrences are reported and preserved',
    (v_omit_result -> 'summary' ->> 'omitted')::integer = 1
      and (
        select count(*) = 2
        from public.curriculum_subjects cs
        where cs.curriculum_plan_id = v_plan_full
      )
  );

  perform pg_temp.assert_result(
    'public RPC grants and direct DML boundary are enforced',
    has_function_privilege(
      'authenticated',
      'public.admin_curriculum_plan_import_dry_run(uuid,text,jsonb,text,text,text,boolean)',
      'EXECUTE'
    )
      and has_function_privilege(
        'authenticated',
        'public.admin_curriculum_plan_import_apply(uuid,text)',
        'EXECUTE'
      )
      and not has_function_privilege(
        'anon',
        'public.admin_curriculum_plan_import_apply(uuid,text)',
        'EXECUTE'
      )
      and not has_function_privilege(
        'anon',
        'public.admin_curriculum_plan_import_dry_run_v2(uuid,integer,text,jsonb,boolean,text,text,text)',
        'EXECUTE'
      )
      and not has_function_privilege(
        'anon',
        'public.admin_curriculum_plan_import_apply_v2(uuid,text)',
        'EXECUTE'
      )
      and pg_temp.authenticated_dml_blocked(
        'update public.curriculum_subjects set hours_total = hours_total where false'
      )
      and pg_temp.authenticated_dml_blocked(
        'update public.import_studio_batches set status = status where false'
      )
      and pg_temp.authenticated_dml_blocked(
        'update public.import_studio_rows set error_text = error_text where false'
      )
  );

  select row_version into v_plan_version
  from public.curriculum_plans where id = v_plan_extra;
  v_security_preview := public.admin_curriculum_plan_import_dry_run(
    v_plan_extra, 'curriculum-document-v2',
    jsonb_build_array(pg_temp.curriculum_row(
      'Б1.О.05', 'Б1.О.05|s5', 'Stage 19.1a Roleplay Subject',
      v_subject, 5, true, 36, 1, '[]'::jsonb
    )), '', null, null, true
  );
  begin
    perform public.admin_curriculum_plan_import_apply(
      (v_security_preview ->> 'preview_id')::uuid,
      'wrong plan code'
    );
  exception when invalid_parameter_value then
    v_confirmation_blocked := true;
  end;
  perform pg_temp.assert_result(
    'exact plan-code confirmation is required',
    v_confirmation_blocked
  );

  select a.user_id into v_other_admin
  from public.admin_role_assignments a
  where a.user_id <> v_admin
    and a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(
      a.user_id, 'subjects.write', 'global', null
    )
  limit 1;
  if v_other_admin is null then
    select u.id into v_other_admin
    from public.users u
    where u.id <> v_admin
      and not exists (
        select 1 from public.admin_role_assignments a
        where a.user_id = u.id
          and a.role_code = 'academic_editor'
          and a.scope_type = 'global'
      )
    order by u.created_at
    limit 1;
  end if;
  if v_other_admin is null then
    raise exception 'roleplay_requires_second_user';
  end if;
  if not private.has_admin_permission(
    v_other_admin, 'subjects.write', 'global', null
  ) then
    insert into public.admin_role_assignments(
      user_id, role_code, scope_type, scope_id, is_active, granted_by
    ) values (
      v_other_admin, 'academic_editor', 'global', null, true, v_admin
    );
  end if;
  perform pg_temp.as_user(v_other_admin);
  begin
    perform public.admin_curriculum_plan_import_apply(
      (v_security_preview ->> 'preview_id')::uuid,
      '19.1A-EXTRA'
    );
  exception when insufficient_privilege then
    v_cross_owner_blocked := true;
  end;
  perform pg_temp.as_user(v_admin);
  perform pg_temp.assert_result(
    'another operator cannot apply a preview',
    v_cross_owner_blocked
  );

  update public.import_studio_batches
  set preview_expires_at = now() - interval '1 second'
  where id = (v_security_preview ->> 'preview_id')::uuid;
  begin
    perform public.admin_curriculum_plan_import_apply(
      (v_security_preview ->> 'preview_id')::uuid,
      '19.1A-EXTRA'
    );
  exception when serialization_failure then
    v_expired_blocked := true;
  end;
  perform pg_temp.assert_result(
    'expired preview is rejected',
    v_expired_blocked
  );

  v_hash_preview := public.admin_curriculum_plan_import_dry_run(
    v_plan_extra, 'curriculum-document-v2',
    jsonb_build_array(pg_temp.curriculum_row(
      'Б1.О.06', 'Б1.О.06|s6', 'Stage 19.1a Roleplay Subject',
      v_subject, 6, true, 36, 1, '[]'::jsonb
    )), '', null, null, true
  );
  update public.import_studio_rows
  set mapped_payload = jsonb_set(
    mapped_payload, '{subject_name}', '"tampered"'::jsonb
  )
  where batch_id = (v_hash_preview ->> 'preview_id')::uuid;
  begin
    perform public.admin_curriculum_plan_import_apply(
      (v_hash_preview ->> 'preview_id')::uuid,
      '19.1A-EXTRA'
    );
  exception when serialization_failure then
    v_hash_blocked := true;
  end;
  perform pg_temp.assert_result(
    'stored payload hash tampering is rejected',
    v_hash_blocked
  );

  v_bad_parser := public.admin_curriculum_plan_import_dry_run(
    v_plan_extra, 'curriculum-document-v2',
    jsonb_build_array(
      jsonb_set(
        pg_temp.curriculum_row(
          'Б1.О.07', 'Б1.О.07|s7', 'Stage 19.1a Roleplay Subject',
          v_subject, 7, true, 36, 1, '[]'::jsonb
        ),
        '{source_parser_version}',
        '"unknown-parser"'::jsonb
      )
    ), '', null, null, true
  );
  perform pg_temp.assert_result(
    'unknown row parser provenance is rejected',
    not (v_bad_parser ->> 'apply_enabled')::boolean
      and (v_bad_parser -> 'items' -> 0 -> 'errors')
            ? 'invalid_row_provenance'
  );

  v_bad_workload := public.admin_curriculum_plan_import_dry_run(
    v_plan_extra, 'curriculum-document-v2',
    jsonb_build_array(
      jsonb_set(
        pg_temp.curriculum_row(
          'Б1.О.08', 'Б1.О.08|s8', 'Stage 19.1a Roleplay Subject',
          v_subject, 8, true, 36, 1, '[]'::jsonb
        ),
        '{workload}',
        '{"lecture_hours": -1}'::jsonb
      )
    ), '', null, null, true
  );
  perform pg_temp.assert_result(
    'invalid semester workload is rejected',
    not (v_bad_workload ->> 'apply_enabled')::boolean
      and (v_bad_workload -> 'items' -> 0 -> 'errors') ? 'invalid_workload'
  );

  perform pg_temp.assert_result(
    'legacy curriculum rows remain unchanged',
    (
      select count(*) from public.curriculum_subjects
      where curriculum_plan_id is null
    ) = v_legacy_before
  );
end;
$$;

select * from academic_plan_persistence_results order by scenario;

do $$
begin
  if exists (
    select 1 from academic_plan_persistence_results where not passed
  ) or (select count(*) from academic_plan_persistence_results) <> 16 then
    raise exception 'academic_plan_import_persistence_roleplay_failed';
  end if;
end;
$$;

rollback;
