-- Stage 17 P1 hardening (Codex round 2). LOCAL ONLY.
-- Complements 20260729151000_stage17_vacancies_domain.sql — do not edit that file.
--
-- Fixes:
--   * post-approval content/audience edit leak (draft|submitted|rejected only)
--   * vacancy asset upload intent + finalize from Storage metadata (no client path/MIME/size)
--   * explicit_users_count requires active enrollment in audience preview
--   * student vacancy asset download authorize (paths stay service-side)
--   * moderation journal list RPC
--   * deprecate trust-the-client admin_register_vacancy_asset

begin;

-- ---------------------------------------------------------------------------
-- Upload intents (mirrors Stage 16.3 content-media pattern)
-- ---------------------------------------------------------------------------
create table if not exists public.vacancy_asset_upload_intents (
  id uuid primary key default gen_random_uuid(),
  vacancy_id uuid not null references public.vacancies (id) on delete cascade,
  actor_user_id uuid not null references public.users (id) on delete cascade,
  storage_bucket text not null default 'content-media',
  storage_path text not null,
  mime_type text not null,
  byte_size bigint null,
  expires_at timestamptz not null,
  finalized_asset_id uuid null references public.vacancy_assets (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint vacancy_asset_upload_intents_path_unique unique (storage_path)
);

alter table public.vacancy_asset_upload_intents enable row level security;
alter table public.vacancy_asset_upload_intents force row level security;
revoke all on table public.vacancy_asset_upload_intents from public, anon, authenticated;
grant select, insert, update, delete on table public.vacancy_asset_upload_intents to service_role;

create or replace function private.vacancy_assert_editable_content(p_status text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_status not in ('draft', 'submitted', 'rejected') then
    raise exception 'not_editable_in_status_%', p_status using errcode = '55000';
  end if;
end;
$$;

revoke all on function private.vacancy_assert_editable_content(text)
  from public, anon, authenticated;
grant execute on function private.vacancy_assert_editable_content(text) to service_role;

-- ---------------------------------------------------------------------------
-- Fail-closed content edits: only draft | submitted | rejected
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_vacancy_draft(
  p_id uuid,
  p_patch jsonb,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_row public.vacancies;
begin
  v_uid := private.require_admin_permission('content.write');

  perform private.vacancy_assert_patch(v_patch, array[
    'title', 'company_name', 'summary', 'description', 'employment_type',
    'work_format', 'location', 'salary_text', 'external_url', 'contacts',
    'priority', 'starts_at', 'ends_at', 'expires_at', 'is_hidden'
  ]);

  v_row := private.vacancy_lock(p_id, p_expected_row_version);
  perform private.vacancy_assert_editable_content(v_row.status);

  update public.vacancies v set
    title = case when v_patch ? 'title' then btrim(v_patch ->> 'title') else v.title end,
    company_name = case when v_patch ? 'company_name'
      then coalesce(v_patch ->> 'company_name', '') else v.company_name end,
    summary = case when v_patch ? 'summary'
      then coalesce(v_patch ->> 'summary', '') else v.summary end,
    description = case when v_patch ? 'description'
      then coalesce(v_patch ->> 'description', '') else v.description end,
    employment_type = case when v_patch ? 'employment_type'
      then nullif(btrim(coalesce(v_patch ->> 'employment_type', '')), '')
      else v.employment_type end,
    work_format = case when v_patch ? 'work_format'
      then nullif(btrim(coalesce(v_patch ->> 'work_format', '')), '')
      else v.work_format end,
    location = case when v_patch ? 'location'
      then nullif(btrim(coalesce(v_patch ->> 'location', '')), '') else v.location end,
    salary_text = case when v_patch ? 'salary_text'
      then nullif(btrim(coalesce(v_patch ->> 'salary_text', '')), '')
      else v.salary_text end,
    external_url = case when v_patch ? 'external_url'
      then nullif(btrim(coalesce(v_patch ->> 'external_url', '')), '')
      else v.external_url end,
    contacts = case when v_patch ? 'contacts'
      then coalesce(v_patch -> 'contacts', '{}'::jsonb) else v.contacts end,
    priority = case when v_patch ? 'priority'
      then coalesce((v_patch ->> 'priority')::integer, 0) else v.priority end,
    starts_at = case when v_patch ? 'starts_at'
      then nullif(v_patch ->> 'starts_at', '')::timestamptz else v.starts_at end,
    ends_at = case when v_patch ? 'ends_at'
      then nullif(v_patch ->> 'ends_at', '')::timestamptz else v.ends_at end,
    expires_at = case when v_patch ? 'expires_at'
      then nullif(v_patch ->> 'expires_at', '')::timestamptz else v.expires_at end,
    is_hidden = case when v_patch ? 'is_hidden'
      then coalesce((v_patch ->> 'is_hidden')::boolean, false) else v.is_hidden end,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'vacancy.update_draft',
    'vacancy',
    p_id,
    jsonb_build_object(
      'row_version', v_row.row_version,
      'patched_keys', (
        select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
        from jsonb_object_keys(v_patch) as k
      )
    )
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_set_vacancy_audience(
  p_id uuid,
  p_mode text,
  p_group_ids uuid[],
  p_user_ids uuid[],
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_mode text := nullif(btrim(coalesce(p_mode, '')), '');
  v_groups uuid[];
  v_users uuid[];
  v_missing uuid;
begin
  v_uid := private.require_admin_permission('content.write');

  if v_mode is null
     or v_mode not in ('all', 'groups', 'users', 'groups_and_users') then
    raise exception 'invalid_audience_mode' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_groups
  from unnest(coalesce(p_group_ids, '{}'::uuid[])) as x
  where x is not null;
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_users
  from unnest(coalesce(p_user_ids, '{}'::uuid[])) as x
  where x is not null;

  if v_mode = 'all' then
    v_groups := '{}'::uuid[];
    v_users := '{}'::uuid[];
  elsif v_mode = 'groups' then
    v_users := '{}'::uuid[];
    if coalesce(array_length(v_groups, 1), 0) = 0 then
      raise exception 'audience_groups_required' using errcode = '22023';
    end if;
  elsif v_mode = 'users' then
    v_groups := '{}'::uuid[];
    if coalesce(array_length(v_users, 1), 0) = 0 then
      raise exception 'audience_users_required' using errcode = '22023';
    end if;
  else
    if coalesce(array_length(v_groups, 1), 0) = 0
       or coalesce(array_length(v_users, 1), 0) = 0 then
      raise exception 'audience_groups_and_users_required' using errcode = '22023';
    end if;
  end if;

  v_row := private.vacancy_lock(p_id, p_expected_row_version);
  perform private.vacancy_assert_editable_content(v_row.status);

  select g into v_missing
  from unnest(v_groups) as g
  where not exists (select 1 from public.groups gr where gr.id = g)
  limit 1;
  if v_missing is not null then
    raise exception 'unknown_group_%', v_missing using errcode = '22023';
  end if;

  select u into v_missing
  from unnest(v_users) as u
  where not exists (
    select 1
    from public.users us
    where us.id = u
      and us.is_active
      and exists (
        select 1
        from public.student_enrollments se
        where se.user_id = us.id
          and se.status = 'active'
          and se.ended_at is null
      )
  )
  limit 1;
  if v_missing is not null then
    raise exception 'ineligible_audience_user_%', v_missing using errcode = '22023';
  end if;

  delete from public.vacancy_audience_groups where vacancy_id = p_id;
  delete from public.vacancy_audience_users where vacancy_id = p_id;

  insert into public.vacancy_audience_groups (vacancy_id, group_id)
  select p_id, g from unnest(v_groups) as g;
  insert into public.vacancy_audience_users (vacancy_id, user_id)
  select p_id, u from unnest(v_users) as u;

  update public.vacancies v set
    audience_mode = v_mode,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_assert_audience_consistent(p_id);
  perform private.vacancy_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'vacancy.set_audience',
    'vacancy',
    p_id,
    jsonb_build_object(
      'audience_mode', v_mode,
      'group_count', coalesce(array_length(v_groups, 1), 0),
      'user_count', coalesce(array_length(v_users, 1), 0)
    )
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

-- explicit_users_count: active enrollment required (matches set-audience eligibility)
create or replace function private.vacancy_preview_audience_count(p_vacancy_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text;
  v_count integer := 0;
  v_groups jsonb;
  v_explicit integer := 0;
begin
  select v.audience_mode into v_mode
  from public.vacancies v
  where v.id = p_vacancy_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select count(*)::integer into v_count
  from public.users u
  where u.is_active
    and exists (
      select 1
      from public.student_enrollments se
      where se.user_id = u.id
        and se.status = 'active'
        and se.ended_at is null
    )
    and (
      v_mode = 'all'
      or (
        v_mode in ('groups', 'groups_and_users')
        and exists (
          select 1
          from public.vacancy_audience_groups g
          join public.student_enrollments se
            on se.group_id = g.group_id
           and se.user_id = u.id
           and se.status = 'active'
           and se.ended_at is null
          where g.vacancy_id = p_vacancy_id
        )
      )
      or (
        v_mode in ('users', 'groups_and_users')
        and exists (
          select 1
          from public.vacancy_audience_users au
          where au.vacancy_id = p_vacancy_id
            and au.user_id = u.id
        )
      )
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object('id', gr.id, 'name', gr.name, 'member_count', gr.member_count)
      order by gr.name
    ),
    '[]'::jsonb
  )
  into v_groups
  from (
    select
      g0.id,
      g0.name,
      (
        select count(*)::integer
        from public.student_enrollments se
        join public.users u on u.id = se.user_id and u.is_active
        where se.group_id = g0.id
          and se.status = 'active'
          and se.ended_at is null
      ) as member_count
    from public.vacancy_audience_groups ag
    join public.groups g0 on g0.id = ag.group_id
    where ag.vacancy_id = p_vacancy_id
  ) gr;

  select count(distinct au.user_id)::integer into v_explicit
  from public.vacancy_audience_users au
  join public.users u on u.id = au.user_id and u.is_active
  where au.vacancy_id = p_vacancy_id
    and exists (
      select 1
      from public.student_enrollments se
      where se.user_id = u.id
        and se.status = 'active'
        and se.ended_at is null
    );

  return jsonb_build_object(
    'vacancy_id', p_vacancy_id,
    'audience_mode', v_mode,
    'recipient_count', coalesce(v_count, 0),
    'breakdown', jsonb_build_object(
      'all', (v_mode = 'all'),
      'groups', v_groups,
      'explicit_users_count', coalesce(v_explicit, 0)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Vacancy asset upload intent + finalize (Storage metadata fail-closed)
-- ---------------------------------------------------------------------------
create or replace function public.admin_create_vacancy_asset_upload_intent(
  p_vacancy_id uuid,
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
  v_vacancy public.vacancies;
  v_mime text := lower(btrim(coalesce(p_mime_type, '')));
  v_path text;
  v_id uuid;
  v_ttl integer := greatest(60, least(coalesce(p_ttl_seconds, 900), 3600));
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_vacancy from public.vacancies where id = p_vacancy_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform private.vacancy_assert_editable_content(v_vacancy.status);

  if v_mime not in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  ) then
    raise exception 'invalid_mime' using errcode = '22023';
  end if;

  v_path := 'vacancy/' || p_vacancy_id::text || '/' || gen_random_uuid()::text
    || case
      when v_mime = 'application/pdf' then '.pdf'
      when v_mime = 'image/png' then '.png'
      when v_mime = 'image/webp' then '.webp'
      else '.jpg'
    end;

  insert into public.vacancy_asset_upload_intents (
    vacancy_id, actor_user_id, storage_path, mime_type, expires_at
  ) values (
    p_vacancy_id, v_uid, v_path, v_mime, now() + make_interval(secs => v_ttl)
  )
  returning id into v_id;

  return jsonb_build_object(
    'intent_id', v_id,
    'mime_type', v_mime,
    'expires_at', now() + make_interval(secs => v_ttl)
  );
end;
$$;

create or replace function public.service_vacancy_upload_intent_storage_path(
  p_intent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_intent public.vacancy_asset_upload_intents;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  select * into v_intent
  from public.vacancy_asset_upload_intents
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

create or replace function public.admin_finalize_vacancy_asset_upload(
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
  v_intent public.vacancy_asset_upload_intents;
  v_obj record;
  v_asset public.vacancy_assets;
  v_meta jsonb;
  v_size bigint;
  v_mime text;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_intent
  from public.vacancy_asset_upload_intents
  where id = p_intent_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_intent.actor_user_id is distinct from v_uid then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_intent.finalized_asset_id is not null then
    select * into v_asset from public.vacancy_assets where id = v_intent.finalized_asset_id;
    return jsonb_build_object(
      'id', v_asset.id,
      'mime_type', v_asset.mime_type,
      'byte_size', v_asset.byte_size,
      'title', coalesce(nullif(btrim(p_title), ''), v_asset.title)
    );
  end if;
  if v_intent.expires_at < now() then
    raise exception 'intent_expired' using errcode = 'P0001';
  end if;

  perform private.vacancy_assert_editable_content(
    (select v.status from public.vacancies v where v.id = v_intent.vacancy_id)
  );

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
  if v_size is null or v_size <= 0 or v_size > 10485760 then
    raise exception 'invalid_byte_size' using errcode = '22023';
  end if;
  if v_mime is distinct from v_intent.mime_type then
    raise exception 'mime_mismatch' using errcode = '22023';
  end if;
  if v_intent.storage_path !~ ('^vacancy/' || v_intent.vacancy_id::text || '/') then
    raise exception 'invalid_storage_path' using errcode = '22023';
  end if;

  insert into public.vacancy_assets (
    vacancy_id, title, storage_bucket, storage_path, mime_type, byte_size, created_by
  ) values (
    v_intent.vacancy_id,
    left(coalesce(p_title, ''), 200),
    v_intent.storage_bucket,
    v_intent.storage_path,
    v_mime,
    v_size,
    v_uid
  )
  returning * into v_asset;

  update public.vacancy_asset_upload_intents
  set finalized_asset_id = v_asset.id
  where id = p_intent_id;

  perform private.content_write_domain_audit(
    'vacancy.finalize_asset',
    'vacancy',
    v_intent.vacancy_id,
    jsonb_build_object('asset_id', v_asset.id, 'mime_type', v_mime, 'byte_size', v_size)
  );

  return jsonb_build_object(
    'id', v_asset.id,
    'mime_type', v_asset.mime_type,
    'byte_size', v_asset.byte_size,
    'title', v_asset.title,
    'created_at', v_asset.created_at
  );
end;
$$;

-- Fail-closed: client-supplied path/MIME/size registration is forbidden.
create or replace function public.admin_register_vacancy_asset(
  p_vacancy_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_title text default '',
  p_checksum text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_admin_permission('content.write');
  raise exception 'deprecated_use_upload_intent'
    using errcode = '55000',
          hint = 'Use admin_create_vacancy_asset_upload_intent + admin_finalize_vacancy_asset_upload';
end;
$$;

-- ---------------------------------------------------------------------------
-- Student/admin signed download authorize (paths never returned to clients)
-- ---------------------------------------------------------------------------
create or replace function public.authorize_vacancy_asset_download(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_asset public.vacancy_assets;
  v_is_admin boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select * into v_asset from public.vacancy_assets where id = p_asset_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_is_admin := private.has_admin_permission(v_uid, 'content.read', 'global', null)
    or private.has_admin_permission(v_uid, 'content.write', 'global', null);

  if v_is_admin then
    return jsonb_build_object(
      'authorized', true,
      'mime_type', v_asset.mime_type,
      'byte_size', v_asset.byte_size,
      'title', v_asset.title
    );
  end if;

  if not private.vacancy_deliverable_to_user(v_asset.vacancy_id, v_uid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'authorized', true,
    'mime_type', v_asset.mime_type,
    'byte_size', v_asset.byte_size,
    'title', v_asset.title
  );
end;
$$;

create or replace function public.service_vacancy_asset_storage_path(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_asset public.vacancy_assets;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  select * into v_asset from public.vacancy_assets where id = p_asset_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'storage_bucket', v_asset.storage_bucket,
    'storage_path', v_asset.storage_path,
    'mime_type', v_asset.mime_type
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Moderation journal list (admin read)
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_vacancy_moderation_actions(
  p_vacancy_id uuid,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  v_uid := private.require_admin_permission('content.read');

  if not exists (select 1 from public.vacancies where id = p_vacancy_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', a.id,
          'action', a.action,
          'from_status', a.from_status,
          'to_status', a.to_status,
          'reason_text', a.reason_text,
          'created_at', a.created_at
        )
        order by a.created_at desc
      )
      from (
        select *
        from public.vacancy_moderation_actions ma
        where ma.vacancy_id = p_vacancy_id
        order by ma.created_at desc
        limit v_limit
      ) a
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.admin_create_vacancy_asset_upload_intent(uuid, text, integer)
  from public, anon;
grant execute on function public.admin_create_vacancy_asset_upload_intent(uuid, text, integer)
  to authenticated, service_role;

revoke all on function public.service_vacancy_upload_intent_storage_path(uuid)
  from public, anon, authenticated;
grant execute on function public.service_vacancy_upload_intent_storage_path(uuid)
  to service_role;

revoke all on function public.admin_finalize_vacancy_asset_upload(uuid, text)
  from public, anon;
grant execute on function public.admin_finalize_vacancy_asset_upload(uuid, text)
  to authenticated, service_role;

revoke all on function public.authorize_vacancy_asset_download(uuid)
  from public, anon;
grant execute on function public.authorize_vacancy_asset_download(uuid)
  to authenticated, service_role;

revoke all on function public.service_vacancy_asset_storage_path(uuid)
  from public, anon, authenticated;
grant execute on function public.service_vacancy_asset_storage_path(uuid)
  to service_role;

revoke all on function public.admin_list_vacancy_moderation_actions(uuid, integer)
  from public, anon;
grant execute on function public.admin_list_vacancy_moderation_actions(uuid, integer)
  to authenticated, service_role;

comment on function public.admin_register_vacancy_asset(uuid, text, text, bigint, text, text) is
  'DEPRECATED (P1): raises deprecated_use_upload_intent. Use intent+finalize instead.';
comment on function public.admin_create_vacancy_asset_upload_intent(uuid, text, integer) is
  'Stage 17 P1: service-side path under vacancy/{id}/; never returns storage_path.';
comment on function public.authorize_vacancy_asset_download(uuid) is
  'Authorize signed download for a vacancy asset. Paths resolved only by service RPC + Edge.';

-- ---------------------------------------------------------------------------
-- Vacancy media cleanup worker (mirrors content-media pending-only leases)
-- ---------------------------------------------------------------------------
alter table public.vacancy_media_cleanup_queue
  add column if not exists claim_token uuid null,
  add column if not exists claim_expires_at timestamptz null;

create index if not exists vacancy_media_cleanup_queue_claim_idx
  on public.vacancy_media_cleanup_queue (claim_expires_at)
  where processed_at is null and claim_token is not null;

create or replace function public.claim_vacancy_media_cleanup_batch(
  p_limit integer default 10,
  p_lease_seconds integer default 600
)
returns setof public.vacancy_media_cleanup_queue
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
    from public.vacancy_media_cleanup_queue q
    where q.processed_at is null
      and (q.claim_expires_at is null or q.claim_expires_at < now())
    order by q.enqueued_at
    limit v_limit
    for update skip locked
  ), upd as (
    update public.vacancy_media_cleanup_queue q
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

create or replace function public.complete_vacancy_media_cleanup(
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
  delete from public.vacancy_media_cleanup_queue
  where id = p_queue_id
    and claim_token = p_claim_token;
end;
$$;

create or replace function public.fail_vacancy_media_cleanup(
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
  update public.vacancy_media_cleanup_queue
  set claim_token = null,
      claim_expires_at = null,
      last_error = left(coalesce(p_error, ''), 500)
  where id = p_queue_id
    and claim_token = p_claim_token;
end;
$$;

revoke all on function public.claim_vacancy_media_cleanup_batch(integer, integer)
  from public, anon, authenticated;
grant execute on function public.claim_vacancy_media_cleanup_batch(integer, integer)
  to service_role;

revoke all on function public.complete_vacancy_media_cleanup(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.complete_vacancy_media_cleanup(uuid, uuid)
  to service_role;

revoke all on function public.fail_vacancy_media_cleanup(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.fail_vacancy_media_cleanup(uuid, uuid, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- Mobile feed: typed asset descriptors (no raw UUID labels in UI)
-- ---------------------------------------------------------------------------
create or replace function public.get_my_vacancies()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_groups uuid[];
  v_eligible boolean;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.users u where u.id = v_uid and u.is_active) then
    return '[]'::jsonb;
  end if;

  v_groups := private.current_user_active_group_ids();
  v_eligible := coalesce(array_length(v_groups, 1), 0) > 0;
  if not v_eligible then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', v.id,
          'title', v.title,
          'company_name', v.company_name,
          'summary', v.summary,
          'description', v.description,
          'employment_type', v.employment_type,
          'work_format', v.work_format,
          'location', v.location,
          'salary_text', v.salary_text,
          'external_url', v.external_url,
          'origin', v.origin,
          'is_demo', (v.origin = 'demo'),
          'published_at', v.published_at,
          'expires_at', v.expires_at,
          'has_contacts', (v.contacts <> '{}'::jsonb),
          'assets', coalesce(
            (
              select jsonb_agg(
                jsonb_build_object(
                  'id', a.id,
                  'title', coalesce(nullif(btrim(a.title), ''), ''),
                  'mime_type', a.mime_type
                )
                order by a.created_at, a.id
              )
              from public.vacancy_assets a
              where a.vacancy_id = v.id
            ),
            '[]'::jsonb
          )
        )
        order by v.priority desc, v.published_at desc nulls last
      )
      from public.vacancies v
      where v.status = 'published'
        and not v.is_hidden
        and (v.starts_at is null or v.starts_at <= v_now)
        and (v.ends_at is null or v.ends_at > v_now)
        and (v.expires_at is null or v.expires_at > v_now)
        and (
          v.audience_mode = 'all'
          or (
            v.audience_mode in ('groups', 'groups_and_users')
            and exists (
              select 1
              from public.vacancy_audience_groups g
              where g.vacancy_id = v.id
                and g.group_id = any (v_groups)
            )
          )
          or (
            v.audience_mode in ('users', 'groups_and_users')
            and exists (
              select 1
              from public.vacancy_audience_users au
              where au.vacancy_id = v.id
                and au.user_id = v_uid
            )
          )
        )
    ),
    '[]'::jsonb
  );
end;
$$;

commit;
