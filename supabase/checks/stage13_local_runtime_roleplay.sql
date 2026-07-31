-- Stage 13 LOCAL runtime role-play. Disposable DB only. Never --linked.
-- Organizer model: admin grants + live active subject-team starosta/owner.
-- users.role is never auth (one-time migration backfill only).
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
  v_admin uuid := 'a5555555-5555-5555-5555-555555555555';
  v_year uuid := 'a6666666-6666-6666-6666-666666666666';
  v_term uuid := 'a7777777-7777-7777-7777-777777777777';
  v_subject uuid := 'a8888888-8888-8888-8888-888888888888';
  v_offering uuid := 'a9999999-9999-9999-9999-999999999999';
  v_subject_team uuid;
  v_space jsonb;
  v_team uuid;
  v_collection uuid;
  v_selection uuid;
  v_ok boolean;
  v_flags jsonb;
begin
  delete from public.group_space_organizer_grants where group_id = v_group;
  delete from public.group_topic_picks where user_id in (v_org, v_s1, v_s2, v_admin);
  delete from public.group_topic_options where selection_id in (
    select id from public.group_topic_selections where group_id = v_group
  );
  delete from public.group_topic_events where selection_id in (
    select id from public.group_topic_selections where group_id = v_group
  );
  delete from public.group_topic_selections where group_id = v_group;
  delete from public.group_collection_contributions where user_id in (v_org, v_s1, v_s2, v_admin);
  delete from public.group_collection_events where collection_id in (
    select id from public.group_collections where group_id = v_group
  );
  delete from public.group_collections where group_id = v_group;
  delete from public.team_members where user_id in (v_org, v_s1, v_s2, v_admin);
  delete from public.chat_members where user_id in (v_org, v_s1, v_s2, v_admin);
  delete from public.chats where team_id in (select id from public.teams where group_id = v_group);
  delete from public.teams where group_id = v_group;
  delete from public.admin_role_assignments where user_id in (v_org, v_s1, v_s2, v_admin);
  delete from public.student_enrollments where user_id in (v_org, v_s1, v_s2, v_admin);
  delete from public.subject_offerings where id = v_offering;
  delete from public.users where id in (v_org, v_s1, v_s2, v_admin);
  delete from auth.identities where user_id in (v_org, v_s1, v_s2, v_admin);
  delete from auth.users where id in (v_org, v_s1, v_s2, v_admin);
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
  insert into public.subject_offerings(
    id, subject_id, group_id, academic_year_id, academic_term_id, semester_number, display_name
  ) values (v_offering, v_subject, v_group, v_year, v_term, 1, 'Stage13 Subject');

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
    (v_s2, 's13.s2@local.test'),
    (v_admin, 's13.admin@local.test')
  ) as u(id, email);

  -- All accounts are student in users.role (matches live). Starosta comes from subject team.
  insert into public.users (
    id, login, name, surname, role, primary_group_id, group_name, is_active
  ) values
    (v_org, 's13org', 'Org', 'Anizer', 'student', v_group, 'STAGE13-RP', true),
    (v_s1, 's13s1', 'Stu', 'One', 'student', v_group, 'STAGE13-RP', true),
    (v_s2, 's13s2', 'Stu', 'Two', 'student', v_group, 'STAGE13-RP', true),
    (v_admin, 's13adm', 'Ad', 'Min', 'student', v_group, 'STAGE13-RP', true);

  insert into public.student_enrollments(user_id, group_id, status)
  values
    (v_org, v_group, 'active'),
    (v_s1, v_group, 'active'),
    (v_s2, v_group, 'active'),
    (v_admin, v_group, 'active');

  -- Subject team with academic starosta (authoritative source).
  insert into public.teams(
    id, name, group_id, subject_id, subject_offering_id,
    academic_year_id, academic_term_id, semester_number, kind
  ) values (
    gen_random_uuid(), 'RP Subject Team', v_group, v_subject, v_offering,
    v_year, v_term, 1, 'subject'
  ) returning id into v_subject_team;
  insert into public.team_members(team_id, user_id, role) values
    (v_subject_team, v_org, 'starosta'),
    (v_subject_team, v_s1, 'member'),
    (v_subject_team, v_s2, 'member');

  -- Admin RBAC user is NOT a group organizer.
  insert into public.admin_role_assignments(
    user_id, role_code, scope_type, scope_id, is_active, granted_by
  ) values (v_admin, 'content_editor', 'global', null, true, null);

  perform pg_temp.as_user(v_org);
  v_space := public.ensure_group_space();
  perform pg_temp.as_postgres();
  v_team := (v_space ->> 'team_id')::uuid;
  perform pg_temp.pass(
    'subject-team starosta becomes group-space organizer',
    coalesce((v_space ->> 'is_organizer')::boolean, false)
      and exists (
        select 1 from public.group_space_organizer_grants g
        where g.group_id = v_group and g.user_id = v_org and g.source = 'subject_team'
      )
      and exists (
        select 1 from public.team_members tm
        where tm.team_id = v_team and tm.user_id = v_org and tm.role = 'starosta'
      ),
    v_space::text
  );

  -- Student cannot manage collections/topics.
  perform pg_temp.as_user(v_s1);
  perform pg_temp.expect_exception(
    'student cannot create collection',
    $sql$select public.create_group_collection('nope', '', '', null, null)$sql$,
    '42501',
    'forbidden'
  );
  perform pg_temp.expect_exception(
    'student cannot create topic selection',
    $sql$select public.create_topic_selection('nope', '', null, true)$sql$,
    '42501',
    'forbidden'
  );

  -- Starosta can manage collections/topics.
  perform pg_temp.as_user(v_org);
  begin
    v_collection := public.create_group_collection('Сбор RP', 'd', 'p', null, null);
    v_selection := public.create_topic_selection('Темы RP', 'd', null, true);
    v_ok := true;
  exception when others then
    v_ok := false;
    v_collection := null;
    v_selection := null;
  end;
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'starosta can create collection and topic',
    v_ok and v_collection is not null and v_selection is not null,
    format('collection=%s selection=%s', v_collection, v_selection)
  );

  -- Revoke academic starosta: auth checks live subject-team role (no manual sync).
  update public.team_members
  set role = 'member'
  where team_id = v_subject_team and user_id = v_org;
  perform pg_temp.as_user(v_org);
  begin
    perform public.create_group_collection('after revoke', '', '', null, null);
    v_ok := true;
  exception when others then
    v_ok := false;
  end;
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'losing subject starosta revokes organizer immediately',
    not v_ok
      and not exists (
        select 1 from public.group_space_organizer_grants g
        where g.group_id = v_group and g.user_id = v_org and g.source = 'subject_team'
      ),
    ''
  );

  -- Restore via admin grant (RBAC-managed set_group_space_organizer), not users.role.
  perform pg_temp.as_user(v_admin);
  -- content_editor is NOT enough for set_group_space_organizer (needs is_group_space_admin).
  perform pg_temp.expect_exception(
    'content_editor cannot set group-space organizer',
    format(
      $sql$select public.set_group_space_organizer(%L::uuid, %L::uuid, true)$sql$,
      v_group, v_org
    ),
    '42501',
    'forbidden'
  );

  -- Elevate admin with subjects.write-equivalent via super_admin for grant path.
  insert into public.admin_role_assignments(
    user_id, role_code, scope_type, scope_id, is_active, granted_by
  ) values (v_admin, 'super_admin', 'global', null, true, null);
  perform pg_temp.as_user(v_admin);
  perform public.set_group_space_organizer(v_group, v_org, true);
  perform pg_temp.as_user(v_org);
  begin
    perform public.create_group_collection('admin grant', '', '', null, null);
    v_ok := true;
  exception when others then
    v_ok := false;
  end;
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'admin grant restores organizer without users.role',
    v_ok
      and exists (
        select 1 from public.group_space_organizer_grants g
        where g.group_id = v_group and g.user_id = v_org and g.source = 'admin'
      ),
    ''
  );

  -- Admin RBAC alone does not grant organizer powers.
  perform pg_temp.as_user(v_admin);
  perform pg_temp.expect_exception(
    'admin RBAC is not group organizer',
    $sql$select public.create_group_collection('rbac mix', '', '', null, null)$sql$,
    '42501',
    'forbidden'
  );

  -- Historical/archived subject-team starosta must not grant organizer powers.
  perform pg_temp.as_postgres();
  insert into public.subject_offerings(
    subject_id, group_id, academic_year_id, academic_term_id,
    semester_number, display_name, status
  ) values (
    v_subject, v_group, v_year, v_term, 1, 'RP Archived Subject', 'archived'
  );
  insert into public.teams(
    name, group_id, subject_id, subject_offering_id,
    academic_year_id, academic_term_id, semester_number, kind
  )
  select
    'RP Archived Subject', v_group, v_subject, so.id,
    v_year, v_term, 1, 'subject'
  from public.subject_offerings so
  where so.group_id = v_group and so.status = 'archived'
  order by so.created_at desc
  limit 1;
  insert into public.team_members(team_id, user_id, role)
  select t.id, v_s1, 'starosta'
  from public.teams t
  where t.group_id = v_group and t.name = 'RP Archived Subject'
  limit 1;
  perform private.refresh_group_space_organizer_grants(v_group);
  perform private.apply_group_space_cached_roles(v_group);
  perform pg_temp.as_user(v_s1);
  begin
    perform public.create_group_collection('stale subject', '', '', null, null);
    v_ok := true;
  exception when others then
    v_ok := false;
  end;
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'archived subject-team starosta does not grant organizer',
    not v_ok,
    ''
  );

  -- Client cannot spoof users.role; even a server-side users.role write does not authorize.
  perform pg_temp.as_user(v_s1);
  perform set_config('role', 'authenticated', true);
  -- Either table privilege denial or guard_users_self_update is acceptable.
  perform pg_temp.expect_exception(
    'client cannot change users.role',
    format($sql$update public.users set role = 'starosta' where id = %L::uuid$sql$, v_s1),
    '42501',
    null
  );
  perform pg_temp.as_postgres();
  update public.users set role = 'starosta' where id = v_s2;
  perform pg_temp.as_user(v_s2);
  perform public.sync_group_space_members(null);
  begin
    perform public.create_topic_selection('users.role ignored', '', null, true);
    v_ok := true;
  exception when others then
    v_ok := false;
  end;
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'users.role is ignored by ongoing sync/auth',
    not v_ok
      and not exists (
        select 1 from public.group_space_organizer_grants g
        where g.group_id = v_group and g.user_id = v_s2
      ),
    ''
  );
  update public.users set role = 'student' where id = v_s2;

  -- Ensure_group_space remains idempotent.
  perform pg_temp.as_user(v_org);
  v_space := public.ensure_group_space();
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'ensure_group_space idempotent',
    (select count(*) from public.teams where group_id = v_group and kind = 'group_space') = 1,
    v_space::text
  );

  perform pg_temp.as_user(v_s1);
  perform set_config('role', 'authenticated', true);
  perform pg_temp.expect_exception(
    'student cannot insert teams',
    format($sql$insert into public.teams(name, group_id, kind) values ('x', %L::uuid, 'group_space')$sql$, v_group),
    '42501',
    null
  );
  perform pg_temp.as_postgres();

  perform pg_temp.as_user(v_s1);
  v_flags := public.get_review_feature_flags();
  perform pg_temp.as_postgres();
  perform pg_temp.pass(
    'reviews text flag off / structured on',
    coalesce((v_flags ->> 'reviews.text_enabled')::boolean, true) = false
      and coalesce((v_flags ->> 'reviews.structured_enabled')::boolean, false) = true,
    v_flags::text
  );

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
