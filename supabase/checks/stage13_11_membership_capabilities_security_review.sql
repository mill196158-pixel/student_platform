-- Stage 13.11 SQL security review (local/assertive).
\set ON_ERROR_STOP on

do $$
declare
  v_search text;
  v_acl text;
begin
  if to_regprocedure('public.get_chat_composer_capabilities(uuid)') is null then
    raise exception 'missing get_chat_composer_capabilities';
  end if;
  if to_regprocedure('public.delete_group_action(text,uuid)') is null then
    raise exception 'missing delete_group_action';
  end if;
  if to_regprocedure(
    'public.create_group_collection(text,text,text,timestamptz,numeric,text,text,text,numeric)'
  ) is null then
    raise exception 'missing create_group_collection with amount mode';
  end if;

  select pg_get_functiondef(oid) into v_search
  from pg_proc
  where oid = 'public.get_chat_composer_capabilities(uuid)'::regprocedure;
  if v_search not like '%search_path%''''%'
     and v_search not like '%search_path = ''''%' then
    -- accept SET search_path = ''
    if position('search_path' in v_search) = 0 then
      raise exception 'get_chat_composer_capabilities missing search_path lock';
    end if;
  end if;

  if v_search not like '%can_create_team_topics%'
     and v_search not like '%can_create_topic_selection%' then
    raise exception 'capabilities must expose create flags';
  end if;
  if v_search like '%v_can_topic := private.can_manage_team_topics%' then
    raise exception 'create topic still gated by can_manage (organizer-only)';
  end if;

  select pg_get_functiondef(oid) into v_search
  from pg_proc
  where oid = 'public.publish_topic_selection_for_chat(uuid,text,text,timestamptz,timestamptz,boolean,boolean,uuid,jsonb)'::regprocedure;
  if v_search like '%can_manage_team_topics%'
     and v_search not like '%can_create_team_topics%' then
    raise exception 'publish_topic_selection still organizer-only';
  end if;
  if position('can_create_team_topics' in v_search) = 0 then
    raise exception 'publish must use can_create_team_topics';
  end if;

  select pg_get_functiondef(oid) into v_search
  from pg_proc
  where oid = 'public.create_group_collection(text,text,text,timestamptz,numeric,text,text,text,numeric)'::regprocedure;
  if position('can_create_team_collections' in v_search) = 0 then
    raise exception 'create_group_collection must use can_create_team_collections';
  end if;

  select pg_get_functiondef(oid) into v_search
  from pg_proc
  where oid = 'public.confirm_collection_contribution(uuid,uuid,text,text)'::regprocedure;
  if position('self_confirm_forbidden' in v_search) = 0
     and position('p_user_id = auth.uid()' in v_search) = 0 then
    raise exception 'confirm_collection_contribution missing self-confirm guard';
  end if;

  select pg_get_functiondef(oid) into v_search
  from pg_proc
  where oid = 'public.upsert_my_collection_contribution(uuid,text,text,numeric,text,uuid)'::regprocedure;
  if position('organizer_comment' in v_search) = 0 then
    raise exception 'upsert must mention organizer_comment protection';
  end if;

  -- EXECUTE grants: authenticated only (not public/anon)
  select string_agg(grantee || ':' || privilege_type, ',') into v_acl
  from information_schema.routine_privileges
  where specific_schema = 'public'
    and routine_name = 'get_chat_composer_capabilities';
  if v_acl ilike '%anon%' or v_acl ilike '%PUBLIC%' then
    raise exception 'get_chat_composer_capabilities exposed to anon/public: %', v_acl;
  end if;

  -- amount_mode XOR columns
  if not exists (
    select 1
    from pg_constraint
    where conname = 'group_collections_amount_mode_check'
      and contype = 'c'
  ) then
    raise exception 'missing group_collections_amount_mode_check';
  end if;

  raise notice 'stage13_11 security review PASS';
end;
$$;
