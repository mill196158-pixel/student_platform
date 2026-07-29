-- Stage 16.1 subject card security review (LOCAL ONLY).
-- Assert RPC grants / FORCE RLS presence. Do not remote apply.

do $$
declare
  missing text;
begin
  if to_regprocedure('public.get_subject_card(uuid)') is null then
    raise exception 'missing get_subject_card';
  end if;
  if to_regprocedure(
    'public.admin_upsert_subject_card(uuid,integer,integer,text,text,text,text,text,text,text,jsonb,text,text,text,text,text,text,date,jsonb)'
  ) is null then
    raise exception 'missing admin_upsert_subject_card';
  end if;

  select string_agg(proname, ', ')
  into missing
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('get_subject_card', 'admin_upsert_subject_card')
    and has_function_privilege('anon', p.oid, 'execute');

  if missing is not null then
    raise exception 'anon execute must be revoked: %', missing;
  end if;

  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'subject_offering_profile_versions'
      and c.relrowsecurity
  ) then
    raise exception 'subject_offering_profile_versions RLS missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Single card model + single source of truth for load.
--
-- Stage 16 must not end up with two competing subject-card models. These
-- assertions pin the decisions that resolved the overlap:
--
--   * load (hours_total / credits) lives ONLY in curriculum_subjects and is
--     surfaced through the offering by get_subject_card; duplicating it onto the
--     profile tables would create a second, drifting source of truth;
--   * exactly one ordering model (section_order + normalize_subject_section_order);
--   * exactly one mobile card RPC (get_subject_card);
--   * card writes are RPC-only, so row_version / section_order validation /
--     version snapshots cannot be bypassed.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
  v_cols text;
begin
  select string_agg(col.table_name || '.' || col.column_name, ', ' order by col.table_name)
  into v_cols
  from information_schema.columns col
  where col.table_schema = 'public'
    and col.table_name in (
      'subject_student_profiles', 'subject_offering_student_profiles'
    )
    and col.column_name in ('hours_total', 'credits');
  if v_cols is not null then
    raise exception
      'stage16.1 FAIL: load duplicated onto profile table(s) (%). SoT is curriculum_subjects via the offering.',
      v_cols;
  end if;

  if not exists (
    select 1 from information_schema.columns col
    where col.table_schema = 'public'
      and col.table_name = 'curriculum_subjects'
      and col.column_name in ('hours_total', 'credits')
  ) then
    raise exception 'stage16.1 FAIL: curriculum_subjects has no hours_total/credits to read';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_subject_card'
      and p.prosrc like '%curriculum_subjects%'
  ) then
    raise exception 'stage16.1 FAIL: get_subject_card does not read load from curriculum_subjects';
  end if;

  -- One ordering model only.
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'private'::regnamespace
      and p.proname = 'normalize_subject_section_order'
  ) then
    raise exception 'stage16.1 FAIL: private.normalize_subject_section_order missing';
  end if;

  select count(*) into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in (
      'get_published_subject_content', 'admin_upsert_subject_content',
      'admin_upsert_subject_offering_content', 'admin_list_subject_content_sections'
    );
  if v_bad > 0 then
    raise exception
      'stage16.1 FAIL: % rival subject-card RPC(s) present; the card model is get_subject_card / admin_upsert_subject_card only',
      v_bad;
  end if;

  select count(*) into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'subject_student_profiles', 'subject_offering_student_profiles',
      'subject_catalog'
    )
    and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  if v_bad > 0 then
    raise exception 'stage16.1 FAIL: % client DML grant(s) on the card tables', v_bad;
  end if;

  raise notice 'stage16.1 card model review: PASS';
end $$;
