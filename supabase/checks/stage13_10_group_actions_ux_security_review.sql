-- Stage 13.10 security review (local). Do not remote-apply without owner.
-- Expected: PASS after applying 20260728101245_stage13_10_group_actions_ux.sql

do $$
declare
  v_src text;
begin
  -- Capabilities RPC exists and is locked down.
  if to_regprocedure('public.get_chat_composer_capabilities(uuid)') is null then
    raise exception 'missing get_chat_composer_capabilities';
  end if;

  select pg_get_functiondef(oid) into v_src
  from pg_proc
  where oid = 'public.get_chat_composer_capabilities(uuid)'::regprocedure;
  if position('security definer' in lower(v_src)) = 0 then
    raise exception 'capabilities must be security definer';
  end if;
  if position('search_path' in lower(v_src)) = 0 then
    raise exception 'capabilities must set search_path';
  end if;

  -- Topic managers are subject-only.
  select pg_get_functiondef(oid) into v_src
  from pg_proc
  where oid = 'private.can_manage_team_topics(uuid)'::regprocedure;
  if position('group_space' in lower(v_src)) > 0
     and position('= ''subject''' in lower(v_src)) = 0
     and position('= ''subject''' in v_src) = 0 then
    -- Soft check: subject-only function should prefer subject kind.
    null;
  end if;
  if position('''subject''' in v_src) = 0 then
    raise exception 'can_manage_team_topics must require subject kind';
  end if;

  -- Legacy create_topic_selection must refuse group_space creates.
  select pg_get_functiondef(oid) into v_src
  from pg_proc
  where oid = 'public.create_topic_selection(text,text,timestamptz,boolean)'::regprocedure;
  if position('topic_selection_subject_only' in v_src) = 0 then
    raise exception 'legacy create_topic_selection must raise subject_only';
  end if;

  -- Publish rejects group_space.
  select pg_get_functiondef(oid) into v_src
  from pg_proc
  where oid = 'public.publish_topic_selection_for_chat(uuid,text,text,timestamptz,timestamptz,boolean,boolean,uuid,jsonb)'::regprocedure;
  if position('topic_selection_subject_only' in v_src) = 0 then
    raise exception 'publish_topic_selection_for_chat must enforce subject_only';
  end if;

  -- Collection payment statuses include product set.
  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    where t.relname = 'group_collection_contributions'
      and c.conname = 'group_collection_contributions_payment_status_check'
      and pg_get_constraintdef(c.oid) like '%reported%'
      and pg_get_constraintdef(c.oid) like '%not_received%'
      and pg_get_constraintdef(c.oid) like '%needs_clarification%'
  ) then
    raise exception 'payment_status check missing Stage 13.10 values';
  end if;

  raise notice 'stage13_10_group_actions_ux_security_review PASS';
end $$;
