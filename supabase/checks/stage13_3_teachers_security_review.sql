-- Stage 13.3 teachers security review. Assertive; fails on deviation.
\set ON_ERROR_STOP on

do $$
declare
  v_missing text;
  v_oid oid;
begin
  select string_agg(t.rel, ', ') into v_missing
  from (values
    ('teachers'),('teacher_versions'),('teacher_import_batches'),('teacher_import_rows')
  ) as t(rel)
  where not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = t.rel
      and c.relrowsecurity and c.relforcerowsecurity
  );
  if v_missing is not null then
    raise exception 'teachers tables missing FORCE RLS: %', v_missing;
  end if;

  if has_table_privilege('anon', 'public.teachers', 'select')
     or has_table_privilege('anon', 'public.teachers', 'insert')
     or has_table_privilege('anon', 'public.teacher_import_batches', 'select') then
    raise exception 'anon has unexpected privilege on teacher tables';
  end if;

  if has_table_privilege('authenticated', 'public.teachers', 'insert')
     or has_table_privilege('authenticated', 'public.teachers', 'update')
     or has_table_privilege('authenticated', 'public.teacher_import_batches', 'insert') then
    raise exception 'authenticated has direct write on teacher admin tables';
  end if;

  select p.oid into v_oid
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_published_teacher'
  order by p.oid limit 1;
  if v_oid is null or not has_function_privilege('authenticated', v_oid, 'execute') then
    raise exception 'authenticated cannot execute get_published_teacher';
  end if;

  select p.oid into v_oid
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'admin_upsert_teacher'
  order by p.oid limit 1;
  if v_oid is null then
    raise exception 'admin_upsert_teacher missing';
  end if;
  if has_function_privilege('anon', v_oid, 'execute') then
    raise exception 'anon can execute admin_upsert_teacher';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'teacher_import_batches_actor_payload_uidx'
  ) then
    raise exception 'missing teacher_import_batches_actor_payload_uidx';
  end if;
end;
$$;
