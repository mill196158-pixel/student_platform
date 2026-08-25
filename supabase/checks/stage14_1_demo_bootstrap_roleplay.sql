-- Stage 14.1 demo bootstrap roleplay (local disposable DB)
begin;

do $$
declare
  v_admin uuid;
  v_before_items integer;
  v_before_vacancies integer;
  v_before_cats integer;
  v_before_placements integer;
  v_before_versions integer;
  v_before_vacancy_versions integer;
  v_before_audit integer;
  v_before_tombstones integer;
  v_after_items integer;
  v_after_vacancies integer;
  v_after_cats integer;
  v_after_placements integer;
  v_after_versions integer;
  v_after_vacancy_versions integer;
  v_after_audit integer;
  v_after_tombstones integer;
  v_plan jsonb;
  v_plan2 jsonb;
  v_id uuid;
  v_rv integer;
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
  limit 1;

  if v_admin is null then
    raise exception 'STAGE14_1_ROLEPLAY FAIL: no admin fixture with content.publish';
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  select count(*) into v_before_items from public.content_items;
  select count(*) into v_before_vacancies from public.vacancies;
  select count(*) into v_before_cats from public.reference_categories;
  select count(*) into v_before_placements from public.content_item_placements;
  select count(*) into v_before_versions from public.content_item_versions;
  select count(*) into v_before_vacancy_versions from public.vacancy_versions;
  select count(*) into v_before_audit from public.content_audit_log;
  select count(*) into v_before_tombstones from public.content_legacy_tombstones;

  v_plan := public.admin_bootstrap_demo_content(true);
  if coalesce((v_plan->>'dry_run')::boolean, false) is not true then
    raise exception 'dry_run flag missing';
  end if;

  select count(*) into v_after_items from public.content_items;
  select count(*) into v_after_vacancies from public.vacancies;
  select count(*) into v_after_cats from public.reference_categories;
  select count(*) into v_after_placements from public.content_item_placements;
  select count(*) into v_after_versions from public.content_item_versions;
  select count(*) into v_after_vacancy_versions from public.vacancy_versions;
  select count(*) into v_after_audit from public.content_audit_log;
  select count(*) into v_after_tombstones from public.content_legacy_tombstones;

  if v_after_items <> v_before_items
     or v_after_vacancies <> v_before_vacancies
     or v_after_cats <> v_before_cats
     or v_after_placements <> v_before_placements
     or v_after_versions <> v_before_versions
     or v_after_vacancy_versions <> v_before_vacancy_versions
     or v_after_audit <> v_before_audit
     or v_after_tombstones <> v_before_tombstones then
    raise exception 'dry_run wrote rows';
  end if;

  -- Foreign unowned category key collision BEFORE bootstrap of that key.
  insert into public.reference_categories (key, title, icon_key, status, sort_order)
  values ('content_ref_cat_faq', 'Foreign FAQ', 'help', 'draft', 4);

  v_plan := public.admin_bootstrap_demo_content(false);

  if not exists (
    select 1 from jsonb_array_elements(v_plan->'entries') e
    where e->>'legacy_key' = 'content:reference_category:faq'
      and e->>'action' = 'conflict'
  ) then
    raise exception 'expected category key conflict: %', v_plan;
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_plan->'entries') e
    where e->>'legacy_key' = 'content:reference_article:faq'
      and e->>'action' = 'create'
  ) then
    raise exception 'article created despite category conflict: %', v_plan;
  end if;
  if exists (
    select 1 from public.content_items
    where legacy_key = 'content:reference_article:faq'
  ) then
    raise exception 'orphaned FAQ article row exists';
  end if;

  v_plan2 := public.admin_bootstrap_demo_content(false);
  if exists (
    select 1 from jsonb_array_elements(v_plan2->'entries') e
    where e->>'action' = 'create'
      and e->>'legacy_key' like 'content:home_promo:%'
  ) then
    raise exception 'replay recreated home promo';
  end if;

  if not exists (
    select 1 from public.content_items
    where legacy_key = 'content:home_promo:stuck_with_assignment'
      and status = 'published'
      and origin = 'demo'
      and payload->>'cta_route' = '/help'
  ) then
    raise exception 'home promo seed missing or invalid';
  end if;

  if exists (
    select 1 from public.vacancies
    where legacy_key like 'vacancy:%' and status <> 'draft'
  ) then
    raise exception 'vacancy bootstrap must remain draft';
  end if;

  select id, row_version into v_id, v_rv
  from public.content_items
  where legacy_key = 'content:home_promo:stuck_with_assignment';
  perform public.admin_archive_content(v_id, v_rv);
  perform public.admin_bootstrap_demo_content(false);
  if (select status from public.content_items where id = v_id) is distinct from 'archived' then
    raise exception 'bootstrap resurrected archived demo content';
  end if;

  select id, row_version into v_id, v_rv
  from public.content_items
  where legacy_key = 'content:profile_feed:about';
  perform public.admin_promote_demo_content(v_id, v_rv);
  perform public.admin_bootstrap_demo_content(false);
  if (
    select count(*) from public.content_items
    where legacy_key = 'content:profile_feed:about'
  ) <> 1 then
    raise exception 'bootstrap duplicated promoted row';
  end if;

  raise notice 'ASSERTED_SCENARIOS PASS stage14_1 demo bootstrap roleplay';
end $$;

rollback;
