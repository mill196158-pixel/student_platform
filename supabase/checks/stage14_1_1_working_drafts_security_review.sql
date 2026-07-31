-- Stage 14.1.1 working-drafts security review (local disposable DB).
-- Static assertions after applying
--   20260730190000_stage14_1_1_working_drafts_and_reference_blocks.sql
-- Expect PASS notice; fails hard on any mismatch.

begin;

do $$
declare
  v_fail text := '';
  v_fn text;
  v_rpc text[] := array[
    'admin_begin_content_edit',
    'admin_save_content_working_draft',
    'admin_publish_content_working_draft',
    'admin_discard_content_working_draft',
    'admin_begin_vacancy_edit',
    'admin_save_vacancy_working_draft',
    'admin_publish_vacancy_working_draft',
    'admin_discard_vacancy_working_draft'
  ];
begin
  -- 1) Tables exist with FORCE RLS
  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'content_item_working_drafts'
      and c.relrowsecurity
      and c.relforcerowsecurity
  ) then
    v_fail := v_fail || 'content_item_working_drafts missing FORCE RLS; ';
  end if;

  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'vacancy_working_drafts'
      and c.relrowsecurity
      and c.relforcerowsecurity
  ) then
    v_fail := v_fail || 'vacancy_working_drafts missing FORCE RLS; ';
  end if;

  -- 2) No client table DML
  if has_table_privilege('anon', 'public.content_item_working_drafts', 'select')
     or has_table_privilege('authenticated', 'public.content_item_working_drafts', 'insert')
     or has_table_privilege('authenticated', 'public.content_item_working_drafts', 'update')
     or has_table_privilege('authenticated', 'public.content_item_working_drafts', 'delete')
  then
    v_fail := v_fail || 'content_item_working_drafts client privileges leak; ';
  end if;

  if has_table_privilege('anon', 'public.vacancy_working_drafts', 'select')
     or has_table_privilege('authenticated', 'public.vacancy_working_drafts', 'insert')
     or has_table_privilege('authenticated', 'public.vacancy_working_drafts', 'update')
     or has_table_privilege('authenticated', 'public.vacancy_working_drafts', 'delete')
  then
    v_fail := v_fail || 'vacancy_working_drafts client privileges leak; ';
  end if;

  -- 3) service_role has table DML
  if not (
    has_table_privilege('service_role', 'public.content_item_working_drafts', 'select')
    and has_table_privilege('service_role', 'public.content_item_working_drafts', 'insert')
    and has_table_privilege('service_role', 'public.content_item_working_drafts', 'update')
    and has_table_privilege('service_role', 'public.content_item_working_drafts', 'delete')
  ) then
    v_fail := v_fail || 'service_role missing content draft DML; ';
  end if;

  if not (
    has_table_privilege('service_role', 'public.vacancy_working_drafts', 'select')
    and has_table_privilege('service_role', 'public.vacancy_working_drafts', 'insert')
    and has_table_privilege('service_role', 'public.vacancy_working_drafts', 'update')
    and has_table_privilege('service_role', 'public.vacancy_working_drafts', 'delete')
  ) then
    v_fail := v_fail || 'service_role missing vacancy draft DML; ';
  end if;

  -- 4) No anon EXECUTE on draft RPCs; authenticated may execute
  foreach v_fn in array v_rpc loop
    if not exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_fn
        and p.prosecdef
    ) then
      v_fail := v_fail || v_fn || ' missing/not security definer; ';
      continue;
    end if;

    if exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_fn
        and has_function_privilege('anon', p.oid, 'execute')
    ) then
      v_fail := v_fail || 'anon can execute ' || v_fn || '; ';
    end if;

    if not exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_fn
        and has_function_privilege('authenticated', p.oid, 'execute')
    ) then
      v_fail := v_fail || 'authenticated missing execute on ' || v_fn || '; ';
    end if;
  end loop;

  -- 5) Publish RPCs require content.publish
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_publish_content_working_draft'
      and p.prosrc like '%require_admin_permission(''content.publish'')%'
  ) then
    v_fail := v_fail || 'content publish RPC missing content.publish gate; ';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_publish_vacancy_working_draft'
      and p.prosrc like '%require_admin_permission(''content.publish'')%'
  ) then
    v_fail := v_fail || 'vacancy publish RPC missing content.publish gate; ';
  end if;

  -- 6) Write RPCs require content.write
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_begin_content_edit'
      and p.prosrc like '%require_admin_permission(''content.write'')%'
  ) then
    v_fail := v_fail || 'begin_content_edit missing content.write gate; ';
  end if;

  -- 7) Lifecycle guards call working_draft_exists helper
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_archive_content'
      and p.prosrc like '%content_assert_no_working_draft%'
  ) then
    v_fail := v_fail || 'archive missing working_draft guard; ';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_safe_delete_content'
      and p.prosrc like '%content_assert_no_working_draft%'
  ) then
    v_fail := v_fail || 'safe_delete missing working_draft guard; ';
  end if;

  -- 8) Schema v3 template active; v2 validator still uses legacy assert
  if not exists (
    select 1 from public.content_templates t
    where t.key = 'reference_article_v1'
      and t.schema_version = 3
      and t.is_active
  ) then
    v_fail := v_fail || 'reference_article_v1 schema_version=3 missing/inactive; ';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'content_assert_reference_blocks_v3'
  ) then
    v_fail := v_fail || 'content_assert_reference_blocks_v3 missing; ';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'validate_content_payload'
      and p.prosrc like '%content_assert_reference_blocks_v3%'
      and p.prosrc like '%p_schema_version = 2%'
      and p.prosrc like '%content_assert_reference_blocks(%'
  ) then
    v_fail := v_fail || 'validate_content_payload v2/v3 split missing; ';
  end if;

  if v_fail <> '' then
    raise exception 'STAGE14_1_1_SECURITY_REVIEW FAIL: %', v_fail;
  end if;

  raise notice 'STAGE14_1_1_WORKING_DRAFTS_SECURITY_REVIEW PASS';
end $$;

rollback;
