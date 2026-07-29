-- Stage 16.1 deep security review (LOCAL ONLY).

do $$
declare
  v_acl text;
  v_force boolean;
begin
  -- Required RPCs exist
  if to_regprocedure('public.get_subject_card(uuid)') is null then
    raise exception 'missing get_subject_card';
  end if;
  if to_regprocedure(
    'public.admin_upsert_subject_card(uuid,integer,integer,text,text,text,text,text,text,text,jsonb,text,text,text,text,text,text,date,jsonb)'
  ) is null then
    raise exception 'missing admin_upsert_subject_card';
  end if;
  if to_regprocedure('public.admin_set_offering_teachers(uuid,integer,uuid[])') is null then
    raise exception 'missing admin_set_offering_teachers(uuid,integer,uuid[])';
  end if;
  if to_regprocedure(
    'public.admin_upsert_offering_student_profile(uuid,integer,text,text,text,text,text,text)'
  ) is null then
    raise exception 'missing admin_upsert_offering_student_profile';
  end if;
  if to_regprocedure('public.admin_list_subject_offerings(uuid)') is null then
    raise exception 'missing admin_list_subject_offerings';
  end if;
  if to_regprocedure('public.admin_list_offering_profile_versions(uuid)') is null then
    raise exception 'missing admin_list_offering_profile_versions';
  end if;
  if to_regprocedure(
    'public.admin_restore_offering_student_profile(uuid,integer,integer)'
  ) is null then
    raise exception 'missing admin_restore_offering_student_profile';
  end if;
  if to_regprocedure(
    'public.admin_restore_subject_version(uuid,integer,integer,integer)'
  ) is null then
    raise exception 'missing admin_restore_subject_version with expected versions';
  end if;
  if to_regprocedure('public.admin_restore_subject_version(uuid,integer)') is not null then
    raise exception 'legacy admin_restore_subject_version(uuid,integer) must be dropped';
  end if;
  if to_regprocedure('public.admin_set_subject_status(uuid,text)') is not null then
    raise exception 'legacy admin_set_subject_status(uuid,text) must be dropped';
  end if;

  -- Direct authenticated client must not execute legacy upsert (card RPC only)
  if has_function_privilege(
    'authenticated',
    'public.admin_upsert_subject(uuid,text,text,text,text,text,text,text,jsonb,text,text,text,text,text,text,integer,integer)'::regprocedure,
    'execute'
  ) then
    raise exception 'authenticated must not execute legacy admin_upsert_subject';
  end if;

  -- hours/credits must not live on profile tables
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name in ('subject_student_profiles', 'subject_offering_student_profiles')
      and column_name in ('hours_total', 'credits')
  ) then
    raise exception 'hours_total/credits must not exist on profile tables';
  end if;

  -- Old 2-arg teachers signature must be gone
  if to_regprocedure('public.admin_set_offering_teachers(uuid,uuid[])') is not null then
    raise exception 'legacy admin_set_offering_teachers(uuid,uuid[]) must be dropped';
  end if;

  -- FORCE RLS on offering profile versions
  select c.relforcerowsecurity into v_force
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'subject_offering_profile_versions';
  if coalesce(v_force, false) is not true then
    raise exception 'subject_offering_profile_versions FORCE RLS required';
  end if;

  -- anon must not execute sensitive RPCs (ACL inspect)
  for v_acl in
    select p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'get_subject_card',
        'admin_upsert_subject_card',
        'admin_set_offering_teachers',
        'admin_upsert_offering_student_profile',
        'admin_list_subject_offerings',
        'admin_list_offering_profile_versions',
        'admin_restore_offering_student_profile'
      )
      and has_function_privilege('anon', p.oid, 'execute')
  loop
    raise exception 'anon execute forbidden for %', v_acl;
  end loop;

  -- authenticated may execute get_subject_card
  if not has_function_privilege(
    'authenticated',
    'public.get_subject_card(uuid)'::regprocedure,
    'execute'
  ) then
    raise exception 'authenticated missing execute on get_subject_card';
  end if;

  -- search_path fixed on private helpers
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'normalize_subject_section_order'
      and pg_get_functiondef(p.oid) ilike '%set search_path%'
  ) then
    raise exception 'normalize_subject_section_order missing fixed search_path';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'null_if_blank'
      and pg_get_functiondef(p.oid) ilike '%set search_path%'
  ) then
    raise exception 'null_if_blank missing fixed search_path';
  end if;

  raise notice 'stage16_1_subject_card_security_review OK';
end $$;
