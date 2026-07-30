-- Stage 14.1.3 vacancy visual-role working-draft isolation (disposable).
-- Never run against production / never --linked.

begin;

do $$
declare
  v_admin uuid;
  v_group uuid;
  v_vacancy uuid;
  v_row_version int;
  v_draft_rv int;
  v_draft_id uuid;
  v_json jsonb;
  v_canon uuid := gen_random_uuid();
  v_draft_asset uuid := gen_random_uuid();
  v_role text;
  v_canon_role text;
  v_is_canonical boolean;
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
  limit 1;
  if v_admin is null then
    raise exception 'stage14_1_3 roleplay BLOCKED: missing content.* admin';
  end if;

  select gm.group_id into v_group
  from public.group_memberships gm
  where gm.is_active
  limit 1;
  if v_group is null then
    raise exception 'stage14_1_3 roleplay BLOCKED: missing group fixture';
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_json := public.admin_create_vacancy_draft(
    jsonb_build_object(
      'title', 'WD visual role vacancy',
      'company_name', 'Test Co',
      'summary', 'summary',
      'description', 'description body'
    ),
    'admin'
  );
  v_vacancy := (v_json->>'id')::uuid;
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_set_vacancy_audience(
    v_vacancy, 'groups', array[v_group], '{}'::uuid[], v_row_version
  );
  v_row_version := (v_json->>'row_version')::int;

  insert into public.vacancy_assets (
    id, vacancy_id, title, storage_bucket, storage_path, mime_type, byte_size,
    created_by, role
  ) values (
    v_canon, v_vacancy, 'canon-logo', 'content-media',
    'vacancy/' || v_vacancy::text || '/canon-' || v_canon::text || '.jpg',
    'image/jpeg', 100, v_admin, 'logo'
  );

  v_json := public.admin_publish_vacancy(v_vacancy, v_row_version);
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_begin_vacancy_edit(v_vacancy);
  v_draft_id := (v_json->'working_draft'->>'id')::uuid;

  insert into public.vacancy_assets (
    id, vacancy_id, title, storage_bucket, storage_path, mime_type, byte_size,
    created_by, role, working_draft_id
  ) values (
    v_draft_asset, v_vacancy, 'draft-logo', 'content-media',
    'vacancy/' || v_vacancy::text || '/draft-' || v_draft_asset::text || '.jpg',
    'image/jpeg', 120, v_admin, 'attachment', v_draft_id
  );

  perform public.admin_set_vacancy_asset_role(v_draft_asset, 'logo');

  select a.role into v_canon_role
  from public.vacancy_assets a where a.id = v_canon;
  if v_canon_role is distinct from 'logo' then
    raise exception 'canonical logo demoted during WD set_role: %', v_canon_role;
  end if;

  select a.role into v_role
  from public.vacancy_assets a where a.id = v_draft_asset;
  if v_role is distinct from 'logo' then
    raise exception 'draft logo role not set: %', v_role;
  end if;

  perform public.admin_clear_vacancy_visual_role(v_vacancy, 'logo');

  if not exists (select 1 from public.vacancy_assets a where a.id = v_canon) then
    raise exception 'clear during WD deleted canonical logo';
  end if;
  if exists (select 1 from public.vacancy_assets a where a.id = v_draft_asset) then
    raise exception 'clear during WD did not delete draft logo';
  end if;
  if not exists (
    select 1
    from public.vacancy_working_drafts d
    where d.id = v_draft_id and 'logo' = any (d.cleared_visual_roles)
  ) then
    raise exception 'clear intent not recorded on working draft';
  end if;

  perform public.admin_discard_vacancy_working_draft(v_vacancy);
  select a.role into v_canon_role from public.vacancy_assets a where a.id = v_canon;
  if v_canon_role is distinct from 'logo' then
    raise exception 'discard changed canonical logo role: %', v_canon_role;
  end if;

  v_json := public.admin_begin_vacancy_edit(v_vacancy);
  v_draft_id := (v_json->'working_draft'->>'id')::uuid;
  v_draft_asset := gen_random_uuid();
  insert into public.vacancy_assets (
    id, vacancy_id, title, storage_bucket, storage_path, mime_type, byte_size,
    created_by, role, working_draft_id
  ) values (
    v_draft_asset, v_vacancy, 'draft-logo-2', 'content-media',
    'vacancy/' || v_vacancy::text || '/draft2-' || v_draft_asset::text || '.jpg',
    'image/jpeg', 130, v_admin, 'attachment', v_draft_id
  );
  perform public.admin_set_vacancy_asset_role(v_draft_asset, 'logo');
  v_draft_rv := (
    select d.row_version from public.vacancy_working_drafts d where d.id = v_draft_id
  );
  perform public.admin_publish_vacancy_working_draft(v_vacancy, v_draft_rv);

  if exists (select 1 from public.vacancy_assets a where a.id = v_canon) then
    raise exception 'publish did not remove superseded canonical logo';
  end if;

  select a.role, (a.working_draft_id is null)
    into v_role, v_is_canonical
  from public.vacancy_assets a
  where a.id = v_draft_asset;
  if v_role is distinct from 'logo' or not v_is_canonical then
    raise exception 'publish did not promote draft logo: role=% canonical=%',
      v_role, v_is_canonical;
  end if;

  -- Latest snapshot must reflect post-reconcile assets (promoted, not draft-bound).
  if not exists (
    select 1
    from public.vacancy_versions vv
    where vv.vacancy_id = v_vacancy
      and vv.version_number = (
        select max(version_number) from public.vacancy_versions
        where vacancy_id = v_vacancy
      )
      and (vv.snapshot -> 'asset_ids') @> jsonb_build_array(v_draft_asset)
      and not ((vv.snapshot -> 'asset_ids') @> jsonb_build_array(v_canon))
      and coalesce(vv.snapshot -> 'draft_asset_ids', '[]'::jsonb) = '[]'::jsonb
      and coalesce(vv.snapshot -> 'has_working_draft', 'false'::jsonb) = 'false'::jsonb
  ) then
    raise exception 'publish snapshot missing reconciled visual assets';
  end if;
end;
$$;

rollback;
