-- Stage 16.3 — reference corrections security review.
--
-- Static, read-only checks to run AFTER applying
-- 20260729150700_stage16_3_reference_corrections.sql. Each query should return
-- zero offending rows (or the expected shape noted above it). Nothing here
-- mutates data. Do not run before the migration is applied.
--
-- Section 0 at the very bottom re-asserts the critical invariants as a hard
-- gate, so the whole file can be run with ON_ERROR_STOP=1 as a pass/fail step.

-- ---------------------------------------------------------------------------
-- 1. content_corrections has RLS enabled AND forced (no owner bypass).
--    Expect: one row, both true.
-- ---------------------------------------------------------------------------
select
  c.relname             as table_name,
  c.relrowsecurity      as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'content_corrections';

-- ---------------------------------------------------------------------------
-- 1b. Missing table (or missing RLS/FORCE) is a hard failure.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  (c.oid is not null)                    as table_exists,
  coalesce(c.relrowsecurity, false)      as rls_enabled,
  coalesce(c.relforcerowsecurity, false) as rls_forced
from (values ('content_corrections')) as t(table_name)
left join pg_class c
  on c.relname = t.table_name
 and c.relnamespace = 'public'::regnamespace
where c.oid is null
   or not c.relrowsecurity
   or not c.relforcerowsecurity;

-- ---------------------------------------------------------------------------
-- 2. public / anon / authenticated must NOT hold direct table DML.
--    Expect: zero rows. Reports are written by RPC only.
-- ---------------------------------------------------------------------------
select table_schema, table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'content_corrections'
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
order by grantee, privilege_type;

-- ---------------------------------------------------------------------------
-- 3. service_role holds the table DML instead.
--    Expect: SELECT/INSERT/UPDATE/DELETE.
-- ---------------------------------------------------------------------------
select
  table_name,
  string_agg(distinct privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'content_corrections'
  and grantee = 'service_role'
group by table_name;

-- ---------------------------------------------------------------------------
-- 4. No RLS policy may expose the table to anon / authenticated.
--    Expect: zero rows (deny-by-absence + FORCE RLS).
-- ---------------------------------------------------------------------------
select
  pol.polname as policy_name,
  pol.polcmd  as command,
  pg_get_expr(pol.polqual, pol.polrelid) as using_expr
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'content_corrections'
order by pol.polname;

-- ---------------------------------------------------------------------------
-- 5. anon must NOT be able to EXECUTE any Stage 16.3 RPC. Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname as function_name, 'anon' as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'submit_content_correction', 'admin_list_content_corrections',
    'admin_resolve_content_correction'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 6. authenticated SHOULD be able to execute them (RBAC in-body).
--    Expect: 3 rows, can_execute = true.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'submit_content_correction', 'admin_list_content_corrections',
    'admin_resolve_content_correction'
  )
order by p.proname;

-- ---------------------------------------------------------------------------
-- 7. Every Stage 16.3 RPC is SECURITY DEFINER with search_path = ''.
--    Expect: zero rows. (Postgres stores it as search_path="" — strip quotes.)
-- ---------------------------------------------------------------------------
select
  p.proname   as function_name,
  p.prosecdef as security_definer,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'submit_content_correction', 'admin_list_content_corrections',
    'admin_resolve_content_correction'
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
-- 8. Full Stage 16.3 RPC inventory must exist. Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('submit_content_correction'),
    ('admin_list_content_corrections'),
    ('admin_resolve_content_correction')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

-- ---------------------------------------------------------------------------
-- 9. Owner-specified shape: id, content_item_id, reporter_user_id, note,
--    status, created_at. Expect: 6 rows.
-- ---------------------------------------------------------------------------
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'content_corrections'
  and column_name in (
    'id', 'content_item_id', 'reporter_user_id', 'note', 'status', 'created_at'
  )
order by column_name;

-- ---------------------------------------------------------------------------
-- 9b. Any of those six columns missing is a hard failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.column_name as missing_column
from (
  values ('id'), ('content_item_id'), ('reporter_user_id'),
         ('note'), ('status'), ('created_at')
) as t(column_name)
where not exists (
  select 1 from information_schema.columns col
  where col.table_schema = 'public'
    and col.table_name = 'content_corrections'
    and col.column_name = t.column_name
);

-- ---------------------------------------------------------------------------
-- 10. REFERENCE REUSES STAGE 14: content_item_id must FK to content_items, so
--     there is no parallel reference system. Expect: one row.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'content_corrections'
  and con.contype = 'f'
  and pg_get_constraintdef(con.oid) ilike '%content_items%';

-- ---------------------------------------------------------------------------
-- 11. IDOR: a student may only report an item that is deliverable to them, so
--     the submit RPC must consult the Stage 14 visibility helper.
--     Expect: one row, checks_deliverable = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%content_item_deliverable_to_user%') as checks_deliverable
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'submit_content_correction';

-- ---------------------------------------------------------------------------
-- 12. Flood protection: one OPEN report per (item, reporter) enforced by a
--     PARTIAL unique index, plus a rate limit in the RPC. Expect: one row.
--
--     The predicate is matched loosely because Postgres renders it with an
--     explicit cast, e.g. `WHERE (status = 'open'::text)`.
-- ---------------------------------------------------------------------------
select
  i.relname as index_name,
  pg_get_indexdef(i.oid) as definition
from pg_class i
join pg_index x on x.indexrelid = i.oid
join pg_class c on c.oid = x.indrelid
where c.relname = 'content_corrections'
  and x.indisunique
  and x.indpred is not null
  and pg_get_indexdef(i.oid) ilike '%status = ''open''%';

-- ---------------------------------------------------------------------------
-- 13. Reporter privacy: the moderator list must NOT return reporter identity.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname as leaks_reporter
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_list_content_corrections'
  and p.prosrc like '%reporter_user_id%';

-- ---------------------------------------------------------------------------
-- 14. Resolution must be audited and must refuse an already-closed report.
--     Expect: one row, both true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%admin_write_audit%') as audits,
  (p.prosrc like '%already_closed%')    as refuses_double_close
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_resolve_content_correction';

-- ---------------------------------------------------------------------------
-- 0. HARD GATE — re-assert the critical invariants. Raises on any violation.
--    Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
  v_rpcs text[] := array[
    'submit_content_correction', 'admin_list_content_corrections',
    'admin_resolve_content_correction'
  ];
begin
  if not exists (
    select 1 from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relname = 'content_corrections'
      and c.relrowsecurity
      and c.relforcerowsecurity
  ) then
    raise exception 'stage16.3 FAIL: content_corrections missing or without FORCE RLS';
  end if;

  select count(*) into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'content_corrections'
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');
  if v_bad > 0 then
    raise exception 'stage16.3 FAIL: % client table grant(s) on content_corrections', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(v_rpcs) as r(name)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = r.name
  );
  if v_bad > 0 then
    raise exception 'stage16.3 FAIL: % RPC(s) missing', v_bad;
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
    raise exception 'stage16.3 FAIL: % RPC(s) not SECURITY DEFINER with search_path=''''', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = any (v_rpcs)
    and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad > 0 then
    raise exception 'stage16.3 FAIL: anon can execute % Stage 16.3 RPC(s)', v_bad;
  end if;

  if not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'content_corrections'
      and con.contype = 'f'
      and pg_get_constraintdef(con.oid) ilike '%content_items%'
  ) then
    raise exception 'stage16.3 FAIL: content_corrections does not reuse content_items';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'submit_content_correction'
      and p.prosrc like '%content_item_deliverable_to_user%'
  ) then
    raise exception 'stage16.3 FAIL: submit does not check item deliverability (IDOR)';
  end if;

  if not exists (
    select 1
    from pg_class i
    join pg_index x on x.indexrelid = i.oid
    join pg_class c on c.oid = x.indrelid
    where c.relname = 'content_corrections'
      and x.indisunique
      and x.indpred is not null
      and pg_get_indexdef(i.oid) ilike '%status = ''open''%'
  ) then
    raise exception 'stage16.3 FAIL: no partial unique index limiting open reports';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_list_content_corrections'
      and p.prosrc like '%reporter_user_id%'
  ) then
    raise exception 'stage16.3 FAIL: moderator list exposes reporter identity';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_resolve_content_correction'
      and p.prosrc like '%admin_write_audit%'
      and p.prosrc like '%already_closed%'
  ) then
    raise exception 'stage16.3 FAIL: resolution is unaudited or allows a double close';
  end if;

  raise notice 'stage16.3 security review: PASS';
end $$;
