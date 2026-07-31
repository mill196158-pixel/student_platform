-- Stage 13.9 hotfix: card messages must use allowed messages.msg_type.
-- Flutter identifies topic/collection cards via content.card, not msg_type.
-- Allowed values: text | assignmentDraft | assignmentPublished | file | forward.

do $$
declare
  v_src text;
  v_oid oid;
begin
  v_oid := 'public.publish_topic_selection_for_chat(uuid,text,text,timestamptz,timestamptz,boolean,boolean,uuid,jsonb)'::regprocedure;
  select pg_get_functiondef(v_oid) into v_src;
  if v_src is null then
    raise exception 'publish_topic_selection_for_chat missing';
  end if;
  if position('''system''' in v_src) = 0 then
    raise notice 'publish_topic_selection_for_chat already patched';
  else
    v_src := replace(v_src, '''system''', '''text''');
    execute v_src;
  end if;

  v_oid := 'public.create_group_collection(text,text,text,timestamptz,numeric,text,text)'::regprocedure;
  select pg_get_functiondef(v_oid) into v_src;
  if v_src is null then
    raise exception 'create_group_collection missing';
  end if;
  if position('''system''' in v_src) = 0 then
    raise notice 'create_group_collection already patched';
  else
    v_src := replace(v_src, '''system''', '''text''');
    execute v_src;
  end if;
end $$;
