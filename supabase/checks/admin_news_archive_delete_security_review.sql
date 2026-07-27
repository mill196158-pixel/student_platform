-- Stage 12.3 — archived news hard-delete security review.
-- Run AFTER applying 20260722121908_admin_news_archive_delete.sql.
-- Read-only. Expect shapes noted in comments.

-- 1) New RPCs are SECURITY DEFINER with locked search_path.
select
  p.proname as function_name,
  p.prosecdef as security_definer,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_restore_archived_news',
    'admin_delete_archived_news',
    'admin_record_news_media_cleanup_failure'
  )
order by p.proname;

-- 2) anon must NOT execute the new RPCs. Expect: zero rows.
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_restore_archived_news',
    'admin_delete_archived_news',
    'admin_record_news_media_cleanup_failure'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- 3) PUBLIC must not retain EXECUTE. Expect: zero rows.
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_restore_archived_news',
    'admin_delete_archived_news',
    'admin_record_news_media_cleanup_failure'
  )
  and has_function_privilege('public', p.oid, 'EXECUTE');

-- 4) authenticated MAY execute (RBAC inside body). Expect: can_execute = true.
select
  p.proname,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_restore_archived_news',
    'admin_delete_archived_news',
    'admin_record_news_media_cleanup_failure'
  )
order by p.proname;

-- 5) Cleanup queue: RLS forced; no direct grants to anon/authenticated.
select
  c.relname,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'news_media_cleanup_queue';

select
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'news_media_cleanup_queue'
  and grantee in ('anon', 'authenticated', 'public');

-- 6) Private helpers not executable by anon/authenticated. Expect: zero rows.
select
  p.proname,
  r.rolname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (values ('anon'), ('authenticated')) as r(rolname)
where n.nspname = 'private'
  and p.proname in (
    'news_collect_media_paths',
    'news_media_path_still_referenced'
  )
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE');

-- 7) Direct DELETE on news_posts must remain unavailable to authenticated.
--    Expect: zero rows with DELETE privilege.
select
  table_name,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('news_posts', 'news_versions', 'news_views')
  and grantee in ('anon', 'authenticated', 'public')
  and privilege_type = 'DELETE';
