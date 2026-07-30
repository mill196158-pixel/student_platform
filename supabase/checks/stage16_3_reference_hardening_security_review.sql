-- Stage 16.3 hardening + content-media security review (LOCAL ONLY, read-only asserts).
-- Run after 20260729150700 + 20260729150750 + 20260729150760.

-- 1. Categories + upload intents RLS forced
select c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'reference_categories',
    'content_item_reference_categories',
    'content_asset_upload_intents'
  )
order by 1;

-- 2. No client DML on category / upload-intent tables
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in (
    'reference_categories',
    'content_item_reference_categories',
    'content_asset_upload_intents'
  )
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');

-- 3. Hard gate
do $$
declare
  v_bad integer;
begin
  if not exists (
    select 1 from public.content_templates
    where key = 'reference_article_v1' and schema_version = 2
  ) then
    raise exception 'stage16.3 FAIL: reference_article_v1 schema 2 missing';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'content_corrections'
      and column_name = 'item_title'
  ) then
    raise exception 'stage16.3 FAIL: correction snapshots missing';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'content_corrections'
      and column_name = 'content_item_id'
      and is_nullable = 'NO'
  ) then
    raise exception 'stage16.3 FAIL: content_item_id must be nullable (SET NULL)';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'submit_content_correction'
      and p.prosrc ilike '%reference_article_v1%'
      and p.prosrc ilike '%pg_advisory_xact_lock%'
  ) then
    raise exception 'stage16.3 FAIL: submit_content_correction missing reference/rate-lock guards';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_safe_delete_content'
      and p.prosrc ilike '%open_corrections_block_delete%'
  ) then
    raise exception 'stage16.3 FAIL: safe_delete missing open correction gate';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_my_reference_bundle'
  ) then
    raise exception 'stage16.3 FAIL: get_my_reference_bundle missing';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_my_reference_bundle'
      and (p.prosrc ilike '%storage_path%' or p.prosrc ilike '%signed%')
  ) then
    raise exception 'stage16.3 FAIL: get_my_reference_bundle leaks storage/signed';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'content_snapshot_version'
      and p.prosrc ilike '%reference_category_id%'
  ) then
    raise exception 'stage16.3 FAIL: snapshot missing reference_category_id';
  end if;

  -- Category upsert: publish gate + immutable key on update
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_upsert_reference_category'
      and p.prosrc ilike '%content.publish%'
      and p.prosrc ilike '%Stable category key is immutable%'
  ) then
    raise exception 'stage16.3 FAIL: category upsert missing publish gate / key immutability';
  end if;

  -- Category-only article mutation must bump version
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_upsert_reference_article'
      and p.prosrc ilike '%content.set_reference_category%'
  ) then
    raise exception 'stage16.3 FAIL: article upsert missing category-only version path';
  end if;

  -- Audience wrap returns reference admin JSON
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_set_content_audience'
      and p.prosrc ilike '%reference_article_admin_json%'
  ) then
    raise exception 'stage16.3 FAIL: admin_set_content_audience missing reference JSON wrap';
  end if;

  -- 150760: upload intents FORCE RLS + no client DML
  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'content_asset_upload_intents'
      and c.relrowsecurity
      and c.relforcerowsecurity
  ) then
    raise exception 'stage16.3 FAIL: content_asset_upload_intents missing FORCE RLS';
  end if;

  select count(*) into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'reference_categories',
      'content_item_reference_categories',
      'content_asset_upload_intents'
    )
    and grantee in ('anon', 'authenticated')
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE');
  if v_bad > 0 then
    raise exception 'stage16.3 FAIL: client DML on category/upload-intent tables';
  end if;

  -- Intent RPC must not return storage_path to clients
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_create_content_asset_upload_intent'
      and p.prosrc ilike '%Never return storage_path%'
      and p.prosrc not ilike '%jsonb_build_object(%storage_path%'
  ) then
    raise exception 'stage16.3 FAIL: upload intent RPC must omit storage_path from client return';
  end if;

  -- Finalize fail-closed on missing Storage MIME
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_finalize_content_asset_upload'
      and p.prosrc ilike '%storage_mime_missing%'
  ) then
    raise exception 'stage16.3 FAIL: finalize missing storage_mime_missing gate';
  end if;

  -- Service-only path resolver + cleanup RPCs
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'service_content_upload_intent_storage_path'
      and p.prosrc ilike '%service_role_required%'
  ) then
    raise exception 'stage16.3 FAIL: service_content_upload_intent_storage_path missing';
  end if;

  select count(*) into v_bad
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'service_content_upload_intent_storage_path',
      'claim_content_media_cleanup_batch',
      'complete_content_media_cleanup',
      'fail_content_media_cleanup'
    )
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');
  if v_bad > 0 then
    raise exception 'stage16.3 FAIL: service-only media RPCs granted to clients';
  end if;

  -- Pending-only cleanup leases
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'claim_content_media_cleanup_batch'
      and p.prosrc ilike '%processed_at is null%'
  ) then
    raise exception 'stage16.3 FAIL: cleanup claim missing processed_at IS NULL';
  end if;

  -- Student download requires current payload reference
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'authorize_content_asset_download'
      and p.prosrc ilike '%content_payload_asset_ids%'
  ) then
    raise exception 'stage16.3 FAIL: download auth missing payload asset membership check';
  end if;

  raise notice 'stage16.3 hardening+media security review: PASS';
end $$;
