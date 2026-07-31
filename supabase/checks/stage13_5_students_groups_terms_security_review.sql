-- Stage 13.5 students/groups/terms security review. Assertive; fails on deviation.
\set ON_ERROR_STOP on

do $$
declare
  v_oid oid;
  v_rls_count integer;
begin
  select count(*) into v_rls_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in ('admin_term_ops_batches', 'admin_term_ops_rows')
    and c.relrowsecurity and c.relforcerowsecurity;
  if v_rls_count <> 2 then
    raise exception 'admin_term_ops_* missing FORCE RLS (found %)', v_rls_count;
  end if;

  if has_table_privilege('authenticated', 'public.admin_term_ops_batches', 'insert')
     or has_table_privilege('authenticated', 'public.admin_term_ops_rows', 'update')
     or has_table_privilege('anon', 'public.admin_term_ops_batches', 'select') then
    raise exception 'unexpected privileges on admin_term_ops tables';
  end if;

  select p.oid into v_oid
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'admin_prepare_term_apply'
  order by p.oid limit 1;
  if v_oid is null then
    raise exception 'admin_prepare_term_apply missing';
  end if;
  if has_function_privilege('anon', v_oid, 'execute') then
    raise exception 'anon can execute admin_prepare_term_apply';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_list_students'
      and has_function_privilege('authenticated', p.oid, 'execute')
  ) then
    raise exception 'authenticated cannot execute admin_list_students';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'admin_term_ops_batches_actor_payload_uidx'
  ) then
    raise exception 'missing admin_term_ops_batches_actor_payload_uidx';
  end if;
end;
$$;
