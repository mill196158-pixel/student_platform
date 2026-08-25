-- Stage 14.2.2 — home/profile WD schema 1→2 (static + disposable).
-- LOCAL / disposable when behavioral section runs. Prefer linked DB after apply.

do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private'
    and p.proname = 'content_working_draft_effective_schema';
  if v_def is null then
    raise exception 'FAIL: content_working_draft_effective_schema missing';
  end if;
  if v_def not ilike '%home_promo_v1%'
     or v_def not ilike '%profile_feed_card_v1%' then
    raise exception 'FAIL: home/profile 1→2 upgrade path missing';
  end if;
  if private.content_working_draft_effective_schema('home_promo_v1', 1, 2) <> 2 then
    raise exception 'FAIL: home 1→2 must return 2';
  end if;
  if private.content_working_draft_effective_schema('profile_feed_card_v1', 1, 2) <> 2 then
    raise exception 'FAIL: profile 1→2 must return 2';
  end if;
  if private.content_working_draft_effective_schema('home_promo_v1', 2, 2) <> 2 then
    raise exception 'FAIL: home 2→2 must return 2';
  end if;
  begin
    perform private.content_working_draft_effective_schema('home_promo_v1', 1, 3);
    raise exception 'FAIL: home 1→3 should be invalid';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not ilike '%invalid_schema_upgrade%' then
      raise exception 'FAIL: unexpected %', sqlerrm;
    end if;
  end;
  raise notice 'stage14_2_2 schema upgrade helper OK';
end;
$$;
