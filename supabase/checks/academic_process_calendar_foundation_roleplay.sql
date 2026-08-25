-- Academic-process calendar foundation role-play.
--
-- LOCAL/DISPOSABLE ONLY. Apply both academic-ingestion migrations first.
-- The transaction always rolls back.

begin;

create temporary table academic_process_calendar_roleplay_results (
  scenario text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null default ''
) on commit drop;

create or replace function pg_temp.calendar_result(
  p_scenario text,
  p_ok boolean,
  p_detail text default ''
)
returns void
language plpgsql
as $fn$
begin
  insert into academic_process_calendar_roleplay_results(
    scenario,
    status,
    detail
  )
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

create or replace function pg_temp.calendar_as_user(p_user_id uuid)
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

create or replace function pg_temp.calendar_authenticated_dml_blocked(
  p_sql text
)
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
  v_year_id uuid;
  v_program_id uuid;
  v_plan_eight uuid;
  v_plan_four uuid;
  v_calendar_eight uuid;
  v_calendar_four uuid;
  v_calendar_program uuid;
  v_calendar_global uuid;
  v_version_eight uuid;
  v_version_four uuid;
  v_version_program uuid;
  v_version_global uuid;
  v_valid jsonb;
  v_short jsonb;
  v_short_program jsonb;
  v_short_global jsonb;
  v_overlap_blocked jsonb;
  v_overlap_allowed jsonb;
  v_outside jsonb;
  v_shape_blocked boolean := false;
  v_contract_blocked boolean := false;
  v_period_mutation_blocked boolean := false;
  v_period_reparent_blocked boolean := false;
  v_series_mutation_blocked boolean := false;
  v_version_mutation_blocked boolean := false;
  v_period_id uuid;
begin
  perform pg_temp.calendar_result(
    'C0 foundation tables exist',
    to_regclass('public.academic_process_calendars') is not null
      and to_regclass(
        'public.academic_process_calendar_versions'
      ) is not null
      and to_regclass('public.academic_process_periods') is not null,
    ''
  );

  select a.user_id
    into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(
      a.user_id,
      'terms.manage',
      'global',
      null
    )
    and private.has_admin_permission(
      a.user_id,
      'subjects.write',
      'global',
      null
    )
  limit 1;

  if v_admin is null then
    select u.id into v_admin
    from public.users u
    order by u.created_at
    limit 1;
    if v_admin is not null then
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
        v_admin,
        'academic_editor',
        'global',
        null,
        true,
        null,
        null
      )
      on conflict do nothing;
    end if;
  end if;

  perform pg_temp.calendar_as_user(v_admin);
  perform pg_temp.calendar_result(
    'C1 RBAC fixture available',
    v_admin is not null
      and private.academic_ingestion_has_permission('terms.manage')
      and private.academic_ingestion_has_permission('subjects.write'),
    coalesce(v_admin::text, 'no user fixture')
  );

  insert into public.academic_years(
    name,
    start_year,
    starts_on,
    ends_on,
    is_current
  )
  values (
    '2096/2097 calendar roleplay',
    2096,
    date '2096-09-01',
    date '2097-08-31',
    false
  )
  on conflict (start_year) do update
    set name = excluded.name
  returning id into v_year_id;

  v_program_id := public.admin_upsert_educational_program(
    p_direction_code => '99.99.99',
    p_direction_name => 'Calendar roleplay',
    p_profile_name => 'Calendar roleplay profile',
    p_qualification => 'bachelor',
    p_study_form => 'full_time',
    p_status => 'active'
  );
  v_plan_eight := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program_id,
    p_admission_year => 2096,
    p_plan_code => 'calendar-eight',
    p_version_label => 'roleplay',
    p_nominal_semesters => 8,
    p_status => 'reviewed',
    p_parser_contract_version => 'curriculum-document-v1'
  );
  v_plan_four := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program_id,
    p_admission_year => 2094,
    p_plan_code => 'calendar-four',
    p_version_label => 'roleplay',
    p_nominal_semesters => 4,
    p_status => 'reviewed',
    p_parser_contract_version => 'curriculum-document-v1'
  );

  v_calendar_eight := public.admin_upsert_academic_process_calendar(
    p_academic_year_id => v_year_id,
    p_audience_kind => 'plan',
    p_curriculum_plan_id => v_plan_eight,
    p_title => 'Eight-semester plan calendar'
  );
  v_calendar_four := public.admin_upsert_academic_process_calendar(
    p_academic_year_id => v_year_id,
    p_audience_kind => 'plan',
    p_curriculum_plan_id => v_plan_four,
    p_title => 'Four-semester plan calendar'
  );
  v_calendar_program := public.admin_upsert_academic_process_calendar(
    p_academic_year_id => v_year_id,
    p_audience_kind => 'program',
    p_educational_program_id => v_program_id,
    p_title => 'Program calendar'
  );
  v_calendar_global := public.admin_upsert_academic_process_calendar(
    p_academic_year_id => v_year_id,
    p_audience_kind => 'global',
    p_title => 'Global calendar'
  );
  v_version_eight :=
    public.admin_create_academic_process_calendar_version(
      p_calendar_id => v_calendar_eight,
      p_version_label => 'roleplay-v1',
      p_source_file_name => 'calendar.png',
      p_source_mime_type => 'image/png',
      p_source_sha256 => repeat('a', 64),
      p_parser_contract_version => 'academic-process-calendar-v1'
    );
  v_version_four :=
    public.admin_create_academic_process_calendar_version(
      p_calendar_id => v_calendar_four,
      p_version_label => 'roleplay-v1',
      p_parser_contract_version => 'academic-process-calendar-v1'
    );
  v_version_program :=
    public.admin_create_academic_process_calendar_version(
      p_calendar_id => v_calendar_program,
      p_version_label => 'roleplay-v1',
      p_parser_contract_version => 'academic-process-calendar-v1'
    );
  v_version_global :=
    public.admin_create_academic_process_calendar_version(
      p_calendar_id => v_calendar_global,
      p_version_label => 'roleplay-v1',
      p_parser_contract_version => 'academic-process-calendar-v1'
    );

  begin
    insert into public.academic_process_calendars(
      academic_year_id,
      audience_kind,
      educational_program_id,
      curriculum_plan_id,
      group_id,
      title
    )
    values (
      v_year_id,
      'global',
      v_program_id,
      null,
      null,
      'Invalid mixed audience'
    );
  exception
    when check_violation then
      v_shape_blocked := true;
  end;
  perform pg_temp.calendar_result(
    'C2 audience shape is exact at database boundary',
    v_shape_blocked,
    ''
  );

  v_valid := public.admin_academic_process_calendar_dry_run(
    v_version_eight,
    'academic-process-calendar-v1',
    jsonb_build_array(
      jsonb_build_object(
        'period_key', 'study-c2-t1',
        'period_type', 'study',
        'course_number', 2,
        'term_in_year', 1,
        'semester_number', 99,
        'starts_on', '2096-09-01',
        'ends_on', '2096-12-20'
      )
    )
  );
  perform pg_temp.calendar_result(
    'C3 server derives semester and ignores client semester',
    (v_valid ->> 'ok')::boolean
      and v_valid -> 'items' -> 0 ->> 'derived_semester_number' = '3',
    left(v_valid::text, 700)
  );

  v_short := public.admin_academic_process_calendar_dry_run(
    v_version_four,
    'academic-process-calendar-v1',
    jsonb_build_array(
      jsonb_build_object(
        'period_key', 'study-c3-t1',
        'period_type', 'study',
        'course_number', 3,
        'term_in_year', 1,
        'starts_on', '2096-09-01',
        'ends_on', '2096-12-20'
      )
    )
  );
  perform pg_temp.calendar_result(
    'C4 semester five is blocked for four-semester plan',
    not (v_short ->> 'ok')::boolean
      and v_short::text like
        '%plan_audience_not_compatible_with_course_or_semester%',
    left(v_short::text, 700)
  );

  v_short_program := public.admin_academic_process_calendar_dry_run(
    v_version_program,
    'academic-process-calendar-v1',
    jsonb_build_array(
      jsonb_build_object(
        'period_key', 'program-study-c3-t1',
        'period_type', 'study',
        'course_number', 3,
        'term_in_year', 1,
        'starts_on', '2096-09-01',
        'ends_on', '2096-12-20'
      )
    )
  );
  v_short_global := public.admin_academic_process_calendar_dry_run(
    v_version_global,
    'academic-process-calendar-v1',
    jsonb_build_array(
      jsonb_build_object(
        'period_key', 'global-study-c3-t1',
        'period_type', 'study',
        'course_number', 3,
        'term_in_year', 1,
        'starts_on', '2096-09-01',
        'ends_on', '2096-12-20'
      )
    )
  );
  perform pg_temp.calendar_result(
    'C4a program and global audiences reject semester overflow',
    not (v_short_program ->> 'ok')::boolean
      and v_short_program::text like
        '%program_plan_nominal_semesters_exceeded%'
      and not (v_short_global ->> 'ok')::boolean
      and v_short_global::text like
        '%global_plan_nominal_semesters_exceeded%',
    left(
      v_short_program::text || ' / ' || v_short_global::text,
      1000
    )
  );

  v_overlap_blocked := public.admin_academic_process_calendar_dry_run(
    v_version_eight,
    'academic-process-calendar-v1',
    jsonb_build_array(
      jsonb_build_object(
        'period_key', 'session-a',
        'period_type', 'session',
        'course_number', 1,
        'term_in_year', 1,
        'starts_on', '2096-12-01',
        'ends_on', '2096-12-20'
      ),
      jsonb_build_object(
        'period_key', 'session-b',
        'period_type', 'session',
        'course_number', 1,
        'term_in_year', 1,
        'starts_on', '2096-12-20',
        'ends_on', '2096-12-25'
      )
    )
  );
  perform pg_temp.calendar_result(
    'C5 inclusive conflicting overlap is rejected',
    not (v_overlap_blocked ->> 'ok')::boolean
      and v_overlap_blocked::text like '%period_overlap:session-a%',
    left(v_overlap_blocked::text, 700)
  );

  v_overlap_allowed := public.admin_academic_process_calendar_dry_run(
    v_version_eight,
    'academic-process-calendar-v1',
    jsonb_build_array(
      jsonb_build_object(
        'period_key', 'study-a',
        'period_type', 'study',
        'course_number', 1,
        'term_in_year', 1,
        'starts_on', '2096-09-01',
        'ends_on', '2096-12-20'
      ),
      jsonb_build_object(
        'period_key', 'practice-a',
        'period_type', 'practice',
        'course_number', 1,
        'term_in_year', 1,
        'starts_on', '2096-12-10',
        'ends_on', '2096-12-25'
      )
    )
  );
  perform pg_temp.calendar_result(
    'C6 declared study-practice overlap is allowed',
    (v_overlap_allowed ->> 'ok')::boolean,
    left(v_overlap_allowed::text, 700)
  );

  v_outside := public.admin_academic_process_calendar_dry_run(
    v_version_eight,
    'academic-process-calendar-v1',
    jsonb_build_array(
      jsonb_build_object(
        'period_key', 'outside',
        'period_type', 'holidays',
        'course_number', 1,
        'term_in_year', 1,
        'starts_on', '2096-08-31',
        'ends_on', '2096-09-01'
      )
    )
  );
  perform pg_temp.calendar_result(
    'C7 dates outside academic year are rejected',
    not (v_outside ->> 'ok')::boolean
      and v_outside::text like '%period_outside_academic_year%',
    left(v_outside::text, 700)
  );

  begin
    perform public.admin_academic_process_calendar_dry_run(
      v_version_eight,
      'academic-process-calendar-v2',
      '[]'::jsonb
    );
  exception
    when invalid_parameter_value then
      v_contract_blocked := true;
  end;
  perform pg_temp.calendar_result(
    'C8 parser contract mismatch and apply are blocked',
    v_contract_blocked
      and to_regprocedure(
        'public.admin_academic_process_calendar_apply(uuid,text,jsonb)'
      ) is null
      and (v_valid ->> 'apply_enabled')::boolean = false
      and (v_valid ->> 'publish_enabled')::boolean = false,
    ''
  );

  perform pg_temp.calendar_result(
    'C9 browser source hash remains unverified',
    (
      select not v.source_verified
      from public.academic_process_calendar_versions v
      where v.id = v_version_eight
    ),
    ''
  );

  insert into public.academic_process_periods(
    calendar_version_id,
    period_key,
    period_type,
    course_number,
    term_in_year,
    starts_on,
    ends_on,
    reviewed_by
  )
  values (
    v_version_eight,
    'immutable-period',
    'study',
    1,
    1,
    date '2096-09-01',
    date '2096-12-20',
    v_admin
  )
  returning id into v_period_id;

  update public.academic_process_calendar_versions
  set status = 'published',
      reviewed_by = v_admin,
      reviewed_at = now(),
      published_by = v_admin,
      published_at = now()
  where id = v_version_eight;

  begin
    update public.academic_process_periods
    set ends_on = date '2096-12-21'
    where id = v_period_id;
  exception
    when object_not_in_prerequisite_state then
      v_period_mutation_blocked := true;
  end;
  begin
    update public.academic_process_periods
    set calendar_version_id = v_version_four
    where id = v_period_id;
  exception
    when object_not_in_prerequisite_state then
      v_period_reparent_blocked := true;
  end;
  begin
    update public.academic_process_calendars
    set title = 'Mutated'
    where id = v_calendar_eight;
  exception
    when object_not_in_prerequisite_state then
      v_series_mutation_blocked := true;
  end;
  begin
    update public.academic_process_calendar_versions
    set version_label = 'Mutated'
    where id = v_version_eight;
  exception
    when object_not_in_prerequisite_state then
      v_version_mutation_blocked := true;
  end;
  perform pg_temp.calendar_result(
    'C10 published series version and periods are immutable',
    v_period_mutation_blocked
      and v_period_reparent_blocked
      and v_series_mutation_blocked
      and v_version_mutation_blocked,
    ''
  );

  perform pg_temp.calendar_result(
    'C10a immutability guards take parent row locks',
    pg_get_functiondef(
      'private.guard_academic_process_calendar_series()'::regprocedure
    ) ilike '%for update%'
      and pg_get_functiondef(
        'private.guard_academic_process_period_mutation()'::regprocedure
      ) ilike '%old.calendar_version_id%'
      and pg_get_functiondef(
        'private.guard_academic_process_period_mutation()'::regprocedure
      ) ilike '%new.calendar_version_id%'
      and pg_get_functiondef(
        'private.guard_academic_process_period_mutation()'::regprocedure
      ) ilike '%for update%',
    'Structural assertion for two-session serialization contract'
  );

  perform pg_temp.calendar_result(
    'C11 authenticated direct DML is denied',
    pg_temp.calendar_authenticated_dml_blocked(
      'update public.academic_process_calendars set title = title where false'
    )
      and pg_temp.calendar_authenticated_dml_blocked(
        'update public.academic_process_calendar_versions '
        || 'set version_label = version_label where false'
      )
      and pg_temp.calendar_authenticated_dml_blocked(
        'update public.academic_process_periods '
        || 'set period_key = period_key where false'
      ),
    ''
  );
end
$$;

select *
from academic_process_calendar_roleplay_results
order by scenario;

do $$
begin
  if exists (
    select required.scenario
    from unnest(array[
      'C0 foundation tables exist',
      'C1 RBAC fixture available',
      'C2 audience shape is exact at database boundary',
      'C3 server derives semester and ignores client semester',
      'C4 semester five is blocked for four-semester plan',
      'C4a program and global audiences reject semester overflow',
      'C5 inclusive conflicting overlap is rejected',
      'C6 declared study-practice overlap is allowed',
      'C7 dates outside academic year are rejected',
      'C8 parser contract mismatch and apply are blocked',
      'C9 browser source hash remains unverified',
      'C10 published series version and periods are immutable',
      'C10a immutability guards take parent row locks',
      'C11 authenticated direct DML is denied'
    ]) as required(scenario)
    left join academic_process_calendar_roleplay_results actual
      on actual.scenario = required.scenario
    where actual.status is distinct from 'PASS'
  ) then
    raise exception 'academic_process_calendar_foundation_roleplay_failed';
  end if;
end
$$;

rollback;
