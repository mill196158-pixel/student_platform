-- Stage 13.8 safe academic terms security review. Assertive; fails on deviation.
\set ON_ERROR_STOP on

do $$
declare
  v_oid oid;
  v_current_count integer;
  v_fn text;
begin
  select count(*)::integer into v_current_count
  from public.academic_terms
  where is_current = true;
  if v_current_count <> 1 then
    raise exception 'expected exactly one current term, found %', v_current_count;
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'academic_terms_one_current_uidx'
  ) then
    raise exception 'missing academic_terms_one_current_uidx';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'academic_terms'
      and column_name = 'auto_activation_enabled'
  ) then
    raise exception 'missing auto_activation_enabled column';
  end if;

  if exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'academic_terms'
      and t.tgname = 'trg_academic_terms_archive_previous'
      and not t.tgisinternal
  ) then
    raise exception 'broad archive-on-current trigger must be removed';
  end if;

  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'academic_terms'
      and t.tgname = 'trg_stage13_8_guard_is_current'
      and not t.tgisinternal
  ) then
    raise exception 'missing is_current guard trigger';
  end if;

  if not exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'academic_terms'
      and c.relrowsecurity
      and c.relforcerowsecurity
  ) then
    raise exception 'academic_terms must use FORCE RLS';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'academic_terms'
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'academic_terms must not expose write policies to clients';
  end if;

  if has_table_privilege('authenticated', 'public.academic_terms', 'insert')
     or has_table_privilege('authenticated', 'public.academic_terms', 'update')
     or has_table_privilege('authenticated', 'public.academic_terms', 'delete')
     or has_table_privilege('anon', 'public.academic_terms', 'update')
  then
    raise exception 'authenticated/anon must not have direct write grants on academic_terms';
  end if;

  foreach v_fn in array array[
    'admin_term_backfill',
    'admin_start_next_term',
    'admin_start_next_term_dry_run',
    'admin_term_readiness',
    'admin_term_backfill_dry_run'
  ]
  loop
    select p.oid into v_oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_fn
    order by p.oid
    limit 1;
    if v_oid is null then
      raise exception 'stage13_8 rpc missing: %', v_fn;
    end if;
    if has_function_privilege('anon', v_oid, 'execute') then
      raise exception 'anon can execute %', v_fn;
    end if;
    if not has_function_privilege('authenticated', v_oid, 'execute') then
      raise exception 'authenticated cannot execute %', v_fn;
    end if;
    if not (select prosecdef from pg_proc where oid = v_oid) then
      raise exception '% must be SECURITY DEFINER', v_fn;
    end if;
    if pg_get_functiondef(v_oid) not ilike '%search_path%' then
      raise exception '% missing locked search_path', v_fn;
    end if;
  end loop;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname like 'stage13_8%'
      and has_function_privilege('authenticated', p.oid, 'execute')
  ) then
    raise exception 'private stage13_8 helpers must not be executable by authenticated';
  end if;
end;
$$;
