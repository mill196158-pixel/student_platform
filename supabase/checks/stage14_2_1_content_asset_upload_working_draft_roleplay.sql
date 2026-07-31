-- Stage 14.2.1 — content asset upload against working draft (roleplay).
-- LOCAL / disposable: begin … rollback. Never --linked / never production.
-- Requires apply of
--   20260731102302_stage14_2_1_content_asset_upload_working_draft.sql

-- ---------------------------------------------------------------------------
-- Static contract checks
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private'
    and p.proname = 'content_assert_asset_upload_allowed';
  if v_def is null then
    raise exception 'FAIL: content_assert_asset_upload_allowed missing';
  end if;
  if v_def not ilike '%working_draft_required%'
     or v_def not ilike '%archived_immutable%' then
    raise exception 'FAIL: upload helper missing expected errors';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'content_asset_upload_intents'
      and column_name = 'bound_to_working_draft'
  ) then
    raise exception 'FAIL: bound_to_working_draft column missing';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'content_asset_upload_intents'
      and column_name = 'finalized_working_draft_row_version'
  ) then
    raise exception 'FAIL: finalized_working_draft_row_version column missing';
  end if;

  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'admin_finalize_content_asset_upload';
  if v_def is null or v_def not ilike '%for update%' then
    raise exception 'FAIL: finalize must lock rows';
  end if;
  if v_def not ilike '%content_items%'
     or v_def not ilike '%content_item_working_drafts%'
     or v_def not ilike '%content_asset_upload_intents%' then
    raise exception 'FAIL: finalize lock order tables incomplete';
  end if;
  if v_def not ilike '%draft_asset_ids%'
     or v_def not ilike '%finalized_working_draft_row_version%' then
    raise exception 'FAIL: finalize missing WD asset / snapshot handling';
  end if;

  raise notice 'stage14_2_1 content asset upload working draft static OK';
end;
$$;

-- ---------------------------------------------------------------------------
-- Behavioral roleplay (disposable transaction)
-- ---------------------------------------------------------------------------
begin;

do $$
declare
  v_admin uuid;
  v_other uuid;
  v_item uuid;
  v_row_version int;
  v_draft_id uuid;
  v_draft_rv int;
  v_draft_rv_after int;
  v_json jsonb;
  v_intent jsonb;
  v_intent_id uuid;
  v_path text;
  v_asset jsonb;
  v_asset_id uuid;
  v_asset2 jsonb;
  v_payload jsonb := jsonb_build_object(
    'title', '14.2.1 upload WD',
    'subtitle', 'Working draft media',
    'icon_key', 'help',
    'gradient_colors', jsonb_build_array('#7367F0', '#B784F7'),
    'cta_label', 'Open',
    'cta_route', '/diary',
    'dismissible', true
  );
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
  limit 1;

  if v_admin is null then
    raise notice 'stage14_2_1 roleplay SKIP: missing content.* admin fixture';
    return;
  end if;

  select u.id into v_other
  from public.users u
  where u.id is distinct from v_admin
    and not exists (
      select 1
      from public.admin_role_assignments a
      where a.user_id = u.id
        and a.is_active
        and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    )
  limit 1;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text,
    true
  );

  v_json := public.admin_create_content_draft(
    'home_promo_v1', 1, '14.2.1 upload WD', v_payload, 'admin'
  );
  v_item := (v_json->>'id')::uuid;
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_set_content_placements(
    v_item,
    jsonb_build_array(jsonb_build_object('placement', 'home_promo', 'sort_order', 0)),
    v_row_version
  );
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_publish_content(v_item, v_row_version);
  v_row_version := (v_json->>'row_version')::int;

  -- 1) published without WD → working_draft_required
  begin
    perform public.admin_create_content_asset_upload_intent(
      v_item, 'image/png', 900
    );
    raise exception 'FAIL: expected working_draft_required without WD';
  exception when others then
    if sqlerrm like 'FAIL: expected%' then
      raise;
    end if;
    if sqlerrm not ilike '%working_draft_required%'
       and sqlerrm not ilike '%draft_only%' then
      raise exception 'FAIL: unexpected error without WD: %', sqlerrm;
    end if;
  end;

  -- 2) begin edit → create intent allowed + bound
  v_json := public.admin_begin_content_edit(v_item);
  v_draft_id := (v_json->'working_draft'->>'id')::uuid;
  v_draft_rv := (v_json->'working_draft'->>'row_version')::int;
  if v_draft_id is null then
    raise exception 'FAIL: begin_edit missing working_draft';
  end if;

  v_intent := public.admin_create_content_asset_upload_intent(
    v_item, 'image/png', 900
  );
  v_intent_id := (v_intent->>'intent_id')::uuid;
  if v_intent_id is null then
    raise exception 'FAIL: create intent missing intent_id';
  end if;
  if coalesce((v_intent->>'bound_to_working_draft')::boolean, false) is not true then
    raise exception 'FAIL: intent must bind to working draft';
  end if;
  if (v_intent->>'working_draft_id')::uuid is distinct from v_draft_id then
    raise exception 'FAIL: intent WD mismatch';
  end if;

  -- 3) editor without content.write → forbidden
  if v_other is not null then
    perform set_config('request.jwt.claim.sub', v_other::text, true);
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub', v_other::text, 'role', 'authenticated')::text,
      true
    );
    begin
      perform public.admin_create_content_asset_upload_intent(
        v_item, 'image/png', 900
      );
      raise exception 'FAIL: expected forbidden for non-writer';
    exception when others then
      if sqlerrm like 'FAIL: expected%' then
        raise;
      end if;
      if sqlerrm not ilike '%forbidden%'
         and sqlerrm not ilike '%permission%'
         and sqlerrm not ilike '%42501%' then
        raise exception 'FAIL: unexpected non-writer error: %', sqlerrm;
      end if;
    end;
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub', v_admin::text, 'role', 'authenticated')::text,
      true
    );
  end if;

  -- 4) finalize without storage → fail closed
  begin
    perform public.admin_finalize_content_asset_upload(v_intent_id, 'hero');
    raise exception 'FAIL: expected storage_object_missing';
  exception when others then
    if sqlerrm like 'FAIL: expected%' then
      raise;
    end if;
    if sqlerrm not ilike '%storage_object_missing%'
       and sqlerrm not ilike '%storage%' then
      raise exception 'FAIL: unexpected finalize-without-object: %', sqlerrm;
    end if;
  end;

  -- Seed storage object via service path resolver
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text,
    true
  );
  v_path := (
    public.service_content_upload_intent_storage_path(v_intent_id)
      ->>'storage_path'
  );
  if v_path is null or length(v_path) = 0 then
    raise exception 'FAIL: service path resolver empty';
  end if;
  insert into storage.objects (bucket_id, name, owner, metadata)
  values (
    'content-media',
    v_path,
    v_admin,
    jsonb_build_object('mimetype', 'image/png', 'size', '1024')
  );

  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text,
    true
  );

  -- 5) finalize → draft_asset_ids + row_version bump + snapshots
  v_asset := public.admin_finalize_content_asset_upload(v_intent_id, 'hero');
  v_asset_id := (v_asset->>'id')::uuid;
  if v_asset_id is null then
    raise exception 'FAIL: finalize missing asset id';
  end if;
  if coalesce((v_asset->>'bound_to_working_draft')::boolean, false) is not true then
    raise exception 'FAIL: finalize must report bound_to_working_draft';
  end if;
  if (v_asset->>'working_draft_id')::uuid is distinct from v_draft_id then
    raise exception 'FAIL: finalize WD id mismatch';
  end if;
  v_draft_rv_after := (v_asset->>'working_draft_row_version')::int;
  if v_draft_rv_after is null or v_draft_rv_after <= v_draft_rv then
    raise exception 'FAIL: finalize must increment working_draft_row_version';
  end if;

  if not exists (
    select 1
    from public.content_item_working_drafts d
    where d.id = v_draft_id
      and v_asset_id = any (coalesce(d.draft_asset_ids, '{}'::uuid[]))
      and d.row_version = v_draft_rv_after
  ) then
    raise exception 'FAIL: draft_asset_ids / row_version not updated';
  end if;

  if not exists (
    select 1
    from public.content_asset_upload_intents i
    where i.id = v_intent_id
      and i.finalized_asset_id = v_asset_id
      and i.finalized_working_draft_id = v_draft_id
      and i.finalized_working_draft_row_version = v_draft_rv_after
  ) then
    raise exception 'FAIL: finalize snapshots missing on intent';
  end if;

  -- 6) idempotent finalize retry → same snapshots, no second RV bump
  v_asset2 := public.admin_finalize_content_asset_upload(v_intent_id, 'hero');
  if (v_asset2->>'id')::uuid is distinct from v_asset_id then
    raise exception 'FAIL: idempotent finalize changed asset id';
  end if;
  if (v_asset2->>'working_draft_row_version')::int is distinct from v_draft_rv_after then
    raise exception 'FAIL: idempotent finalize must not bump RV again';
  end if;
  if exists (
    select 1
    from public.content_item_working_drafts d
    where d.id = v_draft_id
      and d.row_version is distinct from v_draft_rv_after
  ) then
    raise exception 'FAIL: idempotent finalize mutated draft row_version';
  end if;

  -- 7) discard → create intent forbidden again; finalize-after-discard rejected
  perform public.admin_discard_content_working_draft(v_item);

  begin
    perform public.admin_create_content_asset_upload_intent(
      v_item, 'image/png', 900
    );
    raise exception 'FAIL: expected working_draft_required after discard';
  exception when others then
    if sqlerrm like 'FAIL: expected%' then
      raise;
    end if;
    if sqlerrm not ilike '%working_draft_required%'
       and sqlerrm not ilike '%draft_only%' then
      raise exception 'FAIL: unexpected after discard create: %', sqlerrm;
    end if;
  end;

  -- Fresh WD + intent, then discard before finalize
  v_json := public.admin_begin_content_edit(v_item);
  v_draft_id := (v_json->'working_draft'->>'id')::uuid;
  v_intent := public.admin_create_content_asset_upload_intent(
    v_item, 'image/png', 900
  );
  v_intent_id := (v_intent->>'intent_id')::uuid;

  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text,
    true
  );
  v_path := (
    public.service_content_upload_intent_storage_path(v_intent_id)
      ->>'storage_path'
  );
  insert into storage.objects (bucket_id, name, owner, metadata)
  values (
    'content-media',
    v_path,
    v_admin,
    jsonb_build_object('mimetype', 'image/png', 'size', '512')
  );
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text,
    true
  );

  perform public.admin_discard_content_working_draft(v_item);

  begin
    perform public.admin_finalize_content_asset_upload(v_intent_id, 'orphan');
    raise exception 'FAIL: expected working_draft_required on finalize-after-discard';
  exception when others then
    if sqlerrm like 'FAIL: expected%' then
      raise;
    end if;
    if sqlerrm not ilike '%working_draft_required%'
       and sqlerrm not ilike '%draft_only%' then
      raise exception 'FAIL: unexpected finalize-after-discard: %', sqlerrm;
    end if;
  end;

  raise notice 'STAGE14_2_1_CONTENT_ASSET_UPLOAD_WORKING_DRAFT_ROLEPLAY PASS';
end;
$$;

rollback;
