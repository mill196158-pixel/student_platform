-- Synthetic fixture assertions. No remote execution; fixture roles and rows are fake.
do $$ begin
  if current_database() <> 'assignment_security_fixture' or inet_server_addr() <> '127.0.0.1'::inet then
    raise exception 'Run only against the named disposable local database';
  end if;
  if has_function_privilege('anon','public.get_team_assignments(uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_team_assignments(uuid)','EXECUTE')
     or not has_function_privilege('service_role','public.get_team_assignments(uuid)','EXECUTE') then
    raise exception 'Unexpected execution grants';
  end if;
  if pg_get_function_result('public.get_team_assignments(uuid)'::regprocedure) <>
    'TABLE(id uuid, title text, description text, link text, due text, due_at timestamp with time zone, attachments jsonb, published boolean, status text, published_at timestamp with time zone, votes integer, completed_by_me boolean, created_by uuid, created_at timestamp with time zone, group_id uuid, subject_id uuid, subject_offering_id uuid, academic_year_id uuid, academic_term_id uuid, semester_number integer)' then
    raise exception 'function return contract changed';
  end if;
  if not exists(select 1 from pg_proc where oid='public.get_team_assignments(uuid)'::regprocedure
    and prosecdef and proconfig = array['search_path=""']) then
    raise exception 'Expected security definer and empty search path';
  end if;
end $$;
set role anon;
do $$ begin
  begin
    perform * from public.get_team_assignments('10000000-0000-0000-0000-000000000001');
    raise exception 'anon unexpectedly executed function';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','',false);
do $$ begin
  if exists(select 1 from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) then
    raise exception 'missing uid returned rows';
  end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
do $$ begin
  if (select count(*) from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) <> 1
    or (select count(*) from public.assignments where team_id='10000000-0000-0000-0000-000000000001') <> 1
    or (select count(*) from public.assignments where team_id='20000000-0000-0000-0000-000000000002') <> 0
    or not exists(select 1 from public.get_team_assignments('10000000-0000-0000-0000-000000000001')
      where title='fixture one' and votes=1 and completed_by_me and published)
    or exists(select 1 from public.get_team_assignments('20000000-0000-0000-0000-000000000002'))
    or exists(select 1 from public.get_team_assignments(null)) then
    raise exception 'member payload or isolation mismatch';
  end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
do $$ begin
  if (select count(*) from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) <> 1 then
    raise exception 'teacher member lost access';
  end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
do $$ begin
  if (select count(*) from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) <> 1 then
    raise exception 'admin member lost access';
  end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
do $$ begin
  if (select count(*) from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) <> 1 then
    raise exception 'existing stale membership no longer matches table RLS';
  end if;
end $$;
reset role;
delete from public.team_members where team_id='10000000-0000-0000-0000-000000000001'
  and user_id='00000000-0000-0000-0000-000000000004';
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
do $$ begin
  if exists(select 1 from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) then
    raise exception 'removed membership still returned rows';
  end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false);
do $$ begin
  if (select count(*) from public.get_team_assignments('20000000-0000-0000-0000-000000000002')) <> 1 then
    raise exception 'group-space member lost access';
  end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000006',false);
do $$ begin
  if (select count(*) from public.get_team_assignments('30000000-0000-0000-0000-000000000003')) <> 1 then
    raise exception 'archived direct member lost access';
  end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000007',false);
do $$ begin
  if exists(select 1 from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) then
    raise exception 'nonmember returned rows';
  end if;
end $$;
reset role;
set role service_role;
select set_config('request.jwt.claim.sub','',false);
do $$ begin
  if exists(select 1 from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) then
    raise exception 'service role without uid returned rows';
  end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
do $$ begin
  if (select count(*) from public.get_team_assignments('10000000-0000-0000-0000-000000000001')) <> 1 then
    raise exception 'service role with member uid lost access';
  end if;
end $$;
reset role;
