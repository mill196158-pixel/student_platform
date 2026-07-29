-- Stage 16.2 — subject files / private assets security review.
--
-- Static, read-only checks to run AFTER applying
-- 20260729150600_stage16_2_subject_assets.sql. Each query should return zero
-- offending rows (or the expected shape noted above it). Nothing here mutates
-- data. Do not run before the migration is applied.
--
-- Section 0 at the very bottom re-asserts the critical invariants as a hard
-- gate, so the whole file can be run with ON_ERROR_STOP=1 as a pass/fail step.
--
-- The subject CARD model is reviewed separately in
-- stage16_1_subject_card_security_review.sql. This file must never assert card
-- columns: Stage 16.2 is additive and touches no profile column.

-- ---------------------------------------------------------------------------
-- 1. Both Stage 16.2 tables have RLS enabled AND forced (no owner bypass).
--    Expect: 2 rows, rls_enabled = true and rls_forced = true.
-- ---------------------------------------------------------------------------
select
  c.relname             as table_name,
  c.relrowsecurity      as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('subject_assets', 'subject_media_cleanup_queue')
order by c.relname;

-- ---------------------------------------------------------------------------
-- 1b. Either table missing (or missing RLS/FORCE) is a hard failure.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  t.table_name,
  (c.oid is not null)                    as table_exists,
  coalesce(c.relrowsecurity, false)      as rls_enabled,
  coalesce(c.relforcerowsecurity, false) as rls_forced
from (values ('subject_assets'), ('subject_media_cleanup_queue')) as t(table_name)
left join pg_class c
  on c.relname = t.table_name
 and c.relnamespace = 'public'::regnamespace
where c.oid is null
   or not c.relrowsecurity
   or not c.relforcerowsecurity;

-- ---------------------------------------------------------------------------
-- 2. public / anon / authenticated must NOT hold direct table DML.
--    Expect: zero rows. All client access is via RPC.
-- ---------------------------------------------------------------------------
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('subject_assets', 'subject_media_cleanup_queue')
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
order by table_name, grantee, privilege_type;

-- ---------------------------------------------------------------------------
-- 3. service_role holds the table DML instead.
--    Expect: SELECT/INSERT/UPDATE/DELETE for both tables.
-- ---------------------------------------------------------------------------
select
  table_name,
  string_agg(distinct privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('subject_assets', 'subject_media_cleanup_queue')
  and grantee = 'service_role'
group by table_name
order by table_name;

-- ---------------------------------------------------------------------------
-- 4. No RLS policy may expose the asset tables to anon / authenticated.
--    Expect: zero rows (deny-by-absence + FORCE RLS).
-- ---------------------------------------------------------------------------
select
  c.relname   as table_name,
  pol.polname as policy_name,
  pol.polcmd  as command,
  pg_get_expr(pol.polqual, pol.polrelid) as using_expr
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('subject_assets', 'subject_media_cleanup_queue')
order by c.relname, pol.polname;

-- ---------------------------------------------------------------------------
-- 5. anon must NOT be able to EXECUTE any Stage 16.2 RPC. Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  'anon'    as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_register_subject_asset', 'admin_list_subject_assets',
    'admin_delete_subject_asset', 'get_subject_card_assets'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 6. authenticated SHOULD be able to execute them (RBAC is checked inside the
--    function body, not by the grant). Expect: 4 rows, can_execute = true.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_register_subject_asset', 'admin_list_subject_assets',
    'admin_delete_subject_asset', 'get_subject_card_assets'
  )
order by p.proname;

-- ---------------------------------------------------------------------------
-- 7. private asset helpers must NOT be executable by anon / authenticated.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (values ('anon'), ('authenticated')) as r(rolname)
where n.nspname = 'private'
  and (p.proname like 'subject\_asset%' or p.proname = 'require_any_admin_permission')
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
order by p.proname, r.rolname;

-- ---------------------------------------------------------------------------
-- 8. Every Stage 16.2 RPC is SECURITY DEFINER with search_path = ''.
--    Expect: zero rows.
--
--    NOTE ON THE PREDICATE: Postgres stores `set search_path = ''` in
--    pg_proc.proconfig as `search_path=""` (with literal quotes), not as
--    `search_path=`, so the quotes are stripped before comparing.
-- ---------------------------------------------------------------------------
select
  p.proname   as function_name,
  p.prosecdef as security_definer,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_register_subject_asset', 'admin_list_subject_assets',
    'admin_delete_subject_asset', 'get_subject_card_assets'
  )
  and (
    not p.prosecdef
    or p.proconfig is null
    or not exists (
      select 1 from unnest(p.proconfig) as cfg
      where replace(cfg, '"', '') = 'search_path='
    )
  );

-- ---------------------------------------------------------------------------
-- 9. Every private asset helper also pins search_path = ''. Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname   as function_name,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname like 'subject\_asset%'
  and (
    p.proconfig is null
    or not exists (
      select 1 from unnest(p.proconfig) as cfg
      where replace(cfg, '"', '') = 'search_path='
    )
  );

-- ---------------------------------------------------------------------------
-- 10. Full Stage 16.2 RPC inventory must exist. Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('admin_register_subject_asset'),
    ('admin_list_subject_assets'),
    ('admin_delete_subject_asset'),
    ('get_subject_card_assets')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

-- ---------------------------------------------------------------------------
-- 11. subject_assets must NOT be polymorphic free-form. Expect: zero rows.
-- ---------------------------------------------------------------------------
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'subject_assets'
  and column_name in ('owner_kind', 'owner_id', 'owner_type', 'entity_type', 'entity_id');

-- ---------------------------------------------------------------------------
-- 12. Owner is two typed FKs with an XOR constraint.
--     Expect: 2 owner FK rows + the XOR check.
-- ---------------------------------------------------------------------------
select
  con.conname                   as constraint_name,
  con.contype                   as kind,
  pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'subject_assets'
  and (con.contype = 'f' or con.conname = 'subject_assets_owner_xor')
order by con.contype, con.conname;

-- ---------------------------------------------------------------------------
-- 12b. The XOR constraint must exist by name. Expect: exactly one row.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'subject_assets'
  and con.conname = 'subject_assets_owner_xor';

-- ---------------------------------------------------------------------------
-- 13. IDOR: registering a new VERSION must refuse a superseded asset that
--     belongs to a different owner, otherwise an admin scoped to one subject
--     could hijack another subject's file chain.
--     Expect: one row, refuses_foreign_owner = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%asset_foreign_owner%') as refuses_foreign_owner
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_register_subject_asset';

-- ---------------------------------------------------------------------------
-- 14. Deleting a CURRENT file must not break a published card: the RPC has to
--     refuse while the owning card is published.
--     Expect: one row, guards_published = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%unpublish_card_before_deleting_current_asset%') as guards_published
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_delete_subject_asset';

-- ---------------------------------------------------------------------------
-- 15. Deletion must enqueue the storage object before the row disappears, so a
--     private object can never be orphaned. Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_delete_subject_asset'
  and p.prosrc like '%subject_media_cleanup_queue%';

-- ---------------------------------------------------------------------------
-- 16. Storage bucket subject-media must be PRIVATE with size/mime limits.
--     Expect: public = false, file_size_limit = 20971520, whitelist only.
-- ---------------------------------------------------------------------------
select id, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'subject-media';

-- ---------------------------------------------------------------------------
-- 16b. A public or unbounded subject-media bucket is a hard failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select id, public, file_size_limit
from storage.buckets
where id = 'subject-media'
  and (public or file_size_limit is null or allowed_mime_types is null);

-- ---------------------------------------------------------------------------
-- 17. No storage.objects policy may expose subject-media to anon /
--     authenticated. Expect: zero rows (Edge signs URLs with service_role).
-- ---------------------------------------------------------------------------
select polname as policy_name, polcmd as command
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'storage'
  and c.relname = 'objects'
  and (
    pg_get_expr(pol.polqual, pol.polrelid) ilike '%subject-media%'
    or pg_get_expr(pol.polwithcheck, pol.polrelid) ilike '%subject-media%'
  );

-- ---------------------------------------------------------------------------
-- 18. The student read RPC must not hand raw storage paths to students; the
--     client exchanges an asset id for a signed URL. Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_subject_card_assets'
  and p.prosrc ilike '%storage_path%';

-- ---------------------------------------------------------------------------
-- 19. Stage 16.2 is ADDITIVE: it must not have added card columns to the
--     profile tables, and in particular no duplicated load columns.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select col.table_name, col.column_name
from information_schema.columns col
where col.table_schema = 'public'
  and col.table_name in (
    'subject_student_profiles', 'subject_offering_student_profiles'
  )
  and col.column_name in ('hours_total', 'credits', 'as_of_date');

-- ---------------------------------------------------------------------------
-- 0. HARD GATE — re-assert the critical invariants. Raises on any violation.
--    Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
  v_rpcs text[] := array[
    'admin_register_subject_asset', 'admin_list_subject_assets',
    'admin_delete_subject_asset', 'get_subject_card_assets'
  ];
  v_tables text[] := array['subject_assets', 'subject_media_cleanup_queue'];
begin
  select count(*) into v_bad
  from unnest(v_tables) as t(name)
  left join pg_class c
    on c.relname = t.name and c.relnamespace = 'public'::regnamespace
  where c.oid is null or not c.relrowsecurity or not c.relforcerowsecurity;
  if v_bad > 0 then
    raise exception 'stage16.2 FAIL: % table(s) missing or without FORCE RLS', v_bad;
  end if;

  select count(*) into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = any (v_tables)
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');
  if v_bad > 0 then
    raise exception 'stage16.2 FAIL: % client table grant(s) on the asset tables', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(v_rpcs) as r(name)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = r.name
  );
  if v_bad > 0 then
    raise exception 'stage16.2 FAIL: % RPC(s) missing', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = any (v_rpcs)
    and (
      not p.prosecdef
      or p.proconfig is null
      or not exists (
        select 1 from unnest(p.proconfig) as cfg
        where replace(cfg, '"', '') = 'search_path='
      )
    );
  if v_bad > 0 then
    raise exception 'stage16.2 FAIL: % RPC(s) not SECURITY DEFINER with search_path=''''', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = any (v_rpcs)
    and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad > 0 then
    raise exception 'stage16.2 FAIL: anon can execute % Stage 16.2 RPC(s)', v_bad;
  end if;

  if not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'subject_assets'
      and con.conname = 'subject_assets_owner_xor'
  ) then
    raise exception 'stage16.2 FAIL: subject_assets_owner_xor missing (owner not typed XOR)';
  end if;

  select count(*) into v_bad
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'subject_assets'
    and column_name in ('owner_kind', 'owner_id', 'owner_type', 'entity_type', 'entity_id');
  if v_bad > 0 then
    raise exception 'stage16.2 FAIL: subject_assets has % polymorphic owner column(s)', v_bad;
  end if;

  -- IDOR guard on the version chain.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_register_subject_asset'
      and p.prosrc like '%asset_foreign_owner%'
  ) then
    raise exception 'stage16.2 FAIL: supersede path does not refuse a foreign owner';
  end if;

  -- Published cards must not be broken by a delete.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_delete_subject_asset'
      and p.prosrc like '%unpublish_card_before_deleting_current_asset%'
  ) then
    raise exception 'stage16.2 FAIL: delete does not protect a published card';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_delete_subject_asset'
      and p.prosrc like '%subject_media_cleanup_queue%'
  ) then
    raise exception 'stage16.2 FAIL: delete does not enqueue the storage object';
  end if;

  if exists (
    select 1 from storage.buckets
    where id = 'subject-media'
      and (public or file_size_limit is null or allowed_mime_types is null)
  ) then
    raise exception 'stage16.2 FAIL: subject-media bucket is public or unbounded';
  end if;

  if not exists (select 1 from storage.buckets where id = 'subject-media') then
    raise exception 'stage16.2 FAIL: subject-media bucket missing';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_subject_card_assets'
      and p.prosrc ilike '%storage_path%'
  ) then
    raise exception 'stage16.2 FAIL: student read RPC references storage_path';
  end if;

  -- Additive only: no card/load columns may have leaked in here.
  select count(*) into v_bad
  from information_schema.columns col
  where col.table_schema = 'public'
    and col.table_name in (
      'subject_student_profiles', 'subject_offering_student_profiles'
    )
    and col.column_name in ('hours_total', 'credits', 'as_of_date');
  if v_bad > 0 then
    raise exception
      'stage16.2 FAIL: % duplicated card/load column(s) on the profile tables', v_bad;
  end if;

  raise notice 'stage16.2 security review: PASS';
end $$;
