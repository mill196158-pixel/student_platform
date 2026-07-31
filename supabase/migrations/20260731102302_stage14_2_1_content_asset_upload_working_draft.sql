-- Stage 14.2.1: allow content-media upload for published items that have an
-- open working draft. Bind intents to that draft; never upload into published
-- payload without a working draft. Classic status=draft items still upload.
-- Does not enable/disable feature flags. Does not mutate existing published rows.

-- ---------------------------------------------------------------------------
-- 1. Intent columns: WD binding + immutable finalize snapshots
-- ---------------------------------------------------------------------------
alter table public.content_asset_upload_intents
  add column if not exists working_draft_id uuid null
    references public.content_item_working_drafts (id) on delete set null,
  add column if not exists bound_to_working_draft boolean not null default false,
  add column if not exists finalized_working_draft_id uuid null,
  add column if not exists finalized_working_draft_row_version integer null;

comment on column public.content_asset_upload_intents.working_draft_id is
  'Working draft bound at createUpload. ON DELETE SET NULL; use bound_to_working_draft to avoid classic-draft fallback.';
comment on column public.content_asset_upload_intents.bound_to_working_draft is
  'Immutable: true when intent was created against a working draft.';
comment on column public.content_asset_upload_intents.finalized_working_draft_id is
  'Snapshot of draft id at finalize (no FK). Used for idempotent retry.';
comment on column public.content_asset_upload_intents.finalized_working_draft_row_version is
  'Post-increment draft row_version snapshot at finalize.';

create index if not exists content_asset_upload_intents_working_draft_idx
  on public.content_asset_upload_intents (working_draft_id)
  where working_draft_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Upload eligibility helper
-- ---------------------------------------------------------------------------
create or replace function private.content_assert_asset_upload_allowed(
  p_content_item_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.content_items;
  v_draft_id uuid;
begin
  select * into v_item
  from public.content_items ci
  where ci.id = p_content_item_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_item.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  select d.id into v_draft_id
  from public.content_item_working_drafts d
  where d.content_item_id = p_content_item_id
  for update;
  if found then
    return v_draft_id;
  end if;

  if v_item.status = 'draft' then
    return null;
  end if;

  raise exception 'working_draft_required' using errcode = '55000';
end;
$$;

revoke all on function private.content_assert_asset_upload_allowed(uuid)
  from public, anon, authenticated;
grant execute on function private.content_assert_asset_upload_allowed(uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- 3. Create upload intent
-- ---------------------------------------------------------------------------
create or replace function public.admin_create_content_asset_upload_intent(
  p_content_item_id uuid,
  p_mime_type text,
  p_ttl_seconds integer default 900
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_mime text := lower(btrim(coalesce(p_mime_type, '')));
  v_path text;
  v_id uuid;
  v_ttl integer := greatest(60, least(coalesce(p_ttl_seconds, 900), 3600));
  v_draft_id uuid;
  v_expires timestamptz;
begin
  v_uid := private.require_admin_permission('content.write');
  v_draft_id := private.content_assert_asset_upload_allowed(p_content_item_id);

  if v_mime not in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  ) then
    raise exception 'invalid_mime' using errcode = '22023';
  end if;

  v_path := 'content/' || p_content_item_id::text || '/' || gen_random_uuid()::text
    || case
      when v_mime = 'application/pdf' then '.pdf'
      when v_mime = 'image/png' then '.png'
      when v_mime = 'image/webp' then '.webp'
      else '.jpg'
    end;

  v_expires := now() + make_interval(secs => v_ttl);

  insert into public.content_asset_upload_intents (
    content_item_id,
    actor_user_id,
    storage_path,
    mime_type,
    expires_at,
    working_draft_id,
    bound_to_working_draft
  ) values (
    p_content_item_id,
    v_uid,
    v_path,
    v_mime,
    v_expires,
    v_draft_id,
    (v_draft_id is not null)
  )
  returning id into v_id;

  return jsonb_build_object(
    'intent_id', v_id,
    'mime_type', v_mime,
    'expires_at', v_expires,
    'working_draft_id', v_draft_id,
    'bound_to_working_draft', (v_draft_id is not null)
  );
end;
$$;

revoke all on function public.admin_create_content_asset_upload_intent(uuid, text, integer)
  from public, anon;
grant execute on function public.admin_create_content_asset_upload_intent(uuid, text, integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Finalize upload (canonical locks: item → draft → intent)
-- ---------------------------------------------------------------------------
create or replace function public.admin_finalize_content_asset_upload(
  p_intent_id uuid,
  p_title text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_peek public.content_asset_upload_intents;
  v_intent public.content_asset_upload_intents;
  v_item public.content_items;
  v_draft public.content_item_working_drafts;
  v_draft_locked boolean := false;
  v_obj record;
  v_asset public.content_assets;
  v_meta jsonb;
  v_size bigint;
  v_mime text;
  v_title text := left(coalesce(p_title, ''), 200);
  v_assets uuid[];
begin
  v_uid := private.require_admin_permission('content.write');

  -- 1) Discovery only (no authz decisions from this snapshot).
  select * into v_peek
  from public.content_asset_upload_intents
  where id = p_intent_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- 2) Lock content item (canonical order: item → draft → intent).
  select * into v_item
  from public.content_items ci
  where ci.id = v_peek.content_item_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- 3) Lock working draft when discovery saw a binding target.
  if v_peek.bound_to_working_draft and v_peek.working_draft_id is not null then
    select * into v_draft
    from public.content_item_working_drafts d
    where d.id = v_peek.working_draft_id
      and d.content_item_id = v_peek.content_item_id
    for update;
    v_draft_locked := found;
  end if;

  -- 4) Lock intent and re-read authoritatively.
  select * into v_intent
  from public.content_asset_upload_intents
  where id = p_intent_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_intent.actor_user_id is distinct from v_uid then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_intent.content_item_id is distinct from v_item.id then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Idempotent retry: return persisted finalize snapshots only.
  if v_intent.finalized_asset_id is not null then
    select * into v_asset
    from public.content_assets
    where id = v_intent.finalized_asset_id;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    return jsonb_build_object(
      'id', v_asset.id,
      'mime_type', v_asset.mime_type,
      'byte_size', v_asset.byte_size,
      'title', coalesce(nullif(btrim(v_title), ''), ''),
      'working_draft_id', v_intent.finalized_working_draft_id,
      'working_draft_row_version', v_intent.finalized_working_draft_row_version,
      'bound_to_working_draft', v_intent.bound_to_working_draft
    );
  end if;

  if v_intent.expires_at < now() then
    raise exception 'intent_expired' using errcode = 'P0001';
  end if;

  if v_item.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  if v_intent.bound_to_working_draft then
    if v_intent.working_draft_id is null then
      raise exception 'working_draft_required' using errcode = '55000';
    end if;
    if not v_draft_locked
       or v_draft.id is distinct from v_intent.working_draft_id then
      select * into v_draft
      from public.content_item_working_drafts d
      where d.id = v_intent.working_draft_id
        and d.content_item_id = v_intent.content_item_id
      for update;
      if not found then
        raise exception 'working_draft_required' using errcode = '55000';
      end if;
    end if;
  else
    if v_item.status is distinct from 'draft' then
      raise exception 'working_draft_required' using errcode = '55000';
    end if;
  end if;

  select o.name, o.metadata
    into v_obj
  from storage.objects o
  where o.bucket_id = v_intent.storage_bucket
    and o.name = v_intent.storage_path;
  if not found then
    raise exception 'storage_object_missing' using errcode = 'P0002';
  end if;

  v_meta := coalesce(v_obj.metadata, '{}'::jsonb);
  v_size := coalesce(
    nullif(v_meta->>'size', '')::bigint,
    nullif(v_meta->>'contentLength', '')::bigint
  );
  v_mime := lower(coalesce(
    nullif(v_meta->>'mimetype', ''),
    nullif(v_meta->>'contentType', ''),
    ''
  ));
  if v_mime = '' then
    raise exception 'storage_mime_missing' using errcode = '22023';
  end if;
  if v_size is null or v_size <= 0 or v_size > 20 * 1024 * 1024 then
    raise exception 'invalid_byte_size' using errcode = '22023';
  end if;
  if v_mime is distinct from v_intent.mime_type then
    raise exception 'mime_mismatch' using errcode = '22023';
  end if;
  if v_intent.storage_path !~ ('^content/' || v_intent.content_item_id::text || '/') then
    raise exception 'invalid_storage_path' using errcode = '22023';
  end if;

  insert into public.content_assets (
    content_item_id, storage_bucket, storage_path, mime_type, byte_size, created_by
  ) values (
    v_intent.content_item_id,
    v_intent.storage_bucket,
    v_intent.storage_path,
    v_mime,
    v_size,
    v_uid
  )
  returning * into v_asset;

  if v_intent.bound_to_working_draft then
    v_assets := coalesce(v_draft.draft_asset_ids, '{}'::uuid[]);
    if not (v_asset.id = any (v_assets)) then
      v_assets := array_append(v_assets, v_asset.id);
    end if;

    update public.content_item_working_drafts d
    set draft_asset_ids = v_assets,
        row_version = d.row_version + 1,
        updated_at = now(),
        updated_by = v_uid
    where d.id = v_draft.id
    returning * into v_draft;

    update public.content_asset_upload_intents
    set finalized_asset_id = v_asset.id,
        finalized_working_draft_id = v_draft.id,
        finalized_working_draft_row_version = v_draft.row_version
    where id = p_intent_id;

    perform private.admin_write_audit(
      'content_asset.finalize',
      'content_item',
      v_intent.content_item_id::text,
      jsonb_build_object(
        'asset_id', v_asset.id,
        'mime_type', v_mime,
        'byte_size', v_size,
        'working_draft_id', v_draft.id,
        'working_draft_row_version', v_draft.row_version
      )
    );

    return jsonb_build_object(
      'id', v_asset.id,
      'mime_type', v_asset.mime_type,
      'byte_size', v_asset.byte_size,
      'title', v_title,
      'working_draft_id', v_draft.id,
      'working_draft_row_version', v_draft.row_version,
      'bound_to_working_draft', true
    );
  end if;

  update public.content_asset_upload_intents
  set finalized_asset_id = v_asset.id,
      finalized_working_draft_id = null,
      finalized_working_draft_row_version = null
  where id = p_intent_id;

  perform private.admin_write_audit(
    'content_asset.finalize',
    'content_item',
    v_intent.content_item_id::text,
    jsonb_build_object(
      'asset_id', v_asset.id,
      'mime_type', v_mime,
      'byte_size', v_size,
      'bound_to_working_draft', false
    )
  );

  return jsonb_build_object(
    'id', v_asset.id,
    'mime_type', v_asset.mime_type,
    'byte_size', v_asset.byte_size,
    'title', v_title,
    'working_draft_id', null,
    'working_draft_row_version', null,
    'bound_to_working_draft', false
  );
end;
$$;

revoke all on function public.admin_finalize_content_asset_upload(uuid, text)
  from public, anon;
grant execute on function public.admin_finalize_content_asset_upload(uuid, text)
  to authenticated, service_role;

comment on function public.admin_create_content_asset_upload_intent(uuid, text, integer) is
  'Stage 14.2.1: create upload intent for draft items or published items with an open working draft.';
comment on function public.admin_finalize_content_asset_upload(uuid, text) is
  'Stage 14.2.1: finalize upload; bind asset to working draft draft_asset_ids when applicable.';
