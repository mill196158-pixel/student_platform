-- Stage 14.1.1 vacancy draft-asset visibility role-play (disposable transaction).
-- Never run against production / never --linked.

begin;

do $$
declare
  v_admin uuid;
  v_student uuid;
  v_group uuid;
  v_vacancy uuid;
  v_row_version int;
  v_draft_rv int;
  v_draft_id uuid;
  v_json jsonb;
  v_asset uuid := gen_random_uuid();
  v_canon uuid := gen_random_uuid();
  v_assets jsonb;
  v_found boolean;
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
  limit 1;

  if v_admin is null then
    raise exception 'stage14_1_1 vacancy media roleplay BLOCKED: missing content.* admin';
  end if;

  select u.id into v_student
  from public.users u
  where u.is_active
    and exists (
      select 1 from public.group_memberships gm
      where gm.user_id = u.id and gm.is_active
    )
  limit 1;
  if v_student is null then
    raise exception 'stage14_1_1 vacancy media roleplay BLOCKED: missing student fixture';
  end if;

  select gm.group_id into v_group
  from public.group_memberships gm
  where gm.user_id = v_student and gm.is_active
  limit 1;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_json := public.admin_create_vacancy_draft(
    jsonb_build_object(
      'title', 'WD vacancy media',
      'company_name', 'Test Co',
      'summary', 'summary',
      'description', 'description body'
    ),
    'admin'
  );
  v_vacancy := (v_json->>'id')::uuid;
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_set_vacancy_audience(
    v_vacancy,
    'groups',
    array[v_group],
    '{}'::uuid[],
    v_row_version
  );
  v_row_version := (v_json->>'row_version')::int;

  -- Canonical asset on the draft vacancy (becomes public after publish).
  insert into public.vacancy_assets (
    id, vacancy_id, title, storage_bucket, storage_path, mime_type, byte_size, created_by
  ) values (
    v_canon, v_vacancy, 'canon', 'content-media',
    'vacancy/' || v_vacancy::text || '/canon-' || v_canon::text || '.jpg',
    'image/jpeg', 100, v_admin
  );

  v_json := public.admin_publish_vacancy(v_vacancy, v_row_version);
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_begin_vacancy_edit(v_vacancy);
  v_draft_id := (v_json->'working_draft'->>'id')::uuid;
  v_draft_rv := (v_json->'working_draft'->>'row_version')::int;
  if v_draft_id is null then
    raise exception 'begin_vacancy_edit missing working_draft.id';
  end if;

  -- Simulate finalize during working edit: asset bound to working_draft_id.
  insert into public.vacancy_assets (
    id, vacancy_id, title, storage_bucket, storage_path, mime_type, byte_size,
    created_by, working_draft_id
  ) values (
    v_asset, v_vacancy, 'draft-only', 'content-media',
    'vacancy/' || v_vacancy::text || '/draft-' || v_asset::text || '.jpg',
    'image/jpeg', 120, v_admin, v_draft_id
  );

  update public.vacancy_working_drafts
  set draft_asset_ids = array[v_asset]
  where id = v_draft_id;

  -- Student must NOT see draft asset; MUST still see canonical.
  perform set_config('request.jwt.claim.sub', v_student::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  v_json := public.get_my_vacancies();
  select exists (
    select 1
    from jsonb_array_elements(v_json) e
    where e->>'id' = v_vacancy::text
  ) into v_found;
  if not v_found then
    raise exception 'published vacancy missing from get_my_vacancies';
  end if;

  select e->'assets' into v_assets
  from jsonb_array_elements(v_json) e
  where e->>'id' = v_vacancy::text
  limit 1;

  if exists (
    select 1 from jsonb_array_elements(v_assets) a where a->>'id' = v_asset::text
  ) then
    raise exception 'draft asset leaked into get_my_vacancies before publish';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_assets) a where a->>'id' = v_canon::text
  ) then
    raise exception 'canonical asset hidden during working draft';
  end if;

  begin
    perform public.authorize_vacancy_asset_download(v_asset);
    raise exception 'student authorize_vacancy_asset_download allowed draft asset';
  exception
    when others then
      if sqlerrm not ilike '%forbidden%' then
        raise;
      end if;
  end;

  -- Publish promotes draft asset atomically.
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_json := public.admin_publish_vacancy_working_draft(v_vacancy, v_draft_rv);
  if coalesce((v_json->>'has_working_draft')::boolean, true) then
    raise exception 'working draft still present after publish';
  end if;
  if exists (
    select 1 from public.vacancy_assets a
    where a.id = v_asset and a.working_draft_id is not null
  ) then
    raise exception 'draft asset not promoted on publish';
  end if;

  perform set_config('request.jwt.claim.sub', v_student::text, true);
  v_json := public.get_my_vacancies();
  select e->'assets' into v_assets
  from jsonb_array_elements(v_json) e
  where e->>'id' = v_vacancy::text
  limit 1;
  if not exists (
    select 1 from jsonb_array_elements(v_assets) a where a->>'id' = v_asset::text
  ) then
    raise exception 'promoted asset missing from get_my_vacancies after publish';
  end if;

  -- Discard path: new working draft + draft asset must not become public.
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_json := public.admin_begin_vacancy_edit(v_vacancy);
  v_draft_id := (v_json->'working_draft'->>'id')::uuid;
  v_draft_rv := (v_json->'working_draft'->>'row_version')::int;

  v_asset := gen_random_uuid();
  insert into public.vacancy_assets (
    id, vacancy_id, title, storage_bucket, storage_path, mime_type, byte_size,
    created_by, working_draft_id
  ) values (
    v_asset, v_vacancy, 'discard-me', 'content-media',
    'vacancy/' || v_vacancy::text || '/discard-' || v_asset::text || '.jpg',
    'image/jpeg', 80, v_admin, v_draft_id
  );

  v_json := public.admin_discard_vacancy_working_draft(v_vacancy);
  if exists (select 1 from public.vacancy_assets a where a.id = v_asset) then
    raise exception 'discard left draft asset in vacancy_assets';
  end if;
  if exists (
    select 1 from public.vacancy_working_drafts d where d.vacancy_id = v_vacancy
  ) then
    raise exception 'discard left working draft row';
  end if;

  perform set_config('request.jwt.claim.sub', v_student::text, true);
  v_json := public.get_my_vacancies();
  select e->'assets' into v_assets
  from jsonb_array_elements(v_json) e
  where e->>'id' = v_vacancy::text
  limit 1;
  if exists (
    select 1 from jsonb_array_elements(v_assets) a where a->>'id' = v_asset::text
  ) then
    raise exception 'discarded draft asset became public';
  end if;

  raise notice 'stage14_1_1 vacancy draft asset visibility roleplay OK';
end;
$$;

rollback;
