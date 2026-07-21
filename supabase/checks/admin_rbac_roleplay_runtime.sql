-- Stage 12.1 LOCAL runtime role-play (B/C scenarios).
-- Run only against local Supabase: supabase db query --local -f ...
-- Never use --linked / remote.

\set ON_ERROR_STOP on

create temporary table if not exists roleplay_results (
  scenario text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null default ''
) on commit preserve rows;

truncate roleplay_results;
-- Tests switch to authenticated/anon; keep result logging writable.
grant all on table roleplay_results to authenticated, anon, service_role;

create or replace function pg_temp.expect_pass(p_scenario text, p_ok boolean, p_detail text)
returns void
language plpgsql
as $$
begin
  insert into roleplay_results(scenario, status, detail)
  values (p_scenario, case when p_ok then 'PASS' else 'FAIL' end, coalesce(p_detail, ''))
  on conflict (scenario) do update
    set status = excluded.status,
        detail = excluded.detail;
end;
$$;

create or replace function pg_temp.expect_exception(
  p_scenario text,
  p_sql text,
  p_errcode text default null,
  p_message_like text default null
)
returns void
language plpgsql
as $$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
    perform pg_temp.expect_pass(p_scenario, false, 'expected exception, but statement succeeded');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if p_errcode is not null and v_state is distinct from p_errcode then
      perform pg_temp.expect_pass(
        p_scenario,
        false,
        format('errcode %s (expected %s): %s', v_state, p_errcode, v_msg)
      );
    elsif p_message_like is not null and v_msg not ilike ('%' || p_message_like || '%') then
      perform pg_temp.expect_pass(
        p_scenario,
        false,
        format('message %L did not match %L (state=%s)', v_msg, p_message_like, v_state)
      );
    else
      perform pg_temp.expect_pass(
        p_scenario,
        true,
        format('%s: %s', v_state, v_msg)
      );
    end if;
  end;
end;
$$;

create or replace function pg_temp.as_user(p_uid uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);
end;
$$;

create or replace function pg_temp.as_anon()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'anon')::text,
    true
  );
  perform set_config('role', 'anon', true);
end;
$$;

create or replace function pg_temp.as_service()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text,
    true
  );
  reset role;
end;
$$;

-- ---------------------------------------------------------------------------
-- Seed users / scopes as postgres (bypass RLS)
-- ---------------------------------------------------------------------------
do $$
declare
  v_student uuid := '11111111-1111-1111-1111-111111111111';
  v_other uuid := '22222222-2222-2222-2222-222222222222';
  v_content uuid := '33333333-3333-3333-3333-333333333333';
  v_academic uuid := '44444444-4444-4444-4444-444444444444';
  v_super1 uuid := '55555555-5555-5555-5555-555555555555';
  v_super2 uuid := '66666666-6666-6666-6666-666666666666';
  v_group uuid := '77777777-7777-7777-7777-777777777777';
  v_group_other uuid := '88888888-8888-8888-8888-888888888888';
  v_subject uuid := '99999999-9999-9999-9999-999999999999';
begin
  -- Clean previous role-play artifacts (idempotent re-run).
  delete from public.admin_role_assignments
  where user_id in (v_student, v_other, v_content, v_academic, v_super1, v_super2);
  delete from public.admin_audit_log
  where actor_user_id in (v_student, v_other, v_content, v_academic, v_super1, v_super2);
  delete from public.users
  where id in (v_student, v_other, v_content, v_academic, v_super1, v_super2);
  delete from auth.identities
  where user_id in (v_student, v_other, v_content, v_academic, v_super1, v_super2);
  delete from auth.users
  where id in (v_student, v_other, v_content, v_academic, v_super1, v_super2);
  delete from public.groups where id in (v_group, v_group_other);
  delete from public.subject_catalog where id = v_subject;

  insert into public.groups(id, name) values
    (v_group, 'ROLEPLAY-A'),
    (v_group_other, 'ROLEPLAY-B');
  insert into public.subject_catalog(id, name) values (v_subject, 'Roleplay Subject');

  -- Minimal auth.users rows (password triggers need real auth users).
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  )
  select
    '00000000-0000-0000-0000-000000000000',
    u.id,
    'authenticated',
    'authenticated',
    u.email,
    crypt('RoleplayPass1!', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  from (
    values
      (v_student, 'student@local.test'),
      (v_other, 'other@local.test'),
      (v_content, 'content@local.test'),
      (v_academic, 'academic@local.test'),
      (v_super1, 'super1@local.test'),
      (v_super2, 'super2@local.test')
  ) as u(id, email);

  insert into public.users (
    id, login, name, surname, university, group_name, role,
    primary_group_id, must_change_password, status
  ) values
    (v_student, 'student', 'Stu', 'Dent', 'Uni A', 'ROLEPLAY-A', 'student', v_group, true, 'Онлайн'),
    (v_other, 'other', 'Oth', 'Er', 'Uni A', 'ROLEPLAY-A', 'student', v_group, false, 'Онлайн'),
    (v_content, 'content', 'Con', 'Tent', 'Uni A', 'ROLEPLAY-A', 'student', v_group, false, 'Онлайн'),
    (v_academic, 'academic', 'Aca', 'Dem', 'Uni A', 'ROLEPLAY-A', 'student', v_group, false, 'Онлайн'),
    (v_super1, 'super1', 'Super', 'One', 'Uni A', 'ROLEPLAY-A', 'student', v_group, false, 'Онлайн'),
    (v_super2, 'super2', 'Super', 'Two', 'Uni A', 'ROLEPLAY-A', 'student', v_group, false, 'Онлайн');

  -- Assignments (granted_by null / other to satisfy no-self-grant constraint).
  insert into public.admin_role_assignments (
    user_id, role_code, scope_type, scope_id, is_active, expires_at, granted_by
  ) values
    (v_content, 'content_editor', 'global', null, true, null, v_super1),
    (v_academic, 'academic_editor', 'group', v_group, true, null, v_super1),
    (v_academic, 'academic_editor', 'group', v_group_other, true, now() - interval '1 day', v_super1),
    (v_super1, 'super_admin', 'global', null, true, null, null),
    (v_super2, 'super_admin', 'global', null, true, null, v_super1);
end;
$$;

-- ===========================================================================
-- B/C scenarios
-- ===========================================================================

-- B-student-1: empty capabilities
do $$
declare
  v_student uuid := '11111111-1111-1111-1111-111111111111';
  v_caps jsonb;
  v_perms jsonb;
begin
  perform pg_temp.as_user(v_student);
  v_caps := public.get_my_admin_capabilities();
  v_perms := coalesce(v_caps -> 'permissions', '[]'::jsonb);
  perform pg_temp.expect_pass(
    'B1 student capabilities empty',
    jsonb_typeof(v_perms) = 'array' and jsonb_array_length(v_perms) = 0,
    v_caps::text
  );
end;
$$;

-- B-student-2: cannot assign roles
do $$
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  perform pg_temp.expect_exception(
    'B2 student cannot assign roles',
    $sql$select public.admin_assign_role(
      '22222222-2222-2222-2222-222222222222',
      'viewer',
      'global',
      null,
      null
    )$sql$,
    '42501',
    'forbidden'
  );
end;
$$;

-- B-student-3: cannot read audit
do $$
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  perform pg_temp.expect_exception(
    'B3 student cannot read audit',
    $sql$select * from public.admin_list_audit_log(10, 0)$sql$,
    '42501',
    'forbidden'
  );
end;
$$;

-- B4: UPDATE role forbidden
do $$
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  perform pg_temp.expect_exception(
    'B4 UPDATE role forbidden',
    $sql$update public.users set role = 'admin' where id = auth.uid()$sql$,
    null,
    null
  );
end;
$$;

-- B5: UPDATE group_name forbidden (value change)
do $$
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  perform pg_temp.expect_exception(
    'B5 UPDATE group_name change forbidden',
    $sql$update public.users set group_name = 'HACKED' where id = auth.uid()$sql$,
    '42501',
    'users_group_name_immutable'
  );
end;
$$;

-- B6: old profile payload unchanged group/university works
do $$
declare
  v_cnt integer;
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  update public.users
  set
    name = name,
    surname = surname,
    university = university,
    group_name = group_name,
    status = status
  where id = auth.uid();
  get diagnostics v_cnt = row_count;
  perform pg_temp.expect_pass(
    'B6 old profile payload unchanged succeeds',
    v_cnt = 1,
    format('row_count=%s', v_cnt)
  );
end;
$$;

-- B7: own name/status changeable
do $$
declare
  v_name text;
  v_status text;
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  update public.users
  set name = 'StuUpdated', status = 'Занят'
  where id = auth.uid();
  select name, status into v_name, v_status
  from public.users where id = auth.uid();
  perform pg_temp.expect_pass(
    'B7 own name/status updatable',
    v_name = 'StuUpdated' and v_status = 'Занят',
    format('%s / %s', v_name, v_status)
  );
end;
$$;

-- B8: other profile not updatable
do $$
declare
  v_cnt integer;
  v_err text;
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  begin
    update public.users
    set name = 'Hijack'
    where id = '22222222-2222-2222-2222-222222222222';
    get diagnostics v_cnt = row_count;
    perform pg_temp.expect_pass(
      'B8 other profile not updatable',
      v_cnt = 0,
      format('row_count=%s (RLS blocked)', v_cnt)
    );
  exception when others then
    get stacked diagnostics v_err = message_text;
    perform pg_temp.expect_pass(
      'B8 other profile not updatable',
      true,
      format('exception: %s', v_err)
    );
  end;
end;
$$;

-- B9: anon writes absent
do $$
declare
  v_ok boolean := true;
  v_detail text := '';
begin
  perform pg_temp.as_anon();
  begin
    insert into public.users(id, login) values (gen_random_uuid(), 'anon_hack');
    v_ok := false;
    v_detail := 'anon INSERT succeeded';
  exception when others then
    v_detail := 'insert blocked: ' || SQLERRM;
  end;
  if v_ok then
    begin
      update public.users set name = 'x' where login = 'student';
      if found then
        v_ok := false;
        v_detail := 'anon UPDATE affected rows';
      else
        v_detail := v_detail || '; update no rows/privilege';
      end if;
    exception when others then
      v_detail := v_detail || '; update blocked: ' || SQLERRM;
    end;
  end if;
  perform pg_temp.expect_pass('B9 anon writes absent', v_ok, v_detail);
end;
$$;

-- B10: must_change_password direct clear forbidden
do $$
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  -- ensure flag is true
  perform pg_temp.as_service();
  update public.users
  set must_change_password = true
  where id = '11111111-1111-1111-1111-111111111111';

  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  perform pg_temp.expect_exception(
    'B10 direct must_change_password clear forbidden',
    $sql$update public.users set must_change_password = false where id = auth.uid()$sql$,
    '42501',
    'users_must_change_password_immutable'
  );
end;
$$;

-- B11: password trigger clears flag only after encrypted_password change
do $$
declare
  v_student uuid := '11111111-1111-1111-1111-111111111111';
  v_flag boolean;
  v_cnt integer;
begin
  perform pg_temp.as_service();
  update public.users set must_change_password = true where id = v_student;

  -- Non-password auth update must NOT clear the flag.
  update auth.users
  set updated_at = now()
  where id = v_student;

  select must_change_password into v_flag from public.users where id = v_student;
  if v_flag is distinct from true then
    perform pg_temp.expect_pass(
      'B11a non-password auth update keeps flag',
      false,
      format('flag became %s', v_flag)
    );
  else
    perform pg_temp.expect_pass(
      'B11a non-password auth update keeps flag',
      true,
      'flag still true'
    );
  end if;

  -- Real password change clears flag via trigger + GUC.
  update auth.users
  set encrypted_password = crypt('RoleplayPass2!', gen_salt('bf')),
      updated_at = now()
  where id = v_student;

  select must_change_password into v_flag from public.users where id = v_student;
  perform pg_temp.expect_pass(
    'B11b password change clears must_change_password',
    v_flag = false,
    format('flag=%s', v_flag)
  );

  -- Legacy false -> false follow-up succeeds.
  perform pg_temp.as_user(v_student);
  update public.users
  set must_change_password = false
  where id = auth.uid();
  get diagnostics v_cnt = row_count;
  perform pg_temp.expect_pass(
    'B11c legacy false->false UPDATE succeeds',
    v_cnt = 1,
    format('row_count=%s', v_cnt)
  );
end;
$$;

-- B12: presence RPC works
do $$
declare
  v_ts timestamptz;
  v_seen timestamptz;
begin
  perform pg_temp.as_user('11111111-1111-1111-1111-111111111111');
  v_ts := public.touch_my_presence();
  select last_seen_at into v_seen
  from public.users
  where id = auth.uid();
  perform pg_temp.expect_pass(
    'B12 presence RPC works',
    v_ts is not null and v_seen is not null and v_seen = v_ts,
    format('ts=%s seen=%s', v_ts, v_seen)
  );
end;
$$;

-- B13: content_editor lacks academic/roles/audit
do $$
declare
  v_caps jsonb;
  v_perms text;
  v_ok boolean;
begin
  perform pg_temp.as_user('33333333-3333-3333-3333-333333333333');
  v_caps := public.get_my_admin_capabilities();
  v_perms := coalesce(v_caps -> 'permissions', '[]'::jsonb)::text;
  v_ok :=
    v_perms like '%content.%'
    and v_perms not like '%academic.%'
    and v_perms not like '%roles.%'
    and v_perms not like '%audit.%';
  perform pg_temp.expect_pass(
    'B13 content_editor no academic/roles/audit',
    v_ok,
    v_perms
  );

  perform pg_temp.expect_exception(
    'B13b content_editor cannot assign roles',
    $sql$select public.admin_assign_role(
      '22222222-2222-2222-2222-222222222222',
      'viewer',
      'global',
      null,
      null
    )$sql$,
    '42501',
    'forbidden'
  );
end;
$$;

-- B14/B15: scope + expiry — private.has_admin_permission is not granted to
-- authenticated, so evaluate as postgres while JWT still reflects the user.
do $$
declare
  v_uid uuid := '44444444-4444-4444-4444-444444444444';
  v_group uuid := '77777777-7777-7777-7777-777777777777';
  v_group_other uuid := '88888888-8888-8888-8888-888888888888';
  v_ok_in boolean;
  v_ok_out boolean;
  v_ok_expired boolean;
  v_caps jsonb;
  v_scopes text;
begin
  reset role;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_ok_in := private.has_admin_permission(v_uid, 'academic.read', 'group', v_group);
  v_ok_out := private.has_admin_permission(v_uid, 'academic.read', 'group', v_group_other);
  v_ok_expired := private.has_admin_permission(
    v_uid, 'subjects.write', 'group', v_group_other
  );

  perform pg_temp.expect_pass(
    'B14 scope limits academic_editor',
    v_ok_in is true and v_ok_out is not true,
    format('in_scope=%s out_or_expired=%s', v_ok_in, v_ok_out)
  );
  perform pg_temp.expect_pass(
    'B15 expired assignment ineffective',
    v_ok_expired is not true,
    format('expired_group_subjects_write=%s', v_ok_expired)
  );

  -- Also confirm capabilities JSON assignments omit expired group.
  perform pg_temp.as_user(v_uid);
  v_caps := public.get_my_admin_capabilities();
  v_scopes := coalesce(v_caps -> 'assignments', '[]'::jsonb)::text;
  perform pg_temp.expect_pass(
    'B15b capabilities omit expired scope',
    v_scopes like '%' || v_group::text || '%'
      and v_scopes not like '%' || v_group_other::text || '%',
    v_scopes
  );
end;
$$;

-- B16: last super_admin cannot be revoked
do $$
declare
  v_super1 uuid := '55555555-5555-5555-5555-555555555555';
  v_super2 uuid := '66666666-6666-6666-6666-666666666666';
  v_content uuid := '33333333-3333-3333-3333-333333333333';
  v_id1 uuid;
  v_id2 uuid;
begin
  reset role;

  delete from public.admin_role_assignments
  where user_id in (v_super1, v_super2);

  insert into public.admin_role_assignments (
    user_id, role_code, scope_type, scope_id, is_active, expires_at, granted_by
  ) values
    (v_super1, 'super_admin', 'global', null, true, null, null),
    (v_super2, 'super_admin', 'global', null, true, null, v_super1);

  select id into v_id2 from public.admin_role_assignments
  where user_id = v_super2 and role_code = 'super_admin' and is_active;
  select id into v_id1 from public.admin_role_assignments
  where user_id = v_super1 and role_code = 'super_admin' and is_active;

  -- Two supers: super1 revokes super2.
  perform pg_temp.as_user(v_super1);
  perform public.admin_revoke_role(v_id2);

  reset role;
  -- Re-add super2, then super2 revokes super1 => super2 is last.
  insert into public.admin_role_assignments (
    user_id, role_code, scope_type, scope_id, is_active, expires_at, granted_by
  ) values (v_super2, 'super_admin', 'global', null, true, null, v_super1);

  select id into v_id1 from public.admin_role_assignments
  where user_id = v_super1 and role_code = 'super_admin' and is_active;
  select id into v_id2 from public.admin_role_assignments
  where user_id = v_super2 and role_code = 'super_admin' and is_active;

  perform pg_temp.as_user(v_super2);
  perform public.admin_revoke_role(v_id1);

  reset role;
  -- Temporary roles.manage on content_editor to attempt last revoke.
  insert into public.admin_role_permissions(role_code, permission_code)
  values ('content_editor', 'roles.manage')
  on conflict do nothing;

  insert into public.admin_role_assignments (
    user_id, role_code, scope_type, scope_id, is_active, expires_at, granted_by
  )
  select v_content, 'content_editor', 'global', null, true, null, v_super2
  where not exists (
    select 1 from public.admin_role_assignments
    where user_id = v_content and role_code = 'content_editor' and is_active
  );

  select id into v_id2 from public.admin_role_assignments
  where user_id = v_super2 and role_code = 'super_admin' and is_active;

  perform pg_temp.as_user(v_content);
  perform pg_temp.expect_exception(
    'B16 last super_admin cannot be revoked',
    format($sql$select public.admin_revoke_role(%L::uuid)$sql$, v_id2),
    null,
    'last_super_admin'
  );

  reset role;
  delete from public.admin_role_permissions
  where role_code = 'content_editor' and permission_code = 'roles.manage';
end;
$$;

-- B17: self-grant forbidden
do $$
declare
  v_super1 uuid := '55555555-5555-5555-5555-555555555555';
begin
  reset role;
  insert into public.admin_role_assignments (
    user_id, role_code, scope_type, scope_id, is_active, expires_at, granted_by
  )
  select v_super1, 'super_admin', 'global', null, true, null, null
  where not exists (
    select 1 from public.admin_role_assignments
    where user_id = v_super1 and role_code = 'super_admin' and is_active
  );

  perform pg_temp.as_user(v_super1);
  perform pg_temp.expect_exception(
    'B17 self-grant forbidden',
    format(
      $sql$select public.admin_assign_role(%L::uuid, 'viewer', 'global', null, null)$sql$,
      v_super1
    ),
    '42501',
    'self_assignment'
  );
end;
$$;

-- C1/C3: signup server path works (anon calls RPC; verify as postgres)
do $$
declare
  v_id uuid;
  v_login text := 'signup_' || substr(gen_random_uuid()::text, 1, 8);
  v_exists boolean;
begin
  perform pg_temp.as_anon();
  v_id := public.register_local_user(
    v_login,
    'TempPass123!',
    'Sign',
    'Up',
    'Test University',
    'TEST-GROUP'
  );

  reset role;
  select exists(select 1 from public.users u where u.id = v_id and u.login = v_login)
    into v_exists;
  perform pg_temp.expect_pass(
    'C1 signup server path works',
    v_id is not null and v_exists,
    format('id=%s login=%s', v_id, v_login)
  );
exception when others then
  reset role;
  perform pg_temp.expect_pass(
    'C1 signup server path works',
    false,
    SQLERRM
  );
end;
$$;

-- C2: register_local_user executable by anon + security definer
do $$
declare
  v_anon boolean;
  v_secdef boolean;
begin
  select
    has_function_privilege('anon', p.oid, 'EXECUTE'),
    p.prosecdef
  into v_anon, v_secdef
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'register_local_user'
  limit 1;

  perform pg_temp.expect_pass(
    'C2 register_local_user anon + security_definer',
    v_anon and v_secdef,
    format('anon_exec=%s security_definer=%s', v_anon, v_secdef)
  );
end;
$$;

-- Reset role for reporting
reset role;
select set_config('request.jwt.claim.sub', '', true);

select scenario, status, detail
from roleplay_results
order by scenario;

select
  count(*) filter (where status = 'PASS') as pass_count,
  count(*) filter (where status = 'FAIL') as fail_count,
  count(*) as total
from roleplay_results;
