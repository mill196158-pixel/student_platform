-- Stage 12.3 — permanent delete for archived news + restore-as-draft.
--
-- Clients must NOT DELETE news tables directly. All hard-delete goes through
-- admin_delete_archived_news (SECURITY DEFINER, content.publish).
-- Storage object removal is best-effort via Edge; orphan paths are queued
-- when cleanup fails so a later worker/retry can finish the job.

-- ---------------------------------------------------------------------------
-- 1) Queue for failed / pending news-media cleanup (no secrets, path only)
-- ---------------------------------------------------------------------------
create table if not exists public.news_media_cleanup_queue (
  id uuid primary key default gen_random_uuid(),
  object_path text not null,
  source_news_post_id uuid null,
  source_title text null,
  status text not null default 'pending'
    check (status in ('pending', 'done', 'failed')),
  error_text text null,
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists news_media_cleanup_queue_pending_path_uidx
  on public.news_media_cleanup_queue (object_path)
  where status = 'pending';

create index if not exists news_media_cleanup_queue_status_idx
  on public.news_media_cleanup_queue (status, created_at);

comment on table public.news_media_cleanup_queue is
  'Pending private news-media object cleanup after archived news hard-delete. Never store signed URLs or secrets.';

alter table public.news_media_cleanup_queue enable row level security;
alter table public.news_media_cleanup_queue force row level security;

revoke all on table public.news_media_cleanup_queue from public;
revoke all on table public.news_media_cleanup_queue from anon;
revoke all on table public.news_media_cleanup_queue from authenticated;

-- ---------------------------------------------------------------------------
-- 2) Helpers: collect snapshot paths + orphan check
-- ---------------------------------------------------------------------------
create or replace function private.news_collect_media_paths(p_post_id uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct path), '{}'::text[])
  from (
    select nullif(btrim(n.image_path), '') as path
    from public.news_posts n
    where n.id = p_post_id
    union
    select nullif(btrim(v.snapshot->>'image_path'), '') as path
    from public.news_versions v
    where v.news_post_id = p_post_id
  ) s
  where path is not null;
$$;

revoke all on function private.news_collect_media_paths(uuid) from public, anon, authenticated;
grant execute on function private.news_collect_media_paths(uuid) to service_role;

create or replace function private.news_media_path_still_referenced(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.news_posts n
    where nullif(btrim(n.image_path), '') = nullif(btrim(p_path), '')
  )
  or exists (
    select 1
    from public.news_versions v
    where nullif(btrim(v.snapshot->>'image_path'), '') = nullif(btrim(p_path), '')
  );
$$;

revoke all on function private.news_media_path_still_referenced(text) from public, anon, authenticated;
grant execute on function private.news_media_path_still_referenced(text) to service_role;

-- ---------------------------------------------------------------------------
-- 3) Restore archived → draft
-- ---------------------------------------------------------------------------
create or replace function public.admin_restore_archived_news(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_row.status is distinct from 'archived' then
    raise exception 'news_must_be_archived' using errcode = 'P0001';
  end if;

  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    status = 'draft',
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.restore_archived',
    'news_post',
    p_id::text,
    jsonb_build_object(
      'previous_status', 'archived',
      'status', 'draft',
      'title', v_row.title,
      'version_number', v_row.version_number
    )
  );

  return private.news_post_to_json(v_row);
end;
$$;

revoke all on function public.admin_restore_archived_news(uuid) from public, anon;
grant execute on function public.admin_restore_archived_news(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) Hard-delete archived news (+ cascade versions/views)
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_archived_news(p_post_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
  v_title text;
  v_previous_status public.news_post_status;
  v_candidate_paths text[];
  v_delete_paths text[] := '{}'::text[];
  v_path text;
begin
  v_uid := private.require_admin_permission('content.publish');

  select * into v_row from public.news_posts where id = p_post_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_row.status is distinct from 'archived' then
    raise exception 'news_must_be_archived' using errcode = 'P0001';
  end if;

  v_title := v_row.title;
  v_previous_status := v_row.status;
  v_candidate_paths := private.news_collect_media_paths(p_post_id);

  -- Cascade removes news_versions + news_views via ON DELETE CASCADE.
  delete from public.news_posts where id = p_post_id;

  -- Server-side orphan check only (never trust the client).
  foreach v_path in array v_candidate_paths loop
    if v_path is not null
       and not private.news_media_path_still_referenced(v_path) then
      v_delete_paths := array_append(v_delete_paths, v_path);
    end if;
  end loop;

  perform private.admin_write_audit(
    'news.delete_archived',
    'news_post',
    p_post_id::text,
    jsonb_build_object(
      'id', p_post_id,
      'title', v_title,
      'previous_status', v_previous_status,
      'candidate_media_paths', to_jsonb(v_candidate_paths),
      'media_paths_to_delete', to_jsonb(v_delete_paths),
      'tombstone', true
    )
  );

  return jsonb_build_object(
    'deleted', true,
    'id', p_post_id,
    'title', v_title,
    'previous_status', v_previous_status,
    'candidate_media_paths', to_jsonb(v_candidate_paths),
    'media_paths_to_delete', to_jsonb(v_delete_paths)
  );
end;
$$;

revoke all on function public.admin_delete_archived_news(uuid) from public, anon;
grant execute on function public.admin_delete_archived_news(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) Record failed Storage cleanup for later retry
-- ---------------------------------------------------------------------------
create or replace function public.admin_record_news_media_cleanup_failure(
  p_paths text[],
  p_source_news_post_id uuid default null,
  p_source_title text default null,
  p_error_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_path text;
  v_count integer := 0;
  v_error text;
begin
  v_uid := private.require_admin_permission('content.publish');
  v_error := left(coalesce(nullif(btrim(p_error_text), ''), 'storage_cleanup_failed'), 500);

  foreach v_path in array coalesce(p_paths, '{}'::text[]) loop
    v_path := nullif(btrim(v_path), '');
    if v_path is null then
      continue;
    end if;

    -- Never queue a path that is still referenced by another post/version.
    if private.news_media_path_still_referenced(v_path) then
      continue;
    end if;

    insert into public.news_media_cleanup_queue (
      object_path,
      source_news_post_id,
      source_title,
      status,
      error_text,
      attempts,
      updated_at
    ) values (
      v_path,
      p_source_news_post_id,
      left(coalesce(p_source_title, ''), 200),
      'pending',
      v_error,
      1,
      now()
    )
    on conflict (object_path) where status = 'pending'
    do update set
      error_text = excluded.error_text,
      attempts = public.news_media_cleanup_queue.attempts + 1,
      updated_at = now(),
      source_news_post_id = coalesce(
        excluded.source_news_post_id,
        public.news_media_cleanup_queue.source_news_post_id
      ),
      source_title = coalesce(
        nullif(excluded.source_title, ''),
        public.news_media_cleanup_queue.source_title
      );

    v_count := v_count + 1;
  end loop;

  perform private.admin_write_audit(
    'news.media_cleanup_pending',
    'news_media',
    coalesce(p_source_news_post_id::text, 'unknown'),
    jsonb_build_object(
      'queued_count', v_count,
      'title', p_source_title
    )
  );

  return jsonb_build_object('queued', v_count);
end;
$$;

revoke all on function public.admin_record_news_media_cleanup_failure(text[], uuid, text, text)
  from public, anon;
grant execute on function public.admin_record_news_media_cleanup_failure(text[], uuid, text, text)
  to authenticated, service_role;

comment on function public.admin_delete_archived_news(uuid) is
  'Hard-delete archived news_posts only. Returns orphan media paths for Edge cleanup.';
comment on function public.admin_restore_archived_news(uuid) is
  'Restore archived news_posts to draft status.';
