-- Academic ingestion identity foundation role-play.
--
-- LOCAL/DISPOSABLE ONLY. Apply the foundation migration locally first.
-- The transaction always rolls back.

begin;

create temporary table academic_ingestion_roleplay_results (
  scenario text primary key,
  status text not null check (status in ('PASS', 'FAIL', 'SKIP')),
  detail text not null default ''
) on commit drop;

create or replace function pg_temp.rp_result(
  p_scenario text,
  p_ok boolean,
  p_detail text default ''
)
returns void
language plpgsql
as $fn$
begin
  insert into academic_ingestion_roleplay_results(scenario, status, detail)
  values (
    p_scenario,
    case when p_ok then 'PASS' else 'FAIL' end,
    coalesce(p_detail, '')
  )
  on conflict (scenario) do update
    set status = excluded.status,
        detail = excluded.detail;
end
$fn$;

create or replace function pg_temp.rp_skip(
  p_scenario text,
  p_detail text default ''
)
returns void
language plpgsql
as $fn$
begin
  insert into academic_ingestion_roleplay_results(scenario, status, detail)
  values (p_scenario, 'SKIP', coalesce(p_detail, ''))
  on conflict (scenario) do update
    set status = excluded.status,
        detail = excluded.detail;
end
$fn$;

create or replace function pg_temp.rp_as_user(p_user_id uuid)
returns void
language plpgsql
as $fn$
begin
  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', p_user_id::text,
      'role', 'authenticated'
    )::text,
    true
  );
end
$fn$;

create or replace function pg_temp.rp_admin_with(p_permissions text[])
returns uuid
language plpgsql
as $fn$
declare
  v_uid uuid;
begin
  select a.user_id
    into v_uid
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and not exists (
      select 1
      from unnest(p_permissions) as permission(code)
      where not private.has_admin_permission(
        a.user_id,
        permission.code,
        'global',
        null
      )
    )
  limit 1;
  return v_uid;
end
$fn$;

create or replace function pg_temp.rp_authenticated_dml_blocked(p_sql text)
returns boolean
language plpgsql
as $fn$
begin
  execute 'set local role authenticated';
  begin
    execute p_sql;
    execute 'reset role';
    return false;
  exception
    when insufficient_privilege then
      execute 'reset role';
      return true;
    when others then
      execute 'reset role';
      raise;
  end;
end
$fn$;

do $$
declare
  v_admin uuid;
  v_fixture_user uuid;
  v_program_full uuid;
  v_program_part uuid;
  v_plan_full uuid;
  v_plan_part uuid;
  v_dry_full jsonb;
  v_dry_part jsonb;
  v_dry_duplicate jsonb;
  v_legacy_count_before bigint;
  v_legacy_count_after bigint;
  v_group_id uuid;
  v_group_admission_year integer;
  v_group_nominal_semesters integer;
  v_group_max_semester integer;
  v_plan_for_group uuid;
  v_plan_invalid uuid;
  v_assigned uuid;
  v_case_variant_blocked boolean := false;
  v_contract_mismatch_blocked boolean := false;
  v_null_contract_blocked boolean := false;
  v_semester_overflow_blocked boolean := false;
begin
  if to_regclass('public.educational_programs') is null
     or to_regclass('public.curriculum_plans') is null then
    perform pg_temp.rp_result(
      'F0 foundation tables exist',
      false,
      'migration not applied'
    );
    return;
  end if;

  perform pg_temp.rp_result(
    'F0 foundation tables exist',
    true,
    ''
  );

  v_admin := pg_temp.rp_admin_with(
    array['subjects.write', 'groups.write']
  );
  if v_admin is null then
    select u.id
      into v_fixture_user
    from public.users u
    order by u.created_at
    limit 1;

    if v_fixture_user is not null then
      insert into public.admin_role_assignments(
        user_id,
        role_code,
        scope_type,
        scope_id,
        is_active,
        expires_at,
        granted_by
      )
      values (
        v_fixture_user,
        'academic_editor',
        'global',
        null,
        true,
        null,
        null
      )
      on conflict do nothing;
      v_admin := pg_temp.rp_admin_with(
        array['subjects.write', 'groups.write']
      );
    end if;
  end if;
  if v_admin is null then
    perform pg_temp.rp_result(
      'F1 RBAC fixture available',
      false,
      'no public.users row available for transactional academic_editor fixture'
    );
    return;
  end if;

  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_result('F1 RBAC fixture available', true, '');

  select count(*)
    into v_legacy_count_before
  from public.curriculum_subjects
  where curriculum_plan_id is null;

  v_program_full := public.admin_upsert_educational_program(
    p_direction_code => '08.03.01',
    p_direction_name => 'Строительство',
    p_profile_name => 'Промышленное и гражданское строительство',
    p_qualification => 'бакалавр',
    p_study_form => 'full_time',
    p_status => 'draft'
  );
  v_program_part := public.admin_upsert_educational_program(
    p_direction_code => '08.03.01',
    p_direction_name => 'Строительство',
    p_profile_name => 'Промышленное и гражданское строительство',
    p_qualification => 'бакалавр',
    p_study_form => 'extramural',
    p_status => 'draft'
  );

  perform pg_temp.rp_result(
    'F2 study form is part of program identity',
    v_program_full is not null
      and v_program_part is not null
      and v_program_full <> v_program_part,
    concat_ws(',', v_program_full::text, v_program_part::text)
  );

  v_plan_full := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program_full,
    p_admission_year => 2025,
    p_plan_code => '08.03.01_2025_2_ПГС',
    p_version_label => 'roleplay-v1',
    p_nominal_semesters => 8,
    p_status => 'draft',
    p_source_file_name => 'up_08.03.01_pgs_2025.pdf',
    p_source_mime_type => 'application/pdf',
    p_parser_contract_version => 'curriculum-document-v1'
  );
  v_plan_part := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program_part,
    p_admission_year => 2025,
    p_plan_code => '08.03.01_2025_ФБФО',
    p_version_label => 'roleplay-v1',
    p_nominal_semesters => 10,
    p_status => 'draft',
    p_source_file_name => 'fbfo.xlsx',
    p_source_mime_type =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    p_parser_contract_version => 'curriculum-document-v1'
  );

  perform pg_temp.rp_result(
    'F3 distinct plans coexist for one direction/profile',
    v_plan_full is not null
      and v_plan_part is not null
      and v_plan_full <> v_plan_part,
    concat_ws(',', v_plan_full::text, v_plan_part::text)
  );

  v_dry_full := public.admin_curriculum_plan_import_dry_run(
    v_plan_full,
    'curriculum-document-v1',
    jsonb_build_array(
      jsonb_build_object(
        'source_occurrence_key', 'Б1.О.01|s1',
        'subject_index', 'Б1.О.01',
        'subject_name', 'Физическая культура и спорт',
        'semester_number', 1,
        'credits', 2,
        'hours_total', 72,
        'source_page', 1,
        'source_region', jsonb_build_object(
          'left', 10,
          'top', 20,
          'right', 300,
          'bottom', 40
        )
      )
    )
  );
  v_dry_part := public.admin_curriculum_plan_import_dry_run(
    v_plan_part,
    'curriculum-document-v1',
    jsonb_build_array(
      jsonb_build_object(
        'source_occurrence_key', 'Б1.О.01|s1',
        'subject_index', 'Б1.О.01',
        'subject_name', 'Физическая культура и спорт',
        'semester_number', 1,
        'credits', 3,
        'hours_total', 108,
        'source_page', 1,
        'source_region', '{}'::jsonb
      )
    )
  );

  perform pg_temp.rp_result(
    'F4 same subject and semester are isolated by plan',
    (v_dry_full ->> 'ok')::boolean
      and (v_dry_part ->> 'ok')::boolean
      and v_dry_full -> 'summary' ->> 'new' = '1'
      and v_dry_part -> 'summary' ->> 'new' = '1',
    left(v_dry_full::text || ' / ' || v_dry_part::text, 700)
  );

  v_dry_duplicate := public.admin_curriculum_plan_import_dry_run(
    v_plan_full,
    'curriculum-document-v1',
    jsonb_build_array(
      jsonb_build_object(
        'source_occurrence_key', 'Б1.О.01|s1',
        'subject_index', 'Б1.О.01',
        'subject_name', 'Физическая культура и спорт',
        'semester_number', 1
      ),
      jsonb_build_object(
        'source_occurrence_key', 'Б1.О.01|s1',
        'subject_index', 'Б1.О.01',
        'subject_name', 'Физическая культура и спорт',
        'semester_number', 1
      )
    )
  );

  perform pg_temp.rp_result(
    'F5 duplicate occurrence is rejected within one plan',
    not (v_dry_duplicate ->> 'ok')::boolean
      and v_dry_duplicate -> 'summary' ->> 'duplicate' = '1',
    left(v_dry_duplicate::text, 700)
  );

  perform pg_temp.rp_result(
    'F6 plan-aware apply is absent/disabled',
    to_regprocedure(
      'public.admin_curriculum_plan_import_apply(uuid,text,jsonb)'
    ) is null
      and (v_dry_full ->> 'apply_enabled')::boolean = false,
    ''
  );

  select count(*)
    into v_legacy_count_after
  from public.curriculum_subjects
  where curriculum_plan_id is null;

  perform pg_temp.rp_result(
    'F7 legacy curriculum rows remain untouched',
    v_legacy_count_after = v_legacy_count_before,
    format(
      'before=%s after=%s',
      v_legacy_count_before,
      v_legacy_count_after
    )
  );

  select gap.group_id, gap.admission_year, gap.nominal_semesters
    into v_group_id, v_group_admission_year, v_group_nominal_semesters
  from public.group_academic_profiles gap
  where gap.curriculum_plan_id is null
  order by gap.created_at
  limit 1;

  if v_group_id is null then
    perform pg_temp.rp_skip(
      'F8 reviewed matching-year plan can be assigned to group',
      'no unassigned group academic profile fixture'
    );
  else
    v_plan_for_group := public.admin_upsert_curriculum_plan(
      p_educational_program_id => v_program_full,
      p_admission_year => v_group_admission_year,
      p_plan_code => 'roleplay-group-plan',
      p_version_label => 'roleplay-v1',
      p_nominal_semesters => v_group_nominal_semesters,
      p_status => 'reviewed',
      p_parser_contract_version => 'curriculum-document-v1'
    );
    v_assigned := public.admin_assign_group_curriculum_plan(
      v_group_id,
      v_plan_for_group,
      null
    );
    perform pg_temp.rp_result(
      'F8 reviewed matching-year plan can be assigned to group',
      v_assigned = v_plan_for_group
        and (
          select gap.curriculum_plan_id = v_plan_for_group
          from public.group_academic_profiles gap
          where gap.group_id = v_group_id
        ),
      ''
    );
  end if;

  perform pg_temp.rp_result(
    'F9 graduating legacy groups gain no semester mappings',
    not exists (
      select 1
      from public.group_academic_profiles gap
      join public.group_term_semesters gts
        on gts.group_id = gap.group_id
      where gap.nominal_semesters = 4
        and gts.semester_number > 4
    ),
    ''
  );

  begin
    perform public.admin_upsert_curriculum_plan(
      p_educational_program_id => v_program_full,
      p_admission_year => 2025,
      p_plan_code => '  08.03.01_2025_2_пгс  ',
      p_version_label => '  ROLEPLAY-V1 ',
      p_nominal_semesters => 8,
      p_status => 'draft',
      p_parser_contract_version => 'curriculum-document-v1'
    );
  exception
    when unique_violation then
      v_case_variant_blocked := true;
  end;
  perform pg_temp.rp_result(
    'F10 normalized plan identity blocks case/whitespace duplicate',
    v_case_variant_blocked,
    ''
  );

  begin
    perform public.admin_curriculum_plan_import_dry_run(
      v_plan_full,
      'curriculum-document-v2-unknown',
      '[]'::jsonb
    );
  exception
    when invalid_parameter_value then
      v_contract_mismatch_blocked := true;
  end;
  begin
    perform public.admin_upsert_curriculum_plan(
      p_educational_program_id => v_program_full,
      p_admission_year => 2025,
      p_plan_code => 'roleplay-null-contract',
      p_version_label => 'roleplay-v1',
      p_nominal_semesters => 8,
      p_status => 'draft',
      p_parser_contract_version => null
    );
  exception
    when invalid_parameter_value then
      v_null_contract_blocked := true;
  end;
  perform pg_temp.rp_result(
    'F11 mismatched parser contract is rejected',
    v_contract_mismatch_blocked and v_null_contract_blocked,
    ''
  );

  perform pg_temp.rp_result(
    'F12 authenticated direct curriculum DML is denied',
    pg_temp.rp_authenticated_dml_blocked(
      'update public.curriculum_subjects '
      || 'set curriculum_plan_id = null where false'
    ),
    ''
  );
  if v_group_id is not null then
    perform pg_temp.rp_result(
      'F13 authenticated direct group-plan DML is denied',
      pg_temp.rp_authenticated_dml_blocked(
        format(
          'update public.group_academic_profiles '
          || 'set curriculum_plan_id = null where group_id = %L::uuid',
          v_group_id
        )
      ),
      ''
    );

    select max(gts.semester_number)
      into v_group_max_semester
    from public.group_term_semesters gts
    where gts.group_id = v_group_id;

    if coalesce(v_group_max_semester, 0) > 1 then
      update public.group_academic_profiles
      set nominal_semesters = v_group_max_semester - 1,
          curriculum_plan_id = null
      where group_id = v_group_id;

      v_plan_invalid := public.admin_upsert_curriculum_plan(
        p_educational_program_id => v_program_full,
        p_admission_year => v_group_admission_year,
        p_plan_code => 'roleplay-semester-overflow',
        p_version_label => 'roleplay-v1',
        p_nominal_semesters => v_group_max_semester - 1,
        p_status => 'reviewed',
        p_parser_contract_version => 'curriculum-document-v1'
      );

      begin
        perform public.admin_assign_group_curriculum_plan(
          v_group_id,
          v_plan_invalid,
          null
        );
      exception
        when invalid_parameter_value then
          v_semester_overflow_blocked := true;
      end;
      perform pg_temp.rp_result(
        'F14 group semester above plan nominal blocks assignment',
        v_semester_overflow_blocked,
        format(
          'max_semester=%s plan_nominal=%s',
          v_group_max_semester,
          v_group_max_semester - 1
        )
      );
    else
      perform pg_temp.rp_result(
        'F14 group semester above plan nominal blocks assignment',
        false,
        'fixture group has no semester > 1'
      );
    end if;
  else
    perform pg_temp.rp_result(
      'F13 authenticated direct group-plan DML is denied',
      false,
      'no group fixture'
    );
    perform pg_temp.rp_result(
      'F14 group semester above plan nominal blocks assignment',
      false,
      'no group fixture'
    );
  end if;
end
$$;

select *
from academic_ingestion_roleplay_results
order by scenario;

do $$
begin
  if exists (
    select required.scenario
    from unnest(array[
      'F0 foundation tables exist',
      'F1 RBAC fixture available',
      'F2 study form is part of program identity',
      'F3 distinct plans coexist for one direction/profile',
      'F4 same subject and semester are isolated by plan',
      'F5 duplicate occurrence is rejected within one plan',
      'F6 plan-aware apply is absent/disabled',
      'F7 legacy curriculum rows remain untouched',
      'F8 reviewed matching-year plan can be assigned to group',
      'F9 graduating legacy groups gain no semester mappings',
      'F10 normalized plan identity blocks case/whitespace duplicate',
      'F11 mismatched parser contract is rejected',
      'F12 authenticated direct curriculum DML is denied',
      'F13 authenticated direct group-plan DML is denied',
      'F14 group semester above plan nominal blocks assignment'
    ]) as required(scenario)
    left join academic_ingestion_roleplay_results actual
      on actual.scenario = required.scenario
    where actual.status is distinct from 'PASS'
  ) then
    raise exception 'academic_ingestion_identity_foundation_roleplay_failed';
  end if;
end
$$;

rollback;
