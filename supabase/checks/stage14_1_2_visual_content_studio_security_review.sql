-- Stage 14.1.2 Visual Content Studio — static security review (safe on linked DB).
-- Follow-up migration 20260730220218: legacy routes + category tombstone by legacy_key.

do $$
begin
  if not coalesce(
    (select enabled from public.app_feature_flags
     where key = 'content_visual_studio_v2_publish'),
    true
  ) is false then
    raise exception 'FAIL: v2 publish gate must default false';
  end if;

  if not exists (
    select 1 from public.content_templates
    where key = 'home_promo_v1' and schema_version = 2 and is_active
  ) then
    raise exception 'FAIL: home_promo_v1@2 missing';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='vacancy_assets' and column_name='role'
  ) then
    raise exception 'FAIL: vacancy_assets.role missing';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_safe_delete_reference_category'
  ) then
    raise exception 'FAIL: admin_safe_delete_reference_category missing';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_preview_content_audience_lens'
  ) then
    raise exception 'FAIL: audience lens RPC missing';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'content_assert_v2_publish_allowed'
      and pg_get_functiondef(p.oid) ilike '%visual_studio_v2_publish_disabled%'
  ) then
    raise exception 'FAIL: publish gate helper incomplete';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'content_legacy_route_for_screen'
      and pg_get_functiondef(p.oid) ilike '%/my-diary%'
      and pg_get_functiondef(p.oid) ilike '%/help%'
  ) then
    raise exception 'FAIL: legacy route projection missing Mobile aliases';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_safe_delete_reference_category'
      and pg_get_functiondef(p.oid) ilike '%v_row.legacy_key%'
  ) then
    raise exception 'FAIL: category safe-delete must tombstone by legacy_key';
  end if;

  raise notice 'stage14_1_2 visual content studio security review OK';
end;
$$;
