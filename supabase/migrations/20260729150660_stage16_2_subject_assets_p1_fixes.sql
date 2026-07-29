-- Stage 16.2 P1 fixes (LOCAL ONLY). Codex review findings.
-- Depends on 20260729150650_stage16_2_subject_assets_hardening.sql
--
-- 1. Idempotent finalize (finalized_asset_id on intent)
-- 2. Fail-closed finalize (storage.objects MIME+size required)
-- 3. register moved private; authenticated revoke on public register
-- 4. Cleanup lease (claim_token + claim_expires_at)
-- 5. Download auth split: client authorize (no path) + service path RPC

begin;

-- ---------------------------------------------------------------------------
-- Intent idempotency column
-- ---------------------------------------------------------------------------
alter table public.subject_asset_upload_intents
  add column if not exists finalized_asset_id uuid null
    references public.subject_assets (id) on delete set null;

-- ---------------------------------------------------------------------------
-- Cleanup lease columns
-- ---------------------------------------------------------------------------
alter table public.subject_media_cleanup_queue
  add column if not exists claim_token uuid null,
  add column if not exists claim_expires_at timestamptz null;

create index if not exists subject_media_cleanup_queue_claim_expires_idx
  on public.subject_media_cleanup_queue (claim_expires_at)
  where processed_at is null and claim_token is not null;

-- ---------------------------------------------------------------------------
-- Asset descriptor helper (never bucket/path/checksum)
-- ---------------------------------------------------------------------------
create or replace function private.subject_asset_descriptor_json(p_asset_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.subject_assets;
begin
  select * into v_row from public.subject_assets where id = p_asset_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'id', v_row.id,
    'title', v_row.title,
    'mime_type', v_row.mime_type,
    'byte_size', v_row.byte_size,
    'version_number', v_row.version_number,
    'asset_kind', v_row.asset_kind,
    'logical_asset_id', v_row.logical_asset_id,
    'is_current', v_row.is_current,
    'created_at', v_row.created_at
  );
end;
$$;

revoke all on function private.subject_asset_descriptor_json(uuid)
  from public, anon, authenticated;
grant execute on function private.subject_asset_descriptor_json(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Core register (private). Called by finalize + service_role wrapper only.
-- ---------------------------------------------------------------------------
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
  v_row public.subject_assets;
  v_prev public.subject_assets;
  v_version integer := 1;
  v_logical uuid;
begin
  if p_actor_id is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
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
      'version_number', v_row.version_number
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

-- service_role / worker entry (roleplay + Edge finalize internal path)
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
  if v_uid is null then
    v_uid := '00000000-0000-0000-0000-000000000000'::uuid;
  end if;
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

-- ---------------------------------------------------------------------------
-- Idempotent + fail-closed finalize
-- ---------------------------------------------------------------------------
create or replace function public.admin_finalize_subject_asset_upload(
  p_intent_id uuid,
  p_title text default '',
  p_checksum text default null,
  p_supersedes_asset_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_intent public.subject_asset_upload_intents;
  v_obj_size bigint;
  v_obj_mime text;
  v_result jsonb;
begin
  v_uid := private.require_admin_permission('subjects.write');

  select * into v_intent
  from public.subject_asset_upload_intents
  where id = p_intent_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_intent.actor_id is distinct from v_uid then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Idempotent retry: return the same descriptor.
  if v_intent.finalized_asset_id is not null then
    return private.subject_asset_descriptor_json(v_intent.finalized_asset_id);
  end if;

  if v_intent.consumed_at is not null then
    raise exception 'intent_already_consumed' using errcode = '55000';
  end if;
  if v_intent.expires_at <= now() then
    raise exception 'intent_expired' using errcode = '55000';
  end if;

  select
    nullif(btrim(o.metadata->>'size'), '')::bigint,
    nullif(
      btrim(coalesce(o.metadata->>'mimetype', o.metadata->>'contentType', '')),
      ''
    )
  into v_obj_size, v_obj_mime
  from storage.objects o
  where o.bucket_id = 'subject-media'
    and o.name = v_intent.storage_path;

  if not found then
    raise exception 'storage_object_missing' using errcode = 'P0002';
  end if;
  if v_obj_size is null or v_obj_mime is null then
    raise exception 'storage_object_metadata_missing' using errcode = '22023';
  end if;

  perform private.subject_asset_assert_object(
    'subject-media',
    v_intent.storage_path,
    v_obj_mime,
    v_obj_size,
    v_intent.asset_kind
  );

  v_result := private.register_subject_asset(
    v_uid,
    v_intent.subject_catalog_id,
    v_intent.subject_offering_id,
    v_intent.storage_path,
    v_obj_mime,
    v_obj_size,
    p_title,
    p_checksum,
    p_supersedes_asset_id,
    v_intent.asset_kind,
    v_intent.logical_asset_id
  );

  update public.subject_asset_upload_intents
  set
    consumed_at = now(),
    finalized_asset_id = (v_result->>'id')::uuid
  where id = p_intent_id;

  return v_result;
end;
$$;

-- Drop old 5-arg finalize if present (had p_byte_size).
do $$
begin
  if to_regprocedure(
    'public.admin_finalize_subject_asset_upload(uuid,bigint,text,text,uuid)'
  ) is not null then
    revoke all on function public.admin_finalize_subject_asset_upload(
      uuid, bigint, text, text, uuid
    ) from public, anon, authenticated, service_role;
    drop function public.admin_finalize_subject_asset_upload(
      uuid, bigint, text, text, uuid
    );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Download: client authorize (no path) + service signing target
-- ---------------------------------------------------------------------------
create or replace function public.authorize_subject_asset_download(
  p_asset_id uuid,
  p_subject_offering_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_asset public.subject_assets;
  v_offering public.subject_offerings;
  v_offering_published boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_asset_id is null or p_subject_offering_id is null then
    raise exception 'invalid_request' using errcode = '22023';
  end if;

  select * into v_asset from public.subject_assets where id = p_asset_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not v_asset.is_current then
    raise exception 'asset_not_current' using errcode = '42501';
  end if;

  if public.admin_can_read_subject_media() then
    return jsonb_build_object(
      'authorized', true,
      'asset_id', v_asset.id,
      'mime_type', v_asset.mime_type
    );
  end if;

  select * into v_offering
  from public.subject_offerings so
  where so.id = p_subject_offering_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.student_enrollments se
    where se.user_id = v_uid
      and se.group_id = v_offering.group_id
      and se.status = 'active'
      and se.ended_at is null
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.subject_catalog sc
    where sc.id = v_offering.subject_id and sc.status = 'published'
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.subject_student_profiles p
    where p.subject_id = v_offering.subject_id
      and p.moderation_status = 'published'
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.subject_offering_student_profiles op
    where op.subject_offering_id = p_subject_offering_id
      and op.moderation_status = 'published'
  ) into v_offering_published;

  if v_asset.subject_catalog_id is not null then
    if v_asset.subject_catalog_id is distinct from v_offering.subject_id then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  elsif v_asset.subject_offering_id is not null then
    if not v_offering_published
       or v_asset.subject_offering_id is distinct from p_subject_offering_id then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  else
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'authorized', true,
    'asset_id', v_asset.id,
    'mime_type', v_asset.mime_type
  );
end;
$$;

create or replace function public.service_subject_asset_storage_path(p_asset_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_asset public.subject_assets;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if p_asset_id is null then
    raise exception 'invalid_asset' using errcode = '22023';
  end if;

  select * into v_asset from public.subject_assets where id = p_asset_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'storage_bucket', v_asset.storage_bucket,
    'storage_path', v_asset.storage_path
  );
end;
$$;

-- Deprecate path-leaking client RPC (replace with authorize-only).
drop function if exists public.request_subject_asset_download(uuid, uuid);

-- ---------------------------------------------------------------------------
-- Cleanup worker RPCs with lease
-- ---------------------------------------------------------------------------
create or replace function public.claim_subject_media_cleanup_batch(
  p_limit integer default 25,
  p_lease_seconds integer default 600
)
returns table (
  id uuid,
  storage_bucket text,
  storage_path text,
  attempts integer,
  claim_token uuid,
  claim_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
  v_lease integer := greatest(60, least(coalesce(p_lease_seconds, 600), 3600));
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  -- Release expired leases back to the pool.
  update public.subject_media_cleanup_queue q
  set claim_token = null, claim_expires_at = null
  where q.processed_at is null
    and q.claim_token is not null
    and q.claim_expires_at is not null
    and q.claim_expires_at <= now();

  return query
  with picked as (
    select q.id
    from public.subject_media_cleanup_queue q
    where q.processed_at is null
      and q.attempts < 8
      and q.claim_token is null
    order by q.enqueued_at
    limit v_limit
    for update skip locked
  ),
  claimed as (
    update public.subject_media_cleanup_queue q
    set
      attempts = q.attempts + 1,
      claim_token = gen_random_uuid(),
      claim_expires_at = now() + make_interval(secs => v_lease)
    from picked
    where q.id = picked.id
    returning
      q.id,
      q.storage_bucket,
      q.storage_path,
      q.attempts,
      q.claim_token,
      q.claim_expires_at
  )
  select
    c.id,
    c.storage_bucket,
    c.storage_path,
    c.attempts,
    c.claim_token,
    c.claim_expires_at
  from claimed c;
end;
$$;

create or replace function public.complete_subject_media_cleanup(
  p_queue_id uuid,
  p_claim_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if p_queue_id is null or p_claim_token is null then
    raise exception 'invalid_queue_claim' using errcode = '22023';
  end if;

  update public.subject_media_cleanup_queue
  set
    processed_at = now(),
    last_error = null,
    claim_token = null,
    claim_expires_at = null
  where id = p_queue_id
    and processed_at is null
    and claim_token = p_claim_token
    and claim_expires_at > now();

  if not found then
    raise exception 'claim_invalid_or_expired' using errcode = '42501';
  end if;

  return jsonb_build_object('completed', true, 'id', p_queue_id);
end;
$$;

create or replace function public.fail_subject_media_cleanup(
  p_queue_id uuid,
  p_claim_token uuid,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if p_queue_id is null or p_claim_token is null then
    raise exception 'invalid_queue_claim' using errcode = '22023';
  end if;

  update public.subject_media_cleanup_queue
  set
    last_error = left(coalesce(nullif(btrim(p_error), ''), 'cleanup_failed'), 500),
    claim_token = null,
    claim_expires_at = null
  where id = p_queue_id
    and processed_at is null
    and claim_token = p_claim_token;

  if not found then
    raise exception 'claim_invalid_or_expired' using errcode = '42501';
  end if;

  return jsonb_build_object('failed', true, 'id', p_queue_id);
end;
$$;

-- Drop old single-arg complete/fail signatures if present.
do $$
begin
  if to_regprocedure('public.complete_subject_media_cleanup(uuid)') is not null then
    revoke all on function public.complete_subject_media_cleanup(uuid)
      from public, anon, authenticated, service_role;
    drop function public.complete_subject_media_cleanup(uuid);
  end if;
  if to_regprocedure('public.fail_subject_media_cleanup(uuid,text)') is not null then
    revoke all on function public.fail_subject_media_cleanup(uuid, text)
      from public, anon, authenticated, service_role;
    drop function public.fail_subject_media_cleanup(uuid, text);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Grants / revokes (P1 #3, #5)
-- ---------------------------------------------------------------------------
revoke all on function public.admin_register_subject_asset(
  uuid, uuid, text, text, bigint, text, text, uuid, text, uuid
) from public, anon, authenticated;
grant execute on function public.admin_register_subject_asset(
  uuid, uuid, text, text, bigint, text, text, uuid, text, uuid
) to service_role;

revoke all on function public.admin_finalize_subject_asset_upload(
  uuid, text, text, uuid
) from public, anon;
grant execute on function public.admin_finalize_subject_asset_upload(
  uuid, text, text, uuid
) to authenticated, service_role;

revoke all on function public.authorize_subject_asset_download(uuid, uuid)
  from public, anon;
grant execute on function public.authorize_subject_asset_download(uuid, uuid)
  to authenticated, service_role;

revoke all on function public.service_subject_asset_storage_path(uuid)
  from public, anon, authenticated;
grant execute on function public.service_subject_asset_storage_path(uuid)
  to service_role;

revoke all on function public.claim_subject_media_cleanup_batch(integer, integer)
  from public, anon, authenticated;
grant execute on function public.claim_subject_media_cleanup_batch(integer, integer)
  to service_role;

revoke all on function public.complete_subject_media_cleanup(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.complete_subject_media_cleanup(uuid, uuid)
  to service_role;

revoke all on function public.fail_subject_media_cleanup(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.fail_subject_media_cleanup(uuid, uuid, text)
  to service_role;

comment on function public.admin_finalize_subject_asset_upload(uuid, text, text, uuid) is
  'Verifies storage.objects MIME+size, registers via private.register_subject_asset, idempotent on finalized_asset_id.';
comment on function public.authorize_subject_asset_download(uuid, uuid) is
  'Client download gate. Returns asset_id + mime_type only — never storage paths.';
comment on function public.service_subject_asset_storage_path(uuid) is
  'service_role signing helper for Edge after authorize_subject_asset_download.';

commit;
