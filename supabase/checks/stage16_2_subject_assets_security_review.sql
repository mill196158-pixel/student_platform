-- Stage 16.2 — subject files / private assets security review.
--
-- Static, read-only checks to run AFTER applying BOTH:
--   20260729150600_stage16_2_subject_assets.sql
--   20260729150650_stage16_2_subject_assets_hardening.sql
-- Each query should return zero offending rows (or the expected shape noted above it).
-- Nothing here mutates data.
--
-- Section 0 at the very bottom re-asserts the critical invariants as a hard gate.

-- ---------------------------------------------------------------------------
-- 1. Stage 16.2 tables have RLS enabled AND forced.
--    Expect: 3 rows, rls_enabled = true and rls_forced = true.
-- ---------------------------------------------------------------------------
select
  c.relname             as table_name,
  c.relrowsecurity      as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'subject_assets',
    'subject_media_cleanup_queue',
    'subject_asset_upload_intents'
  )
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
from (
  values
    ('subject_assets'),
    ('subject_media_cleanup_queue'),
    ('subject_asset_upload_intents')
) as t(table_name)
left join pg_class c
  on c.relname = t.table_name
 and c.relnamespace = 'public'::regnamespace
where c.oid is null
   or not c.relrowsecurity
   or not c.relforcerowsecurity;

-- ---------------------------------------------------------------------------
-- 2. public / anon / authenticated must NOT hold direct table DML.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in (
    'subject_assets',
    'subject_media_cleanup_queue',
    'subject_asset_upload_intents'
  )
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
order by table_name, grantee, privilege_type;

-- ---------------------------------------------------------------------------
-- 3. service_role holds table DML.
-- ---------------------------------------------------------------------------
select
  table_name,
  string_agg(distinct privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in (
    'subject_assets',
    'subject_media_cleanup_queue',
    'subject_asset_upload_intents'
  )
  and grantee = 'service_role'
group by table_name
order by table_name;

-- ---------------------------------------------------------------------------
-- 4. No RLS policy on asset tables for anon / authenticated. Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  c.relname   as table_name,
  pol.polname as policy_name,
  pol.polcmd  as command
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'subject_assets',
    'subject_media_cleanup_queue',
    'subject_asset_upload_intents'
  )
order by c.relname, pol.polname;

-- ---------------------------------------------------------------------------
-- 5. anon must NOT EXECUTE any Stage 16.2 RPC. Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  'anon'    as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_register_subject_asset',
    'admin_list_subject_assets',
    'admin_delete_subject_asset',
    'get_subject_card_assets',
    'get_subject_card',
    'admin_create_subject_asset_upload_intent',
    'admin_finalize_subject_asset_upload',
    'authorize_subject_asset_download',
    'service_subject_asset_storage_path',
    'admin_can_manage_subject_media',
    'admin_can_read_subject_media',
    'claim_subject_media_cleanup_batch',
    'complete_subject_media_cleanup',
    'fail_subject_media_cleanup'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 6b. authenticated must NOT execute admin_register_subject_asset (P1 #3).
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_register_subject_asset'
  and has_function_privilege('authenticated', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 6c. authorize RPC must not reference storage_path. Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'authorize_subject_asset_download'
  and p.prosrc ilike '%storage_path%';

-- ---------------------------------------------------------------------------
-- 6d. finalize idempotency stores finalized_asset_id. Expect: one row true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%finalized_asset_id%') as idempotent_finalize
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_finalize_subject_asset_upload';

-- ---------------------------------------------------------------------------
-- 6e. Cleanup lease columns exist. Expect: 2 rows.
-- ---------------------------------------------------------------------------
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'subject_media_cleanup_queue'
  and column_name in ('claim_token', 'claim_expires_at')
order by column_name;

-- ---------------------------------------------------------------------------
-- 6f. Intent finalized_asset_id column exists. Expect: one row.
-- ---------------------------------------------------------------------------
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'subject_asset_upload_intents'
  and column_name = 'finalized_asset_id';

-- ---------------------------------------------------------------------------
-- 7. Cleanup RPCs must be service_role only. Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (values ('anon'), ('authenticated')) as r(rolname)
where n.nspname = 'public'
  and p.proname in (
    'claim_subject_media_cleanup_batch',
    'complete_subject_media_cleanup',
    'fail_subject_media_cleanup'
  )
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE');

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
  and (
    p.proname like 'subject\_asset%'
    or p.proname = 'require_any_admin_permission'
    or p.proname = 'subject_card_assets_json'
  )
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
order by p.proname, r.rolname;

-- ---------------------------------------------------------------------------
-- 8. Stage 16.2 client RPCs are SECURITY DEFINER with search_path = ''.
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
    'admin_register_subject_asset',
    'admin_list_subject_assets',
    'admin_delete_subject_asset',
    'get_subject_card_assets',
    'get_subject_card',
    'admin_create_subject_asset_upload_intent',
    'admin_finalize_subject_asset_upload',
    'authorize_subject_asset_download',
    'service_subject_asset_storage_path',
    'admin_can_manage_subject_media',
    'admin_can_read_subject_media'
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
-- 9. Full Stage 16.2 RPC inventory must exist. Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('admin_register_subject_asset'),
    ('admin_list_subject_assets'),
    ('admin_delete_subject_asset'),
    ('get_subject_card_assets'),
    ('get_subject_card'),
    ('admin_create_subject_asset_upload_intent'),
    ('admin_finalize_subject_asset_upload'),
    ('authorize_subject_asset_download'),
    ('service_subject_asset_storage_path'),
    ('admin_can_manage_subject_media'),
    ('admin_can_read_subject_media'),
    ('claim_subject_media_cleanup_batch'),
    ('complete_subject_media_cleanup'),
    ('fail_subject_media_cleanup')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

-- ---------------------------------------------------------------------------
-- 10. asset_kind + logical_asset_id columns present with check constraint.
--     Expect: 2 rows + one check row.
-- ---------------------------------------------------------------------------
select column_name, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'subject_assets'
  and column_name in ('asset_kind', 'logical_asset_id')
order by column_name;

select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'subject_assets'
  and con.conname = 'subject_assets_asset_kind_check';

-- ---------------------------------------------------------------------------
-- 11. Logical-chain + hero uniqueness indexes (old one-current-per-owner gone).
--     Expect: zero rows for dropped legacy indexes.
-- ---------------------------------------------------------------------------
select indexname
from pg_indexes
where schemaname = 'public'
  and tablename = 'subject_assets'
  and indexname in (
    'subject_assets_one_current_catalog_uidx',
    'subject_assets_one_current_offering_uidx'
  );

-- ---------------------------------------------------------------------------
-- 12. Owner FKs use ON DELETE RESTRICT. Expect: zero rows with CASCADE.
-- ---------------------------------------------------------------------------
select
  con.conname,
  pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'subject_assets'
  and con.contype = 'f'
  and con.conname in (
    'subject_assets_subject_catalog_id_fkey',
    'subject_assets_subject_offering_id_fkey'
  )
  and pg_get_constraintdef(con.oid) not ilike '%RESTRICT%';

-- ---------------------------------------------------------------------------
-- 13. IDOR: supersede refuses foreign owner. Expect: one row, true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%asset_foreign_owner%') as refuses_foreign_owner
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_register_subject_asset';

-- ---------------------------------------------------------------------------
-- 14. List RPC uses subjects.read/write (NOT content.read). Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_list_subject_assets'
  and p.prosrc like '%content.read%';

-- ---------------------------------------------------------------------------
-- 15. Delete protects published current assets. Expect: one row, true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%unpublish_card_before_deleting_current_asset%') as guards_published
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_delete_subject_asset';

-- ---------------------------------------------------------------------------
-- 16. Delete always enqueues before row removal. Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_delete_subject_asset'
  and p.prosrc like '%subject_media_cleanup_queue%';

-- ---------------------------------------------------------------------------
-- 17. Register locks parent catalog/offering FOR UPDATE. Expect: one row, true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (
    p.prosrc like '%subject_catalog%for update%'
    or p.prosrc like '%subject_catalog where id = p_subject_catalog_id for update%'
  )
  and p.prosrc like '%subject_offerings%for update%' as locks_parent_owner
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_register_subject_asset';

-- ---------------------------------------------------------------------------
-- 18. Student read paths must not expose storage_path in card RPCs.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('get_subject_card', 'get_subject_card_assets')
  and p.prosrc ilike '%storage_path%';

-- ---------------------------------------------------------------------------
-- 19. get_subject_card embeds assets payload. Expect: one row, true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%subject_card_assets_json%') as embeds_assets
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_subject_card';

-- ---------------------------------------------------------------------------
-- 20. subjects.read permission seeded. Expect: at least one row.
-- ---------------------------------------------------------------------------
select code, description
from public.admin_permissions
where code = 'subjects.read';

-- ---------------------------------------------------------------------------
-- 21. subject-media bucket private with limits. Expect: one row.
-- ---------------------------------------------------------------------------
select id, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'subject-media';

-- ---------------------------------------------------------------------------
-- 22. No storage.objects policy exposes subject-media to clients. Expect: 0.
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
-- 23. Stage 16.2 additive: no card/load columns on profile tables. Expect: 0.
-- ---------------------------------------------------------------------------
select col.table_name, col.column_name
from information_schema.columns col
where col.table_schema = 'public'
  and col.table_name in (
    'subject_student_profiles', 'subject_offering_student_profiles'
  )
  and col.column_name in ('hours_total', 'credits', 'as_of_date');

-- ---------------------------------------------------------------------------
-- 0. HARD GATE
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
  v_rpcs text[] := array[
    'admin_register_subject_asset',
    'admin_list_subject_assets',
    'admin_delete_subject_asset',
    'get_subject_card_assets',
    'get_subject_card',
    'admin_create_subject_asset_upload_intent',
    'admin_finalize_subject_asset_upload',
    'authorize_subject_asset_download',
    'service_subject_asset_storage_path',
    'admin_can_manage_subject_media',
    'admin_can_read_subject_media',
    'claim_subject_media_cleanup_batch',
    'complete_subject_media_cleanup',
    'fail_subject_media_cleanup'
  ];
  v_tables text[] := array[
    'subject_assets',
    'subject_media_cleanup_queue',
    'subject_asset_upload_intents'
  ];
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
    raise exception 'stage16.2 FAIL: % client table grant(s) on asset tables', v_bad;
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
    and p.proname not in (
      'claim_subject_media_cleanup_batch',
      'complete_subject_media_cleanup',
      'fail_subject_media_cleanup',
      'service_subject_asset_storage_path'
    )
    and (
      not p.prosecdef
      or p.proconfig is null
      or not exists (
        select 1 from unnest(p.proconfig) as cfg
        where replace(cfg, '"', '') = 'search_path='
      )
    );
  if v_bad > 0 then
    raise exception 'stage16.2 FAIL: % client RPC(s) not SECURITY DEFINER with search_path=''''', v_bad;
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
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'subject_assets'
      and column_name = 'asset_kind'
  ) then
    raise exception 'stage16.2 FAIL: subject_assets.asset_kind missing';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'subject_assets'
      and column_name = 'logical_asset_id'
  ) then
    raise exception 'stage16.2 FAIL: subject_assets.logical_asset_id missing';
  end if;

  if exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and tablename = 'subject_assets'
      and indexname in (
        'subject_assets_one_current_catalog_uidx',
        'subject_assets_one_current_offering_uidx'
      )
  ) then
    raise exception 'stage16.2 FAIL: legacy one-current-per-owner indexes still present';
  end if;

  -- Guard lives in private.register_subject_asset; public admin_* is a thin
  -- service_role wrapper after Stage 16.2 hardening / upload-intent path.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'register_subject_asset'
      and p.prosrc like '%asset_foreign_owner%'
  ) then
    raise exception 'stage16.2 FAIL: supersede path does not refuse a foreign owner';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_delete_subject_asset'
      and p.prosrc like '%unpublish_card_before_deleting_current_asset%'
  ) then
    raise exception 'stage16.2 FAIL: delete does not protect a published card';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_list_subject_assets'
      and p.prosrc like '%content.read%'
  ) then
    raise exception 'stage16.2 FAIL: admin_list_subject_assets still uses content.read';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_subject_card'
      and p.prosrc like '%subject_card_assets_json%'
  ) then
    raise exception 'stage16.2 FAIL: get_subject_card does not embed assets';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('get_subject_card', 'get_subject_card_assets')
      and p.prosrc ilike '%storage_path%'
  ) then
    raise exception 'stage16.2 FAIL: student card RPC references storage_path';
  end if;

  if not exists (
    select 1 from public.admin_permissions where code = 'subjects.read'
  ) then
    raise exception 'stage16.2 FAIL: subjects.read permission not seeded';
  end if;

  if exists (
    select 1 from storage.buckets
    where id = 'subject-media'
      and (public or file_size_limit is null or allowed_mime_types is null)
  ) then
    raise exception 'stage16.2 FAIL: subject-media bucket is public or unbounded';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_register_subject_asset'
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) then
    raise exception 'stage16.2 FAIL: authenticated can execute admin_register_subject_asset';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'authorize_subject_asset_download'
      and p.prosrc ilike '%storage_path%'
  ) then
    raise exception 'stage16.2 FAIL: authorize_subject_asset_download references storage_path';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'subject_asset_upload_intents'
      and column_name = 'finalized_asset_id'
  ) then
    raise exception 'stage16.2 FAIL: subject_asset_upload_intents.finalized_asset_id missing';
  end if;

  select count(*) into v_bad
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'subject_media_cleanup_queue'
    and column_name in ('claim_token', 'claim_expires_at');
  if v_bad <> 2 then
    raise exception 'stage16.2 FAIL: cleanup queue lease columns missing (expected 2, got %)', v_bad;
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'request_subject_asset_download'
  ) then
    raise exception 'stage16.2 FAIL: request_subject_asset_download still present (path leak)';
  end if;

  -- P1 R2: admin_register must not coerce null auth.uid() to zero-UUID.
  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_register_subject_asset'
      and p.prosrc ilike '%00000000-0000-0000-0000-000000000000%'
  ) then
    raise exception 'stage16.2 FAIL: admin_register_subject_asset still uses zero-UUID created_by';
  end if;

  -- P1 R2: storage path helper must require is_current.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'service_subject_asset_storage_path'
      and p.prosrc ilike '%is_current%'
  ) then
    raise exception 'stage16.2 FAIL: service_subject_asset_storage_path missing is_current filter';
  end if;

  -- P1 R3: register must audit.
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'register_subject_asset'
      and p.prosrc like '%admin_write_audit%'
      and p.prosrc like '%subject_asset.register%'
  ) then
    raise exception 'stage16.2 FAIL: private.register_subject_asset missing subject_asset.register audit';
  end if;

  raise notice 'stage16.2 security review: PASS';
  raise notice 'stage16.2 Edge note: processCleanup must use CLEANUP_DISPATCH_SECRET or service_role bearer (see subject-media/index.ts); ordinary user JWTs forbidden';
end $$;
