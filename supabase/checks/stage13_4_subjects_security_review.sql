-- Stage 13.4 subjects security review. Assertive; fails on deviation.
\set ON_ERROR_STOP on

do $$
declare
  v_missing text;
  v_oid oid;
begin
  select string_agg(t.rel, ', ') into v_missing
  from (values
    ('subject_catalog'),('subject_student_profiles'),('subject_versions'),
    ('subject_import_batches'),('subject_import_rows')
  ) as t(rel)
  where not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = t.rel
      and c.relrowsecurity and c.relforcerowsecurity
  );
  if v_missing is not null then
    raise exception 'subject tables missing FORCE RLS: %', v_missing;
  end if;

  if has_table_privilege('authenticated', 'public.subject_import_batches', 'insert')
     or has_table_privilege('authenticated', 'public.subject_versions', 'insert') then
    raise exception 'authenticated has direct write on subject admin tables';
  end if;

  select p.oid into v_oid
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'admin_upsert_subject'
  order by p.oid limit 1;
  if v_oid is null then
    raise exception 'admin_upsert_subject missing';
  end if;
  if has_function_privilege('anon', v_oid, 'execute') then
    raise exception 'anon can execute admin_upsert_subject';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'subject_import_batches_actor_payload_uidx'
  ) then
    raise exception 'missing subject_import_batches_actor_payload_uidx';
  end if;

  if exists (
    select 1
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'subject_catalog'
      and pol.polname = 'subject_catalog_read_authenticated'
  ) then
    raise exception 'legacy subject_catalog_read_authenticated policy still present';
  end if;
end;
$$;
