-- Stage 12.2 — news_posts security review.
--
-- Static, read-only checks to run AFTER applying
-- 20260722110804_news_posts_and_admin_rpc.sql. Each query should return zero
-- offending rows (or the expected shape noted above it). Nothing here mutates
-- data. Do not run before the migration is applied.

-- ---------------------------------------------------------------------------
-- 1. Tables have RLS enabled AND forced (no owner bypass).
--    Expect: rls_enabled = true and rls_forced = true for news tables
--    (+ news_media_cleanup_queue after Stage 12.3).
-- ---------------------------------------------------------------------------
select
  c.relname            as table_name,
  c.relrowsecurity     as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'news_posts', 'news_versions', 'news_views', 'news_media_cleanup_queue'
  )
order by c.relname;

-- ---------------------------------------------------------------------------
-- 2. anon / authenticated must NOT hold direct table DML on news tables.
--    Expect: zero rows. All client access goes through SECURITY DEFINER RPCs.
-- ---------------------------------------------------------------------------
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('news_posts', 'news_versions', 'news_views')
  and grantee in ('anon', 'authenticated', 'public');

-- ---------------------------------------------------------------------------
-- 3. anon must NOT be able to EXECUTE any admin_* or student news RPC.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  'anon'    as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (
    p.proname like 'admin_%news%'
    or p.proname in ('get_my_published_news', 'mark_news_seen',
                     'admin_can_manage_news_media', 'admin_can_read_news_media')
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 4. authenticated SHOULD be able to execute the public RPCs (RBAC is checked
--    inside the function body, not by the grant).
--    Expect: one row per RPC with can_execute = true.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_list_news', 'admin_get_news', 'admin_create_news_draft',
    'admin_update_news_draft', 'admin_publish_news', 'admin_unpublish_news',
    'admin_archive_news', 'admin_restore_archived_news',
    'admin_delete_archived_news', 'admin_record_news_media_cleanup_failure',
    'admin_duplicate_news', 'admin_reorder_news',
    'admin_list_news_versions', 'admin_restore_news_version',
    'get_my_published_news', 'mark_news_seen',
    'admin_can_manage_news_media', 'admin_can_read_news_media'
  )
order by p.proname;

-- ---------------------------------------------------------------------------
-- 5. private.* helpers must NOT be executable by anon / authenticated.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (values ('anon'), ('authenticated')) as r(rolname)
where n.nspname = 'private'
  and p.proname in (
    'news_post_to_json', 'news_snapshot_version',
    'current_user_active_group_ids', 'require_admin_permission'
  )
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 6. Every public news RPC is SECURITY DEFINER with a locked search_path.
--    Expect: security_definer = true and proconfig contains search_path=''.
-- ---------------------------------------------------------------------------
select
  p.proname                         as function_name,
  p.prosecdef                       as security_definer,
  p.proconfig                       as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (p.proname like 'admin_%news%'
       or p.proname in ('get_my_published_news', 'mark_news_seen',
                        'admin_can_manage_news_media'))
order by p.proname;

-- ---------------------------------------------------------------------------
-- 7. Storage bucket news-media must be PRIVATE with size/mime limits.
--    Expect: public = false, file_size_limit = 5242880, jpeg/png/webp only.
-- ---------------------------------------------------------------------------
select
  id,
  public,
  file_size_limit,
  allowed_mime_types
from storage.buckets
where id = 'news-media';

-- ---------------------------------------------------------------------------
-- 8. No permissive storage.objects policy should expose news-media to
--    anon / authenticated. Expect: zero rows (Edge Function uses service_role).
-- ---------------------------------------------------------------------------
select
  polname as policy_name,
  polcmd  as command
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'storage'
  and c.relname = 'objects'
  and pg_get_expr(pol.polqual, pol.polrelid) ilike '%news-media%';
