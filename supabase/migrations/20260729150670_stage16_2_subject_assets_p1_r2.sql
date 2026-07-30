-- Stage 16.2 P1 R2: nullable created_by for service_role register; current-only path.
-- LOCAL ONLY.

create or replace function public.admin_register_subject_asset(
  p_subject_catalog_id uuid,
  p_subject_offering_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_title text default '',
  p_checksum text default null,
  p_supersedes_asset_id uuid default null,
  p_asset_kind text default 'attachment',
  p_logical_asset_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  -- Nullable created_by when invoked as pure service_role (no JWT sub).
  return private.register_subject_asset(
    v_uid,
    p_subject_catalog_id,
    p_subject_offering_id,
    p_storage_path,
    p_mime_type,
    p_byte_size,
    p_title,
    p_checksum,
    p_supersedes_asset_id,
    p_asset_kind,
    p_logical_asset_id
  );
end;
$$;

-- Ensure private.register accepts null actor (created_by nullable column).
create or replace function private.register_subject_asset(
  p_actor_id uuid,
  p_subject_catalog_id uuid,
  p_subject_offering_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_title text default '',
  p_checksum text default null,
  p_supersedes_asset_id uuid default null,
  p_asset_kind text default 'attachment',
  p_logical_asset_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.subject_assets;
  v_row public.subject_assets;
  v_version integer := 1;
  v_logical uuid;
begin
  if (p_subject_catalog_id is null) = (p_subject_offering_id is null) then
    raise exception 'exactly_one_owner_required' using errcode = '22023';
  end if;
  if p_asset_kind not in ('hero_image', 'attachment') then
    raise exception 'invalid_asset_kind' using errcode = '22023';
  end if;

  perform private.subject_asset_assert_object(
    'subject-media', p_storage_path, p_mime_type, p_byte_size, p_asset_kind
  );

  if p_subject_catalog_id is not null then
    perform 1 from public.subject_catalog where id = p_subject_catalog_id for update;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  else
    perform 1 from public.subject_offerings where id = p_subject_offering_id for update;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  end if;

  perform 1
  from public.subject_assets a
  where (
      (p_subject_catalog_id is not null and a.subject_catalog_id = p_subject_catalog_id)
      or (p_subject_offering_id is not null and a.subject_offering_id = p_subject_offering_id)
    )
  for update;

  if p_supersedes_asset_id is not null then
    select * into v_prev
    from public.subject_assets
    where id = p_supersedes_asset_id
    for update;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    if v_prev.subject_catalog_id is distinct from p_subject_catalog_id
       or v_prev.subject_offering_id is distinct from p_subject_offering_id then
      raise exception 'asset_foreign_owner' using errcode = '42501';
    end if;
    if v_prev.asset_kind is distinct from p_asset_kind then
      raise exception 'asset_kind_mismatch' using errcode = '22023';
    end if;
    if not v_prev.is_current then
      raise exception 'predecessor_not_current' using errcode = '55000';
    end if;
    v_logical := v_prev.logical_asset_id;
    v_version := v_prev.version_number + 1;
    update public.subject_assets
    set is_current = false
    where id = p_supersedes_asset_id
      and is_current;
    if not found then
      raise exception 'predecessor_race' using errcode = '40001';
    end if;
  else
    v_logical := coalesce(p_logical_asset_id, gen_random_uuid());
    if exists (
      select 1 from public.subject_assets a
      where a.is_current
        and a.logical_asset_id = v_logical
        and (
          (p_subject_catalog_id is not null and a.subject_catalog_id = p_subject_catalog_id)
          or (p_subject_offering_id is not null and a.subject_offering_id = p_subject_offering_id)
        )
    ) then
      raise exception 'current_asset_exists_use_supersede' using errcode = '23505';
    end if;
    if p_asset_kind = 'hero_image' and exists (
      select 1 from public.subject_assets a
      where a.is_current
        and a.asset_kind = 'hero_image'
        and (
          (p_subject_catalog_id is not null and a.subject_catalog_id = p_subject_catalog_id)
          or (p_subject_offering_id is not null and a.subject_offering_id = p_subject_offering_id)
        )
    ) then
      raise exception 'hero_image_exists_use_supersede' using errcode = '23505';
    end if;
  end if;

  insert into public.subject_assets (
    subject_catalog_id, subject_offering_id, title, storage_bucket,
    storage_path, mime_type, byte_size, checksum, version_number,
    supersedes_asset_id, is_current, created_by, asset_kind, logical_asset_id
  ) values (
    p_subject_catalog_id,
    p_subject_offering_id,
    left(coalesce(p_title, ''), 200),
    'subject-media',
    p_storage_path,
    p_mime_type,
    p_byte_size,
    nullif(btrim(coalesce(p_checksum, '')), ''),
    v_version,
    p_supersedes_asset_id,
    true,
    p_actor_id,
    p_asset_kind,
    v_logical
  )
  returning * into v_row;

  perform private.admin_write_audit(
    'subject_asset.register',
    case when p_subject_catalog_id is not null
      then 'subject_catalog' else 'subject_offering' end,
    coalesce(p_subject_catalog_id, p_subject_offering_id)::text,
    jsonb_build_object(
      'asset_id', v_row.id,
      'asset_kind', v_row.asset_kind,
      'logical_asset_id', v_row.logical_asset_id,
      'mime_type', v_row.mime_type,
      'byte_size', v_row.byte_size,
      'version_number', v_row.version_number,
      'actor_id', p_actor_id
    )
  );

  return private.subject_asset_descriptor_json(v_row.id);
end;
$$;

revoke all on function private.register_subject_asset(
  uuid, uuid, uuid, text, text, bigint, text, text, uuid, text, uuid
) from public, anon, authenticated;
grant execute on function private.register_subject_asset(
  uuid, uuid, uuid, text, text, bigint, text, text, uuid, text, uuid
) to service_role;

-- Narrow authorize/sign race: only current assets.
create or replace function public.service_subject_asset_storage_path(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.subject_assets;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  select * into v_row
  from public.subject_assets
  where id = p_asset_id
    and is_current;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'storage_bucket', v_row.storage_bucket,
    'storage_path', v_row.storage_path,
    'mime_type', v_row.mime_type
  );
end;
$$;
