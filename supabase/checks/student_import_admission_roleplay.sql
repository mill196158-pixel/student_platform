-- Stage 19.1c rollback-safe role-play.
-- Two admission years, same middle token, record-book mismatch, missing plan.
-- Run in a transaction and roll back. Do not keep fixtures.

begin;

create temporary table student_import_results(
  scenario text primary key,
  passed boolean not null,
  detail text not null default ''
) on commit drop;

create or replace function pg_temp.si_assert(
  p_scenario text,
  p_passed boolean,
  p_detail text default ''
)
returns void language plpgsql as $$
begin
  insert into student_import_results values (
    p_scenario, coalesce(p_passed, false), coalesce(p_detail, '')
  );
end;
$$;

create or replace function pg_temp.si_as_user(p_user_id uuid)
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
  v_year uuid;
  v_program uuid;
  v_plan_2096 uuid;
  v_plan_2097 uuid;
  v_s1 uuid;
  v_s2 uuid;
  v_s3 uuid;
  v_s1_login text;
  v_s2_login text;
  v_s3_login text;
  v_dry jsonb;
  v_apply jsonb;
  v_replay jsonb;
  v_group_2096 uuid;
  v_group_2097 uuid;
  v_other uuid;
  v_before_groups bigint;
  v_legacy_blocked boolean := false;
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'students.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'groups.write', 'global', null)
  limit 1;
  if v_admin is null then
    raise exception 'roleplay_requires_students_and_groups_write_admin';
  end if;
  perform pg_temp.si_as_user(v_admin);

  insert into public.academic_years(
    name, start_year, starts_on, ends_on, is_current
  ) values (
    '2097/2098 student import roleplay', 2097,
    date '2097-09-01', date '2098-08-31', false
  ) returning id into v_year;

  v_program := public.admin_upsert_educational_program(
    p_direction_code => '19.1C',
    p_direction_name => 'Student import direction',
    p_profile_name => 'Student import profile',
    p_qualification => 'bachelor',
    p_study_form => 'full_time',
    p_status => 'active'
  );
  v_plan_2096 := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program,
    p_admission_year => 2096,
    p_plan_code => '19.1C-2096',
    p_version_label => 'roleplay-v1',
    p_nominal_semesters => 8,
    p_status => 'active',
    p_parser_contract_version => 'curriculum-document-v2'
  );
  v_plan_2097 := public.admin_upsert_curriculum_plan(
    p_educational_program_id => v_program,
    p_admission_year => 2097,
    p_plan_code => '19.1C-2097',
    p_version_label => 'roleplay-v1',
    p_nominal_semesters => 8,
    p_status => 'active',
    p_parser_contract_version => 'curriculum-document-v2'
  );

  set local role service_role;
  insert into public.educational_program_aliases(
    educational_program_id, alias_raw, alias_key, status, reviewed_by
  ) values (
    v_program, 'СТДН', private.group_recognition_program_alias_key('СТДН'),
    'active', v_admin
  );

  select u.id, u.login into v_s1, v_s1_login
  from public.users u
  where lower(coalesce(nullif(btrim(u.role), ''), 'student')) = 'student'
  order by u.login
  limit 1;
  select u.id, u.login into v_s2, v_s2_login
  from public.users u
  where lower(coalesce(nullif(btrim(u.role), ''), 'student')) = 'student'
    and u.id <> v_s1
  order by u.login
  limit 1;
  select u.id, u.login into v_s3, v_s3_login
  from public.users u
  where lower(coalesce(nullif(btrim(u.role), ''), 'student')) = 'student'
    and u.id not in (v_s1, v_s2)
  order by u.login
  limit 1;
  if v_s1 is null or v_s2 is null or v_s3 is null then
    raise exception 'roleplay_requires_three_student_users';
  end if;

  update public.users set login = '96991001' where id = v_s1;
  update public.users set login = '96991002' where id = v_s2;
  update public.users set login = '97991001' where id = v_s3;
  reset role;
  perform pg_temp.si_as_user(v_admin);

  perform pg_temp.si_assert(
    'record_book_year_26',
    private.student_import_record_book_year('2612345') = 2026,
    private.student_import_record_book_year('2612345')::text
  );
  perform pg_temp.si_assert(
    'record_book_year_absent',
    private.student_import_record_book_year('ivanov') is null,
    coalesce(private.student_import_record_book_year('ivanov')::text, 'null')
  );

  begin
    perform public.admin_student_import_apply(
      jsonb_build_array(jsonb_build_object(
        'login', '96991001',
        'name', 'Аня',
        'surname', 'Тестова',
        'group_name', '1-СТДН-2'
      ))
    );
  exception when others then
    v_legacy_blocked := sqlerrm like '%student_import_requires_academic_year%';
  end;
  perform pg_temp.si_assert(
    'legacy_apply_requires_year',
    v_legacy_blocked,
    'legacy apply must not guess an admission year'
  );

  select count(*) into v_before_groups from public.groups;

  v_dry := public.admin_student_import_dry_run(
    v_year,
    jsonb_build_array(
      jsonb_build_object(
        'login', '96991001', 'name', 'Первый', 'surname', 'Курс2',
        'group_name', '1-СТДН-2'
      ),
      jsonb_build_object(
        'login', '96991002', 'name', 'Второй', 'surname', 'Курс2',
        'group_name', '1-СТДН-2'
      ),
      jsonb_build_object(
        'login', '97991001', 'name', 'Третий', 'surname', 'Курс1',
        'group_name', '1-СТДН-1'
      )
    )
  );
  perform pg_temp.si_assert(
    'usual_rows_ready',
    (v_dry -> 'items' -> 0 ->> 'classification') = 'update'
      and (v_dry -> 'items' -> 1 ->> 'classification') = 'update'
      and (v_dry -> 'items' -> 2 ->> 'classification') = 'update'
      and (v_dry -> 'items' -> 0 -> 'group_resolution' ->> 'admission_year') = '2096'
      and (v_dry -> 'items' -> 1 -> 'group_resolution' ->> 'same_file_pending_create') = 'true'
      and (v_dry -> 'items' -> 2 -> 'group_resolution' ->> 'admission_year') = '2097',
    v_dry::text
  );

  v_dry := public.admin_student_import_dry_run(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'login', '97991001',
      'group_name', '1-СТДН-2'
    ))
  );
  perform pg_temp.si_assert(
    'rare_second_course_mismatch',
    (v_dry -> 'items' -> 0 ->> 'error_text') = 'record_book_admission_mismatch'
      and (v_dry -> 'items' -> 0 -> 'group_resolution' ->> 'record_book_admission_year') = '2097'
      and (v_dry -> 'items' -> 0 -> 'group_resolution' ->> 'derived_admission_year') = '2096',
    v_dry::text
  );

  v_dry := public.admin_student_import_dry_run(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'login', '96991001',
      'group_name', '1-СТДН-3'
    ))
  );
  perform pg_temp.si_assert(
    'missing_plan_blocks',
    (v_dry -> 'items' -> 0 ->> 'error_text') = 'matching_reviewed_plan_not_found',
    v_dry::text
  );

  v_apply := public.admin_student_import_apply(
    v_year,
    jsonb_build_array(
      jsonb_build_object(
        'login', '96991001', 'name', 'Первый', 'surname', 'Курс2',
        'group_name', '1-СТДН-2'
      ),
      jsonb_build_object(
        'login', '96991002', 'name', 'Второй', 'surname', 'Курс2',
        'group_name', '1-СТДН-2'
      ),
      jsonb_build_object(
        'login', '97991001', 'name', 'Третий', 'surname', 'Курс1',
        'group_name', '1-СТДН-1'
      )
    )
  );
  perform pg_temp.si_assert(
    'first_creates_second_reuses',
    (v_apply ->> 'updated') = '3'
      and (v_apply ->> 'groups_created') = '2'
      and (v_apply ->> 'groups_reused') = '1'
      and (v_apply ->> 'error') = '0',
    v_apply::text
  );

  select i.group_id into v_group_2096
  from public.group_academic_identities i
  where i.educational_program_id = v_program
    and i.admission_year = 2096
    and i.parallel_number = 1
    and i.distinct_discriminator = '';
  select i.group_id into v_group_2097
  from public.group_academic_identities i
  where i.educational_program_id = v_program
    and i.admission_year = 2097
    and i.parallel_number = 1
    and i.distinct_discriminator = '';

  perform pg_temp.si_assert(
    'years_stay_separate',
    v_group_2096 is not null
      and v_group_2097 is not null
      and v_group_2096 <> v_group_2097
      and exists (
        select 1 from public.groups g
        where g.id = v_group_2096 and g.name = '1-СТДН-2'
      )
      and exists (
        select 1 from public.groups g
        where g.id = v_group_2097 and g.name = '1-СТДН-1'
      ),
    format('g2096=%s g2097=%s', v_group_2096, v_group_2097)
  );

  select se.group_id into v_other
  from public.student_enrollments se
  where se.user_id = v_s3 and se.status = 'active' and se.ended_at is null;
  perform pg_temp.si_assert(
    'course1_student_not_in_course2_group',
    v_other = v_group_2097,
    coalesce(v_other::text, 'null')
  );

  v_apply := public.admin_student_import_apply(
    v_year,
    jsonb_build_array(jsonb_build_object(
      'login', '97991001',
      'group_name', '1-СТДН-2'
    ))
  );
  perform pg_temp.si_assert(
    'mismatch_apply_creates_nothing',
    (v_apply ->> 'updated') = '0'
      and (v_apply ->> 'groups_created') = '0'
      and (v_apply ->> 'error') = '1'
      and not exists (
        select 1 from public.group_academic_identities i
        where i.educational_program_id = v_program
          and i.admission_year = 2097
          and i.parallel_number = 1
          and i.group_id <> v_group_2097
      ),
    v_apply::text
  );

  v_replay := public.admin_student_import_apply(
    v_year,
    jsonb_build_array(
      jsonb_build_object(
        'login', '96991001', 'name', 'Первый', 'surname', 'Курс2',
        'group_name', '1-СТДН-2'
      ),
      jsonb_build_object(
        'login', '96991002', 'name', 'Второй', 'surname', 'Курс2',
        'group_name', '1-СТДН-2'
      ),
      jsonb_build_object(
        'login', '97991001', 'name', 'Третий', 'surname', 'Курс1',
        'group_name', '1-СТДН-1'
      )
    )
  );
  perform pg_temp.si_assert(
    'idempotent_replay_includes_year',
    (v_replay ->> 'idempotent_replay') = 'true',
    v_replay::text
  );

  perform pg_temp.si_assert(
    'plans_exist_for_fixtures',
    v_plan_2096 is not null and v_plan_2097 is not null,
    ''
  );
  perform pg_temp.si_assert(
    'no_empty_group_from_mismatch',
    (
      select count(*) from public.groups g
      where g.name in ('1-СТДН-1', '1-СТДН-2')
    ) = 2
      and (select count(*) from public.groups) = v_before_groups + 2,
    format('before=%s now=%s', v_before_groups, (select count(*) from public.groups))
  );

  -- Restore logins inside the rolled-back transaction only for clarity.
  set local role service_role;
  update public.users set login = v_s1_login where id = v_s1;
  update public.users set login = v_s2_login where id = v_s2;
  update public.users set login = v_s3_login where id = v_s3;
  reset role;
end;
$$;

do $$
declare
  v_failed integer;
  v_detail text;
begin
  select count(*) into v_failed from student_import_results where not passed;
  if v_failed > 0 then
    select string_agg(scenario || ': ' || detail, E'\n')
      into v_detail
    from student_import_results
    where not passed;
    raise exception 'student_import_roleplay_failed (%): %', v_failed, v_detail;
  end if;
  raise notice 'student_import_roleplay_passed %/%',
    (select count(*) from student_import_results),
    (select count(*) from student_import_results);
end;
$$;

rollback;
