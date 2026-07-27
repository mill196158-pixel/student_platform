-- Stage 13.2 LOCAL security review. Assertive; fails on deviation.
\set ON_ERROR_STOP on

-- A group can have at most one permanent group-space team.
do $$
begin
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and tablename = 'teams'
      and indexname = 'teams_one_group_space_per_group_idx'
      and indexdef like '%WHERE ((kind = ''group_space''::text) AND (group_id IS NOT NULL))%'
  ) then
    raise exception 'missing partial unique index for group-space teams';
  end if;

  if exists (
    select 1 from public.teams
    where kind = 'group_space'
    group by group_id
    having count(*) > 1
  ) then
    raise exception 'more than one group-space team exists for a group';
  end if;
end;
$$;

-- Students must not gain direct write access to group-space state or teams.
do $$
declare
  v_rel regclass;
begin
  foreach v_rel in array array[
    'public.group_collections'::regclass,
    'public.group_collection_contributions'::regclass,
    'public.group_collection_events'::regclass,
    'public.group_topic_selections'::regclass,
    'public.group_topic_options'::regclass,
    'public.group_topic_picks'::regclass,
    'public.group_topic_events'::regclass
  ] loop
    if has_table_privilege('authenticated', v_rel, 'insert')
       or has_table_privilege('authenticated', v_rel, 'update')
       or has_table_privilege('authenticated', v_rel, 'delete') then
      raise exception 'authenticated has direct write privilege on %', v_rel;
    end if;
  end loop;

  if has_table_privilege('authenticated', 'public.teams'::regclass, 'insert') then
    raise exception 'student/authenticated role can insert teams directly';
  end if;
end;
$$;

-- Organizer confirmation is exclusively mediated by the organizer-checked RPC.
do $$
declare
  v_src text;
begin
  select pg_get_functiondef(
    'public.confirm_collection_contribution(uuid,uuid,text)'::regprocedure
  ) into v_src;
  if lower(v_src) not like '%private.is_group_space_organizer%' then
    raise exception 'confirm_collection_contribution lacks organizer guard';
  end if;
  if has_function_privilege(
    'anon',
    'public.confirm_collection_contribution(uuid,uuid,text)'::regprocedure,
    'execute'
  ) then
    raise exception 'anon can execute organizer confirmation RPC';
  end if;
end;
$$;

-- Capacity/race safety: pick_topic serializes on the option row before counting.
do $$
declare
  v_src text;
begin
  select pg_get_functiondef('public.pick_topic(uuid,uuid)'::regprocedure) into v_src;
  if lower(v_src) not like '%for update%'
     or lower(v_src) not like '%option_full%'
     or lower(v_src) not like '%count(*)%' then
    raise exception 'pick_topic lacks required option lock/capacity checks';
  end if;
end;
$$;

-- Permanent group spaces are not part of academic-term archival.
do $$
declare
  v_src text;
begin
  select pg_get_functiondef(
    'public.archive_academic_chats_for_term(uuid)'::regprocedure
  ) into v_src;
  if lower(v_src) not like '%t.kind<>''group_space''%' then
    raise exception 'archive_academic_chats_for_term does not exclude group spaces';
  end if;
end;
$$;

-- Organizer auth must use live admin grants / subject-team roles; never users.role.
do $$
declare
  v_auth text;
  v_refresh text;
begin
  select pg_get_functiondef('private.is_group_space_organizer(uuid)'::regprocedure)
    into v_auth;
  if position('users.role' in lower(v_auth)) > 0
     or position('u.role' in lower(v_auth)) > 0 then
    raise exception 'is_group_space_organizer must not read users.role';
  end if;
  if position('group_space_organizer_grants' in lower(v_auth)) = 0 then
    raise exception 'is_group_space_organizer must honor admin grants';
  end if;
  if position('is_active_subject_team_for_group' in lower(v_auth)) = 0 then
    raise exception 'is_group_space_organizer must scope subject-team starosta to active offerings';
  end if;

  select pg_get_functiondef('private.refresh_group_space_organizer_grants(uuid)'::regprocedure)
    into v_refresh;
  if position('legacy_users_role' in lower(v_refresh)) > 0
     or position('u.role' in lower(v_refresh)) > 0
     or position('users.role' in lower(v_refresh)) > 0 then
    raise exception 'ongoing grant refresh must not use users.role/legacy source';
  end if;
  if position('is_active_subject_team_for_group' in lower(v_refresh)) = 0 then
    raise exception 'grant refresh must rebuild only from active subject teams';
  end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'team_members'
      and t.tgname = 'trg_subject_team_members_reconcile_group_space'
      and not t.tgisinternal
  ) then
    raise exception 'missing subject-team reconcile trigger for organizer revoke';
  end if;

  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'group_space_organizer_grants'
      and c.relrowsecurity and c.relforcerowsecurity
  ) then
    raise exception 'group_space_organizer_grants missing FORCE RLS';
  end if;

  if has_table_privilege('authenticated', 'public.group_space_organizer_grants', 'insert')
     or has_table_privilege('authenticated', 'public.group_space_organizer_grants', 'update')
     or has_table_privilege('authenticated', 'public.group_space_organizer_grants', 'select') then
    raise exception 'authenticated has direct access to organizer grants';
  end if;
end;
$$;
