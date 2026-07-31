-- Stage 14.2 — student READ wire projection + draft exclusion (static).
-- Safe on linked DB. Gate may be ON after owner SQL flip.

do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_my_content_for_placement';

  if v_def is null then
    raise exception 'FAIL: get_my_content_for_placement missing';
  end if;

  if v_def not ilike '%home_promo_v1%'
     or v_def not ilike '%profile_feed_card_v1%'
     or v_def not ilike '%schema_version = 2%' then
    raise exception 'FAIL: student READ wire schema projection missing';
  end if;

  if v_def not ilike '%status = ''published''%'
     and v_def not ilike '%status=''published''%' then
    raise exception 'FAIL: student feed must filter published only';
  end if;

  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_my_vacancies';

  if v_def is null then
    raise exception 'FAIL: get_my_vacancies missing';
  end if;

  if v_def not ilike '%status = ''published''%'
     and v_def not ilike '%status=''published''%' then
    raise exception 'FAIL: get_my_vacancies must filter published only';
  end if;

  if v_def not ilike '%working_draft_id is null%' then
    raise exception 'FAIL: vacancy assets must exclude working drafts';
  end if;

  raise notice 'stage14_2 student read projection security review OK';
end;
$$;
