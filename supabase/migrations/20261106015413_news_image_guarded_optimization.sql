-- Guarded optimization of private news images. No object is deleted by this migration.
-- Deploy the matching news-media guard first, then apply only this reviewed
-- migration. During the gap guarded deletes fail closed. Never invoke the
-- optimization until both are verified active.
create table if not exists private.news_image_upload_reservations (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null,
  path text not null unique,
  purpose text not null check (purpose in ('backup','optimized')),
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp')),
  used_by_run uuid,
  created_at timestamptz not null default now()
);
revoke all on table private.news_image_upload_reservations from public, anon, authenticated;

-- Reserve before upload. The deletion guard protects this path immediately,
-- eliminating the check/delete race while an optimization is being prepared.
create or replace function public.admin_reserve_news_optimization_upload(
  p_purpose text, p_mime_type text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_ext text;
  v_row private.news_image_upload_reservations%rowtype;
begin
  v_uid := private.require_admin_permission('content.write');
  perform private.require_admin_permission('content.publish');
  if p_purpose is null or p_purpose not in ('backup','optimized')
     or p_mime_type is null or p_mime_type not in ('image/jpeg','image/png','image/webp')
     or (p_purpose='optimized' and p_mime_type <> 'image/jpeg') then
    raise exception 'invalid_optimization_upload' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_uid::text, 719344));
  if (select count(*) from private.news_image_upload_reservations
      where actor_id=v_uid and used_by_run is null) >= 20 then
    raise exception 'too_many_open_reservations' using errcode='54000';
  end if;
  v_ext := case p_mime_type when 'image/png' then 'png' when 'image/webp' then 'webp' else 'jpg' end;
  insert into private.news_image_upload_reservations(actor_id,path,purpose,mime_type)
  values(v_uid,'news/' || v_uid::text || '/' || gen_random_uuid()::text || '.' || v_ext,
         p_purpose,p_mime_type) returning * into v_row;
  return jsonb_build_object('reservation_id',v_row.id,'path',v_row.path,'purpose',v_row.purpose);
end $$;
revoke all on function public.admin_reserve_news_optimization_upload(text,text) from public, anon;
grant execute on function public.admin_reserve_news_optimization_upload(text,text) to authenticated;

-- Releasing an unused reservation never deletes Storage bytes; the normal
-- guarded delete may be called afterward if the operator chooses cleanup.
create or replace function public.admin_release_news_optimization_upload(p_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_uid uuid; v_row private.news_image_upload_reservations%rowtype;
begin
  v_uid := private.require_admin_permission('content.write');
  perform private.require_admin_permission('content.publish');
  select * into v_row from private.news_image_upload_reservations where id=p_id for update;
  if not found or v_row.actor_id <> v_uid or v_row.used_by_run is not null then
    raise exception 'reservation_unavailable' using errcode='42501';
  end if;
  delete from private.news_image_upload_reservations where id=p_id;
  return true;
end $$;
revoke all on function public.admin_release_news_optimization_upload(uuid) from public, anon;
grant execute on function public.admin_release_news_optimization_upload(uuid) to authenticated;

-- Lost upload-intent responses can be investigated without replaying writes.
create or replace function public.admin_list_my_news_optimization_uploads()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_uid uuid; v_result jsonb;
begin
  v_uid := private.require_admin_permission('content.write');
  perform private.require_admin_permission('content.publish');
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id',u.id,
      'path',u.path,'purpose',u.purpose,'mime_type',u.mime_type,
      'created_at',u.created_at) order by u.created_at),'[]'::jsonb)
    into v_result from private.news_image_upload_reservations u
    where u.actor_id=v_uid and u.used_by_run is null;
  return v_result;
end $$;
revoke all on function public.admin_list_my_news_optimization_uploads() from public, anon;
grant execute on function public.admin_list_my_news_optimization_uploads() to authenticated;

create table if not exists private.news_image_optimization_runs (
  id uuid primary key default gen_random_uuid(),
  news_id uuid not null,
  original_path text not null,
  backup_path text not null,
  optimized_path text not null,
  original_etag text not null,
  original_size bigint not null,
  original_mime text not null,
  optimized_etag text not null,
  base_version integer not null,
  applied_version integer not null,
  rollback_version integer,
  applied_by uuid not null,
  applied_at timestamptz not null default now(),
  rolled_back_at timestamptz,
  unique (news_id, base_version),
  check (original_path <> backup_path and backup_path <> optimized_path
         and original_path <> optimized_path)
);
revoke all on table private.news_image_optimization_runs from public, anon, authenticated;

-- Existing archived-news cleanup uses this predicate to identify orphans.
-- Teach it about reservations and retained backups so it does not enqueue
-- protected objects for repeated cleanup after the associated post is removed.
create or replace function private.news_media_path_still_referenced(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.news_posts n
    where nullif(btrim(n.image_path),'') = nullif(btrim(p_path),'')
  ) or exists (
    select 1 from public.news_versions v
    where nullif(btrim(v.snapshot->>'image_path'),'') = nullif(btrim(p_path),'')
  ) or exists (
    select 1 from private.news_image_upload_reservations u where u.path=p_path
  ) or exists (
    select 1 from private.news_image_optimization_runs r
    where p_path in (r.original_path,r.backup_path,r.optimized_path)
  );
$$;
revoke all on function private.news_media_path_still_referenced(text) from public, anon, authenticated;

-- Uses metadata recorded by Storage; only non-multipart MD5 ETags are accepted.
create or replace function private.news_optimization_object_matches(
  p_path text, p_etag text, p_size bigint, p_mime text
) returns boolean language sql stable security definer set search_path = '' as $$
  select p_path is not null and p_path ~ '^news/[0-9a-f-]{36}/[^/]+$'
     and p_etag ~ '^[0-9a-f]{32}$' and p_size > 0
     and exists (
       select 1 from storage.objects o
       where o.bucket_id = 'news-media' and o.name = p_path
         and lower(btrim(coalesce(o.metadata->>'eTag', ''), '"')) = p_etag
         and case when coalesce(o.metadata->>'size','') ~ '^[0-9]+$'
                  then (o.metadata->>'size')::bigint = p_size else false end
         and lower(coalesce(o.metadata->>'mimetype','')) = p_mime
     );
$$;
revoke all on function private.news_optimization_object_matches(text,text,bigint,text)
  from public, anon, authenticated;

-- Edge deletion guard. A retained or historically referenced object is never
-- eligible for deletion through news-media's user-facing delete endpoint.
create or replace function public.admin_can_delete_news_media_guarded(p_path text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin_permission('content.write');
  if p_path is null or p_path !~ '^news/[0-9a-f-]{36}/[^/]+$' then
    return false;
  end if;
  return not private.news_media_path_still_referenced(p_path)
    and not exists (select 1 from private.news_image_upload_reservations u where u.path=p_path)
    and not exists (
      select 1 from private.news_image_optimization_runs r
      where p_path in (r.original_path, r.backup_path, r.optimized_path)
    );
end;
$$;
revoke all on function public.admin_can_delete_news_media_guarded(text) from public, anon;
grant execute on function public.admin_can_delete_news_media_guarded(text) to authenticated;

-- This RPC is intentionally narrower than the generic news editor: it changes
-- only image_path and row version, refuses a changed post, verifies a separate
-- backup and a smaller actual JPEG object, and preserves existing versions.
create or replace function public.admin_optimize_news_image_guarded(
  p_news_id uuid, p_expected_version integer, p_expected_old_path text,
  p_backup_path text, p_new_path text, p_old_etag text, p_old_size bigint,
  p_old_mime text, p_new_etag text, p_new_size bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_post public.news_posts%rowtype;
  v_run private.news_image_optimization_runs%rowtype;
  v_backup private.news_image_upload_reservations%rowtype;
  v_new private.news_image_upload_reservations%rowtype;
begin
  v_uid := private.require_admin_permission('content.write');
  perform private.require_admin_permission('content.publish');
  select * into v_post from public.news_posts where id = p_news_id for update;
  if not found then raise exception 'not_found' using errcode='P0002'; end if;
  if v_post.status <> 'published' or v_post.version_number <> p_expected_version
     or v_post.image_path is distinct from p_expected_old_path then
    raise exception 'news_version_conflict' using errcode='40001';
  end if;
  if p_expected_version is null or p_expected_old_path is null or p_backup_path is null or p_new_path is null
     or p_old_etag is null or p_old_size is null or p_old_mime is null
     or p_new_etag is null or p_new_size is null or p_old_size <= 0
     or p_expected_old_path = p_backup_path or p_expected_old_path = p_new_path
     or p_backup_path = p_new_path
     or p_backup_path not like ('news/' || v_uid::text || '/%')
     or p_new_path not like ('news/' || v_uid::text || '/%')
     or p_old_mime not in ('image/jpeg','image/png','image/webp')
     or p_new_size <= 0 or p_new_size >= p_old_size or p_new_size > 5242880 then
    raise exception 'invalid_optimization' using errcode='22023';
  end if;
  select * into v_backup from private.news_image_upload_reservations
    where path=p_backup_path for update;
  if not found or v_backup.actor_id <> v_uid or v_backup.purpose <> 'backup'
     or v_backup.mime_type <> p_old_mime or v_backup.used_by_run is not null then
    raise exception 'invalid_backup_reservation' using errcode='22023';
  end if;
  select * into v_new from private.news_image_upload_reservations
    where path=p_new_path for update;
  if not found or v_new.actor_id <> v_uid or v_new.purpose <> 'optimized'
     or v_new.mime_type <> 'image/jpeg' or v_new.used_by_run is not null then
    raise exception 'invalid_optimized_reservation' using errcode='22023';
  end if;
  if not coalesce(private.news_optimization_object_matches(p_expected_old_path,p_old_etag,p_old_size,p_old_mime), false)
     or not coalesce(private.news_optimization_object_matches(p_backup_path,p_old_etag,p_old_size,p_old_mime), false)
     or not coalesce(private.news_optimization_object_matches(p_new_path,p_new_etag,p_new_size,'image/jpeg'), false) then
    raise exception 'storage_verification_failed' using errcode='22023';
  end if;
  perform private.news_snapshot_version(p_news_id);
  update public.news_posts set image_path=p_new_path,
    version_number=version_number+1, updated_by=v_uid, updated_at=now()
    where id=p_news_id returning * into v_post;
  perform private.news_snapshot_version(p_news_id);
  insert into private.news_image_optimization_runs
    (news_id, original_path, backup_path, optimized_path, original_etag, original_size, original_mime,
     optimized_etag, base_version, applied_version, applied_by)
  values (p_news_id,p_expected_old_path,p_backup_path,p_new_path,p_old_etag,p_old_size,p_old_mime,
          p_new_etag,p_expected_version,v_post.version_number,v_uid)
  returning * into v_run;
  update private.news_image_upload_reservations set used_by_run=v_run.id
    where id in (v_backup.id,v_new.id);
  perform private.admin_write_audit('news.optimize_image', 'news_post', p_news_id::text,
    jsonb_build_object('run_id',v_run.id,'version_number',v_post.version_number));
  return jsonb_build_object('run_id',v_run.id,'version_number',v_post.version_number);
end;
$$;
revoke all on function public.admin_optimize_news_image_guarded(uuid,integer,text,text,text,text,bigint,text,text,bigint) from public, anon;
grant execute on function public.admin_optimize_news_image_guarded(uuid,integer,text,text,text,text,bigint,text,text,bigint) to authenticated;

-- Rollback is a new version, not destructive history rewriting. The separate
-- backup allows restoring even if an unrelated actor removed the old object.
create or replace function public.admin_rollback_news_image_guarded(
  p_run_id uuid, p_expected_current_version integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_run private.news_image_optimization_runs%rowtype;
  v_post public.news_posts%rowtype;
  v_path text;
begin
  v_uid := private.require_admin_permission('content.write');
  perform private.require_admin_permission('content.publish');
  select * into v_run from private.news_image_optimization_runs where id=p_run_id;
  if not found then raise exception 'run_not_found' using errcode='P0002'; end if;
  -- Canonical lock order is news row then optimization run.
  select * into v_post from public.news_posts where id=v_run.news_id for update;
  if not found then raise exception 'not_found' using errcode='P0002'; end if;
  select * into v_run from private.news_image_optimization_runs where id=p_run_id for update;
  if p_expected_current_version is null or v_run.rolled_back_at is not null or v_post.status <> 'published'
     or v_post.version_number <> p_expected_current_version
     or v_post.image_path is distinct from v_run.optimized_path then
    raise exception 'news_version_conflict' using errcode='40001';
  end if;
  -- Original etag alone is not enough for the initial apply; both original and
  -- backup size+MIME were already verified in the same transaction then.
  if coalesce(private.news_optimization_object_matches(v_run.original_path,
      v_run.original_etag,v_run.original_size,v_run.original_mime), false) then
    v_path := v_run.original_path;
  else
    if not coalesce(private.news_optimization_object_matches(v_run.backup_path,
        v_run.original_etag,v_run.original_size,v_run.original_mime), false) then
      raise exception 'rollback_backup_missing' using errcode='22023';
    end if;
    v_path := v_run.backup_path;
  end if;
  perform private.news_snapshot_version(v_run.news_id);
  update public.news_posts set image_path=v_path, version_number=version_number+1,
    updated_by=v_uid, updated_at=now() where id=v_run.news_id returning * into v_post;
  perform private.news_snapshot_version(v_run.news_id);
  update private.news_image_optimization_runs set rolled_back_at=now(),
    rollback_version=v_post.version_number where id=p_run_id;
  perform private.admin_write_audit('news.rollback_image_optimization', 'news_post', v_run.news_id::text,
    jsonb_build_object('run_id',p_run_id,'version_number',v_post.version_number));
  return jsonb_build_object('run_id',p_run_id,'version_number',v_post.version_number);
end;
$$;
revoke all on function public.admin_rollback_news_image_guarded(uuid,integer) from public, anon;
grant execute on function public.admin_rollback_news_image_guarded(uuid,integer) to authenticated;

-- Read-only recovery when the client lost a response after an apply. The
-- optimized path is unguessable and already present in the operator journal.
create or replace function public.admin_find_news_image_optimization(
  p_news_id uuid, p_optimized_path text
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_run private.news_image_optimization_runs%rowtype;
begin
  perform private.require_admin_permission('content.write');
  perform private.require_admin_permission('content.publish');
  select * into v_run from private.news_image_optimization_runs
    where news_id=p_news_id and optimized_path=p_optimized_path
    order by applied_at desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object('run_id',v_run.id,'news_id',v_run.news_id,
    'original_path',v_run.original_path,'backup_path',v_run.backup_path,
    'optimized_path',v_run.optimized_path,'original_etag',v_run.original_etag,
    'original_size',v_run.original_size,'original_mime',v_run.original_mime,
    'optimized_etag',v_run.optimized_etag,'base_version',v_run.base_version,
    'applied_version',v_run.applied_version,'rollback_version',v_run.rollback_version,
    'rolled_back_at',v_run.rolled_back_at);
end $$;
revoke all on function public.admin_find_news_image_optimization(uuid,text) from public, anon;
grant execute on function public.admin_find_news_image_optimization(uuid,text) to authenticated;

-- Begin a clean, exclusive image-only home-promo edit without reusing a
-- draft that belongs to someone else. Publishing still uses existing CAS RPCs.
create or replace function public.admin_begin_home_promo_image_optimization(
  p_id uuid, p_expected_row_version integer, p_expected_asset_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_row public.content_items%rowtype;
begin
  v_uid := private.require_admin_permission('content.write');
  perform private.require_admin_permission('content.publish');
  if p_id is null or p_expected_row_version is null or p_expected_asset_id is null then
    raise exception 'invalid_arguments' using errcode='22023';
  end if;
  select * into v_row from public.content_items where id=p_id for update;
  if not found then raise exception 'not_found' using errcode='P0002'; end if;
  if v_row.template_key <> 'home_promo_v1' or v_row.status <> 'published'
     or v_row.row_version <> p_expected_row_version
     or v_row.payload->>'image_asset_id' is distinct from p_expected_asset_id::text then
    raise exception 'content_version_conflict' using errcode='40001';
  end if;
  if exists (select 1 from public.content_item_working_drafts where content_item_id=p_id) then
    raise exception 'working_draft_already_exists' using errcode='55000';
  end if;
  if not exists (select 1 from public.content_assets a
                 join storage.objects o on o.bucket_id=a.storage_bucket and o.name=a.storage_path
                 where a.id=p_expected_asset_id and a.content_item_id=p_id) then
    raise exception 'original_asset_missing' using errcode='P0002';
  end if;
  -- admin_begin_content_edit locks the same canonical row, snapshots the
  -- current payload and creates an initially empty draft_asset_ids array.
  return public.admin_begin_content_edit(p_id);
end;
$$;
revoke all on function public.admin_begin_home_promo_image_optimization(uuid,integer,uuid) from public, anon;
grant execute on function public.admin_begin_home_promo_image_optimization(uuid,integer,uuid) to authenticated;
