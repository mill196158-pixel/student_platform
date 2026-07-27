-- Stage 13.6 reviews security review. Assertive; fails on deviation.
\set ON_ERROR_STOP on

do $$
declare
  v_missing text;
  v_text boolean;
  v_struct boolean;
  v_oid oid;
begin
  select string_agg(t.rel, ', ') into v_missing
  from (values
    ('entity_reviews'),('review_reports'),('review_moderation_actions'),
    ('review_tags'),('app_feature_flags')
  ) as t(rel)
  where not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = t.rel
      and c.relrowsecurity and c.relforcerowsecurity
  );
  if v_missing is not null then
    raise exception 'review tables missing FORCE RLS: %', v_missing;
  end if;

  select enabled into v_text from public.app_feature_flags where key = 'reviews.text_enabled';
  select enabled into v_struct from public.app_feature_flags where key = 'reviews.structured_enabled';
  if v_text is distinct from false or v_struct is distinct from true then
    raise exception 'unexpected review feature flags text=% structured=%', v_text, v_struct;
  end if;

  if has_table_privilege('authenticated', 'public.entity_reviews', 'insert')
     or has_table_privilege('authenticated', 'public.review_moderation_actions', 'insert') then
    raise exception 'authenticated has direct write on review tables';
  end if;

  select p.oid into v_oid
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'admin_moderate_review'
  order by p.oid limit 1;
  if v_oid is null then
    raise exception 'admin_moderate_review missing';
  end if;
  if has_function_privilege('anon', v_oid, 'execute') then
    raise exception 'anon can execute admin_moderate_review';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'entity_reviews_one_active_uidx'
  ) then
    raise exception 'missing entity_reviews_one_active_uidx';
  end if;
end;
$$;
