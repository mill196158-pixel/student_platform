-- Stage 14A — managed content security review.
--
-- Static, read-only checks to run AFTER applying
-- 20260729133000_stage14_managed_content_foundation.sql. Each query should
-- return zero offending rows (or the expected shape noted above it). Nothing
-- here mutates data. Do not run before the migration is applied.

-- ---------------------------------------------------------------------------
-- 1. Every Stage 14 table has RLS enabled AND forced (no owner bypass).
--    Expect: 11 rows, rls_enabled = true and rls_forced = true for all.
-- ---------------------------------------------------------------------------
select
  c.relname             as table_name,
  c.relrowsecurity      as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'content_templates',
    'content_items',
    'content_item_versions',
    'content_item_placements',
    'content_item_audience_groups',
    'content_item_audience_users',
    'content_assets',
    'content_media_cleanup_queue',
    'content_item_dismissals',
    'content_item_events',
    'content_audit_log'
  )
order by c.relname;

-- ---------------------------------------------------------------------------
-- 1b. Any Stage 14 table missing (or missing RLS/FORCE) is a hard failure.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  t.table_name,
  (c.oid is not null)                        as table_exists,
  coalesce(c.relrowsecurity, false)          as rls_enabled,
  coalesce(c.relforcerowsecurity, false)     as rls_forced
from (
  values
    ('content_templates'),
    ('content_items'),
    ('content_item_versions'),
    ('content_item_placements'),
    ('content_item_audience_groups'),
    ('content_item_audience_users'),
    ('content_assets'),
    ('content_media_cleanup_queue'),
    ('content_item_dismissals'),
    ('content_item_events'),
    ('content_audit_log')
) as t(table_name)
left join pg_class c
  on c.relname = t.table_name
 and c.relnamespace = 'public'::regnamespace
where c.oid is null
   or not c.relrowsecurity
   or not c.relforcerowsecurity;

-- ---------------------------------------------------------------------------
-- 2. public / anon / authenticated must NOT hold direct table DML.
--    Expect: zero rows. All client access goes through SECURITY DEFINER RPCs.
-- ---------------------------------------------------------------------------
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name like 'content\_%'
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
order by table_name, grantee, privilege_type;

-- ---------------------------------------------------------------------------
-- 3. service_role holds the table DML instead.
--    Expect: select/insert/update/delete for each Stage 14 table.
-- ---------------------------------------------------------------------------
select
  table_name,
  string_agg(distinct privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name like 'content\_%'
  and grantee = 'service_role'
group by table_name
order by table_name;

-- ---------------------------------------------------------------------------
-- 4. No RLS policy may expose Stage 14 tables to anon / authenticated.
--    Expect: zero rows (deny-by-absence + FORCE RLS).
-- ---------------------------------------------------------------------------
select
  c.relname as table_name,
  pol.polname as policy_name,
  pol.polcmd  as command,
  pg_get_expr(pol.polqual, pol.polrelid) as using_expr
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname like 'content\_%'
order by c.relname, pol.polname;

-- ---------------------------------------------------------------------------
-- 5. anon must NOT be able to EXECUTE any Stage 14 RPC.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  'anon'    as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_list_content_items', 'admin_get_content_item',
    'admin_create_content_draft', 'admin_update_content_draft',
    'admin_set_content_placements', 'admin_set_content_audience',
    'admin_preview_content_audience', 'admin_publish_content',
    'admin_unpublish_content', 'admin_archive_content',
    'admin_list_content_versions', 'admin_restore_content_version',
    'admin_reorder_content_placement', 'admin_safe_delete_content',
    'get_my_content_for_placement', 'dismiss_content_item',
    'record_content_event'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 6. authenticated SHOULD be able to execute the public RPCs (RBAC is checked
--    inside the function body, not by the grant).
--    Expect: one row per RPC with can_execute = true (17 rows).
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_list_content_items', 'admin_get_content_item',
    'admin_create_content_draft', 'admin_update_content_draft',
    'admin_set_content_placements', 'admin_set_content_audience',
    'admin_preview_content_audience', 'admin_publish_content',
    'admin_unpublish_content', 'admin_archive_content',
    'admin_list_content_versions', 'admin_restore_content_version',
    'admin_reorder_content_placement', 'admin_safe_delete_content',
    'get_my_content_for_placement', 'dismiss_content_item',
    'record_content_event'
  )
order by p.proname;

-- ---------------------------------------------------------------------------
-- 7. private.* content helpers must NOT be executable by anon / authenticated.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname  as function_name,
  r.rolname  as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (values ('anon'), ('authenticated')) as r(rolname)
where n.nspname = 'private'
  and (p.proname like 'content\_%' or p.proname = 'validate_content_payload')
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
order by p.proname, r.rolname;

-- ---------------------------------------------------------------------------
-- 8. Every Stage 14 public RPC is SECURITY DEFINER with search_path = ''.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname   as function_name,
  p.prosecdef as security_definer,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_list_content_items', 'admin_get_content_item',
    'admin_create_content_draft', 'admin_update_content_draft',
    'admin_set_content_placements', 'admin_set_content_audience',
    'admin_preview_content_audience', 'admin_publish_content',
    'admin_unpublish_content', 'admin_archive_content',
    'admin_list_content_versions', 'admin_restore_content_version',
    'admin_reorder_content_placement', 'admin_safe_delete_content',
    'get_my_content_for_placement', 'dismiss_content_item',
    'record_content_event'
  )
  and (
    not p.prosecdef
    or p.proconfig is null
    or not ('search_path=' = any (p.proconfig))
  );

-- ---------------------------------------------------------------------------
-- 9. Every private content helper also pins search_path = ''.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname   as function_name,
  p.prosecdef as security_definer,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and (p.proname like 'content\_%' or p.proname = 'validate_content_payload')
  and (
    p.proconfig is null
    or not ('search_path=' = any (p.proconfig))
  );

-- ---------------------------------------------------------------------------
-- 10. Full RPC inventory (14 admin + 3 mobile) must exist.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('admin_list_content_items'),
    ('admin_get_content_item'),
    ('admin_create_content_draft'),
    ('admin_update_content_draft'),
    ('admin_set_content_placements'),
    ('admin_set_content_audience'),
    ('admin_preview_content_audience'),
    ('admin_publish_content'),
    ('admin_unpublish_content'),
    ('admin_archive_content'),
    ('admin_list_content_versions'),
    ('admin_restore_content_version'),
    ('admin_reorder_content_placement'),
    ('admin_safe_delete_content'),
    ('get_my_content_for_placement'),
    ('dismiss_content_item'),
    ('record_content_event')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

-- ---------------------------------------------------------------------------
-- 11. content_items must NOT have a sort_order column (ordering lives on
--     content_item_placements only). Expect: zero rows.
-- ---------------------------------------------------------------------------
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'content_items'
  and column_name = 'sort_order';

-- ---------------------------------------------------------------------------
-- 12. content_assets must NOT have a polymorphic owner column in Stage 14.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'content_assets'
  and column_name in ('owner_kind', 'owner_id', 'owner_type');

-- ---------------------------------------------------------------------------
-- 13. Concurrency + event-bucket columns exist with the right types.
--     Expect: content_items.row_version integer,
--             content_item_events.event_hour timestamp with time zone.
-- ---------------------------------------------------------------------------
select table_name, column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'content_items' and column_name in ('row_version', 'version_number'))
    or (table_name = 'content_item_events' and column_name = 'event_hour')
  )
order by table_name, column_name;

-- ---------------------------------------------------------------------------
-- 14. Required unique / primary keys.
--     Expect: rows for the four constraints below.
-- ---------------------------------------------------------------------------
select
  c.relname   as table_name,
  con.conname as constraint_name,
  pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and con.contype in ('p', 'u')
  and c.relname in (
    'content_templates', 'content_item_versions', 'content_item_placements',
    'content_item_events', 'content_assets', 'content_item_dismissals'
  )
order by c.relname, con.conname;

-- ---------------------------------------------------------------------------
-- 15. Schedule check constraint on content_items must exist.
--     Expect: one row with (ends_at > starts_at) semantics.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'content_items'
  and con.contype = 'c'
  and pg_get_constraintdef(con.oid) ilike '%ends_at%starts_at%';

-- ---------------------------------------------------------------------------
-- 16. Guard triggers exist: template immutability + asset-in-use protection.
--     Expect: two rows.
-- ---------------------------------------------------------------------------
select
  c.relname as table_name,
  t.tgname  as trigger_name,
  p.proname as function_name
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc p on p.oid = t.tgfoid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and not t.tgisinternal
  and c.relname in ('content_templates', 'content_assets')
order by c.relname, t.tgname;

-- ---------------------------------------------------------------------------
-- 17. Seeded templates v1 with locked placements.
--     Expect: three active rows.
-- ---------------------------------------------------------------------------
select key, schema_version, allowed_placements, is_active
from public.content_templates
order by key, schema_version;

-- ---------------------------------------------------------------------------
-- 18. Storage bucket content-media must be PRIVATE with size/mime limits.
--     Expect: public = false, file_size_limit = 10485760, whitelist only.
-- ---------------------------------------------------------------------------
select
  id,
  public,
  file_size_limit,
  allowed_mime_types
from storage.buckets
where id = 'content-media';

-- ---------------------------------------------------------------------------
-- 19. No permissive storage.objects policy may expose content-media to
--     anon / authenticated. Expect: zero rows (Edge uses service_role).
-- ---------------------------------------------------------------------------
select
  polname as policy_name,
  polcmd  as command
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'storage'
  and c.relname = 'objects'
  and (
    pg_get_expr(pol.polqual, pol.polrelid) ilike '%content-media%'
    or pg_get_expr(pol.polwithcheck, pol.polrelid) ilike '%content-media%'
  );

-- ---------------------------------------------------------------------------
-- 20. No Stage 14 RPC may be missing an expected-row-version argument.
--     Expect: zero rows (mutating admin RPCs all take p_expected_row_version;
--     admin_reorder_content_placement takes p_expected_row_versions).
-- ---------------------------------------------------------------------------
select
  p.proname,
  pg_get_function_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_update_content_draft', 'admin_set_content_placements',
    'admin_set_content_audience', 'admin_publish_content',
    'admin_unpublish_content', 'admin_archive_content',
    'admin_restore_content_version', 'admin_safe_delete_content'
  )
  and pg_get_function_arguments(p.oid) not like '%p_expected_row_version%';

-- ---------------------------------------------------------------------------
-- 21. admin_create_content_draft must NOT take a row_version argument.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname,
  pg_get_function_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_create_content_draft'
  and pg_get_function_arguments(p.oid) like '%row_version%';
