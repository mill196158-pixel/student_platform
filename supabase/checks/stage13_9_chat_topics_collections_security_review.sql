-- Stage 13.9 LOCAL security review. Assertive; fails on deviation.
\set ON_ERROR_STOP on

do $$
begin
  if to_regprocedure(
    'public.publish_topic_selection_for_chat(uuid,text,text,timestamptz,timestamptz,boolean,boolean,uuid,jsonb)'
  ) is null then
    raise exception 'missing publish_topic_selection_for_chat';
  end if;
  if to_regprocedure('public.list_my_group_action_deadlines(timestamptz,timestamptz)') is null then
    raise exception 'missing list_my_group_action_deadlines';
  end if;
  if to_regprocedure('public.get_collection_proof_file(uuid,uuid)') is null then
    raise exception 'missing get_collection_proof_file';
  end if;
  if to_regprocedure('public.release_topic_pick(uuid,uuid)') is null then
    raise exception 'missing release_topic_pick';
  end if;
end;
$$;

do $$
declare
  v_src text;
begin
  select pg_get_functiondef('public.pick_topic(uuid,uuid)'::regprocedure) into v_src;
  if lower(v_src) not like '%for update%'
     or lower(v_src) not like '%option_full%'
     or lower(v_src) not like '%is distinct from auth.uid()%' then
    raise exception 'pick_topic lacks lock/capacity/self-exclude checks';
  end if;

  select pg_get_functiondef(
    'public.publish_topic_selection_for_chat(uuid,text,text,timestamptz,timestamptz,boolean,boolean,uuid,jsonb)'::regprocedure
  ) into v_src;
  if lower(v_src) not like '%can_manage_team_topics%'
     or lower(v_src) not like '%topic_selection%'
     or lower(v_src) not like '%200%' then
    raise exception 'publish_topic_selection_for_chat missing manager/card/limit guards';
  end if;

  select pg_get_functiondef('public.list_topic_options_for_selection(uuid)'::regprocedure)
    into v_src;
  if lower(v_src) not like '%show_results_to_all%' then
    raise exception 'list_topic_options_for_selection ignores show_results_to_all';
  end if;

  select pg_get_functiondef('public.list_group_collections()'::regprocedure) into v_src;
  if lower(v_src) not like '%payment_details%'
     or lower(v_src) not like '%is_group_space_organizer%' then
    raise exception 'list_group_collections does not redact payment_details';
  end if;

  select pg_get_functiondef(
    'public.upsert_my_collection_contribution(uuid,text,text,numeric,text,uuid)'::regprocedure
  ) into v_src;
  if lower(v_src) not like '%is_sensitive%' then
    raise exception 'upsert contribution must mark proof file sensitive';
  end if;
  if position('p_payment_details' in lower(v_src)) > 0 then
    raise exception 'upsert contribution must not accept/log payment requisites';
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'chat_files'
      and column_name = 'is_sensitive'
  ) then
    raise exception 'chat_files.is_sensitive missing';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'group_topic_selections'
      and column_name = 'show_results_to_all'
  ) then
    raise exception 'group_topic_selections.show_results_to_all missing';
  end if;
  if to_regclass('public.group_collection_secrets') is null then
    raise exception 'group_collection_secrets missing';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'group_collections'
      and column_name = 'payment_details'
  ) then
    raise exception 'payment_details must not remain on group_collections';
  end if;
  if has_table_privilege('authenticated', 'public.group_collection_secrets'::regclass, 'select')
     or has_table_privilege('authenticated', 'public.group_collection_secrets'::regclass, 'insert') then
    raise exception 'authenticated must not access group_collection_secrets directly';
  end if;
end;
$$;

do $$
declare
  v_src text;
begin
  select pg_get_functiondef('private.can_manage_team_topics(uuid)'::regprocedure)
    into v_src;
  if lower(v_src) not like '%is_active_team_member%' then
    raise exception 'can_manage_team_topics must require active membership';
  end if;

  select pg_get_functiondef('private.is_active_team_member(uuid)'::regprocedure)
    into v_src;
  if lower(v_src) not like '%is_active_subject_team_for_group%'
     or lower(v_src) not like '%student_enrollments%' then
    raise exception 'is_active_team_member must gate subject teams via active offering+enrollment';
  end if;

  select pg_get_functiondef(
    'public.publish_topic_selection_for_chat(uuid,text,text,timestamptz,timestamptz,boolean,boolean,uuid,jsonb)'::regprocedure
  ) into v_src;
  if lower(v_src) not like '%is_sensitive%' then
    raise exception 'publish_topic_selection_for_chat must reject sensitive source files';
  end if;

  if not exists (
    select 1 from pg_policy
    where polrelid = 'public.chat_files'::regclass
      and polname = 'chat_files_restrict_sensitive_proof'
      and not polpermissive
  ) then
    raise exception 'missing RESTRICTIVE chat_files sensitive proof policy';
  end if;

  if to_regprocedure('private.chat_files_protect_sensitive_flag()') is null then
    raise exception 'missing sensitive-flag protection trigger function';
  end if;

  select pg_get_functiondef('private.can_manage_team_topics(uuid)'::regprocedure)
    into v_src;
  if lower(v_src) like '%''teacher''%' then
    raise exception 'can_manage_team_topics must not claim unsupported teacher role';
  end if;
end;
$$;

do $$
begin
  if has_function_privilege(
    'anon',
    'public.publish_topic_selection_for_chat(uuid,text,text,timestamptz,timestamptz,boolean,boolean,uuid,jsonb)'::regprocedure,
    'execute'
  ) then
    raise exception 'anon can execute publish_topic_selection_for_chat';
  end if;
  if has_table_privilege('authenticated', 'public.group_topic_picks'::regclass, 'insert')
     or has_table_privilege('authenticated', 'public.group_topic_selections'::regclass, 'insert') then
    raise exception 'authenticated has direct write on topic tables';
  end if;
end;
$$;

select 'stage13_9_security_review_PASS' as status;
