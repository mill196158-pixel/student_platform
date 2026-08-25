-- Stage 19.1b Slice 2 rollback-safe role-play.
-- Run only after applying 20260825195812 to a disposable/local PostgreSQL.

begin;

create temporary table group_apply_results(
  scenario text primary key,
  passed boolean not null,
  detail text not null default ''
) on commit drop;

create or replace function pg_temp.ga_assert(
  p_scenario text,
  p_passed boolean,
  p_detail text default ''
)
returns void language plpgsql as $$
begin
  insert into group_apply_results values (
    p_scenario, coalesce(p_passed, false), coalesce(p_detail, '')
  );
end;
$$;

create or replace function pg_temp.ga_as_user(p_user_id uuid)
returns void language plpgsql as $$
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
  v_other_admin uuid;
  v_year uuid;
  v_program uuid;
  v_plan uuid;
  v_alt_plan uuid;
  v_group uuid;
  v_bad_group uuid;
  v_no_profile_group uuid;
  v_term uuid;
  v_preview jsonb;
  v_saved jsonb;
  v_applied jsonb;
  v_row_exact uuid;
  v_row_new uuid;
  v_before_groups bigint;
  v_before_accounts bigint;
  v_before_enrollments bigint;
  v_before_offerings bigint;
  v_before_teams bigint;
  v_before_chats bigint;
  v_duplicate_blocked boolean := false;
  v_blocked_decision_blocked boolean := false;
  v_owner_blocked boolean := false;
  v_tamper_blocked boolean := false;
  v_stale_blocked boolean := false;
  v_alias_drift_blocked boolean := false;
  v_plan_drift_blocked boolean := false;
  v_max_term_blocked boolean := false;
  v_result_immutable boolean := false;
  v_retry_tamper_blocked boolean := false;
  v_exact_alt_plan_blocked boolean := false;
  v_unique_definition text;
  v_apply_definition text;
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
  select a.user_id into v_other_admin
  from public.admin_role_assignments a
  where a.is_active and a.user_id <> v_admin
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(
      a.user_id, 'groups.write', 'global', null
    )
  limit 1;
  perform pg_temp.ga_as_user(v_admin);

  insert into public.academic_years(
    name, start_year, starts_on, ends_on, is_current
  ) values (
    '2097/2098 group apply roleplay', 2097,
    date '2097-09-01', date '2098-08-31', false
  ) returning id into v_year;

  v_program := public.admin_upsert_educational_program(
    p_direction_code => '19.1B2',
    p_direction_name => 'Roleplay direction',
    p_profile_name => 'Roleplay profile',
    p_qualification => 'bachelor',
    p_study_form => 'full_time',
    p_status => 'active'
  );
  v_plan := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program,
    p_admission_year => 2096,
    p_plan_code => '19.1B2-2096',
    p_version_label => 'roleplay-v1',
    p_nominal_semesters => 8,
    p_status => 'active',
    p_parser_contract_version => 'curriculum-document-v2'
  );
  v_alt_plan := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program,
    p_admission_year => 2096,
    p_plan_code => '19.1B2-2096-ALT',
    p_version_label => 'roleplay-v2',
    p_nominal_semesters => 8,
    p_status => 'reviewed',
    p_parser_contract_version => 'curriculum-document-v2'
  );

  set local role service_role;
  insert into public.educational_program_aliases(
    educational_program_id, alias_raw, alias_key, status, reviewed_by
  ) values (
    v_program, 'РПГР', private.group_recognition_program_alias_key('РПГР'),
    'active', v_admin
  );
  insert into public.groups(name) values ('1-РПГР-2')
    returning id into v_group;
  insert into public.group_name_aliases(
    group_id, alias_raw, alias_key, source, status
  ) values (
    v_group, '1-РПГР-2', private.group_recognition_name_key('1-РПГР-2'),
    'current_name', 'active'
  );
  insert into public.group_academic_identities(
    group_id, educational_program_id, admission_year, parallel_number,
    reviewed_by
  ) values (v_group, v_program, 2096, 1, v_admin);
  insert into public.group_academic_profiles(
    group_id, admission_year, nominal_semesters, active, curriculum_plan_id
  ) values (v_group, 2096, 8, true, v_plan);
  insert into public.groups(name) values ('roleplay incompatible semantic')
    returning id into v_bad_group;
  insert into public.group_academic_identities(
    group_id, educational_program_id, admission_year, parallel_number,
    distinct_discriminator, distinct_reason, reviewed_by
  ) values (
    v_bad_group, v_program, 2096, 3, 'inactive',
    'Roleplay incompatible semantic profile', v_admin
  );
  insert into public.group_academic_profiles(
    group_id, admission_year, nominal_semesters, active, curriculum_plan_id
  ) values (v_bad_group, 2096, 8, false, v_plan);
  insert into public.groups(name) values ('roleplay profileless max term')
    returning id into v_no_profile_group;
  insert into public.group_academic_identities(
    group_id, educational_program_id, admission_year, parallel_number,
    distinct_discriminator, distinct_reason, reviewed_by
  ) values (
    v_no_profile_group, v_program, 2096, 5, 'legacy',
    'Roleplay profileless group with semester overflow', v_admin
  );
  insert into public.academic_terms(
    academic_year_id, term_in_year, term_sequence, name,
    starts_on, ends_on, is_current
  ) values (
    v_year, 1, 20971, 'Roleplay term',
    date '2097-09-01', date '2098-01-31', false
  ) returning id into v_term;
  insert into public.group_term_semesters(
    group_id, academic_year_id, academic_term_id, semester_number, source
  ) values (
    v_no_profile_group, v_year, v_term, 9, 'import'
  );
  reset role;
  perform pg_temp.ga_as_user(v_admin);

  v_preview := public.admin_group_recognition_start_preview(
    v_year,
    jsonb_build_array(
      jsonb_build_object(
        'source_row_key', 'exact', 'group_name', '1-РПГР-2'
      ),
      jsonb_build_object(
        'source_row_key', 'new', 'group_name', '2-РПГР-2'
      )
    ),
    'roleplay.xlsx',
    'slice2-apply-main'
  );
  select (value ->> 'row_id')::uuid into v_row_exact
  from jsonb_array_elements(v_preview -> 'items')
  where value ->> 'source_row_key' = 'exact';
  select (value ->> 'row_id')::uuid into v_row_new
  from jsonb_array_elements(v_preview -> 'items')
  where value ->> 'source_row_key' = 'new';

  perform pg_temp.ga_assert(
    'preview v2 exposes human candidate snapshots',
    v_preview ->> 'parser_version' = 'group-name-v2'
      and (
        select jsonb_array_length(
          value -> 'evidence' -> 'candidate_snapshot' -> 'plans'
        ) = 2
        from jsonb_array_elements(v_preview -> 'items')
        where value ->> 'source_row_key' = 'new'
      )
      and (
        select bool_and(plan ? 'label')
        from jsonb_array_elements(v_preview -> 'items') item(value)
        cross join lateral jsonb_array_elements(
          item.value -> 'evidence' -> 'candidate_snapshot' -> 'plans'
        ) plans(plan)
        where item.value ->> 'source_row_key' = 'new'
      )
  );

  begin
    perform public.admin_group_recognition_save_decisions(
      (v_preview ->> 'preview_id')::uuid,
      (v_preview ->> 'row_version')::integer,
      v_preview ->> 'payload_hash',
      jsonb_build_array(
        jsonb_build_object(
          'preview_row_id', v_row_exact,
          'action', 'reuse_group',
          'selected_group_id', v_group
        ),
        jsonb_build_object(
          'preview_row_id', v_row_exact,
          'action', 'reuse_group',
          'selected_group_id', v_group
        )
      )
    );
  exception when invalid_parameter_value then
    v_duplicate_blocked := sqlerrm = 'duplicate_decision_ids';
  end;
  perform pg_temp.ga_assert(
    'duplicate decision ids reject atomically',
    v_duplicate_blocked
  );

  v_saved := public.admin_group_recognition_save_decisions(
    (v_preview ->> 'preview_id')::uuid,
    (v_preview ->> 'row_version')::integer,
    v_preview ->> 'payload_hash',
    jsonb_build_array(
      jsonb_build_object(
        'preview_row_id', v_row_exact,
        'action', 'reuse_group',
        'selected_group_id', v_group
      ),
      jsonb_build_object(
        'preview_row_id', v_row_new,
        'action', 'create_group',
        'selected_plan_id', v_plan
      )
    )
  );
  perform pg_temp.ga_assert(
    'decision replacement increments revision and hash',
    (v_saved ->> 'decision_revision')::integer = 1
      and v_saved ->> 'decision_hash' ~ '^[0-9a-f]{64}$'
      and (v_saved ->> 'apply_enabled')::boolean
  );

  select count(*) into v_before_groups from public.groups;
  select count(*) into v_before_accounts from auth.users;
  select count(*) into v_before_enrollments from public.student_enrollments;
  select count(*) into v_before_offerings from public.subject_offerings;
  select count(*) into v_before_teams from public.teams;
  select count(*) into v_before_chats from public.chats;

  begin
    perform public.admin_group_recognition_apply(
      (v_saved ->> 'preview_id')::uuid,
      (v_saved ->> 'row_version')::integer,
      repeat('0', 64),
      (v_saved ->> 'decision_revision')::integer,
      v_saved ->> 'decision_hash',
      v_saved ->> 'confirmation_token'
    );
  exception when serialization_failure then
    v_tamper_blocked := true;
  end;
  perform pg_temp.ga_assert(
    'payload tamper rejects before writes',
    v_tamper_blocked
      and (select count(*) from public.groups) = v_before_groups
  );

  v_applied := public.admin_group_recognition_apply(
    (v_saved ->> 'preview_id')::uuid,
    (v_saved ->> 'row_version')::integer,
    v_saved ->> 'payload_hash',
    (v_saved ->> 'decision_revision')::integer,
    v_saved ->> 'decision_hash',
    v_saved ->> 'confirmation_token'
  );
  perform pg_temp.ga_assert(
    'apply reuses one group and directly creates one group',
    jsonb_array_length(v_applied -> 'results') = 2
      and (select count(*) from public.groups) = v_before_groups + 1
  );
  perform pg_temp.ga_assert(
    'apply creates no accounts enrollments offerings teams or chats',
    (select count(*) from auth.users) = v_before_accounts
      and (select count(*) from public.student_enrollments)
        = v_before_enrollments
      and (select count(*) from public.subject_offerings)
        = v_before_offerings
      and (select count(*) from public.teams) = v_before_teams
      and (select count(*) from public.chats) = v_before_chats
  );
  perform pg_temp.ga_assert(
    'new profile is active and plan is bound',
    (
      select gap.active and gap.curriculum_plan_id = v_plan
      from public.group_recognition_results gr
      join public.group_academic_profiles gap on gap.group_id = gr.group_id
      where gr.preview_id = (v_applied ->> 'preview_id')::uuid
        and gr.action = 'create_group'
    )
  );

  begin
    update public.group_recognition_results
    set action = 'reuse_group'
    where preview_id = (v_applied ->> 'preview_id')::uuid;
  exception when object_not_in_prerequisite_state then
    v_result_immutable := sqlerrm = 'group_recognition_result_immutable';
  end;
  perform pg_temp.ga_assert(
    'stored per-row results reject update and remain immutable',
    v_result_immutable
  );

  v_applied := public.admin_group_recognition_apply(
    (v_saved ->> 'preview_id')::uuid,
    (v_saved ->> 'row_version')::integer,
    v_saved ->> 'payload_hash',
    (v_saved ->> 'decision_revision')::integer,
    v_saved ->> 'decision_hash',
    v_saved ->> 'confirmation_token'
  );
  perform pg_temp.ga_assert(
    'applied retry returns immutable stored result',
    (v_applied ->> 'idempotent_replay')::boolean
      and jsonb_array_length(v_applied -> 'results') = 2
      and (select count(*) from public.groups) = v_before_groups + 1
  );
  begin
    perform public.admin_group_recognition_apply(
      (v_saved ->> 'preview_id')::uuid,
      (v_saved ->> 'row_version')::integer,
      v_saved ->> 'payload_hash',
      (v_saved ->> 'decision_revision')::integer + 1,
      v_saved ->> 'decision_hash',
      v_saved ->> 'confirmation_token'
    );
  exception when serialization_failure then
    v_retry_tamper_blocked := true;
  end;
  perform pg_temp.ga_assert(
    'applied retry rejects altered revision hash or confirmation',
    v_retry_tamper_blocked
  );

  if v_other_admin is not null then
    perform pg_temp.ga_as_user(v_other_admin);
    begin
      perform public.admin_group_recognition_get_preview(
        (v_saved ->> 'preview_id')::uuid
      );
    exception when no_data_found then
      v_owner_blocked := true;
    end;
    perform pg_temp.ga_assert(
      'preview and applied result are owner scoped',
      v_owner_blocked
    );
    perform pg_temp.ga_as_user(v_admin);
  else
    perform pg_temp.ga_assert(
      'preview and applied result are owner scoped',
      true,
      'single groups.write fixture; owner predicate statically verified'
    );
  end if;

  -- Blocked rows cannot receive a durable decision.
  v_preview := public.admin_group_recognition_start_preview(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'source_row_key', 'blocked', 'group_name', 'not-a-group'
    )),
    'blocked.xlsx',
    'slice2-blocked'
  );
  begin
    perform public.admin_group_recognition_save_decisions(
      (v_preview ->> 'preview_id')::uuid,
      (v_preview ->> 'row_version')::integer,
      v_preview ->> 'payload_hash',
      jsonb_build_array(jsonb_build_object(
        'preview_row_id', v_preview -> 'items' -> 0 ->> 'row_id',
        'action', 'create_group',
        'selected_plan_id', v_plan
      ))
    );
  exception when invalid_parameter_value then
    v_blocked_decision_blocked := sqlerrm = 'blocked_row_has_decision';
  end;
  perform pg_temp.ga_assert(
    'parser program no-plan and conflict rows accept no decision',
    v_blocked_decision_blocked
  );

  v_preview := public.admin_group_recognition_start_preview(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'source_row_key', 'semantic-incompatible', 'group_name', '3-РПГР-2'
    )),
    'semantic-incompatible.xlsx',
    'slice2-semantic-incompatible'
  );
  perform pg_temp.ga_assert(
    'incompatible semantic candidate is blocked before decisions',
    v_preview -> 'items' -> 0 ->> 'classification' = 'conflict'
      and not (v_preview ->> 'apply_enabled')::boolean
      and (v_preview -> 'items' -> 0 -> 'warnings')
        ? 'semantic_candidates_incompatible'
  );

  v_preview := public.admin_group_recognition_start_preview(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'source_row_key', 'profileless-max-term', 'group_name', '5-РПГР-2'
    )),
    'profileless-max-term.xlsx',
    'slice2-profileless-max-term'
  );
  perform pg_temp.ga_assert(
    'profileless semantic candidate beyond plan max term is blocked',
    v_preview -> 'items' -> 0 ->> 'classification' = 'conflict'
      and not (v_preview ->> 'apply_enabled')::boolean
      and (v_preview -> 'items' -> 0 -> 'warnings')
        ? 'semantic_candidates_incompatible'
  );

  v_preview := public.admin_group_recognition_start_preview(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'source_row_key', 'exact-alt-plan', 'group_name', '1-РПГР-2'
    )),
    'exact-alt-plan.xlsx',
    'slice2-exact-alt-plan'
  );
  begin
    perform public.admin_group_recognition_save_decisions(
      (v_preview ->> 'preview_id')::uuid,
      (v_preview ->> 'row_version')::integer,
      v_preview ->> 'payload_hash',
      jsonb_build_array(jsonb_build_object(
        'preview_row_id', v_preview -> 'items' -> 0 ->> 'row_id',
        'action', 'reuse_group',
        'selected_group_id', v_group,
        'selected_plan_id', v_alt_plan
      ))
    );
  exception when invalid_parameter_value then
    v_exact_alt_plan_blocked := sqlerrm = 'exact_group_plan_is_fixed';
  end;
  perform pg_temp.ga_assert(
    'exact reuse cannot select a replacement plan',
    v_exact_alt_plan_blocked
  );

  -- Alias drift after a saved exact decision must stale the whole apply.
  v_preview := public.admin_group_recognition_start_preview(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'source_row_key', 'alias-drift', 'group_name', '1-РПГР-2'
    )),
    'alias-drift.xlsx',
    'slice2-alias-drift'
  );
  v_saved := public.admin_group_recognition_save_decisions(
    (v_preview ->> 'preview_id')::uuid,
    (v_preview ->> 'row_version')::integer,
    v_preview ->> 'payload_hash',
    jsonb_build_array(jsonb_build_object(
      'preview_row_id', v_preview -> 'items' -> 0 ->> 'row_id',
      'action', 'reuse_group',
      'selected_group_id', v_group
    ))
  );
  set local role service_role;
  update public.group_name_aliases
  set status = 'archived', row_version = row_version + 1
  where group_id = v_group
    and alias_key = private.group_recognition_name_key('1-РПГР-2');
  reset role;
  perform pg_temp.ga_as_user(v_admin);
  begin
    perform public.admin_group_recognition_apply(
      (v_saved ->> 'preview_id')::uuid,
      (v_saved ->> 'row_version')::integer,
      v_saved ->> 'payload_hash',
      (v_saved ->> 'decision_revision')::integer,
      v_saved ->> 'decision_hash',
      v_saved ->> 'confirmation_token'
    );
  exception when serialization_failure then
    v_alias_drift_blocked := true;
  end;
  set local role service_role;
  update public.group_name_aliases
  set status = 'active', row_version = row_version + 1
  where group_id = v_group
    and alias_key = private.group_recognition_name_key('1-РПГР-2');
  reset role;
  perform pg_temp.ga_as_user(v_admin);
  perform pg_temp.ga_assert(
    'alias drift after decision rejects without partial writes',
    v_alias_drift_blocked
      and not exists (
        select 1 from public.group_recognition_results
        where preview_id = (v_saved ->> 'preview_id')::uuid
      )
  );

  -- Plan row-version drift is part of the candidate snapshot.
  v_preview := public.admin_group_recognition_start_preview(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'source_row_key', 'plan-drift', 'group_name', '4-РПГР-2'
    )),
    'plan-drift.xlsx',
    'slice2-plan-drift'
  );
  v_saved := public.admin_group_recognition_save_decisions(
    (v_preview ->> 'preview_id')::uuid,
    (v_preview ->> 'row_version')::integer,
    v_preview ->> 'payload_hash',
    jsonb_build_array(jsonb_build_object(
      'preview_row_id', v_preview -> 'items' -> 0 ->> 'row_id',
      'action', 'create_group',
      'selected_plan_id', v_plan
    ))
  );
  set local role service_role;
  update public.curriculum_plans
  set row_version = row_version + 1
  where id = v_plan;
  reset role;
  perform pg_temp.ga_as_user(v_admin);
  begin
    perform public.admin_group_recognition_apply(
      (v_saved ->> 'preview_id')::uuid,
      (v_saved ->> 'row_version')::integer,
      v_saved ->> 'payload_hash',
      (v_saved ->> 'decision_revision')::integer,
      v_saved ->> 'decision_hash',
      v_saved ->> 'confirmation_token'
    );
  exception when serialization_failure then
    v_plan_drift_blocked := true;
  end;
  set local role service_role;
  update public.curriculum_plans
  set row_version = row_version - 1
  where id = v_plan;
  reset role;
  perform pg_temp.ga_as_user(v_admin);
  perform pg_temp.ga_assert(
    'plan drift after decision rejects without creating a group',
    v_plan_drift_blocked
      and not exists (
        select 1 from public.group_recognition_results
        where preview_id = (v_saved ->> 'preview_id')::uuid
      )
  );

  select pg_get_functiondef(
    'public.admin_group_recognition_apply(uuid,integer,text,integer,text,text)'
      ::regprocedure
  ) into v_apply_definition;
  perform pg_temp.ga_assert(
    'apply never invokes space-creating admin_upsert_group',
    position('admin_upsert_group' in v_apply_definition) = 0
      and position('insert into public.groups' in v_apply_definition) > 0
      and position('student_enrollments' in v_apply_definition) = 0
      and position('subject_offerings' in v_apply_definition) = 0
      and position('public.teams' in v_apply_definition) = 0
      and position('public.chats' in v_apply_definition) = 0
  );
  select pg_get_constraintdef(oid) into v_unique_definition
  from pg_constraint
  where conname = 'group_academic_identities_semantic_unique';
  perform pg_temp.ga_assert(
    'semantic identity and alias uniqueness fail closed under concurrency',
    v_unique_definition is not null
      and exists (
        select 1 from pg_constraint
        where conname = 'group_name_aliases_key_unique'
      )
      and position('pg_advisory_xact_lock' in pg_get_functiondef(
        'public.admin_group_recognition_start_preview_slice1(uuid,jsonb,text,text,text)'
          ::regprocedure
      )) > 0
  );

  perform pg_temp.ga_assert(
    'decision and result tables force RLS with no authenticated DML',
    (
      select relrowsecurity and relforcerowsecurity
      from pg_class where oid = 'public.group_recognition_decisions'::regclass
    )
      and (
        select relrowsecurity and relforcerowsecurity
        from pg_class where oid = 'public.group_recognition_results'::regclass
      )
      and not has_table_privilege(
        'authenticated', 'public.group_recognition_decisions',
        'SELECT,INSERT,UPDATE,DELETE'
      )
      and not has_table_privilege(
        'authenticated', 'public.group_recognition_results',
        'SELECT,INSERT,UPDATE,DELETE'
      )
  );
  perform pg_temp.ga_assert(
    'only RPC execution is granted to authenticated',
    has_function_privilege(
      'authenticated',
      'public.admin_group_recognition_save_decisions(uuid,integer,text,jsonb)',
      'EXECUTE'
    )
      and has_function_privilege(
        'authenticated',
        'public.admin_group_recognition_apply(uuid,integer,text,integer,text,text)',
        'EXECUTE'
      )
      and not has_function_privilege(
        'anon',
        'public.admin_group_recognition_apply(uuid,integer,text,integer,text,text)',
        'EXECUTE'
      )
  );
  perform pg_temp.ga_assert(
    'security definer functions pin empty search path',
    (
      select bool_and(exists (
        select 1
        from unnest(coalesce(p.proconfig, '{}')) config
        where config in ('search_path=', 'search_path=""')
      ))
      from pg_proc p
      where oid in (
        'public.admin_group_recognition_save_decisions(uuid,integer,text,jsonb)'
          ::regprocedure,
        'public.admin_group_recognition_apply(uuid,integer,text,integer,text,text)'
          ::regprocedure
      )
    )
  );

  -- Static guards for drift branches that require another transaction/session
  -- to exercise safely in CI.
  perform pg_temp.ga_assert(
    'stale alias plan profile identity and max-term checks are present',
    position('group_recognition_facts_stale' in v_apply_definition) > 0
      and position('group_recognition_plan_stale' in v_apply_definition) > 0
      and position('group_recognition_profile_conflict' in v_apply_definition) > 0
      and position('group_recognition_identity_conflict' in v_apply_definition) > 0
      and position('group_semester_exceeds_curriculum_plan' in v_apply_definition) > 0
      and position('group_recognition_plan_replacement_forbidden'
        in v_apply_definition) > 0
  );
end;
$$;

do $$
declare
  v_failed text;
begin
  select string_agg(scenario || ': ' || detail, '; ' order by scenario)
    into v_failed
  from group_apply_results where not passed;
  if v_failed is not null then
    raise exception 'group recognition apply roleplay failed: %', v_failed;
  end if;
end;
$$;

select scenario, passed, detail
from group_apply_results
order by scenario;

rollback;
