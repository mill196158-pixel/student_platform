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
-- 20. SUPERSEDED by section 60 below (Stage 19 completion migration
--     20260729154000_stage19_import_studio_completion.sql promotes terms and
--     curriculum to `apply`). Kept as a historical record of the foundation
--     gate; do not treat its "Expect" comment as current. The corrected,
--     current-state assertion is section 60 / hard gate 0d.
--     The terms and curriculum domains must be validate-only, so a dry run
--     can never be applied for them.
--     Expect (FOUNDATION ONLY, now false): supports_apply = false for both.
-- ---------------------------------------------------------------------------
select
  d.domain,
  private.import_studio_supports_apply(d.domain) as supports_apply
from (values ('terms'), ('curriculum')) as d(domain)
order by d.domain;

-- ---------------------------------------------------------------------------
-- 20b. SUPERSEDED by section 60b. Foundation-only expectation (now false):
--      either domain claiming apply support is a failure.
-- ---------------------------------------------------------------------------
select d.domain as unexpectedly_appliable_FOUNDATION_ONLY_SEE_60B
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

  -- SUPERSEDED by hard gate 0d (section 60, below): the completion migration
  -- 20260729154000_stage19_import_studio_completion.sql intentionally
  -- promotes terms/curriculum (and offerings/teacher_links/groups/
  -- enrollments) from validate_only to apply, so this foundation-era ban
  -- would now always fail against the current schema — found while
  -- verifying this file end to end against a completion-migration DB
  -- (P1 fix session: "stale foundation gate always FAILs post-completion").
  -- Left as a comment, not a live check, so this file stays a working
  -- pass/fail gate for the CURRENT schema rather than a permanent failure.

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

  -- 4) Honest domain matrix. SUPERSEDED by the Stage 19 completion migration
  --    (20260729154000_stage19_import_studio_completion.sql), which promotes
  --    every domain to `apply` — there are no more not_implemented/
  --    validate_only domains to honestly flag here. The substance of this
  --    check (domain_state still names offerings/teacher_links/enrollments,
  --    so they cannot silently disappear from the matrix) is preserved; the
  --    now-retired `not_implemented` literal requirement is dropped. See
  --    hard gate 0d below for the completion-era honesty assertion
  --    (all nine domains must report `apply`, none may report
  --    not_implemented/validate_only).
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_domain_state'
      and p.prosrc like '%offerings%'
      and p.prosrc like '%teacher_links%'
      and p.prosrc like '%enrollments%'
  ) then
    raise exception
      'stage19 P1 FAIL: the domain matrix no longer names offerings/teacher_links/enrollments';
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

-- ===========================================================================
-- P1 HARDENING (Codex CHANGES_REQUESTED round 2)
-- ===========================================================================

-- 45. Applied batch_key replay must compare payload_hash.
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_start_dry_run'
  and p.prosrc like '%batch_key_payload_mismatch%'
  and p.prosrc like '%payload_hash is distinct from v_hash%';

-- 46. Apply must fail closed and persist failed after nested rollback.
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_apply'
  and p.prosrc like '%delegated_apply_failed_inner%'
  and p.prosrc like '%delegated_apply_failed%'
  and p.prosrc like '%delegated_result%'
  and p.prosrc like '%status = ''failed''%';

-- 47. Teacher mapped payload: teacher_id authoritative + public contacts.
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_validate_row'
  and p.prosrc like '%teacher_id%'
  and p.prosrc like '%contacts_public%'
  and p.prosrc like '%public_email%';

-- 0c. HARD GATE for P1 hardening.
do $$
begin
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_start_dry_run'
      and p.prosrc like '%batch_key_payload_mismatch%'
      and p.prosrc like '%payload_hash is distinct from v_hash%'
  ) then
    raise exception
      'stage19 P1 hardening FAIL: dry-run missing payload_hash mismatch guard on applied replay';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_apply'
      and p.prosrc like '%delegated_apply_failed_inner%'
      and p.prosrc like '%delegated_apply_failed%'
      and p.prosrc like '%status = ''failed''%'
  ) then
    raise exception
      'stage19 P1 hardening FAIL: apply does not persist failed after nested rollback';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_validate_row'
      and p.prosrc like '%teacher_id%'
      and p.prosrc like '%contacts_public%'
  ) then
    raise exception
      'stage19 P1 hardening FAIL: teacher validate/map missing teacher_id/contacts_public';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_template'
      and p.prosrc like '%teacher_id%'
  ) then
    raise exception
      'stage19 P1 hardening FAIL: teacher template omits teacher_id';
  end if;

  raise notice 'stage19 P1 hardening assertions: PASS';
end $$;

-- ===========================================================================
-- STAGE 19 COMPLETION — 20260729154000_stage19_import_studio_completion.sql
--
-- Promotes groups, terms, curriculum, offerings, teacher_links and
-- enrollments from validate_only/not_implemented to a real, owned apply +
-- rollback path (teachers/subjects/students keep delegating to the existing
-- Stage 13 RPCs, unchanged). Read-only.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 60. Every domain must now report domain_state = 'apply'. This intentionally
--     replaces sections 20/20b and the "not_implemented" half of 43/0b, which
--     encoded the foundation's honest gaps — those gaps are now closed.
--     Expect: 9 rows, all domain_state = 'apply'.
-- ---------------------------------------------------------------------------
select
  d.domain,
  private.import_studio_domain_state(d.domain) as domain_state,
  private.import_studio_supports_apply(d.domain) as supports_apply
from (
  values
    ('teachers'), ('subjects'), ('students'), ('groups'), ('curriculum'),
    ('terms'), ('offerings'), ('teacher_links'), ('enrollments')
) as d(domain)
order by d.domain;

-- ---------------------------------------------------------------------------
-- 60b. Any domain not reporting apply is a completion regression.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select d.domain as domain_not_promoted_to_apply
from (
  values
    ('teachers'), ('subjects'), ('students'), ('groups'), ('curriculum'),
    ('terms'), ('offerings'), ('teacher_links'), ('enrollments')
) as d(domain)
where coalesce(private.import_studio_domain_state(d.domain), '') <> 'apply';

-- ---------------------------------------------------------------------------
-- 61. Each of the six newly-owned domains has a dedicated Stage-19 apply
--     helper: SECURITY DEFINER, search_path = '', service_role only.
--     Expect: 6 rows, all three flags true.
-- ---------------------------------------------------------------------------
select
  t.helper,
  p.prosecdef as security_definer,
  (
    p.proconfig is not null
    and exists (
      select 1 from unnest(p.proconfig) as cfg
      where replace(cfg, '"', '') = 'search_path='
    )
  ) as pins_search_path,
  (
    has_function_privilege('service_role', p.oid, 'EXECUTE')
    and not has_function_privilege('anon', p.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) as service_role_only
from (
  values
    ('import_studio_apply_groups'), ('import_studio_apply_terms'),
    ('import_studio_apply_curriculum'), ('import_studio_apply_offerings'),
    ('import_studio_apply_teacher_links'), ('import_studio_apply_enrollments')
) as t(helper)
join pg_proc p on p.proname = t.helper
join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'private'
order by t.helper;

-- ---------------------------------------------------------------------------
-- 61b. A missing, non-definer, unpinned or client-executable apply helper is
--      a hard failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.helper as broken_apply_helper
from (
  values
    ('import_studio_apply_groups'), ('import_studio_apply_terms'),
    ('import_studio_apply_curriculum'), ('import_studio_apply_offerings'),
    ('import_studio_apply_teacher_links'), ('import_studio_apply_enrollments')
) as t(helper)
left join pg_proc p
  on p.proname = t.helper
 and p.pronamespace = 'private'::regnamespace
where p.oid is null
   or not p.prosecdef
   or p.proconfig is null
   or not exists (
     select 1 from unnest(p.proconfig) as cfg
     where replace(cfg, '"', '') = 'search_path='
   )
   or has_function_privilege('anon', p.oid, 'EXECUTE')
   or has_function_privilege('authenticated', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 62. admin_import_studio_apply must dispatch to every one of the six new
--     helpers by name, so a domain can never fall through to "nothing runs".
--     Expect: 6 rows, all true.
-- ---------------------------------------------------------------------------
select
  t.helper,
  p.prosrc like ('%' || t.helper || '%') as is_dispatched
from (
  values
    ('import_studio_apply_groups'), ('import_studio_apply_terms'),
    ('import_studio_apply_curriculum'), ('import_studio_apply_offerings'),
    ('import_studio_apply_teacher_links'), ('import_studio_apply_enrollments')
) as t(helper)
cross join (
  select p.prosrc from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'admin_import_studio_apply'
) as p
order by t.helper;

-- ---------------------------------------------------------------------------
-- 62b. Any of the six helpers not referenced from the dispatcher is a hard
--      failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.helper as not_dispatched
from (
  values
    ('import_studio_apply_groups'), ('import_studio_apply_terms'),
    ('import_studio_apply_curriculum'), ('import_studio_apply_offerings'),
    ('import_studio_apply_teacher_links'), ('import_studio_apply_enrollments')
) as t(helper)
where not exists (
  select 1 from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'admin_import_studio_apply'
    and p.prosrc like '%' || t.helper || '%'
);

-- ---------------------------------------------------------------------------
-- 63. ROLLBACK SAFETY is an EXPLICIT allow-list of exactly four domains
--     (terms, curriculum, offerings, teacher_links). groups and enrollments
--     are intentionally excluded (side effects: group_space team/chat,
--     team-membership drift) and must never be set rollback_safe = true.
--     Expect: one row naming exactly those four domains.
-- ---------------------------------------------------------------------------
select p.prosrc like
  '%domain in (''terms'', ''curriculum'', ''offerings'', ''teacher_links'')%'
  as rollback_safe_allowlist_matches
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_apply';

-- ---------------------------------------------------------------------------
-- 63b. Rollback-safe allow-list drifting from those exact four domains is a
--      hard failure (either widened to an unsafe domain, or narrowed so a
--      safe domain can no longer roll back). Expect: one row, matches = true.
-- ---------------------------------------------------------------------------
select p.proname, false as matches
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_apply'
  and p.prosrc not like
    '%domain in (''terms'', ''curriculum'', ''offerings'', ''teacher_links'')%';

-- ---------------------------------------------------------------------------
-- 64. Rollback must refuse a non-rollback-safe batch by its persisted flag,
--     not by re-deriving domain rules at rollback time (so an applied batch's
--     safety can never silently change after the fact).
--     Expect: one row, refuses_by_flag = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%not v_batch.rollback_safe%') as refuses_by_flag
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_rollback_batch';

-- ---------------------------------------------------------------------------
-- 65. Rollback dependency checks are EXPLICIT existence checks
--     (private.import_studio_*_blockers), not "delete and catch the FK
--     violation" — several of the relevant FKs are ON DELETE SET NULL /
--     CASCADE and would silently orphan or cascade-delete unrelated rows
--     instead of raising. Expect: 3 rows, service_role only.
-- ---------------------------------------------------------------------------
select
  t.blocker,
  (
    has_function_privilege('service_role', p.oid, 'EXECUTE')
    and not has_function_privilege('anon', p.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) as service_role_only
from (
  values
    ('import_studio_term_blockers'),
    ('import_studio_curriculum_blockers'),
    ('import_studio_offering_blockers')
) as t(blocker)
join pg_proc p on p.proname = t.blocker
join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'private'
order by t.blocker;

-- ---------------------------------------------------------------------------
-- 65b. A missing or client-executable blocker function is a hard failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.blocker as broken_blocker
from (
  values
    ('import_studio_term_blockers'),
    ('import_studio_curriculum_blockers'),
    ('import_studio_offering_blockers')
) as t(blocker)
left join pg_proc p
  on p.proname = t.blocker and p.pronamespace = 'private'::regnamespace
where p.oid is null
   or has_function_privilege('anon', p.oid, 'EXECUTE')
   or has_function_privilege('authenticated', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 66. admin_import_studio_rollback_batch must actually call the three
--     blocker functions before deleting rows for their domains — a rollback
--     that only checks the rollback_safe flag but skips the dependency check
--     would silently destroy dependent data (e.g. deleting a term that
--     already has offerings against it).
--     Expect: one row, all three calls present + guarded by a raised
--     exception on any blocker.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%import_studio_term_blockers%')       as calls_term_blockers,
  (p.prosrc like '%import_studio_curriculum_blockers%')  as calls_curriculum_blockers,
  (p.prosrc like '%import_studio_offering_blockers%')    as calls_offering_blockers,
  (p.prosrc like '%rollback_blocked_by_dependency%')     as raises_on_blocker
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_rollback_batch';

-- ---------------------------------------------------------------------------
-- 66b. Any of those four signals missing is a hard failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname as rollback_missing_dependency_guard
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_import_studio_rollback_batch'
  and (
    p.prosrc not like '%import_studio_term_blockers%'
    or p.prosrc not like '%import_studio_curriculum_blockers%'
    or p.prosrc not like '%import_studio_offering_blockers%'
    or p.prosrc not like '%rollback_blocked_by_dependency%'
  );

-- ---------------------------------------------------------------------------
-- 67. The completion migration extends the TYPED, non-polymorphic match
--     invariant from sections 14/15 to the six new domains: five new typed
--     FK columns, one per domain (groups already had matched_group_id).
--     Expect: 5 rows, all real FKs.
-- ---------------------------------------------------------------------------
select
  col.column_name,
  exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'import_studio_rows'
      and con.contype = 'f'
      and pg_get_constraintdef(con.oid) like '%' || col.column_name || '%'
  ) as is_real_fk
from (
  values
    ('matched_curriculum_subject_id'), ('matched_term_id'),
    ('matched_offering_id'), ('matched_teacher_link_id'),
    ('matched_enrollment_id')
) as col(column_name)
order by col.column_name;

-- ---------------------------------------------------------------------------
-- 67b. A missing or non-FK typed match column is a hard failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select col.column_name as missing_or_untyped_match_column
from (
  values
    ('matched_curriculum_subject_id'), ('matched_term_id'),
    ('matched_offering_id'), ('matched_teacher_link_id'),
    ('matched_enrollment_id')
) as col(column_name)
where not exists (
  select 1 from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = 'import_studio_rows'
    and c.column_name = col.column_name
)
or not exists (
  select 1 from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  where c.relname = 'import_studio_rows'
    and con.contype = 'f'
    and pg_get_constraintdef(con.oid) like '%' || col.column_name || '%'
);

-- ---------------------------------------------------------------------------
-- 68. TERM SAFETY must keep holding for the newly-owned terms apply path: the
--     new terms helper itself must never FLIP is_current (the ban is "never
--     flip / never silently create Autumn 2026", enforced by validate_row +
--     the apply-time fingerprint tripwire from section 19/19b/19d, which
--     wraps ALL domains unconditionally — this pins that the new helper does
--     not try to route around it).
--
--     This is NOT a ban on the literal string 'is_current': the helper
--     legitimately writes `is_current = false` on every INSERT (new terms
--     and years are never current), and a blanket substring match on
--     'is_current' would false-positive on that (found: "security review
--     is_current false positive"). What is actually forbidden is (a) any
--     UPDATE statement whose SET clause touches is_current at all — an
--     update to an existing term should never change its current-ness —
--     and (b) is_current ever being set/compared to true anywhere in the
--     function body. Setting is_current to false in an INSERT's values
--     list remains allowed and expected.
--     Expect: one row, flips_is_current = false.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (
    p.prosrc ~* 'update\s+public\.academic_(terms|years)\y[^;]*\yset\y[^;]*\yis_current\y'
    or p.prosrc ~* '\yis_current\s*=\s*true\y'
    or p.prosrc ~* '\yis_current\s*,\s*true\y'
  ) as flips_is_current
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_apply_terms';

-- ---------------------------------------------------------------------------
-- 68b. The new terms helper flipping is_current (via UPDATE ... SET
--      is_current, or setting/comparing it to true anywhere) would be a
--      second, narrower path around the term-safety tripwire.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname as terms_helper_flips_is_current
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_apply_terms'
  and (
    p.prosrc ~* 'update\s+public\.academic_(terms|years)\y[^;]*\yset\y[^;]*\yis_current\y'
    or p.prosrc ~* '\yis_current\s*=\s*true\y'
    or p.prosrc ~* '\yis_current\s*,\s*true\y'
  );

-- ---------------------------------------------------------------------------
-- 69. Dry-run warnings (group_space team/chat creation, non-reversible
--     enrollment/teacher-transfer caveats) must reach the diff/confirm UI
--     through a dedicated, service_role-only helper — not silently dropped.
--     Expect: one row, service_role_only = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (
    has_function_privilege('service_role', p.oid, 'EXECUTE')
    and not has_function_privilege('anon', p.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) as service_role_only
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'import_studio_batch_warnings';

-- ---------------------------------------------------------------------------
-- 69b. Missing or client-executable warnings helper is a hard failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select 'import_studio_batch_warnings' as broken_warnings_helper
where not exists (
  select 1 from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname = 'import_studio_batch_warnings'
)
or exists (
  select 1 from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname = 'import_studio_batch_warnings'
    and (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    )
);

-- ---------------------------------------------------------------------------
-- 70. Excel templates for the six newly-owned domains must expose their ID
--     column first, so a re-import matches existing rows by ID rather than
--     creating silent duplicates by name-only matching.
--     Expect: 6 rows, all id_column_present = true.
-- ---------------------------------------------------------------------------
select
  t.domain,
  t.id_column,
  (
    select coalesce(array_position(private.import_studio_template(t.domain), t.id_column), 0)
  ) > 0 as id_column_present
from (
  values
    ('groups', 'group_id'),
    ('terms', 'term_id'),
    ('curriculum', 'curriculum_subject_id'),
    ('offerings', 'offering_id'),
    ('teacher_links', 'teacher_link_id'),
    ('enrollments', 'enrollment_id')
) as t(domain, id_column)
order by t.domain;

-- ---------------------------------------------------------------------------
-- 70b. Any domain whose template omits its ID column is a hard failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.domain as template_missing_id_column
from (
  values
    ('groups', 'group_id'),
    ('terms', 'term_id'),
    ('curriculum', 'curriculum_subject_id'),
    ('offerings', 'offering_id'),
    ('teacher_links', 'teacher_link_id'),
    ('enrollments', 'enrollment_id')
) as t(domain, id_column)
where coalesce(
  array_position(private.import_studio_template(t.domain), t.id_column), 0
) = 0;

-- ---------------------------------------------------------------------------
-- 0d. HARD GATE for Stage 19 completion. Raises on any violation. Read-only.
--     Supersedes the "validate-only terms/curriculum" and "not_implemented"
--     assumptions baked into hard gates 0 and 0b's domain-matrix checks,
--     which section 60/0d now correct for the intentional promotion.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
  v_all_domains text[] := array[
    'teachers', 'subjects', 'students', 'groups', 'curriculum', 'terms',
    'offerings', 'teacher_links', 'enrollments'
  ];
  v_new_helpers text[] := array[
    'import_studio_apply_groups', 'import_studio_apply_terms',
    'import_studio_apply_curriculum', 'import_studio_apply_offerings',
    'import_studio_apply_teacher_links', 'import_studio_apply_enrollments'
  ];
  v_blockers text[] := array[
    'import_studio_term_blockers', 'import_studio_curriculum_blockers',
    'import_studio_offering_blockers'
  ];
  v_match_cols text[] := array[
    'matched_curriculum_subject_id', 'matched_term_id', 'matched_offering_id',
    'matched_teacher_link_id', 'matched_enrollment_id'
  ];
  v_terms_prosrc text;
  v_terms_cols text;
  v_years_cols text;
begin
  -- 1) All nine domains must be apply now.
  select count(*) into v_bad
  from unnest(v_all_domains) as d(domain)
  where coalesce(private.import_studio_domain_state(d.domain), '') <> 'apply';
  if v_bad > 0 then
    raise exception 'stage19 completion FAIL: % domain(s) not promoted to apply', v_bad;
  end if;

  -- 2) Every new apply helper exists, is SECURITY DEFINER, pins search_path,
  --    and is service_role only.
  select count(*) into v_bad
  from unnest(v_new_helpers) as h(name)
  left join pg_proc p
    on p.proname = h.name and p.pronamespace = 'private'::regnamespace
  where p.oid is null
     or not p.prosecdef
     or p.proconfig is null
     or not exists (
       select 1 from unnest(p.proconfig) as cfg
       where replace(cfg, '"', '') = 'search_path='
     )
     or has_function_privilege('anon', p.oid, 'EXECUTE')
     or has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_bad > 0 then
    raise exception 'stage19 completion FAIL: % apply helper(s) missing/misconfigured', v_bad;
  end if;

  -- 3) The dispatcher must reference every one of those helpers by name.
  select count(*) into v_bad
  from unnest(v_new_helpers) as h(name)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_apply'
      and p.prosrc like '%' || h.name || '%'
  );
  if v_bad > 0 then
    raise exception 'stage19 completion FAIL: % apply helper(s) not dispatched', v_bad;
  end if;

  -- 4) Rollback-safe allow-list must be exactly these four domains.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_apply'
      and p.prosrc like
        '%domain in (''terms'', ''curriculum'', ''offerings'', ''teacher_links'')%'
  ) then
    raise exception
      'stage19 completion FAIL: rollback_safe allow-list is not exactly (terms, curriculum, offerings, teacher_links)';
  end if;

  -- 5) Rollback must gate on the persisted flag and call all three explicit
  --    dependency-blocker checks before deleting anything.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_import_studio_rollback_batch'
      and p.prosrc like '%not v_batch.rollback_safe%'
      and p.prosrc like '%import_studio_term_blockers%'
      and p.prosrc like '%import_studio_curriculum_blockers%'
      and p.prosrc like '%import_studio_offering_blockers%'
      and p.prosrc like '%rollback_blocked_by_dependency%'
  ) then
    raise exception
      'stage19 completion FAIL: rollback is missing the flag check or a dependency-blocker call';
  end if;

  -- 6) The three blocker functions must exist and stay service_role only.
  select count(*) into v_bad
  from unnest(v_blockers) as b(name)
  left join pg_proc p
    on p.proname = b.name and p.pronamespace = 'private'::regnamespace
  where p.oid is null
     or has_function_privilege('anon', p.oid, 'EXECUTE')
     or has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_bad > 0 then
    raise exception 'stage19 completion FAIL: % rollback blocker(s) missing/exposed', v_bad;
  end if;

  -- 7) Five new typed match FK columns, extending the anti-polymorphism
  --    invariant to the completion domains.
  select count(*) into v_bad
  from unnest(v_match_cols) as col(name)
  where not exists (
    select 1 from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'import_studio_rows'
      and c.column_name = col.name
  )
  or not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'import_studio_rows'
      and con.contype = 'f'
      and pg_get_constraintdef(con.oid) like '%' || col.name || '%'
  );
  if v_bad > 0 then
    raise exception 'stage19 completion FAIL: % new typed match column(s) missing or untyped', v_bad;
  end if;

  -- 8) The new terms apply helper must never FLIP is_current — term safety
  --    is enforced once, centrally, by the fingerprint tripwire (section 19),
  --    not re-implemented (and potentially bypassed) per helper. Not a ban
  --    on the literal string 'is_current': the helper legitimately inserts
  --    is_current = false for new terms/years (found: "security review
  --    is_current false positive"). Forbidden: an UPDATE that touches
  --    is_current at all, or is_current ever set/compared to true.
  --
  --    8a is the negative ban (unchanged). 8b/8c are a POSITIVE proof, not
  --    just the absence of a bad pattern (found: "weak is_current INSERT
  --    contract" — a ban-only check would also pass a helper that never
  --    assigned is_current at all, silently relying on a column default
  --    that could be flipped later without this check ever noticing).
  --    Every INSERT this helper makes into academic_terms / academic_years
  --    must (a) name is_current in its column list and (b) end its VALUES
  --    list with the literal `false` immediately before that statement's
  --    own terminator (`returning id into v_term_id` / `on conflict (name)`
  --    respectively) — proving the helper writes false, not merely that it
  --    avoids writing true.
  select p.prosrc into v_terms_prosrc
  from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname = 'import_studio_apply_terms';

  if v_terms_prosrc is null then
    raise exception 'stage19 completion FAIL: import_studio_apply_terms not found';
  end if;

  -- 8a. Negative ban: no UPDATE ever touches is_current, and it is never
  --     set/compared to true.
  -- NB: word-boundary matches in PostgreSQL ARE regexes use \y, not the
  -- PCRE-style \b (found: "\b silently never matches in PG regex" — \b is
  -- not a boundary escape here, so a \b-based ban would trivially always
  -- pass regardless of content; verified live against this helper's prosrc).
  if v_terms_prosrc ~* 'update\s+public\.academic_(terms|years)\y[^;]*\yset\y[^;]*\yis_current\y'
    or v_terms_prosrc ~* '\yis_current\s*=\s*true\y'
    or v_terms_prosrc ~* '\yis_current\s*,\s*true\y'
  then
    raise exception
      'stage19 completion FAIL: the terms apply helper flips is_current (UPDATE touching it, or setting it true)';
  end if;

  -- 8b. Positive proof for the academic_terms INSERT: is_current named in
  --     the column list, and `false` is the last value before `returning
  --     id into v_term_id`. The column-list capture is safe with a
  --     no-nested-parens character class because a plain column list (only
  --     identifiers and commas) can never contain '(' or ')'; the VALUES
  --     list is not captured the same way because it legitimately contains
  --     nested parens (casts, ->>), so it is asserted positionally instead.
  v_terms_cols := substring(
    v_terms_prosrc from 'insert\s+into\s+public\.academic_terms\s*\(([^()]*)\)'
  );
  if v_terms_cols is null or v_terms_cols !~* '\yis_current\y' then
    raise exception
      'stage19 completion FAIL: academic_terms INSERT does not name is_current in its column list';
  end if;
  if v_terms_prosrc !~* ',\s*false\s*\)\s*returning\s+id\s+into\s+v_term_id' then
    raise exception
      'stage19 completion FAIL: academic_terms INSERT does not assign is_current = false as its last value';
  end if;

  -- 8c. Same positive proof for the academic_years INSERT this helper
  --     performs when it also needs a brand-new academic year.
  v_years_cols := substring(
    v_terms_prosrc from 'insert\s+into\s+public\.academic_years\s*\(([^()]*)\)'
  );
  if v_years_cols is null or v_years_cols !~* '\yis_current\y' then
    raise exception
      'stage19 completion FAIL: academic_years INSERT does not name is_current in its column list';
  end if;
  if v_terms_prosrc !~* ',\s*false\s*\)\s*on\s+conflict\s*\(\s*name\s*\)' then
    raise exception
      'stage19 completion FAIL: academic_years INSERT does not assign is_current = false as its last value';
  end if;

  -- 9) Warnings helper must exist and stay service_role only.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'import_studio_batch_warnings'
      and not has_function_privilege('anon', p.oid, 'EXECUTE')
      and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) then
    raise exception
      'stage19 completion FAIL: batch_warnings helper missing or client-executable';
  end if;

  -- 10) Every new domain's template must expose its ID column so re-import
  --     matches by ID first and never silently duplicates by name.
  select count(*) into v_bad
  from (
    values
      ('groups', 'group_id'), ('terms', 'term_id'),
      ('curriculum', 'curriculum_subject_id'), ('offerings', 'offering_id'),
      ('teacher_links', 'teacher_link_id'), ('enrollments', 'enrollment_id')
  ) as t(domain, id_column)
  where coalesce(
    array_position(private.import_studio_template(t.domain), t.id_column), 0
  ) = 0;
  if v_bad > 0 then
    raise exception 'stage19 completion FAIL: % domain template(s) missing their ID column', v_bad;
  end if;

  raise notice 'stage19 completion assertions: PASS';
end $$;
