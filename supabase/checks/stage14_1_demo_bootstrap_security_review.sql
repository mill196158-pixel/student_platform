-- Stage 14.1 security review assertions (local disposable DB)
begin;

do $$
declare
  v_fail text := '';
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'content_items'
      and column_name = 'legacy_key'
  ) then
    v_fail := v_fail || 'missing content_items.legacy_key; ';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'vacancies'
      and column_name = 'legacy_key'
  ) then
    v_fail := v_fail || 'missing vacancies.legacy_key; ';
  end if;

  if to_regclass('public.content_legacy_tombstones') is null then
    v_fail := v_fail || 'missing content_legacy_tombstones; ';
  end if;

  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'content_legacy_tombstones'
      and c.relrowsecurity
      and c.relforcerowsecurity
  ) then
    v_fail := v_fail || 'tombstones RLS/FORCE missing; ';
  end if;

  if has_table_privilege('anon', 'public.content_legacy_tombstones', 'select')
     or has_table_privilege('authenticated', 'public.content_legacy_tombstones', 'insert')
  then
    v_fail := v_fail || 'tombstones direct client DML not revoked; ';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_bootstrap_demo_content'
      and p.prosecdef
      and pg_get_function_identity_arguments(p.oid) in ('boolean', 'p_dry_run boolean')
  ) then
    v_fail := v_fail || 'bootstrap RPC missing/not definer; ';
  end if;

  if has_function_privilege('anon', 'public.admin_bootstrap_demo_content(boolean)', 'execute')
  then
    v_fail := v_fail || 'anon can execute bootstrap; ';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.admin_bootstrap_demo_content(boolean)',
    'execute'
  ) then
    v_fail := v_fail || 'authenticated missing bootstrap execute; ';
  end if;

  -- Bootstrap body must gate on content.publish
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_bootstrap_demo_content'
      and p.prosrc like '%require_admin_permission(''content.publish'')%'
  ) then
    v_fail := v_fail || 'bootstrap missing content.publish gate; ';
  end if;

  -- /help allowlisted
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'content_assert_cta'
      and p.prosrc like '%/help%'
  ) then
    v_fail := v_fail || 'CTA allowlist missing /help; ';
  end if;

  if v_fail <> '' then
    raise exception 'STAGE14_1_SECURITY_REVIEW FAIL: %', v_fail;
  end if;

  raise notice 'STAGE14_1_SECURITY_REVIEW PASS';
end $$;

rollback;
