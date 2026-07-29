-- Stage 16.2: subject files / private assets (SPEC section 4.2).
--
-- ADDITIVE ONLY. This file deliberately does NOT touch the subject card model:
-- the card (columns, section_order, row_version, get_subject_card,
-- admin_upsert_subject_card) is owned solely by
-- 20260729150500_stage16_1_subject_card_foundation.sql. In particular this file
-- adds NO hours_total / credits columns to the profile tables: the single source
-- of truth for load is curriculum_subjects, reached through the offering, and it
-- is surfaced by get_subject_card only.
--
-- Adds a typed subject asset table (FK to subject_catalog XOR subject_offerings,
-- never a free-form polymorphic owner), a private storage bucket and a cleanup
-- queue, mirroring the Stage 14 content assets.
--
-- Depends on: 20260721202054 (RBAC), 20260722110804 (require_admin_permission),
-- 20260609133000 (subject knowledge), 20260727184238 (subjects admin),
-- 20260729150500 (Stage 16.1 subject card).
--
-- Local only. Not applied to remote in this session.

begin;

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Shared RBAC helper: OR-of-permissions gate.
--
-- Live RBAC seeds BOTH `moderation.action` (20260721202054) and
-- `moderation.write` (20260727184457) for the moderator / super_admin roles.
-- SPEC section 12 treats them as the same capability, so moderation writes
-- accept either code. Definition is repeated verbatim in the Stage 16.3/17/18/19
-- migrations so each file stays independently re-appliable.
-- ---------------------------------------------------------------------------
create or replace function private.require_any_admin_permission(p_permissions text[])
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_perm text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_permissions is null or coalesce(array_length(p_permissions, 1), 0) = 0 then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  foreach v_perm in array p_permissions loop
    if private.has_admin_permission(v_uid, v_perm, 'global', null) then
      return v_uid;
    end if;
  end loop;

  raise exception 'forbidden' using errcode = '42501';
end;
$$;

revoke all on function private.require_any_admin_permission(text[])
  from public, anon, authenticated;
grant execute on function private.require_any_admin_permission(text[]) to service_role;

-- ---------------------------------------------------------------------------
-- Typed asset owner (catalog XOR offering), never polymorphic. Private bucket
-- plus cleanup queue. Storage paths never leave the server for students.
-- ---------------------------------------------------------------------------
create table if not exists public.subject_assets (
  id uuid primary key default gen_random_uuid(),
  subject_catalog_id uuid null
    references public.subject_catalog (id) on delete cascade,
  subject_offering_id uuid null
    references public.subject_offerings (id) on delete cascade,
  title text not null default '',
  storage_bucket text not null default 'subject-media',
  storage_path text not null,
  mime_type text not null,
  byte_size bigint not null check (byte_size >= 0),
  checksum text null,
  version_number integer not null default 1 check (version_number >= 1),
  supersedes_asset_id uuid null
    references public.subject_assets (id) on delete set null,
  is_current boolean not null default true,
  created_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint subject_assets_object_unique unique (storage_bucket, storage_path),
  constraint subject_assets_owner_xor check (
    (subject_catalog_id is not null and subject_offering_id is null)
    or (subject_catalog_id is null and subject_offering_id is not null)
  ),
  constraint subject_assets_title_len check (char_length(title) <= 200),
  constraint subject_assets_no_self_supersede check (
    supersedes_asset_id is null or supersedes_asset_id <> id
  )
);

comment on table public.subject_assets is
  'Subject card files. Owner is subject_catalog XOR subject_offering via real FKs; there is no polymorphic owner_kind column. Storage paths are server-side only.';

create index if not exists subject_assets_catalog_idx
  on public.subject_assets (subject_catalog_id)
  where subject_catalog_id is not null;
create index if not exists subject_assets_offering_idx
  on public.subject_assets (subject_offering_id)
  where subject_offering_id is not null;
create index if not exists subject_assets_current_idx
  on public.subject_assets (is_current);

-- At most one current asset per catalog owner.
create unique index if not exists subject_assets_one_current_catalog_uidx
  on public.subject_assets (subject_catalog_id)
  where is_current and subject_catalog_id is not null;

-- At most one current asset per offering owner.
create unique index if not exists subject_assets_one_current_offering_uidx
  on public.subject_assets (subject_offering_id)
  where is_current and subject_offering_id is not null;

-- Version numbers unique per owner.
create unique index if not exists subject_assets_catalog_version_uidx
  on public.subject_assets (subject_catalog_id, version_number)
  where subject_catalog_id is not null;

create unique index if not exists subject_assets_offering_version_uidx
  on public.subject_assets (subject_offering_id, version_number)
  where subject_offering_id is not null;

create table if not exists public.subject_media_cleanup_queue (
  id uuid primary key default gen_random_uuid(),
  storage_bucket text not null,
  storage_path text not null,
  source_subject_catalog_id uuid null,
  source_subject_offering_id uuid null,
  source_title text null,
  enqueued_at timestamptz not null default now(),
  attempts integer not null default 0,
  last_error text null,
  processed_at timestamptz null
);

comment on table public.subject_media_cleanup_queue is
  'Pending private subject-media object cleanup. Never store signed URLs or secrets. Source ids are plain columns (no FK) so tombstones survive owner deletion.';

create unique index if not exists subject_media_cleanup_queue_pending_uidx
  on public.subject_media_cleanup_queue (storage_bucket, storage_path)
  where processed_at is null;
create index if not exists subject_media_cleanup_queue_pending_idx
  on public.subject_media_cleanup_queue (enqueued_at)
  where processed_at is null;

alter table public.subject_assets enable row level security;
alter table public.subject_assets force row level security;
alter table public.subject_media_cleanup_queue enable row level security;
alter table public.subject_media_cleanup_queue force row level security;

revoke all on table public.subject_assets from public, anon, authenticated;
revoke all on table public.subject_media_cleanup_queue from public, anon, authenticated;

grant select, insert, update, delete on table public.subject_assets to service_role;
grant select, insert, update, delete on table public.subject_media_cleanup_queue
  to service_role;

-- ---------------------------------------------------------------------------
-- Subject asset MIME / size policy (mirrors the private bucket config).
-- ---------------------------------------------------------------------------
create or replace function private.subject_asset_assert_object(
  p_bucket text,
  p_path text,
  p_mime text,
  p_byte_size bigint
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
  if p_mime not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf') then
    raise exception 'invalid_mime_type' using errcode = '22023';
  end if;
  if p_byte_size is null or p_byte_size < 0 or p_byte_size > 20971520 then
    raise exception 'invalid_byte_size' using errcode = '22023';
  end if;
end;
$$;

revoke all on function private.subject_asset_assert_object(text, text, text, bigint)
  from public, anon, authenticated;
grant execute on function private.subject_asset_assert_object(text, text, text, bigint)
  to service_role;

-- Descriptors only: never storage_bucket / storage_path / checksum.
create or replace function private.subject_assets_json(
  p_subject_catalog_id uuid,
  p_subject_offering_id uuid,
  p_current_only boolean default true
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
    and (not p_current_only or a.is_current);
$$;

revoke all on function private.subject_assets_json(uuid, uuid, boolean)
  from public, anon, authenticated;
grant execute on function private.subject_assets_json(uuid, uuid, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- Admin RPCs. Write permission: subjects.write.
-- ---------------------------------------------------------------------------
create or replace function public.admin_register_subject_asset(
  p_subject_catalog_id uuid,
  p_subject_offering_id uuid,
  p_storage_path text,
  p_mime_type text,
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
  v_row public.subject_assets;
  v_prev public.subject_assets;
  v_version integer := 1;
begin
  v_uid := private.require_admin_permission('subjects.write');

  if (p_subject_catalog_id is null) = (p_subject_offering_id is null) then
    raise exception 'exactly_one_owner_required' using errcode = '22023';
  end if;

  perform private.subject_asset_assert_object(
    'subject-media', p_storage_path, p_mime_type, p_byte_size
  );

  if p_subject_catalog_id is not null
     and not exists (
       select 1 from public.subject_catalog where id = p_subject_catalog_id
     ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_subject_offering_id is not null
     and not exists (
       select 1 from public.subject_offerings where id = p_subject_offering_id
     ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- Serialize concurrent supersedes for the same owner.
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
    -- A new version must replace a file of the SAME owner (IDOR protection).
    if v_prev.subject_catalog_id is distinct from p_subject_catalog_id
       or v_prev.subject_offering_id is distinct from p_subject_offering_id then
      raise exception 'asset_foreign_owner' using errcode = '42501';
    end if;
    if not v_prev.is_current then
      raise exception 'predecessor_not_current' using errcode = '55000';
    end if;
    v_version := v_prev.version_number + 1;
    update public.subject_assets
    set is_current = false
    where id = p_supersedes_asset_id
      and is_current;
    if not found then
      raise exception 'predecessor_race' using errcode = '40001';
    end if;
  else
    -- First asset for owner: ensure no other current row races in.
    if exists (
      select 1 from public.subject_assets a
      where a.is_current
        and (
          (p_subject_catalog_id is not null and a.subject_catalog_id = p_subject_catalog_id)
          or (p_subject_offering_id is not null and a.subject_offering_id = p_subject_offering_id)
        )
    ) then
      raise exception 'current_asset_exists_use_supersede' using errcode = '23505';
    end if;
  end if;

  insert into public.subject_assets (
    subject_catalog_id, subject_offering_id, title, storage_bucket,
    storage_path, mime_type, byte_size, checksum, version_number,
    supersedes_asset_id, is_current, created_by
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
    v_uid
  )
  returning * into v_row;

  perform private.admin_write_audit(
    'subject_asset.register',
    case when p_subject_catalog_id is not null
      then 'subject_catalog' else 'subject_offering' end,
    coalesce(p_subject_catalog_id, p_subject_offering_id)::text,
    jsonb_build_object(
      'asset_id', v_row.id,
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
declare
  v_uid uuid;
begin
  v_uid := private.require_any_admin_permission(
    array['subjects.write', 'content.read']
  );

  if (p_subject_catalog_id is null) = (p_subject_offering_id is null) then
    raise exception 'exactly_one_owner_required' using errcode = '22023';
  end if;

  return private.subject_assets_json(
    p_subject_catalog_id, p_subject_offering_id, coalesce(p_current_only, false)
  );
end;
$$;

-- Deleting a file that a published card still shows would break the student
-- card, so the owning card must be unpublished (or the asset superseded) first.
create or replace function public.admin_delete_subject_asset(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.subject_assets;
  v_published boolean := false;
begin
  v_uid := private.require_admin_permission('subjects.write');

  select * into v_row from public.subject_assets where id = p_asset_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- Never delete the current tip of the version chain. Supersede first, then
  -- delete the non-current predecessor (keeps version_number sequence intact).
  if v_row.is_current then
    raise exception 'supersede_current_asset_before_delete'
      using errcode = '55000';
  end if;

  -- Queue the storage object BEFORE the row disappears.
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
    jsonb_build_object('asset_id', p_asset_id, 'queued_media', true)
  );

  return jsonb_build_object('deleted', true, 'id', p_asset_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Student read path. Descriptor-only companion to Stage 16.1
-- get_subject_card: same access rule (active enrollment in the offering group
-- plus a published catalog row and a published card), never a storage path.
-- The signed download comes from a separate Edge path that re-authorizes.
-- ---------------------------------------------------------------------------
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
  v_offering_published boolean;
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
    'subject_assets', private.subject_assets_json(v_offering.subject_id, null, true),
    'offering_assets', case
      when v_offering_published
        then private.subject_assets_json(null, p_subject_offering_id, true)
      else '[]'::jsonb
    end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants for RPCs (RBAC is enforced inside each function body).
-- ---------------------------------------------------------------------------
revoke all on function public.admin_register_subject_asset(
  uuid, uuid, text, text, bigint, text, text, uuid
) from public, anon;
grant execute on function public.admin_register_subject_asset(
  uuid, uuid, text, text, bigint, text, text, uuid
) to authenticated, service_role;

revoke all on function public.admin_list_subject_assets(uuid, uuid, boolean)
  from public, anon;
grant execute on function public.admin_list_subject_assets(uuid, uuid, boolean)
  to authenticated, service_role;

revoke all on function public.admin_delete_subject_asset(uuid) from public, anon;
grant execute on function public.admin_delete_subject_asset(uuid)
  to authenticated, service_role;

revoke all on function public.get_subject_card_assets(uuid) from public, anon;
grant execute on function public.get_subject_card_assets(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Private storage bucket for subject files. No public/anon access. Access is
-- denied by the ABSENCE of storage.objects policies plus RLS; the Edge function
-- uses service_role and re-checks authorization.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'subject-media',
  'subject-media',
  false,
  20971520,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

comment on function public.get_subject_card_assets(uuid) is
  'Asset descriptors for a published subject card the caller is enrolled in. Never returns storage paths; offering files require a published offering override.';
comment on function public.admin_delete_subject_asset(uuid) is
  'Deletes a subject file and queues the storage object. Refuses to remove a CURRENT file while the owning card is published.';

commit;
