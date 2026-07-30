-- Stage 14.1.1 follow-up: working draft target_schema_version + v2→v3 publish path
-- NEW migration only. Does not edit 20260730155714.

alter table public.content_item_working_drafts
  add column if not exists target_schema_version integer null;

comment on column public.content_item_working_drafts.target_schema_version is
  'When set, publish validates and writes this schema_version (e.g. reference 2→3). Null means keep canonical schema_version.';

create or replace function private.content_working_draft_to_json(
  p_draft public.content_item_working_drafts
)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_draft.id,
    'content_item_id', p_draft.content_item_id,
    'base_canonical_row_version', p_draft.base_canonical_row_version,
    'title', p_draft.title,
    'payload', p_draft.payload,
    'priority', p_draft.priority,
    'starts_at', p_draft.starts_at,
    'ends_at', p_draft.ends_at,
    'is_hidden', p_draft.is_hidden,
    'audience_mode', p_draft.audience_mode,
    'audience_group_ids', to_jsonb(p_draft.audience_group_ids),
    'audience_user_ids', to_jsonb(p_draft.audience_user_ids),
    'placement', p_draft.placement,
    'sort_order', p_draft.sort_order,
    'reference_category_id', p_draft.reference_category_id,
    'draft_asset_ids', to_jsonb(p_draft.draft_asset_ids),
    'target_schema_version', p_draft.target_schema_version,
    'row_version', p_draft.row_version,
    'updated_at', p_draft.updated_at
  );
$$;

-- Patch save to accept target_schema_version in p_patch
-- and publish to validate/apply target_schema_version.
-- Re-create save + publish with the upgrade path by reading current bodies is heavy;
-- instead replace validate call sites via create or replace of the two RPCs' critical sections
-- by full recreate from previous migration with amendments.

-- Lightweight helper used by save/publish
create or replace function private.content_working_draft_effective_schema(
  p_canonical_template text,
  p_canonical_schema integer,
  p_target integer
)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_target is null then
    return p_canonical_schema;
  end if;
  if p_canonical_template = 'reference_article_v1'
     and p_canonical_schema in (1, 2)
     and p_target = 3 then
    return 3;
  end if;
  if p_target = p_canonical_schema then
    return p_target;
  end if;
  raise exception 'invalid_schema_upgrade' using errcode = '22023';
end;
$$;

revoke all on function private.content_working_draft_effective_schema(text, integer, integer)
  from public, anon, authenticated;
grant execute on function private.content_working_draft_effective_schema(text, integer, integer)
  to service_role;

-- Upgrade path RPC for reference articles: set draft target to v3
create or replace function public.admin_set_content_working_draft_schema(
  p_id uuid,
  p_expected_draft_row_version integer,
  p_target_schema_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
  v_draft public.content_item_working_drafts;
  v_eff integer;
  v_base jsonb;
begin
  v_uid := private.require_admin_permission('content.write');
  select * into v_row from public.content_items where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  select * into v_draft from public.content_item_working_drafts
    where content_item_id = p_id for update;
  if not found then raise exception 'working_draft_required' using errcode = 'P0001'; end if;
  if v_draft.row_version is distinct from p_expected_draft_row_version then
    raise exception 'conflict' using errcode = 'P0001';
  end if;
  v_eff := private.content_working_draft_effective_schema(
    v_row.template_key, v_row.schema_version, p_target_schema_version
  );
  update public.content_item_working_drafts d
  set target_schema_version = v_eff,
      row_version = d.row_version + 1,
      updated_by = v_uid,
      updated_at = now()
  where d.content_item_id = p_id
  returning * into v_draft;

  if v_row.template_key = 'reference_article_v1' then
    v_base := private.reference_article_admin_json(p_id);
  else
    v_base := private.content_item_to_admin_json(p_id);
  end if;
  return v_base || jsonb_build_object(
    'has_working_draft', true,
    'working_draft', private.content_working_draft_to_json(v_draft)
  );
end;
$$;

revoke all on function public.admin_set_content_working_draft_schema(uuid, integer, integer)
  from public, anon;
grant execute on function public.admin_set_content_working_draft_schema(uuid, integer, integer)
  to authenticated, service_role;

comment on function public.admin_set_content_working_draft_schema(uuid, integer, integer) is
  'Sets working draft target_schema_version (reference 2→3). Does not mutate canonical until publish.';

-- Auto-detect v3-only block types in a payload
create or replace function private.content_payload_needs_reference_v3(p_payload jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select exists (
    select 1
    from jsonb_array_elements(
      case
        when jsonb_typeof(coalesce(p_payload, '{}'::jsonb) -> 'blocks') = 'array'
          then p_payload -> 'blocks'
        else '[]'::jsonb
      end
    ) b
    where jsonb_typeof(b.value) = 'object'
      and b.value->>'type' in ('heading', 'info', 'warning', 'list')
  );
$$;

revoke all on function private.content_payload_needs_reference_v3(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_payload_needs_reference_v3(jsonb)
  to service_role;

-- Patch validate sites via wrappers used only by working-draft RPCs
create or replace function private.content_validate_working_draft_payload(
  p_template_key text,
  p_canonical_schema integer,
  p_target_schema integer,
  p_payload jsonb
)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_eff integer := p_canonical_schema;
  v_target integer := p_target_schema;
begin
  if p_template_key = 'reference_article_v1'
     and private.content_payload_needs_reference_v3(p_payload) then
    v_target := coalesce(v_target, 3);
  end if;
  v_eff := private.content_working_draft_effective_schema(
    p_template_key, p_canonical_schema, v_target
  );
  perform private.validate_content_payload(p_template_key, v_eff, p_payload);
  return v_eff;
end;
$$;

revoke all on function private.content_validate_working_draft_payload(text, integer, integer, jsonb)
  from public, anon, authenticated;
grant execute on function private.content_validate_working_draft_payload(text, integer, integer, jsonb)
  to service_role;

create or replace function public.admin_save_content_working_draft(
  p_id uuid,
  p_expected_draft_row_version integer,
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
  v_draft public.content_item_working_drafts;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_mode text;
  v_place text;
  v_cat uuid;
  v_groups uuid[];
  v_users uuid[];
  v_assets uuid[];
  v_base jsonb;
  v_eff integer;
  v_payload jsonb;
  v_target integer;
begin
  v_uid := private.require_admin_permission('content.write');

  if jsonb_typeof(v_patch) <> 'object' then
    raise exception 'invalid_patch' using errcode = '22023';
  end if;
  if p_expected_draft_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;

  perform private.content_assert_allowed_keys(v_patch, array[
    'title', 'payload', 'priority', 'starts_at', 'ends_at', 'is_hidden',
    'audience_mode', 'audience_group_ids', 'audience_user_ids',
    'placement', 'sort_order', 'reference_category_id', 'draft_asset_ids',
    'target_schema_version'
  ]);

  select * into v_row from public.content_items where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.content_item_working_drafts d
  where d.content_item_id = p_id
  for update;
  if not found then
    raise exception 'working_draft_not_found' using errcode = 'P0002';
  end if;
  if v_draft.row_version <> p_expected_draft_row_version then
    raise exception 'row_version_conflict' using errcode = 'P0001';
  end if;

  if v_patch ? 'payload' then
    if jsonb_typeof(v_patch -> 'payload') <> 'object' then
      raise exception 'invalid_payload_not_object' using errcode = '22023';
    end if;
  end if;

  v_payload := coalesce(v_patch -> 'payload', v_draft.payload);
  if v_patch ? 'target_schema_version' then
    v_target := nullif(v_patch ->> 'target_schema_version', '')::integer;
  else
    v_target := v_draft.target_schema_version;
  end if;

  if v_patch ? 'payload'
     or v_patch ? 'target_schema_version'
     or private.content_payload_needs_reference_v3(v_payload) then
    v_eff := private.content_validate_working_draft_payload(
      v_row.template_key,
      v_row.schema_version,
      v_target,
      v_payload
    );
  end if;

  if v_patch ? 'audience_mode' then
    v_mode := nullif(btrim(coalesce(v_patch ->> 'audience_mode', '')), '');
    if v_mode is null
       or v_mode not in ('all', 'groups', 'users', 'groups_and_users') then
      raise exception 'invalid_audience_mode' using errcode = '22023';
    end if;
  end if;

  if v_patch ? 'placement' then
    v_place := nullif(btrim(coalesce(v_patch ->> 'placement', '')), '');
    if v_place is not null
       and v_place not in ('home_promo', 'profile_feed', 'reference') then
      raise exception 'invalid_placement' using errcode = '22023';
    end if;
  end if;

  if v_patch ? 'reference_category_id' then
    v_cat := nullif(v_patch ->> 'reference_category_id', '')::uuid;
    if v_cat is not null
       and not exists (select 1 from public.reference_categories c where c.id = v_cat) then
      raise exception 'reference_category_missing' using errcode = 'P0002';
    end if;
  end if;

  if v_patch ? 'audience_group_ids' then
    if jsonb_typeof(v_patch -> 'audience_group_ids') <> 'array' then
      raise exception 'invalid_audience_group_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_groups
    from jsonb_array_elements_text(v_patch -> 'audience_group_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  if v_patch ? 'audience_user_ids' then
    if jsonb_typeof(v_patch -> 'audience_user_ids') <> 'array' then
      raise exception 'invalid_audience_user_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_users
    from jsonb_array_elements_text(v_patch -> 'audience_user_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  if v_patch ? 'draft_asset_ids' then
    if jsonb_typeof(v_patch -> 'draft_asset_ids') <> 'array' then
      raise exception 'invalid_draft_asset_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_assets
    from jsonb_array_elements_text(v_patch -> 'draft_asset_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  update public.content_item_working_drafts d set
    title = case
      when v_patch ? 'title' then left(coalesce(v_patch ->> 'title', ''), 200)
      else d.title
    end,
    payload = case when v_patch ? 'payload' then v_patch -> 'payload' else d.payload end,
    priority = case
      when v_patch ? 'priority' then coalesce((v_patch ->> 'priority')::integer, 0)
      else d.priority
    end,
    starts_at = case
      when v_patch ? 'starts_at' then nullif(v_patch ->> 'starts_at', '')::timestamptz
      else d.starts_at
    end,
    ends_at = case
      when v_patch ? 'ends_at' then nullif(v_patch ->> 'ends_at', '')::timestamptz
      else d.ends_at
    end,
    is_hidden = case
      when v_patch ? 'is_hidden' then coalesce((v_patch ->> 'is_hidden')::boolean, false)
      else d.is_hidden
    end,
    audience_mode = case when v_patch ? 'audience_mode' then v_mode else d.audience_mode end,
    audience_group_ids = case
      when v_patch ? 'audience_group_ids' then coalesce(v_groups, '{}'::uuid[])
      else d.audience_group_ids
    end,
    audience_user_ids = case
      when v_patch ? 'audience_user_ids' then coalesce(v_users, '{}'::uuid[])
      else d.audience_user_ids
    end,
    placement = case when v_patch ? 'placement' then v_place else d.placement end,
    sort_order = case
      when v_patch ? 'sort_order' then coalesce((v_patch ->> 'sort_order')::integer, 0)
      else d.sort_order
    end,
    reference_category_id = case
      when v_patch ? 'reference_category_id' then v_cat
      else d.reference_category_id
    end,
    draft_asset_ids = case
      when v_patch ? 'draft_asset_ids' then (
        select coalesce(array_agg(distinct x), '{}'::uuid[])
        from unnest(d.draft_asset_ids || coalesce(v_assets, '{}'::uuid[])) as x
        where x is not null
      )
      else d.draft_asset_ids
    end,
    target_schema_version = case
      when v_eff is not null then v_eff
      else d.target_schema_version
    end,
    row_version = d.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where d.content_item_id = p_id
  returning * into v_draft;

  perform private.content_write_domain_audit(
    'content.save_working_draft',
    'content_item',
    p_id,
    jsonb_build_object(
      'draft_row_version', v_draft.row_version,
      'patched_keys', (
        select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
        from jsonb_object_keys(v_patch) as k
      )
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    v_base := private.reference_article_admin_json(p_id);
  else
    v_base := private.content_item_to_admin_json(p_id);
  end if;

  return v_base || jsonb_build_object(
    'has_working_draft', true,
    'working_draft', private.content_working_draft_to_json(v_draft)
  );
end;
$$;

revoke all on function public.admin_save_content_working_draft(uuid, integer, jsonb)
  from public, anon;
grant execute on function public.admin_save_content_working_draft(uuid, integer, jsonb)
  to authenticated, service_role;

create or replace function public.admin_publish_content_working_draft(
  p_id uuid,
  p_expected_draft_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
  v_draft public.content_item_working_drafts;
  v_allowed text[];
  v_queued integer := 0;
  v_eff integer;
begin
  v_uid := private.require_admin_permission('content.publish');

  if p_expected_draft_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;

  select * into v_row from public.content_items where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.content_item_working_drafts d
  where d.content_item_id = p_id
  for update;
  if not found then
    raise exception 'working_draft_not_found' using errcode = 'P0002';
  end if;

  if v_draft.row_version <> p_expected_draft_row_version then
    raise exception 'row_version_conflict' using errcode = 'P0001';
  end if;
  if v_row.row_version <> v_draft.base_canonical_row_version then
    raise exception 'canonical_changed_rebase_required' using errcode = 'P0001';
  end if;

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  v_eff := private.content_validate_working_draft_payload(
    v_row.template_key,
    v_row.schema_version,
    v_draft.target_schema_version,
    v_draft.payload
  );

  if v_draft.placement is not null then
    select t.allowed_placements into v_allowed
    from public.content_templates t
    where t.key = v_row.template_key
      and t.schema_version = v_eff;
    if v_allowed is null then
      select t.allowed_placements into v_allowed
      from public.content_templates t
      where t.key = v_row.template_key
        and t.schema_version = v_row.schema_version;
    end if;
    if not (v_draft.placement = any (coalesce(v_allowed, '{}'::text[]))) then
      raise exception 'placement_not_allowed_for_template' using errcode = '22023';
    end if;
  end if;

  update public.content_items c set
    schema_version = v_eff,
    title = v_draft.title,
    payload = v_draft.payload,
    priority = v_draft.priority,
    starts_at = v_draft.starts_at,
    ends_at = v_draft.ends_at,
    is_hidden = v_draft.is_hidden,
    audience_mode = v_draft.audience_mode,
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  if v_draft.placement is not null then
    delete from public.content_item_placements where content_item_id = p_id;
    insert into public.content_item_placements (content_item_id, placement, sort_order)
    values (p_id, v_draft.placement, v_draft.sort_order);
  end if;

  delete from public.content_item_audience_groups where content_item_id = p_id;
  insert into public.content_item_audience_groups (content_item_id, group_id)
  select p_id, g
  from unnest(coalesce(v_draft.audience_group_ids, '{}'::uuid[])) as g
  where exists (select 1 from public.groups gr where gr.id = g);

  delete from public.content_item_audience_users where content_item_id = p_id;
  insert into public.content_item_audience_users (content_item_id, user_id)
  select p_id, u
  from unnest(coalesce(v_draft.audience_user_ids, '{}'::uuid[])) as u
  where exists (select 1 from public.users us where us.id = u);

  if v_row.template_key = 'reference_article_v1' then
    if v_draft.reference_category_id is null then
      raise exception 'reference_category_required' using errcode = 'P0001';
    end if;
    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (p_id, v_draft.reference_category_id)
    on conflict (content_item_id) do update
      set reference_category_id = excluded.reference_category_id;
  elsif v_draft.reference_category_id is not null then
    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (p_id, v_draft.reference_category_id)
    on conflict (content_item_id) do update
      set reference_category_id = excluded.reference_category_id;
  end if;

  perform private.content_assert_payload_assets(p_id);
  perform private.content_assert_audience_consistent(p_id);
  perform private.reference_assert_publishable(p_id);

  perform private.content_snapshot_version(p_id);

  -- Orphan draft-only assets not referenced by canonical/versions after publish.
  v_queued := private.content_queue_orphan_draft_assets(
    p_id, v_draft.draft_asset_ids, v_draft.title
  );

  delete from public.content_item_working_drafts where content_item_id = p_id;

  -- Intentionally NO notification / outbox side effects.
  perform private.content_write_domain_audit(
    'content.publish_working_draft',
    'content_item',
    p_id,
    jsonb_build_object(
      'row_version', v_row.row_version,
      'version_number', v_row.version_number,
      'schema_version', v_row.schema_version,
      'queued_orphan_assets', v_queued
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    return private.reference_article_admin_json(p_id);
  end if;
  return private.content_item_to_admin_json(p_id);
end;
$$;

revoke all on function public.admin_publish_content_working_draft(uuid, integer)
  from public, anon;
grant execute on function public.admin_publish_content_working_draft(uuid, integer)
  to authenticated, service_role;
