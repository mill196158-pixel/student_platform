-- Stage 17 — vacancies domain security review.
--
-- Static, read-only checks to run AFTER applying
-- 20260729151000_stage17_vacancies_domain.sql and
-- 20260729151050_stage17_vacancies_p1_hardening.sql.
-- offending rows (or the expected shape noted above it). Nothing here mutates
-- data. Do not run before the migration is applied.
--
-- Section 0 at the very bottom re-asserts the critical invariants as a hard
-- gate, so the whole file can be run with ON_ERROR_STOP=1 as a pass/fail step.

-- ---------------------------------------------------------------------------
-- 1. Every Stage 17 table has RLS enabled AND forced (no owner bypass).
--    Expect: 9 rows, rls_enabled = true and rls_forced = true for all.
-- ---------------------------------------------------------------------------
select
  c.relname             as table_name,
  c.relrowsecurity      as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'vacancies',
    'vacancy_versions',
    'vacancy_audience_groups',
    'vacancy_audience_users',
    'vacancy_assets',
    'vacancy_asset_upload_intents',
    'vacancy_media_cleanup_queue',
    'vacancy_reports',
    'vacancy_moderation_actions'
  )
order by c.relname;

-- ---------------------------------------------------------------------------
-- 1b. Any Stage 17 table missing (or missing RLS/FORCE) is a hard failure.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  t.table_name,
  (c.oid is not null)                    as table_exists,
  coalesce(c.relrowsecurity, false)      as rls_enabled,
  coalesce(c.relforcerowsecurity, false) as rls_forced
from (
  values
    ('vacancies'), ('vacancy_versions'), ('vacancy_audience_groups'),
    ('vacancy_audience_users'), ('vacancy_assets'),
    ('vacancy_asset_upload_intents'),
    ('vacancy_media_cleanup_queue'), ('vacancy_reports'),
    ('vacancy_moderation_actions')
) as t(table_name)
left join pg_class c
  on c.relname = t.table_name
 and c.relnamespace = 'public'::regnamespace
where c.oid is null
   or not c.relrowsecurity
   or not c.relforcerowsecurity;

-- ---------------------------------------------------------------------------
-- 2. public / anon / authenticated must NOT hold direct table DML.
--    This is what keeps `contacts` and unpublished drafts unreachable.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and (table_name = 'vacancies' or table_name like 'vacancy\_%')
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
order by table_name, grantee, privilege_type;

-- ---------------------------------------------------------------------------
-- 3. service_role holds the table DML instead.
--    Expect: SELECT/INSERT/UPDATE/DELETE for each of the 9 tables.
-- ---------------------------------------------------------------------------
select
  table_name,
  string_agg(distinct privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
  and (table_name = 'vacancies' or table_name like 'vacancy\_%')
  and grantee = 'service_role'
group by table_name
order by table_name;

-- ---------------------------------------------------------------------------
-- 4. No RLS policy may expose Stage 17 tables to anon / authenticated.
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
  and (c.relname = 'vacancies' or c.relname like 'vacancy\_%')
order by c.relname, pol.polname;

-- ---------------------------------------------------------------------------
-- 5. anon must NOT be able to EXECUTE any Stage 17 RPC.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  'anon'    as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_list_vacancies', 'admin_get_vacancy',
    'admin_create_vacancy_draft', 'admin_update_vacancy_draft',
    'admin_set_vacancy_audience', 'admin_preview_vacancy_audience',
    'admin_moderate_vacancy', 'admin_publish_vacancy',
    'admin_set_vacancy_lifecycle', 'admin_list_vacancy_versions',
    'admin_list_vacancy_reports', 'admin_resolve_vacancy_report',
    'admin_register_vacancy_asset', 'admin_delete_vacancy_asset',
    'get_my_vacancies', 'get_vacancy_contacts',
    'submit_vacancy', 'report_vacancy'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- ---------------------------------------------------------------------------
-- 6. authenticated SHOULD be able to execute the Stage 17 RPCs (RBAC is
--    checked inside the function body, not by the grant).
--    Expect: 18 rows, can_execute = true.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_list_vacancies', 'admin_get_vacancy',
    'admin_create_vacancy_draft', 'admin_update_vacancy_draft',
    'admin_set_vacancy_audience', 'admin_preview_vacancy_audience',
    'admin_moderate_vacancy', 'admin_publish_vacancy',
    'admin_set_vacancy_lifecycle', 'admin_list_vacancy_versions',
    'admin_list_vacancy_reports', 'admin_resolve_vacancy_report',
    'admin_register_vacancy_asset', 'admin_delete_vacancy_asset',
    'get_my_vacancies', 'get_vacancy_contacts',
    'submit_vacancy', 'report_vacancy'
  )
order by p.proname;

-- ---------------------------------------------------------------------------
-- 7. private.vacancy_* helpers must NOT be executable by anon / authenticated.
--    vacancy_expire_due in particular is a scheduled job, not a client call.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname as function_name,
  r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (values ('anon'), ('authenticated')) as r(rolname)
where n.nspname = 'private'
  and p.proname like 'vacancy\_%'
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
order by p.proname, r.rolname;

-- ---------------------------------------------------------------------------
-- 8. Every Stage 17 public RPC is SECURITY DEFINER with search_path = ''.
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
    'admin_list_vacancies', 'admin_get_vacancy',
    'admin_create_vacancy_draft', 'admin_update_vacancy_draft',
    'admin_set_vacancy_audience', 'admin_preview_vacancy_audience',
    'admin_moderate_vacancy', 'admin_publish_vacancy',
    'admin_set_vacancy_lifecycle', 'admin_list_vacancy_versions',
    'admin_list_vacancy_reports', 'admin_resolve_vacancy_report',
    'admin_register_vacancy_asset', 'admin_delete_vacancy_asset',
    'get_my_vacancies', 'get_vacancy_contacts',
    'submit_vacancy', 'report_vacancy'
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
-- 9. Every private vacancy helper also pins search_path = ''.
--    Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname   as function_name,
  p.prosecdef as security_definer,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname like 'vacancy\_%'
  and (
    p.proconfig is null
    or not exists (
      select 1 from unnest(p.proconfig) as cfg
      where replace(cfg, '"', '') = 'search_path='
    )
  );

-- ---------------------------------------------------------------------------
-- 10. Full Stage 17 RPC inventory must exist (14 admin + 4 student).
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('admin_list_vacancies'), ('admin_get_vacancy'),
    ('admin_create_vacancy_draft'), ('admin_update_vacancy_draft'),
    ('admin_set_vacancy_audience'), ('admin_preview_vacancy_audience'),
    ('admin_moderate_vacancy'), ('admin_publish_vacancy'),
    ('admin_set_vacancy_lifecycle'), ('admin_list_vacancy_versions'),
    ('admin_list_vacancy_reports'), ('admin_resolve_vacancy_report'),
    ('admin_register_vacancy_asset'), ('admin_delete_vacancy_asset'),
    ('get_my_vacancies'), ('get_vacancy_contacts'),
    ('submit_vacancy'), ('report_vacancy')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

-- ---------------------------------------------------------------------------
-- 11. Status machine: the CHECK constraint must allow exactly the eight
--     owner-specified statuses.
--     Expect: draft, submitted, in_moderation, approved, published, expired,
--             archived, rejected.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'vacancies'
  and con.contype = 'c'
  and con.conname = 'vacancies_status_check';

-- ---------------------------------------------------------------------------
-- 11b. Any of the eight statuses missing from the constraint is a failure.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.status as missing_status
from (
  values ('draft'), ('submitted'), ('in_moderation'), ('approved'),
         ('published'), ('expired'), ('archived'), ('rejected')
) as t(status)
where not exists (
  select 1
  from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  where c.relname = 'vacancies'
    and con.conname = 'vacancies_status_check'
    and pg_get_constraintdef(con.oid) like '%''' || t.status || '''%'
);

-- ---------------------------------------------------------------------------
-- 12. Origin must be constrained to demo | admin | user_submission.
--     Expect: one row listing exactly those three.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'vacancies'
  and con.conname = 'vacancies_origin_check';

-- ---------------------------------------------------------------------------
-- 12b. Each of the three origins must be present. Expect: zero rows.
-- ---------------------------------------------------------------------------
select t.origin as missing_origin
from (values ('demo'), ('admin'), ('user_submission')) as t(origin)
where not exists (
  select 1
  from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  where c.relname = 'vacancies'
    and con.conname = 'vacancies_origin_check'
    and pg_get_constraintdef(con.oid) like '%''' || t.origin || '''%'
);

-- ---------------------------------------------------------------------------
-- 13. vacancy_assets must hang off a typed vacancy_id FK, not a polymorphic
--     owner. Expect: one FK row to vacancies; zero polymorphic columns.
-- ---------------------------------------------------------------------------
select con.conname, pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'vacancy_assets'
  and con.contype = 'f'
  and pg_get_constraintdef(con.oid) ilike '%vacancies%';

select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'vacancy_assets'
  and column_name in ('owner_kind', 'owner_id', 'owner_type', 'entity_type', 'entity_id');

-- ---------------------------------------------------------------------------
-- 14. Contacts protection: the student list RPC must expose only a
--     `has_contacts` boolean and never a `contacts` payload key. Raw contacts
--     are reachable only through get_vacancy_contacts, which re-checks
--     published + audience visibility.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_my_vacancies'
  and p.prosrc like '%''contacts'',%';

-- ---------------------------------------------------------------------------
-- 14b. get_my_vacancies must still advertise has_contacts. Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_my_vacancies'
  and p.prosrc like '%has_contacts%';

-- ---------------------------------------------------------------------------
-- 15. A student submission must never auto-publish: submit_vacancy has to pin
--     origin = 'user_submission' and status = 'submitted'.
--     Expect: one row.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'submit_vacancy'
  and p.prosrc like '%user_submission%'
  and p.prosrc like '%submitted%';

-- ---------------------------------------------------------------------------
-- 15b. submit_vacancy must NOT be able to reach the published state directly.
--      Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'submit_vacancy'
  and p.prosrc like '%''published''%';

-- ---------------------------------------------------------------------------
-- 16. Mutating Stage 17 admin RPCs must take an expected row version.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select
  p.proname,
  pg_get_function_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_update_vacancy_draft', 'admin_set_vacancy_audience',
    'admin_moderate_vacancy', 'admin_publish_vacancy',
    'admin_set_vacancy_lifecycle'
  )
  and pg_get_function_arguments(p.oid) not like '%p_expected_row_version%';

-- ---------------------------------------------------------------------------
-- 17. admin_create_vacancy_draft must NOT take a row_version argument.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select p.proname, pg_get_function_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_create_vacancy_draft'
  and pg_get_function_arguments(p.oid) like '%row_version%';

-- ---------------------------------------------------------------------------
-- 18. Audience tables must be scoped by typed FKs to groups / users.
--     Expect: one FK to groups, one FK to users.
-- ---------------------------------------------------------------------------
select
  c.relname   as table_name,
  con.conname as constraint_name,
  pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname in ('vacancy_audience_groups', 'vacancy_audience_users')
  and con.contype = 'f'
order by c.relname, con.conname;

-- ---------------------------------------------------------------------------
-- 19. Moderation + report trails exist and are append-oriented.
--     Expect: rows for vacancy_moderation_actions and vacancy_reports PKs.
-- ---------------------------------------------------------------------------
select
  c.relname   as table_name,
  con.conname as constraint_name,
  con.contype as kind
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname in ('vacancy_moderation_actions', 'vacancy_reports')
  and con.contype in ('p', 'u')
order by c.relname, con.conname;

-- ---------------------------------------------------------------------------
-- 0. HARD GATE — re-assert the critical invariants. Raises on any violation.
--    Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
  v_rpcs text[] := array[
    'admin_list_vacancies', 'admin_get_vacancy',
    'admin_create_vacancy_draft', 'admin_update_vacancy_draft',
    'admin_set_vacancy_audience', 'admin_preview_vacancy_audience',
    'admin_moderate_vacancy', 'admin_publish_vacancy',
    'admin_set_vacancy_lifecycle', 'admin_list_vacancy_versions',
    'admin_list_vacancy_reports', 'admin_resolve_vacancy_report',
    'admin_register_vacancy_asset', 'admin_delete_vacancy_asset',
    'get_my_vacancies', 'get_vacancy_contacts',
    'submit_vacancy', 'report_vacancy'
  ];
  v_tables text[] := array[
    'vacancies', 'vacancy_versions', 'vacancy_audience_groups',
    'vacancy_audience_users', 'vacancy_assets',
    'vacancy_asset_upload_intents',
    'vacancy_media_cleanup_queue', 'vacancy_reports',
    'vacancy_moderation_actions'
  ];
  v_statuses text[] := array[
    'draft', 'submitted', 'in_moderation', 'approved',
    'published', 'expired', 'archived', 'rejected'
  ];
begin
  select count(*) into v_bad
  from unnest(v_tables) as t(name)
  left join pg_class c
    on c.relname = t.name and c.relnamespace = 'public'::regnamespace
  where c.oid is null or not c.relrowsecurity or not c.relforcerowsecurity;
  if v_bad > 0 then
    raise exception 'stage17 FAIL: % table(s) missing or without FORCE RLS', v_bad;
  end if;

  select count(*) into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = any (v_tables)
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');
  if v_bad > 0 then
    raise exception 'stage17 FAIL: % client table grant(s) on vacancy tables', v_bad;
  end if;

  select count(*) into v_bad
  from pg_policy pol
  join pg_class c on c.oid = pol.polrelid
  where c.relnamespace = 'public'::regnamespace
    and c.relname = any (v_tables);
  if v_bad > 0 then
    raise exception 'stage17 FAIL: % RLS policy/policies on vacancy tables', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(v_rpcs) as r(name)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = r.name
  );
  if v_bad > 0 then
    raise exception 'stage17 FAIL: % RPC(s) missing', v_bad;
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
    raise exception 'stage17 FAIL: % RPC(s) not SECURITY DEFINER with search_path=''''', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = any (v_rpcs)
    and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad > 0 then
    raise exception 'stage17 FAIL: anon can execute % Stage 17 RPC(s)', v_bad;
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname like 'vacancy\_%'
    and (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    );
  if v_bad > 0 then
    raise exception 'stage17 FAIL: % private vacancy helper(s) client-executable', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(v_statuses) as t(status)
  where not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'vacancies'
      and con.conname = 'vacancies_status_check'
      and pg_get_constraintdef(con.oid) like '%''' || t.status || '''%'
  );
  if v_bad > 0 then
    raise exception 'stage17 FAIL: % status(es) missing from the status machine', v_bad;
  end if;

  select count(*) into v_bad
  from unnest(array['demo', 'admin', 'user_submission']) as t(origin)
  where not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'vacancies'
      and con.conname = 'vacancies_origin_check'
      and pg_get_constraintdef(con.oid) like '%''' || t.origin || '''%'
  );
  if v_bad > 0 then
    raise exception 'stage17 FAIL: % origin value(s) missing', v_bad;
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_my_vacancies'
      and p.prosrc like '%''contacts'',%'
  ) then
    raise exception 'stage17 FAIL: get_my_vacancies exposes a contacts payload';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_my_vacancies'
      and p.prosrc like '%has_contacts%'
  ) then
    raise exception 'stage17 FAIL: get_my_vacancies lost the has_contacts flag';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'submit_vacancy'
      and p.prosrc like '%''published''%'
  ) then
    raise exception 'stage17 FAIL: submit_vacancy can reach the published state';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'submit_vacancy'
      and p.prosrc like '%user_submission%'
      and p.prosrc like '%submitted%'
  ) then
    raise exception 'stage17 FAIL: submit_vacancy does not pin origin/status';
  end if;

  select count(*) into v_bad
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'vacancy_assets'
    and column_name in ('owner_kind', 'owner_id', 'owner_type', 'entity_type', 'entity_id');
  if v_bad > 0 then
    raise exception 'stage17 FAIL: vacancy_assets has % polymorphic owner column(s)', v_bad;
  end if;

  raise notice 'stage17 security review: PASS';
end $$;

-- ===========================================================================
-- P1 REWORK ASSERTIONS (Codex REJECT round 1)
--
-- Everything below is additive: it pins the three lifecycle P1s so a later
-- refactor cannot silently reopen them. Still read-only.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 20. The moderation trail must be able to express AUTHORING events
--     (`create_draft`, `submit`) and the cron transition (`auto_expire`)
--     separately from real moderation decisions, so a draft is never recorded
--     as `take_in_moderation`. Expect: one row containing all three codes.
-- ---------------------------------------------------------------------------
select
  con.conname,
  pg_get_constraintdef(con.oid) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relname = 'vacancy_moderation_actions'
  and con.contype = 'c'
  and pg_get_constraintdef(con.oid) like '%create_draft%'
  and pg_get_constraintdef(con.oid) like '%submit%'
  and pg_get_constraintdef(con.oid) like '%auto_expire%';

-- ---------------------------------------------------------------------------
-- 21. Draft creation records `create_draft` and must NOT claim the vacancy was
--     taken into moderation. Expect: one row, records_draft = true,
--     falsifies_moderation = false.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%''create_draft''%')       as records_draft,
  (p.prosrc like '%take_in_moderation%')     as falsifies_moderation
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_create_vacancy_draft';

-- ---------------------------------------------------------------------------
-- 22. Cron expiry changes lifecycle, so it must snapshot a version AND write
--     the moderation/audit trail per vacancy.
--     Expect: one row, all three flags true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%vacancy_snapshot_version%')     as snapshots_version,
  (p.prosrc like '%''auto_expire''%')             as records_action,
  (p.prosrc like '%vacancy_record_action%')        as uses_trail_helper
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'vacancy_expire_due';

-- ---------------------------------------------------------------------------
-- 23. Expiry must be row-by-row (a set-based UPDATE cannot snapshot each
--     vacancy) and bounded, so a huge backlog cannot lock the table forever.
--     Expect: one row, iterates = true, bounded = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc ilike '%for %in%loop%')  as iterates,
  (pg_get_function_identity_arguments(p.oid) like '%integer%') as bounded
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'vacancy_expire_due';

-- ---------------------------------------------------------------------------
-- 23b. Exactly ONE vacancy_expire_due overload may exist, otherwise cron may
--      keep calling the old audit-less zero-arg version. Expect: one row,
--      overloads = 1.
-- ---------------------------------------------------------------------------
select count(*) as overloads
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'vacancy_expire_due';

-- ---------------------------------------------------------------------------
-- 24. ASSET SAFETY: deleting a file must never break a PUBLISHED card.
--     Expect: one row, guards_published = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%unpublish_vacancy_before_deleting_asset%') as guards_published,
  (p.prosrc like '%vacancy_media_cleanup_queue%')             as queues_object
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_delete_vacancy_asset';

-- ---------------------------------------------------------------------------
-- 25. Every lifecycle-changing RPC snapshots a version before it writes.
--     Expect: zero rows.
-- ---------------------------------------------------------------------------
select r.proname as missing_snapshot
from (
  values
    ('admin_moderate_vacancy'),
    ('admin_publish_vacancy'),
    ('admin_set_vacancy_lifecycle'),
    ('submit_vacancy')
) as r(proname)
where not exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = r.proname
    and p.prosrc like '%vacancy_snapshot_version%'
);

-- ---------------------------------------------------------------------------
-- 0b. HARD GATE for the P1 rework. Raises on any violation. Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  -- 1) Authoring / cron action codes exist in the trail constraint.
  if not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'vacancy_moderation_actions'
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) like '%create_draft%'
      and pg_get_constraintdef(con.oid) like '%submit%'
      and pg_get_constraintdef(con.oid) like '%auto_expire%'
  ) then
    raise exception
      'stage17 P1 FAIL: vacancy_moderation_actions cannot express create_draft/submit/auto_expire';
  end if;

  -- 2) Draft creation must not be recorded as a moderation decision.
  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_create_vacancy_draft'
      and p.prosrc like '%take_in_moderation%'
  ) then
    raise exception
      'stage17 P1 FAIL: admin_create_vacancy_draft still records take_in_moderation';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_create_vacancy_draft'
      and p.prosrc like '%''create_draft''%'
  ) then
    raise exception
      'stage17 P1 FAIL: admin_create_vacancy_draft does not record create_draft';
  end if;

  -- 3) Cron expiry snapshots and audits.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'vacancy_expire_due'
      and p.prosrc like '%vacancy_snapshot_version%'
      and p.prosrc like '%''auto_expire''%'
  ) then
    raise exception
      'stage17 P1 FAIL: vacancy_expire_due changes lifecycle without snapshot/audit';
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'private'::regnamespace
    and p.proname = 'vacancy_expire_due';
  if v_bad <> 1 then
    raise exception
      'stage17 P1 FAIL: % vacancy_expire_due overload(s); the audit-less one must be dropped', v_bad;
  end if;

  -- 4) Asset deletion must not break a published card.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_delete_vacancy_asset'
      and p.prosrc like '%unpublish_vacancy_before_deleting_asset%'
  ) then
    raise exception
      'stage17 P1 FAIL: admin_delete_vacancy_asset can delete a published vacancy file';
  end if;

  -- 5) No lifecycle write without a version snapshot.
  select count(*) into v_bad
  from (
    values ('admin_moderate_vacancy'), ('admin_publish_vacancy'),
           ('admin_set_vacancy_lifecycle'), ('submit_vacancy')
  ) as r(proname)
  where not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = r.proname
      and p.prosrc like '%vacancy_snapshot_version%'
  );
  if v_bad > 0 then
    raise exception
      'stage17 P1 FAIL: % lifecycle RPC(s) change state without a version snapshot', v_bad;
  end if;

  raise notice 'stage17 P1 rework assertions: PASS';
end $$;

-- ===========================================================================
-- P1 ROUND 2 ASSERTIONS (Codex REJECT round 2 — post-hardening migration)
-- Requires 20260729151050_stage17_vacancies_p1_hardening.sql applied.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 26. Content edits fail-closed outside draft|submitted|rejected.
--     Expect: one row, uses_editable_guard = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%vacancy_assert_editable_content%') as uses_editable_guard
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_update_vacancy_draft', 'admin_set_vacancy_audience');

-- ---------------------------------------------------------------------------
-- 27. admin_update_vacancy_draft must NOT allow in_moderation|approved edits.
--     Expect: zero rows (no legacy allow-list).
-- ---------------------------------------------------------------------------
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_update_vacancy_draft'
  and p.prosrc like '%in_moderation%'
  and p.prosrc like '%approved%'
  and p.prosrc not like '%vacancy_assert_editable_content%';

-- ---------------------------------------------------------------------------
-- 28. Client-trusted asset register is deprecated.
--     Expect: one row, raises_deprecated = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%deprecated_use_upload_intent%') as raises_deprecated
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_register_vacancy_asset';

-- ---------------------------------------------------------------------------
-- 29. Upload intent + finalize RPCs exist; intent never returns storage_path.
--     Expect: zero rows missing; intent RPC has no path leak.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('admin_create_vacancy_asset_upload_intent'),
    ('admin_finalize_vacancy_asset_upload'),
    ('service_vacancy_upload_intent_storage_path'),
    ('authorize_vacancy_asset_download'),
    ('service_vacancy_asset_storage_path'),
    ('admin_list_vacancy_moderation_actions')
) as r(proname)
where not exists (
  select 1 from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_create_vacancy_asset_upload_intent'
  and p.prosrc like '%storage_path%'
  and p.prosrc like '%return jsonb_build_object%'
  and p.prosrc like '%''storage_path''%';

-- ---------------------------------------------------------------------------
-- 30. Finalize reads MIME/size from storage.objects (fail-closed).
--     Expect: one row, all flags true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%storage.objects%') as reads_storage,
  (p.prosrc like '%storage_mime_missing%') as fail_closed_mime,
  (p.prosrc like '%mime_mismatch%') as checks_intent_mime
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_finalize_vacancy_asset_upload';

-- ---------------------------------------------------------------------------
-- 31. explicit_users_count requires active enrollment.
--     Expect: one row, checks_enrollment = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%student_enrollments%'
   and p.prosrc like '%explicit_users_count%') as checks_enrollment
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'vacancy_preview_audience_count';

-- ---------------------------------------------------------------------------
-- 0c. HARD GATE for P1 round 2. Raises on any violation. Read-only.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_update_vacancy_draft'
      and p.prosrc like '%vacancy_assert_editable_content%'
  ) then
    raise exception
      'stage17 P1r2 FAIL: admin_update_vacancy_draft missing editable guard';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_set_vacancy_audience'
      and p.prosrc like '%vacancy_assert_editable_content%'
  ) then
    raise exception
      'stage17 P1r2 FAIL: admin_set_vacancy_audience missing editable guard';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_register_vacancy_asset'
      and p.prosrc like '%deprecated_use_upload_intent%'
  ) then
    raise exception
      'stage17 P1r2 FAIL: admin_register_vacancy_asset still trusts client path';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'admin_finalize_vacancy_asset_upload'
      and p.prosrc like '%storage.objects%'
      and p.prosrc like '%storage_mime_missing%'
  ) then
    raise exception
      'stage17 P1r2 FAIL: finalize does not fail-closed on storage metadata';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'vacancy_preview_audience_count'
      and p.prosrc like '%student_enrollments%'
  ) then
    raise exception
      'stage17 P1r2 FAIL: explicit_users_count ignores enrollment';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'authorize_vacancy_asset_download'
  ) then
    raise exception
      'stage17 P1r2 FAIL: authorize_vacancy_asset_download missing';
  end if;

  raise notice 'stage17 P1 round 2 assertions: PASS';
end $$;

-- ===========================================================================
-- P1 ROUND 3 ASSERTIONS (Codex REJECT round 3 — cleanup worker + assets + gates)
-- Requires 20260729151050_stage17_vacancies_p1_hardening.sql (extended).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 32. Vacancy cleanup worker RPCs exist and are service_role-only.
--     Expect: zero rows missing; zero client grants.
-- ---------------------------------------------------------------------------
select r.proname as missing_rpc
from (
  values
    ('claim_vacancy_media_cleanup_batch'),
    ('complete_vacancy_media_cleanup'),
    ('fail_vacancy_media_cleanup')
) as r(proname)
where not exists (
  select 1 from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = r.proname
);

select
  routine_name,
  grantee
from information_schema.routine_privileges
where routine_schema = 'public'
  and routine_name in (
    'claim_vacancy_media_cleanup_batch',
    'complete_vacancy_media_cleanup',
    'fail_vacancy_media_cleanup',
    'service_vacancy_upload_intent_storage_path',
    'service_vacancy_asset_storage_path'
  )
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
order by routine_name, grantee;

-- ---------------------------------------------------------------------------
-- 33. Cleanup claim uses pending-only leases (processed_at IS NULL).
--     Expect: one row, pending_only = true.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc ilike '%processed_at is null%') as pending_only
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'claim_vacancy_media_cleanup_batch';

-- ---------------------------------------------------------------------------
-- 34. vacancy_asset_upload_intents: FORCE RLS + no client DML.
--     Expect: one row forced; zero client grants.
-- ---------------------------------------------------------------------------
select
  c.relname             as table_name,
  c.relrowsecurity      as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'vacancy_asset_upload_intents';

select
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'vacancy_asset_upload_intents'
  and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');

-- ---------------------------------------------------------------------------
-- 35. get_my_vacancies returns typed assets (not bare asset_ids).
--     Expect: one row, emits_assets = true; zero rows still emitting asset_ids.
-- ---------------------------------------------------------------------------
select
  p.proname,
  (p.prosrc like '%''assets''%') as emits_assets
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_my_vacancies';

select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_my_vacancies'
  and p.prosrc like '%''asset_ids''%';

-- ---------------------------------------------------------------------------
-- 0d. HARD GATE for P1 round 3. Raises on any violation. Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  -- vacancy_asset_upload_intents FORCE RLS + no client DML
  if not exists (
    select 1 from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relname = 'vacancy_asset_upload_intents'
      and c.relrowsecurity
      and c.relforcerowsecurity
  ) then
    raise exception
      'stage17 P1r3 FAIL: vacancy_asset_upload_intents missing FORCE RLS';
  end if;

  select count(*) into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'vacancy_asset_upload_intents'
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');
  if v_bad > 0 then
    raise exception
      'stage17 P1r3 FAIL: % client grant(s) on vacancy_asset_upload_intents', v_bad;
  end if;

  -- Service-only upload/download/cleanup RPCs
  select count(*) into v_bad
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'service_vacancy_upload_intent_storage_path',
      'service_vacancy_asset_storage_path',
      'claim_vacancy_media_cleanup_batch',
      'complete_vacancy_media_cleanup',
      'fail_vacancy_media_cleanup'
    )
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public');
  if v_bad > 0 then
    raise exception
      'stage17 P1r3 FAIL: % client grant(s) on service vacancy media RPCs', v_bad;
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'claim_vacancy_media_cleanup_batch'
      and p.prosrc ilike '%processed_at is null%'
  ) then
    raise exception
      'stage17 P1r3 FAIL: cleanup claim missing processed_at IS NULL';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_my_vacancies'
      and p.prosrc like '%''assets''%'
      and p.prosrc like '%mime_type%'
  ) then
    raise exception
      'stage17 P1r3 FAIL: get_my_vacancies missing typed assets payload';
  end if;

  raise notice 'stage17 P1 round 3 assertions: PASS';
end $$;
