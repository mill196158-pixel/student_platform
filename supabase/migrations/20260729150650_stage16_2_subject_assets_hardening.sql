-- Stage 16.2 hardening (LOCAL ONLY). Codex plan APPROVE contracts.
-- Depends on 20260729150600_stage16_2_subject_assets.sql
--
-- Adds asset_kind + logical_asset_id chains, upload intents, download auth RPC,
-- cleanup worker RPCs, get_subject_card asset descriptors, RESTRICT owner FKs.

begin;

-- ---------------------------------------------------------------------------
-- subjects.read permission (SPEC §16.2 list/download gate)
-- ---------------------------------------------------------------------------
insert into public.admin_permissions (code, description)
values ('subjects.read', 'Read subjects and subject files')
on conflict (code) do update set description = excluded.description;

insert into public.admin_role_permissions (role_code, permission_code)
values
  ('super_admin', 'subjects.read'),
  ('academic_editor', 'subjects.read'),
  ('viewer', 'subjects.read')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Schema: asset_kind + logical_asset_id
-- ---------------------------------------------------------------------------
alter table public.subject_assets
  add column if not exists asset_kind text not null default 'attachment',
  add column if not exists logical_asset_id uuid not null default gen_random_uuid();

alter table public.subject_assets
  drop constraint if exists subject_assets_asset_kind_check;

alter table public.subject_assets
  add constraint subject_assets_asset_kind_check
  check (asset_kind in ('hero_image', 'attachment'));

-- Backfill: each legacy row becomes its own logical chain (defaults above).

-- Drop superseded uniqueness (one current per owner → one current per logical chain).
drop index if exists public.subject_assets_one_current_catalog_uidx;
drop index if exists public.subject_assets_one_current_offering_uidx;
drop index if exists public.subject_assets_catalog_version_uidx;
drop index if exists public.subject_assets_offering_version_uidx;

create unique index if not exists subject_assets_catalog_logical_current_uidx
  on public.subject_assets (subject_catalog_id, logical_asset_id)
  where is_current and subject_catalog_id is not null;

create unique index if not exists subject_assets_offering_logical_current_uidx
  on public.subject_assets (subject_offering_id, logical_asset_id)
  where is_current and subject_offering_id is not null;

create unique index if not exists subject_assets_catalog_hero_current_uidx
  on public.subject_assets (subject_catalog_id)
  where is_current and subject_catalog_id is not null and asset_kind = 'hero_image';

create unique index if not exists subject_assets_offering_hero_current_uidx
  on public.subject_assets (subject_offering_id)
  where is_current and subject_offering_id is not null and asset_kind = 'hero_image';

create unique index if not exists subject_assets_catalog_logical_version_uidx
  on public.subject_assets (subject_catalog_id, logical_asset_id, version_number)
  where subject_catalog_id is not null;

create unique index if not exists subject_assets_offering_logical_version_uidx
  on public.subject_assets (subject_offering_id, logical_asset_id, version_number)
  where subject_offering_id is not null;

-- Owner FKs: RESTRICT + audited safe-delete (enqueue before metadata removal).
alter table public.subject_assets
  drop constraint if exists subject_assets_subject_catalog_id_fkey;

alter table public.subject_assets
  drop constraint if exists subject_assets_subject_offering_id_fkey;

alter table public.subject_assets
  add constraint subject_assets_subject_catalog_id_fkey
    foreign key (subject_catalog_id)
    references public.subject_catalog (id)
    on delete restrict;

alter table public.subject_assets
  add constraint subject_assets_subject_offering_id_fkey
    foreign key (subject_offering_id)
    references public.subject_offerings (id)
    on delete restrict;

-- ---------------------------------------------------------------------------
-- Upload intents (short-lived, actor/owner-bound, single-use)
-- ---------------------------------------------------------------------------
create table if not exists public.subject_asset_upload_intents (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.users (id) on delete restrict,
  subject_catalog_id uuid null
    references public.subject_catalog (id) on delete restrict,
  subject_offering_id uuid null
    references public.subject_offerings (id) on delete restrict,
  asset_kind text not null check (asset_kind in ('hero_image', 'attachment')),
  logical_asset_id uuid not null default gen_random_uuid(),
  storage_path text not null,
  mime_type text not null,
  expires_at timestamptz not null,
  consumed_at timestamptz null,
  created_at timestamptz not null default now(),
  constraint subject_asset_upload_intents_owner_xor check (
    (subject_catalog_id is not null and subject_offering_id is null)
    or (subject_catalog_id is null and subject_offering_id is not null)
  ),
  constraint subject_asset_upload_intents_path_unique unique (storage_path)
);

comment on table public.subject_asset_upload_intents is
  'Reserved subject-media upload slots. Edge finalize verifies storage.objects before register.';

alter table public.subject_asset_upload_intents enable row level security;
alter table public.subject_asset_upload_intents force row level security;
revoke all on table public.subject_asset_upload_intents from public, anon, authenticated;
grant select, insert, update, delete on table public.subject_asset_upload_intents
  to service_role;

-- Drop superseded helper signatures (param count changed).
drop function if exists private.subject_asset_assert_object(text, text, text, bigint);
drop function if exists private.subject_assets_json(uuid, uuid, boolean);

-- ---------------------------------------------------------------------------
-- Kind-aware MIME policy
-- ---------------------------------------------------------------------------
create or replace function private.subject_asset_assert_mime(
  p_asset_kind text,
  p_mime text
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_asset_kind not in ('hero_image', 'attachment') then
    raise exception 'invalid_asset_kind' using errcode = '22023';
  end if;
  if p_asset_kind = 'hero_image' then
    if p_mime not in ('image/jpeg', 'image/png', 'image/webp') then
      raise exception 'invalid_mime_type' using errcode = '22023';
    end if;
  elsif p_mime not in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  ) then
    raise exception 'invalid_mime_type' using errcode = '22023';
  end if;
end;
$$;

create or replace function private.subject_asset_assert_object(
  p_bucket text,
  p_path text,
  p_mime text,
  p_byte_size bigint,
  p_asset_kind text default 'attachment'
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_bucket is distinct from 'subject-media' then
    raise exception 'invalid_storage_bucket' using errcode = '22023';
  end if;
  if p_path is null
     or btrim(p_path) = ''
     or char_length(p_path) > 400
     or p_path ~ '[[:space:]]'
     or p_path like '/%'
     or p_path like '%..%' then
    raise exception 'invalid_storage_path' using errcode = '22023';
  end if;
  if p_path !~ '^subject/[0-9a-fA-F-]{36}/[A-Za-z0-9._-]+$' then
    raise exception 'invalid_storage_path' using errcode = '22023';
  end if;
  perform private.subject_asset_assert_mime(p_asset_kind, p_mime);
  if p_byte_size is null or p_byte_size < 0 or p_byte_size > 20971520 then
    raise exception 'invalid_byte_size' using errcode = '22023';
  end if;
end;
$$;

revoke all on function private.subject_asset_assert_mime(text, text)
  from public, anon, authenticated;
grant execute on function private.subject_asset_assert_mime(text, text) to service_role;

revoke all on function private.subject_asset_assert_object(text, text, text, bigint, text)
  from public, anon, authenticated;
grant execute on function private.subject_asset_assert_object(text, text, text, bigint, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- Descriptor helpers (never bucket/path/checksum)
-- ---------------------------------------------------------------------------
create or replace function private.subject_assets_json(
  p_subject_catalog_id uuid,
  p_subject_offering_id uuid,
  p_current_only boolean default true,
  p_asset_kind text default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'title', a.title,
        'mime_type', a.mime_type,
        'byte_size', a.byte_size,
        'version_number', a.version_number,
        'asset_kind', a.asset_kind,
        'logical_asset_id', a.logical_asset_id,
        'is_current', a.is_current,
        'created_at', a.created_at
      )
      order by a.created_at, a.id
    ),
    '[]'::jsonb
  )
  from public.subject_assets a
  where (
      (p_subject_catalog_id is not null and a.subject_catalog_id = p_subject_catalog_id)
      or (p_subject_offering_id is not null and a.subject_offering_id = p_subject_offering_id)
    )
    and (not p_current_only or a.is_current)
    and (p_asset_kind is null or a.asset_kind = p_asset_kind);
$$;

create or replace function private.subject_card_assets_json(
  p_subject_catalog_id uuid,
  p_subject_offering_id uuid,
  p_include_offering boolean default true
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'catalog', jsonb_build_object(
      'hero_image', (
        select elem
        from jsonb_array_elements(
          private.subject_assets_json(p_subject_catalog_id, null, true, 'hero_image')
        ) elem
        limit 1
      ),
      'attachments', private.subject_assets_json(
        p_subject_catalog_id, null, true, 'attachment'
      )
    ),
    'offering', case
      when p_include_offering then jsonb_build_object(
        'hero_image', (
          select elem
          from jsonb_array_elements(
            private.subject_assets_json(null, p_subject_offering_id, true, 'hero_image')
          ) elem
          limit 1
        ),
        'attachments', private.subject_assets_json(
          null, p_subject_offering_id, true, 'attachment'
        )
      )
      else jsonb_build_object(
        'hero_image', null,
        'attachments', '[]'::jsonb
      )
    end
  );
$$;

revoke all on function private.subject_assets_json(uuid, uuid, boolean, text)
  from public, anon, authenticated;
grant execute on function private.subject_assets_json(uuid, uuid, boolean, text)
  to service_role;

revoke all on function private.subject_card_assets_json(uuid, uuid, boolean)
  from public, anon, authenticated;
grant execute on function private.subject_card_assets_json(uuid, uuid, boolean)
  to service_role;

-- ---------------------------------------------------------------------------
-- Effective presentation published check (catalog vs offering owner)
-- ---------------------------------------------------------------------------
create or replace function private.subject_asset_owner_published(
  p_subject_catalog_id uuid,
  p_subject_offering_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_subject_catalog_id is not null then
    return exists (
      select 1
      from public.subject_catalog sc
      join public.subject_student_profiles p on p.subject_id = sc.id
      where sc.id = p_subject_catalog_id
        and sc.status = 'published'
        and p.moderation_status = 'published'
    );
  end if;
  return exists (
    select 1
    from public.subject_offering_student_profiles op
    where op.subject_offering_id = p_subject_offering_id
      and op.moderation_status = 'published'
  );
end;
$$;

revoke all on function private.subject_asset_owner_published(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.subject_asset_owner_published(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Admin media permission helpers (Edge pre-checks)
-- ---------------------------------------------------------------------------
create or replace function public.admin_can_manage_subject_media()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return false; end if;
  return private.has_admin_permission(v_uid, 'subjects.write', 'global', null);
end;
$$;

create or replace function public.admin_can_read_subject_media()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return false; end if;
  return private.has_admin_permission(v_uid, 'subjects.read', 'global', null)
    or private.has_admin_permission(v_uid, 'subjects.write', 'global', null);
end;
$$;

revoke all on function public.admin_can_manage_subject_media() from public, anon;
grant execute on function public.admin_can_manage_subject_media()
  to authenticated, service_role;

revoke all on function public.admin_can_read_subject_media() from public, anon;
grant execute on function public.admin_can_read_subject_media()
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Drop old register signature (adds asset_kind + logical_asset_id)
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure(
    'public.admin_register_subject_asset(uuid,uuid,text,text,bigint,text,text,uuid)'
  ) is not null then
    revoke all on function public.admin_register_subject_asset(
      uuid, uuid, text, text, bigint, text, text, uuid
    ) from public, anon, authenticated, service_role;
    drop function public.admin_register_subject_asset(
      uuid, uuid, text, text, bigint, text, text, uuid
    );
  end if;
end $$;

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
  v_uid uuid;
  v_row public.subject_assets;
  v_prev public.subject_assets;
  v_version integer := 1;
  v_logical uuid;
begin
  v_uid := private.require_admin_permission('subjects.write');

  if (p_subject_catalog_id is null) = (p_subject_offering_id is null) then
    raise exception 'exactly_one_owner_required' using errcode = '22023';
  end if;
  if p_asset_kind not in ('hero_image', 'attachment') then
    raise exception 'invalid_asset_kind' using errcode = '22023';
  end if;

  perform private.subject_asset_assert_object(
    'subject-media', p_storage_path, p_mime_type, p_byte_size, p_asset_kind
  );

  -- Lock owning catalog/offering row first (not only the asset set).
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
    v_uid,
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

create or replace function public.admin_list_subject_assets(
  p_subject_catalog_id uuid default null,
  p_subject_offering_id uuid default null,
  p_current_only boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_any_admin_permission(
    array['subjects.read', 'subjects.write']
  );

  if (p_subject_catalog_id is null) = (p_subject_offering_id is null) then
    raise exception 'exactly_one_owner_required' using errcode = '22023';
  end if;

  return private.subject_assets_json(
    p_subject_catalog_id, p_subject_offering_id, coalesce(p_current_only, false), null
  );
end;
$$;

create or replace function public.admin_delete_subject_asset(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.subject_assets;
  v_published boolean;
begin
  v_uid := private.require_admin_permission('subjects.write');

  select * into v_row from public.subject_assets where id = p_asset_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_published := private.subject_asset_owner_published(
    v_row.subject_catalog_id, v_row.subject_offering_id
  );

  if v_row.is_current and v_published then
    raise exception 'unpublish_card_before_deleting_current_asset'
      using errcode = '55000';
  end if;

  insert into public.subject_media_cleanup_queue (
    storage_bucket, storage_path, source_subject_catalog_id,
    source_subject_offering_id, source_title
  ) values (
    v_row.storage_bucket,
    v_row.storage_path,
    v_row.subject_catalog_id,
    v_row.subject_offering_id,
    left(v_row.title, 200)
  )
  on conflict do nothing;

  delete from public.subject_assets where id = p_asset_id;

  perform private.admin_write_audit(
    'subject_asset.delete',
    case when v_row.subject_catalog_id is not null
      then 'subject_catalog' else 'subject_offering' end,
    coalesce(v_row.subject_catalog_id, v_row.subject_offering_id)::text,
    jsonb_build_object(
      'asset_id', p_asset_id,
      'was_current', v_row.is_current,
      'queued_media', true
    )
  );

  return jsonb_build_object('deleted', true, 'id', p_asset_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Upload intent RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_create_subject_asset_upload_intent(
  p_subject_catalog_id uuid,
  p_subject_offering_id uuid,
  p_asset_kind text,
  p_mime_type text,
  p_logical_asset_id uuid default null,
  p_ttl_seconds integer default 900
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_logical uuid;
  v_owner uuid;
  v_path text;
  v_intent public.subject_asset_upload_intents;
  v_ttl integer;
begin
  v_uid := private.require_admin_permission('subjects.write');

  if (p_subject_catalog_id is null) = (p_subject_offering_id is null) then
    raise exception 'exactly_one_owner_required' using errcode = '22023';
  end if;
  if p_asset_kind not in ('hero_image', 'attachment') then
    raise exception 'invalid_asset_kind' using errcode = '22023';
  end if;

  perform private.subject_asset_assert_mime(p_asset_kind, p_mime_type);

  v_owner := coalesce(p_subject_catalog_id, p_subject_offering_id);
  v_logical := coalesce(p_logical_asset_id, gen_random_uuid());
  v_path := format(
    'subject/%s/%s',
    v_owner::text,
    replace(gen_random_uuid()::text, '-', '')
  );

  v_ttl := greatest(60, least(coalesce(p_ttl_seconds, 900), 3600));

  insert into public.subject_asset_upload_intents (
    actor_id, subject_catalog_id, subject_offering_id,
    asset_kind, logical_asset_id, storage_path, mime_type, expires_at
  ) values (
    v_uid,
    p_subject_catalog_id,
    p_subject_offering_id,
    p_asset_kind,
    v_logical,
    v_path,
    p_mime_type,
    now() + make_interval(secs => v_ttl)
  )
  returning * into v_intent;

  return jsonb_build_object(
    'intent_id', v_intent.id,
    'storage_path', v_intent.storage_path,
    'asset_kind', v_intent.asset_kind,
    'logical_asset_id', v_intent.logical_asset_id,
    'mime_type', v_intent.mime_type,
    'expires_at', v_intent.expires_at
  );
end;
$$;

create or replace function public.admin_finalize_subject_asset_upload(
  p_intent_id uuid,
  p_byte_size bigint,
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
  if v_intent.consumed_at is not null then
    raise exception 'intent_already_consumed' using errcode = '55000';
  end if;
  if v_intent.expires_at <= now() then
    raise exception 'intent_expired' using errcode = '55000';
  end if;

  select
    (o.metadata->>'size')::bigint,
    coalesce(o.metadata->>'mimetype', o.metadata->>'contentType')
  into v_obj_size, v_obj_mime
  from storage.objects o
  where o.bucket_id = 'subject-media'
    and o.name = v_intent.storage_path;

  if not found then
    raise exception 'storage_object_missing' using errcode = 'P0002';
  end if;

  perform private.subject_asset_assert_object(
    'subject-media',
    v_intent.storage_path,
    coalesce(v_obj_mime, v_intent.mime_type),
    coalesce(v_obj_size, p_byte_size),
    v_intent.asset_kind
  );

  update public.subject_asset_upload_intents
  set consumed_at = now()
  where id = p_intent_id
    and consumed_at is null;

  return public.admin_register_subject_asset(
    v_intent.subject_catalog_id,
    v_intent.subject_offering_id,
    v_intent.storage_path,
    coalesce(v_obj_mime, v_intent.mime_type),
    coalesce(v_obj_size, p_byte_size),
    p_title,
    p_checksum,
    p_supersedes_asset_id,
    v_intent.asset_kind,
    v_intent.logical_asset_id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Download authorization (returns storage path to Edge for signing)
-- ---------------------------------------------------------------------------
create or replace function public.request_subject_asset_download(
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

  select * into v_asset
  from public.subject_assets
  where id = p_asset_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not v_asset.is_current then
    raise exception 'asset_not_current' using errcode = '42501';
  end if;

  if public.admin_can_read_subject_media() then
    return jsonb_build_object(
      'storage_bucket', v_asset.storage_bucket,
      'storage_path', v_asset.storage_path,
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
    select 1
    from public.student_enrollments se
    where se.user_id = v_uid
      and se.group_id = v_offering.group_id
      and se.status = 'active'
      and se.ended_at is null
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.subject_catalog sc
    where sc.id = v_offering.subject_id and sc.status = 'published'
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
    from public.subject_student_profiles p
    where p.subject_id = v_offering.subject_id
      and p.moderation_status = 'published'
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select exists (
    select 1
    from public.subject_offering_student_profiles op
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
    'storage_bucket', v_asset.storage_bucket,
    'storage_path', v_asset.storage_path,
    'mime_type', v_asset.mime_type
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Patch get_subject_card: embed asset descriptors (same access checks)
-- ---------------------------------------------------------------------------
create or replace function public.get_subject_card(p_subject_offering_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_offering public.subject_offerings%rowtype;
  v_cat public.subject_catalog%rowtype;
  v_prof public.subject_student_profiles%rowtype;
  v_o_prof public.subject_offering_student_profiles%rowtype;
  v_cs public.curriculum_subjects%rowtype;
  v_desc text;
  v_how text;
  v_hours numeric;
  v_credits numeric;
  v_teachers jsonb;
  v_offering_published boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_subject_offering_id is null then
    raise exception 'invalid_offering' using errcode = '22023';
  end if;

  select * into v_offering
  from public.subject_offerings so
  where so.id = p_subject_offering_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
    from public.student_enrollments se
    where se.user_id = v_uid
      and se.group_id = v_offering.group_id
      and se.status = 'active'
      and se.ended_at is null
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_cat
  from public.subject_catalog
  where id = v_offering.subject_id
    and status = 'published';
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_prof
  from public.subject_student_profiles
  where subject_id = v_offering.subject_id
    and moderation_status = 'published';
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_o_prof
  from public.subject_offering_student_profiles
  where subject_offering_id = p_subject_offering_id
    and moderation_status = 'published';

  v_offering_published := found;

  if v_offering.curriculum_subject_id is not null then
    select * into v_cs
    from public.curriculum_subjects
    where id = v_offering.curriculum_subject_id;
  end if;

  v_desc := coalesce(
    private.null_if_blank(v_o_prof.local_description),
    private.null_if_blank(v_cat.description)
  );
  v_how := coalesce(
    private.null_if_blank(v_o_prof.semester_tips),
    private.null_if_blank(v_prof.how_to_pass)
  );
  v_hours := v_cs.hours_total;
  v_credits := v_cs.credits;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'full_name', coalesce(nullif(btrim(t.full_name), ''), 'Преподаватель')
      )
      order by t.full_name
    ),
    '[]'::jsonb
  )
  into v_teachers
  from public.offering_teachers ot
  join public.teachers t on t.id = ot.teacher_id
  where ot.subject_offering_id = p_subject_offering_id;

  return jsonb_build_object(
    'subject_id', v_offering.subject_id,
    'subject_offering_id', p_subject_offering_id,
    'canonical_name', v_cat.canonical_name,
    'department', v_cat.department,
    'control_form', v_cat.control_form,
    'requirements', v_cat.requirements,
    'learning_outcomes', v_cat.learning_outcomes,
    'useful_links', coalesce(v_cat.useful_links, '[]'::jsonb),
    'short_description', v_prof.short_description,
    'what_to_expect', v_prof.what_to_expect,
    'useful_materials_note', v_prof.useful_materials_note,
    'common_pitfalls', v_prof.common_pitfalls,
    'relevance_date', v_prof.relevance_date,
    'section_order', private.normalize_subject_section_order(v_prof.section_order),
    'description', v_desc,
    'how_to_pass', v_how,
    'teacher_specific_note', private.null_if_blank(v_o_prof.teacher_specific_note),
    'assessment_note', private.null_if_blank(v_o_prof.assessment_note),
    'workload_note', private.null_if_blank(v_o_prof.workload_note),
    'hours_total', v_hours,
    'credits', v_credits,
    'hours_credits_available', (v_offering.curriculum_subject_id is not null),
    'teachers', coalesce(v_teachers, '[]'::jsonb),
    'assets', private.subject_card_assets_json(
      v_offering.subject_id,
      p_subject_offering_id,
      v_offering_published
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Cleanup worker RPCs (service_role only)
-- ---------------------------------------------------------------------------
create or replace function public.claim_subject_media_cleanup_batch(
  p_limit integer default 25
)
returns table (
  id uuid,
  storage_bucket text,
  storage_path text,
  attempts integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  return query
  with picked as (
    select q.id
    from public.subject_media_cleanup_queue q
    where q.processed_at is null
      and q.attempts < 8
    order by q.enqueued_at
    limit v_limit
    for update skip locked
  ),
  claimed as (
    update public.subject_media_cleanup_queue q
    set attempts = q.attempts + 1
    from picked
    where q.id = picked.id
    returning q.id, q.storage_bucket, q.storage_path, q.attempts
  )
  select c.id, c.storage_bucket, c.storage_path, c.attempts
  from claimed c;
end;
$$;

create or replace function public.complete_subject_media_cleanup(p_queue_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if p_queue_id is null then
    raise exception 'invalid_queue_id' using errcode = '22023';
  end if;

  update public.subject_media_cleanup_queue
  set processed_at = now(), last_error = null
  where id = p_queue_id
    and processed_at is null;

  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object('completed', true, 'id', p_queue_id);
end;
$$;

create or replace function public.fail_subject_media_cleanup(
  p_queue_id uuid,
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
  if p_queue_id is null then
    raise exception 'invalid_queue_id' using errcode = '22023';
  end if;

  update public.subject_media_cleanup_queue
  set last_error = left(coalesce(nullif(btrim(p_error), ''), 'cleanup_failed'), 500)
  where id = p_queue_id
    and processed_at is null;

  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object('failed', true, 'id', p_queue_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants / revokes
-- ---------------------------------------------------------------------------
revoke all on function public.admin_register_subject_asset(
  uuid, uuid, text, text, bigint, text, text, uuid, text, uuid
) from public, anon;
grant execute on function public.admin_register_subject_asset(
  uuid, uuid, text, text, bigint, text, text, uuid, text, uuid
) to authenticated, service_role;

revoke all on function public.admin_list_subject_assets(uuid, uuid, boolean)
  from public, anon;
grant execute on function public.admin_list_subject_assets(uuid, uuid, boolean)
  to authenticated, service_role;

revoke all on function public.admin_delete_subject_asset(uuid) from public, anon;
grant execute on function public.admin_delete_subject_asset(uuid)
  to authenticated, service_role;

revoke all on function public.admin_create_subject_asset_upload_intent(
  uuid, uuid, text, text, uuid, integer
) from public, anon;
grant execute on function public.admin_create_subject_asset_upload_intent(
  uuid, uuid, text, text, uuid, integer
) to authenticated, service_role;

revoke all on function public.admin_finalize_subject_asset_upload(
  uuid, bigint, text, text, uuid
) from public, anon;
grant execute on function public.admin_finalize_subject_asset_upload(
  uuid, bigint, text, text, uuid
) to authenticated, service_role;

revoke all on function public.request_subject_asset_download(uuid, uuid)
  from public, anon;
grant execute on function public.request_subject_asset_download(uuid, uuid)
  to authenticated, service_role;

revoke all on function public.get_subject_card(uuid) from public, anon;
grant execute on function public.get_subject_card(uuid) to authenticated, service_role;

revoke all on function public.claim_subject_media_cleanup_batch(integer)
  from public, anon, authenticated;
grant execute on function public.claim_subject_media_cleanup_batch(integer)
  to service_role;

revoke all on function public.complete_subject_media_cleanup(uuid)
  from public, anon, authenticated;
grant execute on function public.complete_subject_media_cleanup(uuid)
  to service_role;

revoke all on function public.fail_subject_media_cleanup(uuid, text)
  from public, anon, authenticated;
grant execute on function public.fail_subject_media_cleanup(uuid, text)
  to service_role;

comment on function public.admin_delete_subject_asset(uuid) is
  'Deletes a subject file after enqueueing storage cleanup. Refuses to remove a CURRENT file while the owning card presentation is published.';
comment on function public.get_subject_card(uuid) is
  'Merged subject card for enrolled students. Includes current asset descriptors (hero + attachments) without storage paths.';
comment on function public.request_subject_asset_download(uuid, uuid) is
  'Authorizes subject-media download for admin (subjects.read/write) or enrolled student with published card; returns storage path for Edge signing.';

-- Keep standalone assets RPC aligned with get_subject_card asset shape.
create or replace function public.get_subject_card_assets(p_subject_offering_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_offering public.subject_offerings;
  v_offering_published boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_subject_offering_id is null then
    raise exception 'invalid_offering' using errcode = '22023';
  end if;

  select * into v_offering
  from public.subject_offerings so
  where so.id = p_subject_offering_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
    from public.student_enrollments se
    where se.user_id = v_uid
      and se.group_id = v_offering.group_id
      and se.status = 'active'
      and se.ended_at is null
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.subject_catalog sc
    where sc.id = v_offering.subject_id and sc.status = 'published'
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
    from public.subject_student_profiles p
    where p.subject_id = v_offering.subject_id
      and p.moderation_status = 'published'
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select exists (
    select 1
    from public.subject_offering_student_profiles p
    where p.subject_offering_id = p_subject_offering_id
      and p.moderation_status = 'published'
  ) into v_offering_published;

  return jsonb_build_object(
    'subject_id', v_offering.subject_id,
    'subject_offering_id', p_subject_offering_id,
    'assets', private.subject_card_assets_json(
      v_offering.subject_id,
      p_subject_offering_id,
      v_offering_published
    )
  );
end;
$$;

revoke all on function public.get_subject_card_assets(uuid) from public, anon;
grant execute on function public.get_subject_card_assets(uuid)
  to authenticated, service_role;

commit;
