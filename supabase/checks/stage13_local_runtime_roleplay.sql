-- Stage 13 LOCAL runtime role-play. Disposable DB only. Never --linked.
\set ON_ERROR_STOP on

create temporary table if not exists stage13_roleplay_results (
  scenario text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null default ''
) on commit preserve rows;

truncate stage13_roleplay_results;
grant all on table stage13_roleplay_results to authenticated, anon, service_role;

create or replace function pg_temp.pass(p_scenario text, p_ok boolean, p_detail text default '')
returns void
language plpgsql as $$
begin
  insert into stage13_roleplay_results(scenario, status, detail)
  values (p_scenario, case when p_ok then 'PASS' else 'FAIL' end, coalesce(p_detail, ''))
  on conflict (scenario) do update
    set status = excluded.status, detail = excluded.detail;
end;
$$;

create or replace function pg_temp.as_user(p_user_id uuid)
returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_user_id::text, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);
end;
$$;

create or replace function pg_temp.as_postgres()
returns void
language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
end;
$$;

create or replace function pg_temp.expect_exception(
  p_scenario text,
  p_sql text,
  p_errcode text default null,
  p_message_like text default null
) returns void
language plpgsql as $$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
    perform pg_temp.pass(p_scenario, false, 'expected exception, got success');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform pg_temp.pass(
      p_scenario,
      (p_errcode is null or v_state = p_errcode)
        and (p_message_like is null or v_msg ilike '%' || p_message_like || '%'),
      format('state=%s msg=%s', v_state, v_msg)
    );
  end;
end;
$$;

do $$
declare
  v_group uuid := 'a1111111-1111-1111-1111-111111111111';
  v_org uuid := 'a2222222-2222-2222-2222-222222222222';
  v_s1 uuid := 'a3333333-3333-3333-3333-333333333333';
  v_s2 uuid := 'a4444444-4444-4444-4444-444444444444';
  v_year uuid := 'a5555555-5555-5555-5555-555555555555';
  v_term uuid := 'a6666666-6666-6666-6666-666666666666';
  v_subject uuid := 'a7777777-7777-7777-7777-777777777777';
  v_space jsonb;
  v_team uuid;
  v_collection uuid;
  v_selection uuid;
  v_option uuid;
  v_ok1 boolean := false;
  v_ok2 boolean := false;
  v_flags jsonb;
  v_dup jsonb;
begin
  delete from public.group_topic_picks where user_id in (v_org, v_s1, v_s2);
  delete from public.group_topic_options where selection_id in (
    select id from public.group_topic_selections where group_id = v_group
  );
  delete from public.group_topic_events where selection_id in (
    select id from public.group_topic_selections where group_id = v_group
  );
  delete from public.group_topic_selections where group_id = v_group;
  delete from public.group_collection_contributions where user_id in (v_org, v_s1, v_s2);
  delete from public.group_collection_events where collection_id in (
    select id from public.group_collections where group_id = v_group
  );
  delete from public.group_collections where group_id = v_group;
  delete from public.team_members where user_id in (v_org, v_s1, v_s2);
  delete from public.chat_members where user_id in (v_org, v_s1, v_s2);
  delete from public.chats where team_id in (select id from public.teams where group_id = v_group);
  delete from public.teams where group_id = v_group;
  delete from public.student_enrollments where user_id in (v_org, v_s1, v_s2);
  delete from public.users where id in (v_org, v_s1, v_s2);
  delete from auth.identities where user_id in (v_org, v_s1, v_s2);
  delete from auth.users where id in (v_org, v_s1, v_s2);
  delete from public.subject_offerings where id in (
    select id from public.subject_offerings where group_id = v_group
  );
  delete from public.academic_terms where id = v_term;
  delete from public.academic_years where id = v_year;
  delete from public.subject_catalog where id = v_subject;
  delete from public.groups where id = v_group;

  insert into public.groups(id, name) values (v_group, 'STAGE13-RP');
  insert into public.academic_years(id, name, start_year, starts_on, ends_on, is_current)
  values (v_year, 'STAGE13-YEAR', 2099, '2099-09-01', '2100-08-31', true);
  insert into public.academic_terms(
    id, academic_year_id, term_in_year, term_sequence, name, starts_on, ends_on, is_current
  ) values (v_term, v_year, 1, 909901, 'STAGE13-TERM', '2099-09-01', '2100-01-31', true);
  insert into public.subject_catalog(id, canonical_name, normalized_name)
  values (v_subject, 'Stage13 Subject', 'stage13 subject');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.email, crypt('RoleplayPass1!', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()
  from (values
    (v_org, 's13.org@local.test'),
    (v_s1, 's13.s1@local.test'),
    (v_s2, 's13.s2@local.test')
  ) as u(id, email);

  insert into public.users (
    id, login, name, surname, role, primary_group_id, group_name, is_active
  ) values
    (v_org, 's13org', 'Org', 'Anizer', 'starosta', v_group, 'STAGE13-RP', true),
    (v_s1, 's13s1', 'Stu', 'One', 'student', v_group, 'STAGE13-RP', true),
    (v_s2, 's13s2', 'Stu', 'Two', 'student', v_group, 'STAGE13-RP', true);

  insert into public.student_enrollments(user_id, group_id, status)
  values (v_org, v_group, 'active'), (v_s1, v_group, 'active'), (v_s2, v_group, 'active');

  -- Idempotent ensure_group_space
  perform pg_temp.as_user(v_org);
  v_space := public.ensure_group_space();
  v_dup := public.ensure_group_space();
  perform pg_temp.as_postgres();
  v_team := (v_space ->> 'team_id')::uuid;
  perform pg_temp.pass(
    'ensure_group_space idempotent',
    (v_dup ->> 'team_id') = (v_space ->> 'team_id')
      and (select count(*) from public.teams where group_id = v_group and kind = 'group_space') = 1
      and coalesce((v_space ->> 'is_organizer')::boolean, false) = true,
    v_space::text
  );

  -- Student cannot insert teams directly
  perform pg_temp.as_user(v_s1);
  perform pg_temp.expect_exception(
    'student cannot insert teams',
    format($sql$insert into public.teams(name, group_id, kind) values ('x', %L::uuid, 'group_space')$sql$, v_group),
    null,
    null
  );
  perform pg_temp.as_postgres();

  -- Collection create by organizer + contribute by student
  perform pg_temp.as_user(v_org);
  v_collection := public.create_group_collection(
    'Сбор RP', 'desc', 'purpose', null, null
  );
  perform pg_temp.as_user(v_s1);
  perform public.upsert_my_collection_contribution(
    v_collection, 'joining', 'pending_review', null, 'ok', null
  );
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'collection contribution upsert',
    exists (
      select 1 from public.group_collection_contributions
      where collection_id = v_collection and user_id = v_s1
        and participation_status = 'joining'
    ),
    ''
  );

  -- Topic race: capacity 1, two students try to pick
  perform pg_temp.as_user(v_org);
  v_selection := public.create_topic_selection('Темы RP', 'd', null, true);
  v_option := public.add_topic_option(v_selection, 'Only seat', 1, 1);

  begin
    perform pg_temp.as_user(v_s1);
    perform public.pick_topic(v_selection, v_option);
    v_ok1 := true;
  exception when others then
    v_ok1 := false;
  end;
  begin
    perform pg_temp.as_user(v_s2);
    perform public.pick_topic(v_selection, v_option);
    v_ok2 := true;
  exception when others then
    v_ok2 := false;
  end;
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'topic capacity race one winner',
    (v_ok1 and not v_ok2) or (v_ok2 and not v_ok1),
    format('s1=%s s2=%s picks=%s', v_ok1, v_ok2,
      (select count(*) from public.group_topic_picks where option_id = v_option))
  );

  -- Feature flags
  perform pg_temp.as_user(v_s1);
  v_flags := public.get_review_feature_flags();
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'reviews text flag off / structured on',
    coalesce((v_flags ->> 'reviews.text_enabled')::boolean, true) = false
      and coalesce((v_flags ->> 'reviews.structured_enabled')::boolean, false) = true,
    v_flags::text
  );

  -- anon cannot execute sensitive RPCs
  perform set_config('role', 'anon', true);
  perform pg_temp.expect_exception(
    'anon cannot ensure_group_space',
    'select public.ensure_group_space()',
    null,
    null
  );
  perform pg_temp.as_postgres();
end;
$$;

do $$
declare
  v_fail int;
begin
  select count(*) into v_fail from stage13_roleplay_results where status = 'FAIL';
  if v_fail > 0 then
    raise exception 'Stage13 role-play failures: %', (
      select string_agg(scenario || ': ' || detail, '; ')
      from stage13_roleplay_results where status = 'FAIL'
    );
  end if;
end;
$$;

select scenario, status, detail from stage13_roleplay_results order by scenario;
