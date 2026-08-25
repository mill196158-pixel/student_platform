-- Stage 19.1b Slice 1 group-recognition role-play.
-- ROLLBACK-SAFE: all fixtures remain inside this transaction.

begin;

create temporary table group_recognition_results(
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
  insert into group_recognition_results values (
    p_scenario,
    coalesce(p_passed, false),
    coalesce(p_detail, '')
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

do $$
declare
  v_admin uuid;
  v_year uuid;
  v_program uuid;
  v_plan uuid;
  v_group uuid;
  v_preview jsonb;
  v_replay jsonb;
  v_rows jsonb;
  v_apply_blocked boolean := false;
  v_key_mismatch_blocked boolean := false;
  v_parser jsonb;
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(
      a.user_id, 'groups.write', 'global', null
    )
  limit 1;
  if v_admin is null then
    raise exception 'roleplay_requires_groups_write_admin';
  end if;
  perform pg_temp.as_user(v_admin);

  v_parser := private.parse_academic_group_name(
    ' 1—РПсб(ПГС)-2 ',
    'group-name-v1'
  );
  perform pg_temp.assert_result(
    'approved punctuation variants normalize deterministically',
    (v_parser ->> 'ok')::boolean
      and (v_parser ->> 'parallel_number')::integer = 1
      and v_parser ->> 'program_alias_key' = 'рпсбпгс'
      and (v_parser ->> 'course_number')::integer = 2
  );
  perform pg_temp.assert_result(
    'unapproved punctuation and unbalanced parentheses fail closed',
    not (private.parse_academic_group_name(
      '1-РПсб/ПГС-2', 'group-name-v1'
    ) ->> 'ok')::boolean
      and not (private.parse_academic_group_name(
        '1-РПсб.ПГС-2', 'group-name-v1'
      ) ->> 'ok')::boolean
      and not (private.parse_academic_group_name(
        '1-РПсб(ПГС-2', 'group-name-v1'
      ) ->> 'ok')::boolean
  );

  insert into public.academic_years(
    name, start_year, starts_on, ends_on, is_current
  ) values (
    '2099/2100 group recognition roleplay',
    2099,
    date '2099-09-01',
    date '2100-08-31',
    false
  ) returning id into v_year;

  v_program := public.admin_upsert_educational_program(
    p_direction_code => '19.1B',
    p_direction_name => 'Roleplay construction',
    p_profile_name => 'Roleplay PGS',
    p_qualification => 'bachelor',
    p_study_form => 'full_time',
    p_status => 'active'
  );
  v_plan := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program,
    p_admission_year => 2098,
    p_plan_code => '19.1B-PGS-2098',
    p_version_label => 'approved',
    p_nominal_semesters => 8,
    p_status => 'reviewed',
    p_parser_contract_version => 'curriculum-document-v2'
  );

  set local role service_role;
  insert into public.groups(name)
  values ('1-РПсбПГС-2')
  returning id into v_group;
  insert into public.educational_program_aliases(
    educational_program_id,
    alias_raw,
    alias_key,
    reviewed_by
  ) values (
    v_program,
    'РПсб(ПГС)',
    private.group_recognition_program_alias_key('РПсб(ПГС)'),
    v_admin
  );
  insert into public.group_name_aliases(
    group_id,
    alias_raw,
    alias_key,
    source,
    status
  ) values (
    v_group,
    '1-РПсбПГС-2',
    private.group_recognition_name_key('1-РПсбПГС-2'),
    'current_name',
    'active'
  );
  insert into public.group_academic_identities(
    group_id,
    educational_program_id,
    admission_year,
    parallel_number,
    reviewed_by
  ) values (
    v_group,
    v_program,
    2098,
    1,
    v_admin
  );
  reset role;
  perform pg_temp.as_user(v_admin);

  v_rows := jsonb_build_array(
      jsonb_build_object(
        'source_row_key', 'exact',
        'group_name', '1-рпсб(ПГС)-2'
      ),
      jsonb_build_object(
        'source_row_key', 'new',
        'group_name', '2-РПсбПГС-2'
      ),
      jsonb_build_object(
        'source_row_key', 'unknown-program',
        'group_name', '3-НЕИЗВЕСТНО-2'
      ),
      jsonb_build_object(
        'source_row_key', 'bad-shape',
        'group_name', 'РПсбПГС'
      )
    );
  v_preview := public.admin_group_recognition_start_preview(
    v_year,
    v_rows,
    'roleplay.xlsx',
    'group-recognition-roleplay'
  );

  perform pg_temp.assert_result(
    'preview derives admission year from selected academic year',
    (
      select bool_and((item ->> 'derived_admission_year')::integer = 2098)
      from jsonb_array_elements(v_preview -> 'items') item
      where item ->> 'source_row_key' in ('exact', 'new', 'unknown-program')
    )
  );
  perform pg_temp.assert_result(
    'current-name variant resolves exact group',
    (
      select item ->> 'classification' = 'exact_group'
        and (item -> 'candidate_group_ids') ? v_group::text
      from jsonb_array_elements(v_preview -> 'items') item
      where item ->> 'source_row_key' = 'exact'
    )
  );
  perform pg_temp.assert_result(
    'known program and reviewed plan produce new candidate',
    (
      select item ->> 'classification' = 'new_candidate'
        and (item -> 'candidate_plan_ids') ? v_plan::text
      from jsonb_array_elements(v_preview -> 'items') item
      where item ->> 'source_row_key' = 'new'
    )
  );
  perform pg_temp.assert_result(
    'unknown program and malformed name fail closed',
    (
      select count(*) = 2
      from jsonb_array_elements(v_preview -> 'items') item
      where item ->> 'classification'
        in ('program_unregistered', 'parser_blocked')
    )
  );
  perform pg_temp.assert_result(
    'slice remains preview-only',
    not (v_preview ->> 'apply_enabled')::boolean
      and v_preview ->> 'apply_blocker'
        = 'group_recognition_foundation_preview_only'
  );

  v_replay := public.admin_group_recognition_start_preview(
    v_year,
    v_rows,
    'roleplay.xlsx',
    'group-recognition-roleplay'
  );
  perform pg_temp.assert_result(
    'idempotency key replays original immutable preview',
    (v_replay ->> 'idempotent_replay')::boolean
      and v_replay ->> 'preview_id' = v_preview ->> 'preview_id'
      and jsonb_array_length(v_replay -> 'items') = 4
  );

  begin
    perform public.admin_group_recognition_start_preview(
      v_year,
      jsonb_build_array(jsonb_build_object(
        'source_row_key', 'different-payload',
        'group_name', '4-НЕИЗВЕСТНО-2'
      )),
      'roleplay.xlsx',
      'group-recognition-roleplay'
    );
  exception when invalid_parameter_value then
    v_key_mismatch_blocked := true;
  end;
  perform pg_temp.assert_result(
    'idempotency key rejects a different payload',
    v_key_mismatch_blocked
  );

  begin
    perform public.admin_group_recognition_apply(
      (v_preview ->> 'preview_id')::uuid,
      'CONFIRM'
    );
  exception when feature_not_supported then
    v_apply_blocked := true;
  end;
  perform pg_temp.assert_result(
    'apply RPC is fail-closed',
    v_apply_blocked
  );

  perform pg_temp.assert_result(
    'anon cannot execute recognition RPCs',
    not has_function_privilege(
      'anon',
      'public.admin_group_recognition_start_preview(uuid,jsonb,text,text,text)',
      'EXECUTE'
    )
      and not has_function_privilege(
        'anon',
        'public.admin_group_recognition_apply(uuid,text)',
        'EXECUTE'
      )
  );
end;
$$;

do $$
declare
  v_failed text;
begin
  select string_agg(scenario || ': ' || detail, '; ' order by scenario)
    into v_failed
  from group_recognition_results
  where not passed;
  if v_failed is not null then
    raise exception 'group recognition roleplay failed: %', v_failed;
  end if;
end;
$$;

select scenario, passed, detail
from group_recognition_results
order by scenario;

rollback;
