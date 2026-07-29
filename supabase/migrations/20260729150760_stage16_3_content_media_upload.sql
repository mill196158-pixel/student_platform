-- Stage 16.3 content-media upload intents + leased cleanup (LOCAL ONLY).
-- Complements 150750 download authorize RPCs and content-media Edge.

begin;

create table if not exists public.content_asset_upload_intents (
  id uuid primary key default gen_random_uuid(),
  content_item_id uuid not null references public.content_items (id) on delete cascade,
  actor_user_id uuid not null references public.users (id) on delete cascade,
  storage_bucket text not null default 'content-media',
  storage_path text not null,
  mime_type text not null,
  byte_size bigint null,
  expires_at timestamptz not null,
  finalized_asset_id uuid null references public.content_assets (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint content_asset_upload_intents_path_unique unique (storage_path)
);

alter table public.content_asset_upload_intents enable row level security;
alter table public.content_asset_upload_intents force row level security;
revoke all on table public.content_asset_upload_intents from public, anon, authenticated;
grant select, insert, update, delete on table public.content_asset_upload_intents to service_role;

alter table public.content_media_cleanup_queue
  add column if not exists claim_token uuid null,
  add column if not exists claim_expires_at timestamptz null,
  add column if not exists attempts integer not null default 0,
  add column if not exists last_error text null;

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
  v_item public.content_items;
  v_mime text := lower(btrim(coalesce(p_mime_type, '')));
  v_path text;
  v_id uuid;
  v_ttl integer := greatest(60, least(coalesce(p_ttl_seconds, 900), 3600));
begin
  v_uid := private.require_admin_permission('content.write');
  select * into v_item from public.content_items where id = p_content_item_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_item.status is distinct from 'draft' then
    raise exception 'draft_only' using errcode = '55000';
  end if;
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

  insert into public.content_asset_upload_intents (
    content_item_id, actor_user_id, storage_path, mime_type, expires_at
  ) values (
    p_content_item_id, v_uid, v_path, v_mime, now() + make_interval(secs => v_ttl)
  )
  returning id into v_id;

  -- Never return storage_path to authenticated clients (Edge uses service RPC).
  return jsonb_build_object(
    'intent_id', v_id,
    'mime_type', v_mime,
    'expires_at', now() + make_interval(secs => v_ttl)
  );
end;
$$;

create or replace function public.service_content_upload_intent_storage_path(
  p_intent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_intent public.content_asset_upload_intents;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  select * into v_intent
  from public.content_asset_upload_intents
  where id = p_intent_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_intent.expires_at < now() then
    raise exception 'intent_expired' using errcode = 'P0001';
  end if;
  if v_intent.finalized_asset_id is not null then
    raise exception 'intent_already_finalized' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'intent_id', v_intent.id,
    'storage_bucket', v_intent.storage_bucket,
    'storage_path', v_intent.storage_path,
    'mime_type', v_intent.mime_type
  );
end;
$$;

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
  v_intent public.content_asset_upload_intents;
  v_obj record;
  v_asset public.content_assets;
  v_meta jsonb;
  v_size bigint;
  v_mime text;
begin
  v_uid := private.require_admin_permission('content.write');

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
  if v_intent.finalized_asset_id is not null then
    select * into v_asset from public.content_assets where id = v_intent.finalized_asset_id;
    return jsonb_build_object(
      'id', v_asset.id,
      'mime_type', v_asset.mime_type,
      'byte_size', v_asset.byte_size,
      'title', coalesce(nullif(btrim(p_title), ''), '')
    );
  end if;
  if v_intent.expires_at < now() then
    raise exception 'intent_expired' using errcode = 'P0001';
  end if;

  select o.name, o.metadata, o.metadata->>'size' as size_text, o.metadata->>'mimetype' as mime_text
    into v_obj
  from storage.objects o
  where o.bucket_id = v_intent.storage_bucket
    and o.name = v_intent.storage_path;
  if not found then
    raise exception 'storage_object_missing' using errcode = 'P0002';
  end if;

  v_meta := coalesce(v_obj.metadata, '{}'::jsonb);
  v_size := coalesce(nullif(v_meta->>'size', '')::bigint, nullif(v_meta->>'contentLength', '')::bigint);
  -- Fail-closed: MIME must come from Storage metadata, never client intent fallback.
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

  update public.content_asset_upload_intents
  set finalized_asset_id = v_asset.id
  where id = p_intent_id;

  perform private.admin_write_audit(
    'content_asset.finalize',
    'content_item',
    v_intent.content_item_id::text,
    jsonb_build_object('asset_id', v_asset.id, 'mime_type', v_mime, 'byte_size', v_size)
  );

  return jsonb_build_object(
    'id', v_asset.id,
    'mime_type', v_asset.mime_type,
    'byte_size', v_asset.byte_size,
    'title', left(coalesce(p_title, ''), 200)
  );
end;
$$;

create or replace function public.claim_content_media_cleanup_batch(
  p_limit integer default 10,
  p_lease_seconds integer default 600
)
returns setof public.content_media_cleanup_queue
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 10), 25));
  v_lease integer := greatest(30, least(coalesce(p_lease_seconds, 600), 3600));
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  return query
  with picked as (
    select q.id
    from public.content_media_cleanup_queue q
    where q.processed_at is null
      and (q.claim_expires_at is null or q.claim_expires_at < now())
    order by q.enqueued_at
    limit v_limit
    for update skip locked
  ), upd as (
    update public.content_media_cleanup_queue q
    set claim_token = gen_random_uuid(),
        claim_expires_at = now() + make_interval(secs => v_lease),
        attempts = q.attempts + 1
    from picked p
    where q.id = p.id
    returning q.*
  )
  select * from upd;
end;
$$;

create or replace function public.complete_content_media_cleanup(
  p_queue_id uuid,
  p_claim_token uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  delete from public.content_media_cleanup_queue
  where id = p_queue_id
    and claim_token = p_claim_token;
end;
$$;

create or replace function public.fail_content_media_cleanup(
  p_queue_id uuid,
  p_claim_token uuid,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  update public.content_media_cleanup_queue
  set claim_token = null,
      claim_expires_at = null,
      last_error = left(coalesce(p_error, ''), 500)
  where id = p_queue_id
    and claim_token = p_claim_token;
end;
$$;

revoke all on function public.admin_create_content_asset_upload_intent(uuid, text, integer)
  from public, anon;
grant execute on function public.admin_create_content_asset_upload_intent(uuid, text, integer)
  to authenticated, service_role;

revoke all on function public.service_content_upload_intent_storage_path(uuid)
  from public, anon, authenticated;
grant execute on function public.service_content_upload_intent_storage_path(uuid)
  to service_role;

revoke all on function public.admin_finalize_content_asset_upload(uuid, text)
  from public, anon;
grant execute on function public.admin_finalize_content_asset_upload(uuid, text)
  to authenticated, service_role;

revoke all on function public.claim_content_media_cleanup_batch(integer, integer)
  from public, anon, authenticated;
grant execute on function public.claim_content_media_cleanup_batch(integer, integer) to service_role;

revoke all on function public.complete_content_media_cleanup(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.complete_content_media_cleanup(uuid, uuid) to service_role;

revoke all on function public.fail_content_media_cleanup(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.fail_content_media_cleanup(uuid, uuid, text) to service_role;

commit;
