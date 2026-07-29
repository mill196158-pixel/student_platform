-- Stage 18 — reviews moderation + student points security review.
--
-- Static, read-only checks to run AFTER applying
-- 20260729152000_stage18_reviews_points_moderation.sql. Each query should
-- return zero offending rows (or the expected shape noted above it). Nothing
-- here mutates data. Do not run before the migration is applied.
--
-- Stage 18 EXTENDS the Stage 13.6 entity_reviews system; several checks below
-- exist specifically to prove no second reviews system was introduced.
--
-- Section 0 at the very bottom re-asserts the critical invariants as a hard
-- gate, so the whole file can be run with ON_ERROR_STOP=1 as a pass/fail step.

-- ---------------------------------------------------------------------------
-- 1. The new ledger table has RLS enabled AND forced. entity_reviews keeps its
--    Stage 13.6 posture and is listed here for visibility.
--    Expect: 2 rows, rls_enabled = true (ledger also rls_forced = true).
-- ---------------------------------------------------------------------------
select
  c.relname             as table_name,
  c.relrowsecurity      as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('student_points_ledger', 'entity_reviews')
order by c.relname;

-- ---------------------------------------------------------------------------
-- 1b. student_points_ledger must exist with RLS enabled AND forced.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  'student_points_ledger'                as table_name,
  (c.oid is not null)                    as table_exists,
  coalesce(c.relrowsecurity, false)      as rls_enabled,
  coalesce(c.relforcerowsecurity, false) as rls_forced
from (select 1) as _
left join pg_class c
  on c.relname = 'student_points_ledger'
 and c.relnamespace = 'public'::regnamespace
where c.oid is null
   or not c.relrowsecurity
   or not c.relforcerowsecurity;

-- ---------------------------------------------------------------------------
-- 2. public / anon / authenticated must NOT hold direct DML on the ledger.
--    A client-side INSERT here would be free points.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'student_points_ledger'
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
order by grantee, privilege_type;

-- ---------------------------------------------------------------------------
-- 3. service_role holds the ledger DML instead.
--    Expect: SELECT/INSERT/UPDATE/DELETE.
-- ---------------------------------------------------------------------------
select
  table_name,
  string_agg(distinct privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'student_points_ledger'
  and grantee = 'service_role'
group by table_name;

-- ---------------------------------------------------------------------------
-- 4. No RLS policy may expose the ledger to anon / authenticated.
--    Expect: zero rows (reads go through get_my_points_summary).
-- ---------------------------------------------------------------------------
select
  pol.polname as policy_name,
  pol.polcmd  as command,
  pg_get_expr(pol.polqual, pol.polrelid) as using_expr
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'student_points_ledger'
order by pol.polname;

-- ---------------------------------------------------------------------------
-- 5. anon must NOT be able to EXECUTE any Stage 18 RPC.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  'anon'    as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_moderate_review_v2', 'admin_resolve_review_report',
    'admin_list_unified_moderation_queue', 'admin_moderation_action',
    'admin_list_student_points',
    'submit_my_entity_review', 'get_my_points_summary'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 6. authenticated SHOULD be able to execute the Stage 18 RPCs (RBAC is
--    checked inside the function body, not by the grant).
--    Expect: 7 rows, can_execute = true.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_moderate_review_v2', 'admin_resolve_review_report',
    'admin_list_unified_moderation_queue', 'admin_moderation_action',
    'admin_list_student_points',
    'submit_my_entity_review', 'get_my_points_summary'
  )
order by p.proname;

-- ---------------------------------------------------------------------------
-- 7. private Stage 18 helpers must NOT be executable by anon / authenticated.
--    student_points_record in particular mints points.
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
    'student_points_record', 'student_points_balance',
    'entity_review_assert_not_own', 'entity_reviews_moderation_gate'
  )
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
order by p.proname, r.rolname;

-- ---------------------------------------------------------------------------
-- 8. Every Stage 18 public RPC is SECURITY DEFINER with search_path = ''.
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
    'admin_moderate_review_v2', 'admin_resolve_review_report',
    'admin_list_unified_moderation_queue', 'admin_moderation_action',
    'admin_list_student_points',
    'submit_my_entity_review', 'get_my_points_summary'
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
-- 9. Every private Stage 18 helper also pins search_path = ''.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname   as function_name,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and (p.proname like 'student\_points\_%' or p.proname like 'entity\_review%')
  and (
    p.proconfig is null
    or not exists (
      select 1 from unnest(p.proconfig) as cfg
      where replace(cfg, '"', '') = 'search_path='
    )
  );

-- ---------------------------------------------------------------------------
-- 10. Full Stage 18 RPC inventory must exist. Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('admin_moderate_review_v2'),
    ('admin_resolve_review_report'),
    ('admin_list_unified_moderation_queue'),
    ('admin_moderation_action'),
    ('admin_list_student_points'),
    ('submit_my_entity_review'),
    ('get_my_points_summary')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

-- ---------------------------------------------------------------------------
-- 11. NO SECOND REVIEWS SYSTEM: Stage 18 extends the Stage 13.6 tables and
--     must not introduce a parallel one. The allowlist below is exactly the
--     Stage 13.6 set (entity_reviews, review_reports, review_moderation_actions,
--     review_tags); anything else means a second system appeared.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select c.relname as unexpected_reviews_table
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
  and (c.relname like '%review%')
  and c.relname not in (
    'entity_reviews', 'review_reports',
    'review_moderation_actions', 'review_tags'
  );

-- ---------------------------------------------------------------------------
-- 12. entity_reviews gained the moderation columns.
--     Expect: 4 rows (moderation_status, moderation_reason, moderated_by,
--     moderated_at).
-- ---------------------------------------------------------------------------
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'entity_reviews'
  and column_name in (
    'moderation_status', 'moderation_reason', 'moderated_by', 'moderated_at'
  )
order by column_name;

-- ---------------------------------------------------------------------------
-- 12b. Any of the four moderation columns missing is a failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.column_name as missing_column
from (
  values ('moderation_status'), ('moderation_reason'),
         ('moderated_by'), ('moderated_at')
) as t(column_name)
where not exists (
  select 1 from information_schema.columns col
  where col.table_schema = 'public'
    and col.table_name = 'entity_reviews'
    and col.column_name = t.column_name
);

-- ---------------------------------------------------------------------------
-- 13. moderation_status must be constrained to draft|pending|approved|rejected.
--     Expect: one row containing all four.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'entity_reviews'
  and con.conname = 'entity_reviews_moderation_status_check';

-- ---------------------------------------------------------------------------
-- 13b. Each of the four states must be present. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.state as missing_state
from (values ('draft'), ('pending'), ('approved'), ('rejected')) as t(state)
where not exists (
  select 1 from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  where c.relname = 'entity_reviews'
    and con.conname = 'entity_reviews_moderation_status_check'
    and pg_get_constraintdef(con.oid) like '%''' || t.state || '''%'
);

-- ---------------------------------------------------------------------------
-- 14. No existing review may have been left with a NULL / unknown
--     moderation_status by the backfill. Expect: zero rows.
-- ---------------------------------------------------------------------------
select id, status, moderation_status
from public.entity_reviews
where moderation_status is null
   or moderation_status not in ('draft', 'pending', 'approved', 'rejected')
limit 20;

-- ---------------------------------------------------------------------------
-- 15. student_points_ledger must carry the owner-specified shape:
--     id, user_id, review_id, delta, reason_code, meta, created_at.
--     Expect: 7 rows.
-- ---------------------------------------------------------------------------
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'student_points_ledger'
  and column_name in (
    'id', 'user_id', 'review_id', 'delta', 'reason_code', 'meta', 'created_at'
  )
order by column_name;

-- ---------------------------------------------------------------------------
-- 15b. Any of those seven columns missing is a failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.column_name as missing_column
from (
  values ('id'), ('user_id'), ('review_id'), ('delta'),
         ('reason_code'), ('meta'), ('created_at')
) as t(column_name)
where not exists (
  select 1 from information_schema.columns col
  where col.table_schema = 'public'
    and col.table_name = 'student_points_ledger'
    and col.column_name = t.column_name
);

-- ---------------------------------------------------------------------------
-- 15c. review_id must be NULLABLE (non-review point sources stay possible).
--      Expect: one row with is_nullable = YES.
-- ---------------------------------------------------------------------------
select column_name, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'student_points_ledger'
  and column_name = 'review_id';

-- ---------------------------------------------------------------------------
-- 16. ONE CREDIT PER REVIEW: a partial unique index must make a second
--     `review_approved` credit for the same review_id impossible.
--     Expect: at least one unique index on (review_id, reason_code)
--     or equivalent.
-- ---------------------------------------------------------------------------
select
  i.relname as index_name,
  pg_get_indexdef(i.oid) as definition
from pg_index x
join pg_class c on c.oid = x.indrelid
join pg_class i on i.oid = x.indexrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'student_points_ledger'
  and x.indisunique
order by i.relname;

-- ---------------------------------------------------------------------------
-- 16b. The unique credit guard must exist and mention review_id.
--      Expect: at least one row.
-- ---------------------------------------------------------------------------
select i.relname as index_name
from pg_index x
join pg_class c on c.oid = x.indrelid
join pg_class i on i.oid = x.indexrelid
where c.relnamespace = 'public'::regnamespace
  and c.relname = 'student_points_ledger'
  and x.indisunique
  and pg_get_indexdef(i.oid) ilike '%review_id%';

-- ---------------------------------------------------------------------------
-- 17. Ledger integrity constraints: delta must be non-zero and bounded, and
--     meta must be a JSON object.
--     Expect: rows for delta_nonzero, delta_range, meta_object, review_sign.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'student_points_ledger'
  and con.contype = 'c'
order by con.conname;

-- ---------------------------------------------------------------------------
-- 18. Ledger rows must FK to users and (optionally) entity_reviews so a
--     deleted review cannot orphan a credit silently.
--     Expect: FK rows.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'student_points_ledger'
  and con.contype = 'f'
order by con.conname;

-- ---------------------------------------------------------------------------
-- 19. Self-moderation guard: both the canonical Stage 18 RPC and the patched
--     Stage 13.6 RPC must call the not-own assertion.
--     Expect: 2 rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_moderate_review_v2', 'admin_moderate_review')
  and p.prosrc like '%entity_review_assert_not_own%'
order by p.proname;

-- ---------------------------------------------------------------------------
-- 19b. Either RPC missing the guard is a failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.proname as rpc_without_self_moderation_guard
from (values ('admin_moderate_review_v2'), ('admin_moderate_review')) as t(proname)
where not exists (
  select 1 from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = t.proname
    and p.prosrc like '%entity_review_assert_not_own%'
);

-- ---------------------------------------------------------------------------
-- 20. The moderation gate trigger must be attached to entity_reviews so a
--     pending review can never be left publicly visible.
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
  and c.relname = 'entity_reviews'
  and p.proname = 'entity_reviews_moderation_gate';

-- ---------------------------------------------------------------------------
-- 21. The moderation requirement is feature-flagged so Stage 13.6 behaviour
--     stays the default until the owner flips it.
--     Expect: one row, key = reviews.moderation_required.
-- ---------------------------------------------------------------------------
select key, enabled, description
from public.app_feature_flags
where key = 'reviews.moderation_required';

-- ---------------------------------------------------------------------------
-- 22. UNIFIED QUEUE COVERAGE: the queue RPC must span reviews, vacancies,
--     reports and content_corrections. Expect: 5 rows, covered = true.
-- ---------------------------------------------------------------------------
select
  d.domain,
  (p.prosrc like '%' || d.domain || '%') as covered
from (
  values ('review'), ('review_report'), ('vacancy'),
         ('vacancy_report'), ('content_correction')
) as d(domain)
cross join pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname = 'admin_list_unified_moderation_queue'
order by d.domain;

-- ---------------------------------------------------------------------------
-- 22b. Any uncovered domain is a failure. Expect: zero rows.
-- ---------------------------------------------------------------------------
select d.domain as uncovered_domain
from (
  values ('review'), ('review_report'), ('vacancy'),
         ('vacancy_report'), ('content_correction')
) as d(domain)
where not exists (
  select 1 from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'admin_list_unified_moderation_queue'
    and p.prosrc like '%' || d.domain || '%'
);

-- ---------------------------------------------------------------------------
-- 23. The queue RPC must accept filter parameters (domains / status / limit).
--     Expect: one row showing the argument list.
-- ---------------------------------------------------------------------------
select p.proname, pg_get_function_arguments(p.oid) as args
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname = 'admin_list_unified_moderation_queue';

-- ---------------------------------------------------------------------------
-- 24. Audit coverage for every domain the unified queue can act on.
--
--     Some handlers call private.admin_write_audit directly; the vacancy ones
--     reach it through private.vacancy_record_action ->
--     private.content_write_domain_audit -> private.admin_write_audit, which
--     also lands a row in the domain actions table. Check 24c below proves
--     those helpers really do reach admin_write_audit, so the indirection is
--     verified rather than assumed.
--
--     public.admin_moderation_action is deliberately excluded: it is a pure
--     dispatcher that returns the delegate's result, and auditing there too
--     would double-log every moderation action.
--
--     Expect: 5 rows, audited = true.
-- ---------------------------------------------------------------------------
select
  t.proname,
  (
    p.prosrc like '%admin_write_audit%'
    or p.prosrc like '%vacancy_record_action%'
    or p.prosrc like '%content_write_domain_audit%'
  ) as audited
from (
  values ('admin_moderate_review_v2'), ('admin_resolve_review_report'),
         ('admin_moderate_vacancy'), ('admin_resolve_vacancy_report'),
         ('admin_resolve_content_correction')
) as t(proname)
join pg_proc p
  on p.pronamespace = 'public'::regnamespace and p.proname = t.proname
order by t.proname;

-- ---------------------------------------------------------------------------
-- 24b. Any queue-reachable handler with no audit path is a failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.proname as rpc_without_audit
from (
  values ('admin_moderate_review_v2'), ('admin_resolve_review_report'),
         ('admin_moderate_vacancy'), ('admin_resolve_vacancy_report'),
         ('admin_resolve_content_correction')
) as t(proname)
where not exists (
  select 1 from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = t.proname
    and (
      p.prosrc like '%admin_write_audit%'
      or p.prosrc like '%vacancy_record_action%'
      or p.prosrc like '%content_write_domain_audit%'
    )
);

-- ---------------------------------------------------------------------------
-- 24c. The indirect audit helpers must actually reach admin_write_audit,
--      otherwise 24/24b would pass on a broken chain. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.proname as helper_not_reaching_admin_write_audit
from (values ('content_write_domain_audit'), ('vacancy_record_action')) as t(proname)
where not exists (
  select 1 from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname = t.proname
    and (
      p.prosrc like '%admin_write_audit%'
      or p.prosrc like '%content_write_domain_audit%'
    )
);

-- ---------------------------------------------------------------------------
-- 24d. The dispatcher must route to all five handlers, so no domain can be
--      acted on without hitting an audited path. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.handler as handler_not_reachable_from_dispatcher
from (
  values ('admin_moderate_review_v2'), ('admin_resolve_review_report'),
         ('admin_moderate_vacancy'), ('admin_resolve_vacancy_report'),
         ('admin_resolve_content_correction')
) as t(handler)
where not exists (
  select 1 from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'admin_moderation_action'
    and p.prosrc like '%' || t.handler || '%'
);

-- ---------------------------------------------------------------------------
-- 0. HARD GATE — re-assert the critical invariants. Raises on any violation.
--    Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
  v_rpcs text[] := array[
    'admin_moderate_review_v2', 'admin_resolve_review_report',
    'admin_list_unified_moderation_queue', 'admin_moderation_action',
    'admin_list_student_points',
    'submit_my_entity_review', 'get_my_points_summary'
  ];
begin
  if not exists (
    select 1 from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relname = 'student_points_ledger'
      and c.relrowsecurity
      and c.relforcerowsecurity
  ) then
    raise exception 'stage18 FAIL: student_points_ledger missing or without FORCE RLS';
  end if;

  select count(*) into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'student_points_ledger'
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % client grant(s) on student_points_ledger', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(v_rpcs) as r(name)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = r.name
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % RPC(s) missing', v_bad;
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
    raise exception 'stage18 FAIL: % RPC(s) not SECURITY DEFINER with search_path=''''', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = any (v_rpcs)
    and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad > 0 then
    raise exception 'stage18 FAIL: anon can execute % Stage 18 RPC(s)', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname in (
      'student_points_record', 'student_points_balance',
      'entity_review_assert_not_own', 'entity_reviews_moderation_gate'
    )
    and (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % private points/review helper(s) client-executable', v_bad;
  end if;

  -- No second reviews system: only the Stage 13.6 tables may exist.
  select count(*) into v_bad
  from pg_class c
  where c.relnamespace = 'public'::regnamespace
    and c.relkind = 'r'
    and c.relname like '%review%'
    and c.relname not in (
      'entity_reviews', 'review_reports',
      'review_moderation_actions', 'review_tags'
    );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % unexpected reviews table(s) created', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(array['moderation_status', 'moderation_reason',
                    'moderated_by', 'moderated_at']) as t(col)
  where not exists (
    select 1 from information_schema.columns col
    where col.table_schema = 'public'
      and col.table_name = 'entity_reviews'
      and col.column_name = t.col
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % moderation column(s) missing on entity_reviews', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(array['draft', 'pending', 'approved', 'rejected']) as t(state)
  where not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'entity_reviews'
      and con.conname = 'entity_reviews_moderation_status_check'
      and pg_get_constraintdef(con.oid) like '%''' || t.state || '''%'
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % moderation state(s) missing from the constraint', v_bad;
  end if;

  select count(*) into v_bad
  from public.entity_reviews
  where moderation_status is null
     or moderation_status not in ('draft', 'pending', 'approved', 'rejected');
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % existing review(s) left with a bad moderation_status', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(array['id', 'user_id', 'review_id', 'delta',
                    'reason_code', 'meta', 'created_at']) as t(col)
  where not exists (
    select 1 from information_schema.columns col
    where col.table_schema = 'public'
      and col.table_name = 'student_points_ledger'
      and col.column_name = t.col
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % ledger column(s) missing', v_bad;
  end if;

  if not exists (
    select 1 from information_schema.columns col
    where col.table_schema = 'public'
      and col.table_name = 'student_points_ledger'
      and col.column_name = 'review_id'
      and col.is_nullable = 'YES'
  ) then
    raise exception 'stage18 FAIL: student_points_ledger.review_id is not nullable';
  end if;

  -- One credit per review must be enforced by a unique index, not by code.
  if not exists (
    select 1
    from pg_index x
    join pg_class c on c.oid = x.indrelid
    join pg_class i on i.oid = x.indexrelid
    where c.relnamespace = 'public'::regnamespace
      and c.relname = 'student_points_ledger'
      and x.indisunique
      and pg_get_indexdef(i.oid) ilike '%review_id%'
  ) then
    raise exception 'stage18 FAIL: no unique index guarding one credit per review_id';
  end if;

  select count(*) into v_bad
  from unnest(array['admin_moderate_review_v2', 'admin_moderate_review']) as t(proname)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = t.proname
      and p.prosrc like '%entity_review_assert_not_own%'
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % review moderation RPC(s) missing the self-moderation guard', v_bad;
  end if;

  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
    where c.relnamespace = 'public'::regnamespace
      and not t.tgisinternal
      and c.relname = 'entity_reviews'
      and p.proname = 'entity_reviews_moderation_gate'
  ) then
    raise exception 'stage18 FAIL: entity_reviews moderation gate trigger missing';
  end if;

  if not exists (
    select 1 from public.app_feature_flags
    where key = 'reviews.moderation_required'
  ) then
    raise exception 'stage18 FAIL: reviews.moderation_required feature flag missing';
  end if;

  select count(*) into v_bad
  from unnest(array['review', 'review_report', 'vacancy',
                    'vacancy_report', 'content_correction']) as d(domain)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_list_unified_moderation_queue'
      and p.prosrc like '%' || d.domain || '%'
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % domain(s) missing from the unified queue', v_bad;
  end if;

  -- Every domain the dispatcher can act on must land an admin audit record,
  -- either directly or through the verified helper chain (see 24c).
  select count(*) into v_bad
  from unnest(array['admin_moderate_review_v2', 'admin_resolve_review_report',
                    'admin_moderate_vacancy', 'admin_resolve_vacancy_report',
                    'admin_resolve_content_correction']) as t(proname)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = t.proname
      and (
        p.prosrc like '%admin_write_audit%'
        or p.prosrc like '%vacancy_record_action%'
        or p.prosrc like '%content_write_domain_audit%'
      )
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % moderation handler(s) without an audit write', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(array['content_write_domain_audit', 'vacancy_record_action']) as t(proname)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = t.proname
      and (
        p.prosrc like '%admin_write_audit%'
        or p.prosrc like '%content_write_domain_audit%'
      )
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % audit helper(s) do not reach admin_write_audit', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(array['admin_moderate_review_v2', 'admin_resolve_review_report',
                    'admin_moderate_vacancy', 'admin_resolve_vacancy_report',
                    'admin_resolve_content_correction']) as t(handler)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_moderation_action'
      and p.prosrc like '%' || t.handler || '%'
  );
  if v_bad > 0 then
    raise exception 'stage18 FAIL: % handler(s) unreachable from the dispatcher', v_bad;
  end if;

  raise notice 'stage18 security review: PASS';
end $$;

-- ===========================================================================
-- P1 REWORK ASSERTIONS (Codex REJECT round 1)
--
-- Pins the five points/moderation P1s. Read-only.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 30. The trail vocabulary must contain a REAL approval code, so an approval is
--     never disguised as `restore`. Expect: one row with approve + reject +
--     remove_violation, and the legacy hide/restore still present.
-- ---------------------------------------------------------------------------
select
  con.conname,
  pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'review_moderation_actions'
  and con.contype = 'c'
  and pg_get_constraintdef(con.oid) like '%approve%'
  and pg_get_constraintdef(con.oid) like '%reject%'
  and pg_get_constraintdef(con.oid) like '%remove_violation%';

-- ---------------------------------------------------------------------------
-- 31. Stage 18 moderation must record `approve` and must not relabel an
--     approval as `restore`. Expect: one row, records_approve = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%''approve''%') as records_approve
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'review_moderate_apply';

-- ---------------------------------------------------------------------------
-- 32. Both moderation entry points must share ONE core, so the legacy Stage
--     13.6 RPC cannot bypass points compensation.
--     Expect: 2 rows, delegates = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%review_moderate_apply%') as delegates
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_moderate_review', 'admin_moderate_review_v2')
order by p.proname;

-- ---------------------------------------------------------------------------
-- 32b. Neither entry point may write entity_reviews moderation state itself.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname as writes_directly
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_moderate_review', 'admin_moderate_review_v2')
  and p.prosrc ilike '%update public.entity_reviews%';

-- ---------------------------------------------------------------------------
-- 33. RE-CREDIT AFTER COMPENSATION: uniqueness must be per credit CYCLE, not
--     per (review_id, reason_code), otherwise a restored review can never be
--     credited again. Expect: the cycle index present, the old one gone.
-- ---------------------------------------------------------------------------
select
  i.relname as index_name,
  pg_get_indexdef(i.oid) as definition
from pg_class i
join pg_index x on x.indexrelid = i.oid
join pg_class c on c.oid = x.indrelid
where c.relname = 'student_points_ledger'
  and x.indisunique
order by i.relname;

-- ---------------------------------------------------------------------------
-- 33b. The pre-rework index must NOT exist any more. Expect: zero rows.
-- ---------------------------------------------------------------------------
select i.relname as stale_index
from pg_class i
where i.relname = 'student_points_ledger_review_reason_uidx';

-- ---------------------------------------------------------------------------
-- 33c. cycle_number must exist, be NOT NULL and >= 1. Expect: one row.
-- ---------------------------------------------------------------------------
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'student_points_ledger'
  and column_name = 'cycle_number';

-- ---------------------------------------------------------------------------
-- 33d. The sign model must be enforced: +1 only for a credit, -1 only for a
--      revocation. Expect: one row.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'student_points_ledger'
  and con.conname = 'student_points_ledger_review_sign';

-- ---------------------------------------------------------------------------
-- 34. Points must be written by ONE trigger-backed path, so an auto-approved
--     insert (moderation flag OFF) is credited too. Expect: one AFTER trigger
--     on insert or update.
-- ---------------------------------------------------------------------------
select
  t.tgname,
  pg_get_triggerdef(t.oid) as definition
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
where c.relname = 'entity_reviews'
  and not t.tgisinternal
  and t.tgname = 'trg_entity_reviews_points_sync';

-- ---------------------------------------------------------------------------
-- 34b. That trigger must be AFTER (not BEFORE): a BEFORE trigger would credit
--      a row that may still fail. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.tgname
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
where c.relname = 'entity_reviews'
  and t.tgname = 'trg_entity_reviews_points_sync'
  and pg_get_triggerdef(t.oid) not ilike '%after insert or update%';

-- ---------------------------------------------------------------------------
-- 35. Idempotent backfill for legacy auto-approved reviews must exist and must
--     reuse the same sync core. Expect: one row, reuses_core = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%review_points_sync_one%') as reuses_core,
  (p.prosrc like '%outstanding%')            as skips_already_credited
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_backfill_review_points';

-- ---------------------------------------------------------------------------
-- 36. REJECTED -> RESUBMIT -> PENDING: the author edit path must send the
--     review back to pending AND clear the stale rejection reason, instead of
--     leaving it rejected. Expect: one row, all three true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%''pending''%')            as returns_to_pending,
  (p.prosrc like '%moderation_reason = null%') as clears_rejection_reason,
  (p.prosrc like '%''removed''%')            as excludes_terminal_removal
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'submit_my_entity_review';

-- ---------------------------------------------------------------------------
-- 36b. The moderation gate trigger must also re-open an edited approved or
--      rejected review. Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'entity_reviews_moderation_gate'
  and p.prosrc like '%rejected%'
  and p.prosrc like '%pending%';

-- ---------------------------------------------------------------------------
-- 0b. HARD GATE for the P1 rework. Raises on any violation. Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  -- 1) Real approval action code.
  if not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'review_moderation_actions'
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) like '%approve%'
      and pg_get_constraintdef(con.oid) like '%reject%'
      and pg_get_constraintdef(con.oid) like '%remove_violation%'
  ) then
    raise exception
      'stage18 P1 FAIL: review_moderation_actions cannot record approve/reject/remove_violation';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'review_moderate_apply'
      and p.prosrc like '%''approve''%'
  ) then
    raise exception 'stage18 P1 FAIL: approval is not recorded as approve';
  end if;

  -- 2) Legacy RPC must not bypass the points-aware core.
  select count(*) into v_bad
  from (values ('admin_moderate_review'), ('admin_moderate_review_v2')) as r(proname)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = r.proname
      and p.prosrc like '%review_moderate_apply%'
  );
  if v_bad > 0 then
    raise exception
      'stage18 P1 FAIL: % moderation entry point(s) do not delegate to the shared core', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in ('admin_moderate_review', 'admin_moderate_review_v2')
    and p.prosrc ilike '%update public.entity_reviews%';
  if v_bad > 0 then
    raise exception
      'stage18 P1 FAIL: % moderation entry point(s) write review state directly', v_bad;
  end if;

  -- 3) Re-credit after compensation must be representable.
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'student_points_ledger'
      and column_name = 'cycle_number'
      and is_nullable = 'NO'
  ) then
    raise exception 'stage18 P1 FAIL: student_points_ledger.cycle_number missing';
  end if;

  if exists (
    select 1 from pg_class i
    where i.relname = 'student_points_ledger_review_reason_uidx'
  ) then
    raise exception
      'stage18 P1 FAIL: stale (review_id, reason_code) unique index blocks a re-credit';
  end if;

  if not exists (
    select 1
    from pg_class i
    join pg_index x on x.indexrelid = i.oid
    join pg_class c on c.oid = x.indrelid
    where c.relname = 'student_points_ledger'
      and x.indisunique
      and pg_get_indexdef(i.oid) like '%cycle_number%'
  ) then
    raise exception 'stage18 P1 FAIL: no per-cycle unique index on student_points_ledger';
  end if;

  if not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'student_points_ledger'
      and con.conname = 'student_points_ledger_review_sign'
  ) then
    raise exception 'stage18 P1 FAIL: credit/revocation sign is not constrained';
  end if;

  -- 4) One trigger-backed points path, AFTER insert or update.
  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    where c.relname = 'entity_reviews'
      and t.tgname = 'trg_entity_reviews_points_sync'
      and pg_get_triggerdef(t.oid) ilike '%after insert or update%'
  ) then
    raise exception
      'stage18 P1 FAIL: points are not synced by an AFTER INSERT OR UPDATE trigger';
  end if;

  -- 5) Idempotent backfill exists and reuses the core.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_backfill_review_points'
      and p.prosrc like '%review_points_sync_one%'
  ) then
    raise exception 'stage18 P1 FAIL: no idempotent review points backfill';
  end if;

  if has_function_privilege('anon', 'public.admin_backfill_review_points(integer)', 'EXECUTE') then
    raise exception 'stage18 P1 FAIL: anon can execute admin_backfill_review_points';
  end if;

  -- 6) rejected -> resubmit -> pending.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'submit_my_entity_review'
      and p.prosrc like '%''pending''%'
      and p.prosrc like '%moderation_reason = null%'
  ) then
    raise exception
      'stage18 P1 FAIL: rejected reviews cannot be resubmitted back to pending';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'entity_reviews_moderation_gate'
      and p.prosrc like '%rejected%'
      and p.prosrc like '%pending%'
  ) then
    raise exception
      'stage18 P1 FAIL: the moderation gate does not re-open an edited rejected review';
  end if;

  raise notice 'stage18 P1 rework assertions: PASS';
end $$;

-- ===========================================================================
-- P1 HARDENING ASSERTIONS (Codex round 2)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 37. Audit-writing list RPCs must be VOLATILE, not STABLE.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname, p.provolatile
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in (
    'admin_list_student_points', 'admin_list_unified_moderation_queue'
  )
  and p.provolatile = 's';

-- ---------------------------------------------------------------------------
-- 38. Stage 18 contract: moderation_required must be ON after hardening.
--     Expect: one row, enabled = true.
-- ---------------------------------------------------------------------------
select key, enabled
from public.app_feature_flags
where key = 'reviews.moderation_required';

-- ---------------------------------------------------------------------------
-- 39. Unified queue must expose moderator-only author fields in its JSON.
--     Expect: one row, all three present in source.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%author_user_id%') as has_author_id,
  (p.prosrc like '%author_label%') as has_author_label,
  (p.prosrc like '%assignee_user_id%') as has_assignee
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname = 'admin_list_unified_moderation_queue';

-- ---------------------------------------------------------------------------
-- 40. Mobile my-reviews RPC exists and is auth-gated.
--     Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname, pg_get_function_arguments(p.oid) as args
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname = 'get_my_entity_reviews';

-- ---------------------------------------------------------------------------
-- 41. Review moderation history RPC exists (parity with vacancies).
--     Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname = 'admin_list_review_moderation_actions';

-- ---------------------------------------------------------------------------
-- 0c. HARD GATE for P1 hardening. Raises on any violation. Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in (
      'admin_list_student_points', 'admin_list_unified_moderation_queue'
    )
    and p.provolatile = 's';
  if v_bad > 0 then
    raise exception
      'stage18 P1 hardening FAIL: % audit-writing list RPC(s) still STABLE', v_bad;
  end if;

  if not exists (
    select 1 from public.app_feature_flags
    where key = 'reviews.moderation_required' and enabled = true
  ) then
    raise exception
      'stage18 P1 hardening FAIL: reviews.moderation_required is not enabled';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_list_unified_moderation_queue'
      and p.prosrc like '%author_label%'
      and p.prosrc like '%assignee_user_id%'
  ) then
    raise exception
      'stage18 P1 hardening FAIL: unified queue missing moderator author fields';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_my_entity_reviews'
      and p.prosrc like '%moderation_reason%'
  ) then
    raise exception
      'stage18 P1 hardening FAIL: get_my_entity_reviews omits moderation_reason';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_list_review_moderation_actions'
  ) then
    raise exception
      'stage18 P1 hardening FAIL: admin_list_review_moderation_actions missing';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_my_vacancy_submissions'
      and p.prosrc like '%rejection_reason%'
  ) then
    raise exception
      'stage18 P1 r4 FAIL: get_my_vacancy_submissions missing rejection_reason';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'update_my_vacancy_draft'
      and p.prosrc like '%expected_version_required%'
      and p.prosrc like '%is distinct from p_expected_row_version%'
  ) or not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'resubmit_my_vacancy'
      and p.prosrc like '%expected_version_required%'
      and p.prosrc like '%is distinct from p_expected_row_version%'
  ) then
    raise exception
      'stage18 P1 r4 FAIL: author vacancy draft/resubmit missing NULL row_version guard';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_moderate_vacancy'
      and p.prosrc like '%request_clarification%'
      and p.prosrc like
        '%when v_action in (''reject'', ''request_clarification'') then v_reason%'
  ) then
    raise exception
      'stage18 P1 r4 FAIL: clarification clears rejection_reason';
  end if;

  raise notice 'stage18 P1 hardening assertions: PASS';
end $$;
