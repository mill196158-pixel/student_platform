-- Stage 19 — Import Studio foundation security review.
--
-- Static, read-only checks to run AFTER applying
-- 20260729153000_stage19_import_studio_foundation.sql. Each query should
-- return zero offending rows (or the expected shape noted above it). Nothing
-- here mutates data. Do not run before the migration is applied.
--
-- Section 0 at the very bottom re-asserts the critical invariants as a hard
-- gate, so the whole file can be run with ON_ERROR_STOP=1 as a pass/fail step.

-- ---------------------------------------------------------------------------
-- 1. Both Stage 19 tables have RLS enabled AND forced (no owner bypass).
--    Expect: 2 rows, rls_enabled = true and rls_forced = true.
-- ---------------------------------------------------------------------------
select
  c.relname             as table_name,
  c.relrowsecurity      as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('import_studio_batches', 'import_studio_rows')
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
from (values ('import_studio_batches'), ('import_studio_rows')) as t(table_name)
left join pg_class c
  on c.relname = t.table_name
 and c.relnamespace = 'public'::regnamespace
where c.oid is null
   or not c.relrowsecurity
   or not c.relforcerowsecurity;

-- ---------------------------------------------------------------------------
-- 2. public / anon / authenticated must NOT hold direct table DML. Staged
--    import rows contain unvalidated personal data, so client reads are RPC
--    only. Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name like 'import\_studio\_%'
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
  and table_name like 'import\_studio\_%'
  and grantee = 'service_role'
group by table_name
order by table_name;

-- ---------------------------------------------------------------------------
-- 4. No RLS policy may expose the import tables to anon / authenticated.
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
  and c.relname like 'import\_studio\_%'
order by c.relname, pol.polname;

-- ---------------------------------------------------------------------------
-- 5. anon must NOT be able to EXECUTE any Stage 19 RPC.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  'anon'    as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'admin\_import\_studio\_%'
  and has_function_privilege('anon', p.oid, 'EXECUTE')
order by p.proname;

-- ---------------------------------------------------------------------------
-- 6. authenticated SHOULD be able to execute the Stage 19 RPCs (per-domain
--    RBAC is checked inside the function body, not by the grant).
--    Expect: 6 rows, can_execute = true.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'admin\_import\_studio\_%'
order by p.proname;

-- ---------------------------------------------------------------------------
-- 7. private import helpers must NOT be executable by anon / authenticated.
--    import_studio_validate_row and the RBAC helpers must stay internal.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (values ('anon'), ('authenticated')) as r(rolname)
where n.nspname = 'private'
  and p.proname like 'import\_studio\_%'
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
order by p.proname, r.rolname;

-- ---------------------------------------------------------------------------
-- 8. Every Stage 19 public RPC is SECURITY DEFINER with search_path = ''.
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
  and p.proname like 'admin\_import\_studio\_%'
  and (
    not p.prosecdef
    or p.proconfig is null
    or not exists (
      select 1 from unnest(p.proconfig) as cfg
      where replace(cfg, '"', '') = 'search_path='
    )
  );

-- ---------------------------------------------------------------------------
-- 9. Every private import helper also pins search_path = ''.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname   as function_name,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname like 'import\_studio\_%'
  and (
    p.proconfig is null
    or not exists (
      select 1 from unnest(p.proconfig) as cfg
      where replace(cfg, '"', '') = 'search_path='
    )
  );

-- ---------------------------------------------------------------------------
-- 10. Full Stage 19 RPC inventory must exist. Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('admin_import_studio_list_domains'),
    ('admin_import_studio_start_dry_run'),
    ('admin_import_studio_get_diff'),
    ('admin_import_studio_apply'),
    ('admin_import_studio_list_batches'),
    ('admin_import_studio_cancel_batch')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

-- ---------------------------------------------------------------------------
-- 11. NO service_role IN WEB: the Import Studio RPCs must never be the place
--     a service_role key is needed. Confirm the six RPCs are executable by
--     `authenticated` (so Admin Web uses the user's JWT) and that RBAC is
--     enforced in-body via the permission helpers.
--     Expect: 6 rows, enforces_rbac = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (
    p.prosrc like '%import_studio_require_read%'
    or p.prosrc like '%import_studio_require_apply%'
    or p.prosrc like '%require_any_admin_permission%'
    or p.prosrc like '%require_admin_permission%'
  ) as enforces_rbac
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'admin\_import\_studio\_%'
order by p.proname;

-- ---------------------------------------------------------------------------
-- 11b. Any Import Studio RPC without an in-body RBAC check is a failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname as rpc_without_rbac
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'admin\_import\_studio\_%'
  and p.prosrc not like '%import_studio_require_read%'
  and p.prosrc not like '%import_studio_require_apply%'
  and p.prosrc not like '%require_any_admin_permission%'
  and p.prosrc not like '%require_admin_permission%';

-- ---------------------------------------------------------------------------
-- 12. Per-domain RBAC mapping must cover every supported domain and must name
--     the live permission codes. Expect: 6 rows with a non-null permission.
-- ---------------------------------------------------------------------------
select
  d.domain,
  private.import_studio_domain_permission(d.domain) as required_permission,
  private.import_studio_supports_apply(d.domain)    as supports_apply
from (
  values ('teachers'), ('subjects'), ('students'),
         ('groups'), ('curriculum'), ('terms')
) as d(domain)
order by d.domain;

-- ---------------------------------------------------------------------------
-- 12b. Every domain must map to a permission code. Expect: zero rows.
-- ---------------------------------------------------------------------------
select d.domain as domain_without_permission
from (
  values ('teachers'), ('subjects'), ('students'),
         ('groups'), ('curriculum'), ('terms')
) as d(domain)
where coalesce(private.import_studio_domain_permission(d.domain), '') = '';

-- ---------------------------------------------------------------------------
-- 13. Batch keys must be idempotent: a unique constraint on (domain,
--     batch_key) is what makes a replayed dry run reuse the same batch.
--     Expect: one row.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'import_studio_batches'
  and con.contype = 'u';

-- ---------------------------------------------------------------------------
-- 13b. The idempotency constraint must exist and cover batch_key.
--      Expect: at least one row.
-- ---------------------------------------------------------------------------
select con.conname
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'import_studio_batches'
  and con.contype = 'u'
  and pg_get_constraintdef(con.oid) ilike '%batch_key%';

-- ---------------------------------------------------------------------------
-- 14. import_studio_rows must use typed match FKs, not one polymorphic id.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'import_studio_rows'
  and column_name in (
    'matched_entity_id', 'matched_entity_type', 'entity_id', 'entity_type',
    'owner_kind', 'owner_id'
  );

-- ---------------------------------------------------------------------------
-- 15. The typed match columns must each be a real FK.
--     Expect: 4 FK rows (teachers, subject_catalog, users, groups) plus the
--     batch FK.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'import_studio_rows'
  and con.contype = 'f'
order by con.conname;

-- ---------------------------------------------------------------------------
-- 15b. Each typed match column must exist. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.column_name as missing_match_column
from (
  values ('matched_teacher_id'), ('matched_subject_id'),
         ('matched_user_id'), ('matched_group_id')
) as t(column_name)
where not exists (
  select 1 from information_schema.columns col
  where col.table_schema = 'public'
    and col.table_name = 'import_studio_rows'
    and col.column_name = t.column_name
);

-- ---------------------------------------------------------------------------
-- 16. A row may match at most one PRIMARY entity. matched_group_id is
--     intentionally outside the XOR because `students` resolves user + group
--     and `curriculum` resolves subject + group; the per-domain trigger in 17
--     is what pins each column to its domain.
--     Expect: one row.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'import_studio_rows'
  and con.conname = 'import_studio_rows_single_match';

-- ---------------------------------------------------------------------------
-- 17. The per-domain match trigger must be attached, otherwise a teachers
--     batch could carry a student match.
--     Expect: one row.
-- ---------------------------------------------------------------------------
select
  c.relname as table_name,
  t.tgname  as trigger_name,
  p.proname as function_name
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc p on p.oid = t.tgfoid
where c.relnamespace = 'public'::regnamespace
  and not t.tgisinternal
  and c.relname = 'import_studio_rows'
  and p.proname = 'import_studio_rows_assert_domain';

-- ---------------------------------------------------------------------------
-- 18. Domain / status / classification vocabularies must be constrained.
--     Expect: rows for the domain, status and classification checks.
-- ---------------------------------------------------------------------------
select
  c.relname   as table_name,
  con.conname as constraint_name,
  pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname in ('import_studio_batches', 'import_studio_rows')
  and con.contype = 'c'
  and con.conname in (
    'import_studio_batches_domain_check',
    'import_studio_batches_status_check',
    'import_studio_rows_classification_check'
  )
order by c.relname, con.conname;

-- ---------------------------------------------------------------------------
-- 18b. All six domains must be present in the domain constraint.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select d.domain as missing_domain
from (
  values ('teachers'), ('subjects'), ('students'),
         ('groups'), ('curriculum'), ('terms')
) as d(domain)
where not exists (
  select 1 from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  where c.relname = 'import_studio_batches'
    and con.conname = 'import_studio_batches_domain_check'
    and pg_get_constraintdef(con.oid) like '%''' || d.domain || '''%'
);

-- ---------------------------------------------------------------------------
-- 19. TERM SAFETY — the two owner-mandated hard bans (never flip the current
--     term, never create Autumn 2026) are enforced in two layers:
--
--       Layer 1, dry run: private.import_studio_validate_row marks the offending
--       row with 'current_term_flip_forbidden' / 'autumn_2026_forbidden', which
--       makes the batch unappliable because apply refuses error rows.
--       Layer 2, apply: private.import_studio_assert_term_safety compares a
--       before/after fingerprint and raises 'import_must_not_flip_current_term'
--       / 'import_must_not_create_autumn_2026' as a post-condition tripwire.
--
--     Both layers are checked, because layer 1 alone could be bypassed by a
--     future domain writer and layer 2 alone would surface too late.
--     Expect: layer 1 row with both flags true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%current_term_flip_forbidden%') as flags_current_term_flip,
  (p.prosrc like '%autumn_2026_forbidden%')       as flags_autumn_2026
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_validate_row';

-- ---------------------------------------------------------------------------
-- 19b. Layer 2 tripwire must raise on both bans. Expect: one row, both true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%import_must_not_flip_current_term%')  as raises_on_term_flip,
  (p.prosrc like '%import_must_not_create_autumn_2026%') as raises_on_autumn_2026
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_assert_term_safety';

-- ---------------------------------------------------------------------------
-- 19c. Either layer missing a ban is a hard failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.guard, t.problem
from (
  values
    ('import_studio_validate_row', 'missing current_term_flip_forbidden'),
    ('import_studio_validate_row', 'missing autumn_2026_forbidden'),
    ('import_studio_assert_term_safety', 'missing import_must_not_flip_current_term'),
    ('import_studio_assert_term_safety', 'missing import_must_not_create_autumn_2026')
) as t(guard, problem)
where not exists (
  select 1 from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname = t.guard
    and p.prosrc like '%' || split_part(t.problem, ' ', 2) || '%'
);

-- ---------------------------------------------------------------------------
-- 19d. The layer 2 tripwire must actually be wired into apply, not merely
--      defined. Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_apply'
  and p.prosrc like '%import_studio_assert_term_safety%';

-- ---------------------------------------------------------------------------
-- 20. The terms and curriculum domains must be validate-only, so a dry run
--     can never be applied for them.
--     Expect: supports_apply = false for both.
-- ---------------------------------------------------------------------------
select
  d.domain,
  private.import_studio_supports_apply(d.domain) as supports_apply
from (values ('terms'), ('curriculum')) as d(domain)
order by d.domain;

-- ---------------------------------------------------------------------------
-- 20b. Either domain claiming apply support is a failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select d.domain as unexpectedly_appliable
from (values ('terms'), ('curriculum')) as d(domain)
where private.import_studio_supports_apply(d.domain);

-- ---------------------------------------------------------------------------
-- 21. Apply must be confirmation-gated (batch_key) so a stale Admin tab cannot
--     replay someone else's batch. Expect: one row whose args include a key.
-- ---------------------------------------------------------------------------
select p.proname, pg_get_function_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_apply';

-- ---------------------------------------------------------------------------
-- 21b. admin_import_studio_apply must take a confirmation key argument.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname as apply_without_confirmation
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_apply'
  and pg_get_function_arguments(p.oid) not like '%batch_key%';

-- ---------------------------------------------------------------------------
-- 22. Apply must refuse batches that still contain error rows.
--     Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_apply'
  and p.prosrc like '%error%';

-- ---------------------------------------------------------------------------
-- 23. Audit: apply and dry run must land admin audit records.
--     Expect: 2 rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_import_studio_start_dry_run', 'admin_import_studio_apply'
  )
  and p.prosrc like '%admin_write_audit%'
order by p.proname;

-- ---------------------------------------------------------------------------
-- 23b. Either RPC without an audit write is a failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.proname as rpc_without_audit
from (
  values ('admin_import_studio_start_dry_run'), ('admin_import_studio_apply')
) as t(proname)
where not exists (
  select 1 from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = t.proname
    and p.prosrc like '%admin_write_audit%'
);

-- ---------------------------------------------------------------------------
-- 0. HARD GATE — re-assert the critical invariants. Raises on any violation.
--    Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
  v_domains text[] := array[
    'teachers', 'subjects', 'students', 'groups', 'curriculum', 'terms'
  ];
begin
  select count(*) into v_bad
  from unnest(array['import_studio_batches', 'import_studio_rows']) as t(name)
  left join pg_class c
    on c.relname = t.name and c.relnamespace = 'public'::regnamespace
  where c.oid is null or not c.relrowsecurity or not c.relforcerowsecurity;
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % table(s) missing or without FORCE RLS', v_bad;
  end if;

  select count(*) into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name like 'import\_studio\_%'
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % client table grant(s) on import tables', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(array[
    'admin_import_studio_list_domains', 'admin_import_studio_start_dry_run',
    'admin_import_studio_get_diff', 'admin_import_studio_apply',
    'admin_import_studio_list_batches', 'admin_import_studio_cancel_batch'
  ]) as r(name)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = r.name
  );
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % RPC(s) missing', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname like 'admin\_import\_studio\_%'
    and (
      not p.prosecdef
      or p.proconfig is null
      or not exists (
        select 1 from unnest(p.proconfig) as cfg
        where replace(cfg, '"', '') = 'search_path='
      )
    );
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % RPC(s) not SECURITY DEFINER with search_path=''''', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname like 'admin\_import\_studio\_%'
    and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad > 0 then
    raise exception 'stage19 FAIL: anon can execute % Import Studio RPC(s)', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname like 'import\_studio\_%'
    and (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    );
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % private import helper(s) client-executable', v_bad;
  end if;

  -- Every RPC must enforce RBAC in-body; the web client uses the user JWT,
  -- never a service_role key.
  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname like 'admin\_import\_studio\_%'
    and p.prosrc not like '%import_studio_require_read%'
    and p.prosrc not like '%import_studio_require_apply%'
    and p.prosrc not like '%require_any_admin_permission%'
    and p.prosrc not like '%require_admin_permission%';
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % Import Studio RPC(s) without an in-body RBAC check', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(v_domains) as d(domain)
  where coalesce(private.import_studio_domain_permission(d.domain), '') = '';
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % domain(s) without a permission mapping', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(v_domains) as d(domain)
  where not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'import_studio_batches'
      and con.conname = 'import_studio_batches_domain_check'
      and pg_get_constraintdef(con.oid) like '%''' || d.domain || '''%'
  );
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % domain(s) missing from the domain constraint', v_bad;
  end if;

  -- Idempotent batch keys.
  if not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'import_studio_batches'
      and con.contype = 'u'
      and pg_get_constraintdef(con.oid) ilike '%batch_key%'
  ) then
    raise exception 'stage19 FAIL: no unique constraint making batch keys idempotent';
  end if;

  -- Typed matches, not polymorphic.
  select count(*) into v_bad
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'import_studio_rows'
    and column_name in (
      'matched_entity_id', 'matched_entity_type', 'entity_id', 'entity_type',
      'owner_kind', 'owner_id'
    );
  if v_bad > 0 then
    raise exception 'stage19 FAIL: import_studio_rows has % polymorphic match column(s)', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(array['matched_teacher_id', 'matched_subject_id',
                    'matched_user_id', 'matched_group_id']) as t(col)
  where not exists (
    select 1 from information_schema.columns col
    where col.table_schema = 'public'
      and col.table_name = 'import_studio_rows'
      and col.column_name = t.col
  );
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % typed match column(s) missing', v_bad;
  end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
    where c.relnamespace = 'public'::regnamespace
      and not t.tgisinternal
      and c.relname = 'import_studio_rows'
      and p.proname = 'import_studio_rows_assert_domain'
  ) then
    raise exception 'stage19 FAIL: per-domain match trigger missing';
  end if;

  -- Term safety, layer 1: the dry-run validator must flag both bans.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_validate_row'
      and p.prosrc like '%current_term_flip_forbidden%'
      and p.prosrc like '%autumn_2026_forbidden%'
  ) then
    raise exception 'stage19 FAIL: dry-run validator missing a term-safety ban';
  end if;

  -- Term safety, layer 2: the apply-time tripwire must raise on both bans.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_assert_term_safety'
      and p.prosrc like '%import_must_not_flip_current_term%'
      and p.prosrc like '%import_must_not_create_autumn_2026%'
  ) then
    raise exception 'stage19 FAIL: apply-time term-safety tripwire missing a ban';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_apply'
      and p.prosrc like '%import_studio_assert_term_safety%'
  ) then
    raise exception 'stage19 FAIL: term-safety tripwire is defined but not wired into apply';
  end if;

  -- Validate-only domains must not be appliable.
  select count(*) into v_bad
  from unnest(array['terms', 'curriculum']) as d(domain)
  where private.import_studio_supports_apply(d.domain);
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % validate-only domain(s) claim apply support', v_bad;
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_apply'
      and pg_get_function_arguments(p.oid) not like '%batch_key%'
  ) then
    raise exception 'stage19 FAIL: admin_import_studio_apply is not confirmation-gated';
  end if;

  select count(*) into v_bad
  from unnest(array['admin_import_studio_start_dry_run',
                    'admin_import_studio_apply']) as t(proname)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = t.proname
      and p.prosrc like '%admin_write_audit%'
  );
  if v_bad > 0 then
    raise exception 'stage19 FAIL: % import RPC(s) without an audit write', v_bad;
  end if;

  raise notice 'stage19 security review: PASS';
end $$;

-- ===========================================================================
-- P1 REWORK ASSERTIONS (Codex REJECT round 1)
--
-- Pins the four foundation P1s: batch ownership, PII read scope, honest domain
-- matrix, rollback refusal. Read-only.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 40. Batch idempotency is PER OPERATOR: uniqueness is
--     (created_by, domain, batch_key), so one admin cannot replay, refresh or
--     cancel another admin's batch by guessing a key. Expect: one row.
-- ---------------------------------------------------------------------------
select
  con.conname,
  pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'import_studio_batches'
  and con.contype = 'u'
  and pg_get_constraintdef(con.oid) like '%created_by%'
  and pg_get_constraintdef(con.oid) like '%domain%'
  and pg_get_constraintdef(con.oid) like '%batch_key%';

-- ---------------------------------------------------------------------------
-- 40b. A (domain, batch_key)-only unique constraint would make the workspace
--      shared again. Expect: zero rows.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'import_studio_batches'
  and con.contype = 'u'
  and pg_get_constraintdef(con.oid) like '%batch_key%'
  and pg_get_constraintdef(con.oid) not like '%created_by%';

-- ---------------------------------------------------------------------------
-- 40c. created_by must be NOT NULL, otherwise the per-operator key degenerates
--      (NULLs are never equal, so uniqueness would stop applying).
--      Expect: one row, is_nullable = NO.
-- ---------------------------------------------------------------------------
select column_name, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'import_studio_batches'
  and column_name = 'created_by';

-- ---------------------------------------------------------------------------
-- 41. Every batch-scoped RPC must enforce OWNERSHIP, not just the domain
--     permission. Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_owner_check
from (
  values
    ('admin_import_studio_get_diff'),
    ('admin_import_studio_apply'),
    ('admin_import_studio_cancel_batch'),
    ('admin_import_studio_rollback_batch')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = r.proname
    and p.prosrc like '%import_studio_assert_owner%'
);

-- ---------------------------------------------------------------------------
-- 41b. Dry-run refresh must look up the existing batch by created_by, so it
--      cannot hijack another operator's batch row. Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_start_dry_run'
  and p.prosrc like '%created_by = v_uid%';

-- ---------------------------------------------------------------------------
-- 41c. The batch list must be scoped to the caller. Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_list_batches'
  and p.prosrc like '%created_by%';

-- ---------------------------------------------------------------------------
-- 42. PII SCOPE: `academic.read` must NOT be a generic cross-domain payload
--     read. The domain permission map may never map a domain to it.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname as maps_domain_to_academic_read
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_domain_permission'
  and p.prosrc like '%academic.read%';

-- ---------------------------------------------------------------------------
-- 42b. The staged-row read gate must require the DOMAIN permission.
--      Expect: one row, requires_domain_perm = true,
--      accepts_academic_read = false.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%import_studio_domain_permission%') as requires_domain_perm,
  (p.prosrc like '%academic.read%')                   as accepts_academic_read
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_require_read';

-- ---------------------------------------------------------------------------
-- 42c. Only the payload-free hub catalogue may accept academic.read.
--      Expect: one row (list_domains), and nothing else.
-- ---------------------------------------------------------------------------
select p.proname as mentions_academic_read
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'admin\_import\_studio\_%'
  and p.prosrc like '%academic.read%'
order by p.proname;

-- ---------------------------------------------------------------------------
-- 43. HONEST DOMAIN MATRIX: there must be a single function stating each
--     domain's real state, and the three unimplemented domains must be
--     `not_implemented` rather than silently advertised.
--     Expect: one row, all flags true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%not_implemented%')  as has_not_implemented_state,
  (p.prosrc like '%offerings%')        as declares_offerings,
  (p.prosrc like '%teacher_links%')    as declares_teacher_links,
  (p.prosrc like '%enrollments%')      as declares_enrollments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_domain_state';

-- ---------------------------------------------------------------------------
-- 43b. Both gates must refuse an unimplemented domain up front, so a stub can
--      never look like a working import. Expect: 2 rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname in ('import_studio_require_read', 'import_studio_require_apply')
  and p.prosrc like '%import_studio_assert_implemented%'
order by p.proname;

-- ---------------------------------------------------------------------------
-- 43c. The refusal must be a real error, not a silent empty result.
--      Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_assert_implemented'
  and p.prosrc like '%not_implemented_domain_%';

-- ---------------------------------------------------------------------------
-- 43d. The hub catalogue must report the state and must not claim apply for a
--      validate-only or unimplemented domain. Expect: one row, both true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%domain_state%')               as reports_state,
  (p.prosrc like '%import_studio_domain_state%') as derives_from_matrix
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_list_domains';

-- ---------------------------------------------------------------------------
-- 44. ROLLBACK: the RPC exists, is gated on rollback_safe, and refuses every
--     batch in this foundation. Expect: one row, all flags true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%rollback_safe%')                        as checks_flag,
  (p.prosrc like '%rollback_not_supported_for_batch%')     as refuses_unsafe,
  (p.prosrc like '%batch_key_confirmation_mismatch%')      as requires_confirmation,
  (p.prosrc like '%admin_write_audit%')                    as audits_attempt
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_rollback_batch';

-- ---------------------------------------------------------------------------
-- 44b. rollback_safe must default to FALSE, so no batch is rollbackable by
--      accident. Expect: one row, column_default like 'false'.
-- ---------------------------------------------------------------------------
select column_name, column_default, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'import_studio_batches'
  and column_name = 'rollback_safe';

-- ---------------------------------------------------------------------------
-- 0b. HARD GATE for the P1 rework. Raises on any violation. Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  -- 1) Per-operator batch key.
  if not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'import_studio_batches'
      and con.contype = 'u'
      and pg_get_constraintdef(con.oid) like '%created_by%'
      and pg_get_constraintdef(con.oid) like '%domain%'
      and pg_get_constraintdef(con.oid) like '%batch_key%'
  ) then
    raise exception
      'stage19 P1 FAIL: batch_key uniqueness is not scoped by (created_by, domain, batch_key)';
  end if;

  if exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'import_studio_batches'
      and con.contype = 'u'
      and pg_get_constraintdef(con.oid) like '%batch_key%'
      and pg_get_constraintdef(con.oid) not like '%created_by%'
  ) then
    raise exception
      'stage19 P1 FAIL: a cross-operator (domain, batch_key) unique constraint still exists';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'import_studio_batches'
      and column_name = 'created_by'
      and is_nullable = 'NO'
  ) then
    raise exception
      'stage19 P1 FAIL: import_studio_batches.created_by is nullable, so the per-operator key does not hold';
  end if;

  -- 2) Ownership on every batch-scoped RPC.
  select count(*) into v_bad
  from (
    values ('admin_import_studio_get_diff'), ('admin_import_studio_apply'),
           ('admin_import_studio_cancel_batch'),
           ('admin_import_studio_rollback_batch')
  ) as r(proname)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = r.proname
      and p.prosrc like '%import_studio_assert_owner%'
  );
  if v_bad > 0 then
    raise exception 'stage19 P1 FAIL: % batch RPC(s) without an ownership check', v_bad;
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_start_dry_run'
      and p.prosrc like '%created_by = v_uid%'
  ) then
    raise exception
      'stage19 P1 FAIL: dry-run refresh is not scoped to the calling operator';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_list_batches'
      and p.prosrc like '%created_by%'
  ) then
    raise exception 'stage19 P1 FAIL: the batch list is not scoped to the caller';
  end if;

  -- 3) academic.read is not a generic PII pass.
  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname in (
        'import_studio_domain_permission', 'import_studio_require_read',
        'import_studio_require_apply'
      )
      and p.prosrc like '%academic.read%'
  ) then
    raise exception
      'stage19 P1 FAIL: academic.read is accepted as a cross-domain payload read';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_require_read'
      and p.prosrc like '%import_studio_domain_permission%'
  ) then
    raise exception
      'stage19 P1 FAIL: the staged-row read gate does not require the domain permission';
  end if;

  -- 4) Honest domain matrix.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_domain_state'
      and p.prosrc like '%not_implemented%'
      and p.prosrc like '%offerings%'
      and p.prosrc like '%teacher_links%'
      and p.prosrc like '%enrollments%'
  ) then
    raise exception
      'stage19 P1 FAIL: the domain matrix does not honestly declare the unimplemented domains';
  end if;

  select count(*) into v_bad
  from (
    values ('import_studio_require_read'), ('import_studio_require_apply')
  ) as r(proname)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = r.proname
      and p.prosrc like '%import_studio_assert_implemented%'
  );
  if v_bad > 0 then
    raise exception
      'stage19 P1 FAIL: % gate(s) do not refuse an unimplemented domain', v_bad;
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_assert_implemented'
      and p.prosrc like '%not_implemented_domain_%'
  ) then
    raise exception
      'stage19 P1 FAIL: an unimplemented domain fails silently instead of raising';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_list_domains'
      and p.prosrc like '%import_studio_domain_state%'
  ) then
    raise exception
      'stage19 P1 FAIL: the hub catalogue does not derive capability from the domain matrix';
  end if;

  -- 5) Rollback stub refuses everything and audits the attempt.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_rollback_batch'
      and p.prosrc like '%rollback_safe%'
      and p.prosrc like '%rollback_not_supported_for_batch%'
      and p.prosrc like '%admin_write_audit%'
  ) then
    raise exception
      'stage19 P1 FAIL: admin_import_studio_rollback_batch missing, ungated or unaudited';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'import_studio_batches'
      and column_name = 'rollback_safe'
      and is_nullable = 'NO'
      and column_default ilike '%false%'
  ) then
    raise exception
      'stage19 P1 FAIL: rollback_safe is nullable or does not default to false';
  end if;

  raise notice 'stage19 P1 rework assertions: PASS';
end $$;
