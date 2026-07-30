-- Stage 14.1.1 vacancy draft-asset visibility — static security review.
-- Read-only expectations against catalog (safe on linked DB).

do $$
declare
  v_missing text;
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'vacancy_assets'
      and column_name = 'working_draft_id'
  ) then
    raise exception 'FAIL: vacancy_assets.working_draft_id missing';
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'vacancy_assets_working_draft_fkey'
      and confdeltype = 'r' -- restrict
  ) then
    raise exception 'FAIL: vacancy_assets_working_draft_fkey must be ON DELETE RESTRICT';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'get_my_vacancies'
      and pg_get_functiondef(p.oid) ilike '%working_draft_id is null%'
  ) then
    raise exception 'FAIL: get_my_vacancies must filter working_draft_id IS NULL';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'authorize_vacancy_asset_download'
      and pg_get_functiondef(p.oid) ilike '%working_draft_id is not null%'
  ) then
    raise exception 'FAIL: authorize_vacancy_asset_download must reject draft assets';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_finalize_vacancy_asset_upload'
      and pg_get_functiondef(p.oid) ilike '%working_draft_id%'
  ) then
    raise exception 'FAIL: finalize must set working_draft_id';
  end if;

  -- Direct table grants must remain service_role-only for DML.
  select string_agg(privilege_type, ',')
    into v_missing
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'vacancy_assets'
    and grantee in ('anon', 'authenticated')
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE');

  if v_missing is not null then
    raise exception 'FAIL: vacancy_assets grants to anon/authenticated: %', v_missing;
  end if;

  raise notice 'stage14_1_1 vacancy draft asset visibility security review OK';
end;
$$;
