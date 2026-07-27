-- Stage 13.2 LOCAL security review. Run only against a disposable local database
-- after 20260727140000_stage13_2_group_space.sql. It does not write application data.
--
-- Validation status note for agents:
-- If the full dependency stack (teams/chats/enrollments/archive helpers) cannot be
-- applied locally in this environment, record UNKNOWN_DB_LOCAL_VALIDATION and do
-- not treat Stage 13.2 as remote-ready. Remote apply remains forbidden without
-- explicit owner permission.

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

-- Capacity/race safety: pick_topic serializes on the option row before counting
-- picks. For a live two-session role-play, create a capacity=1 option and invoke
-- pick_topic from two enrolled users concurrently; exactly one must succeed.
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
