-- Stage 14.1.1 — vacancy draft asset visibility (server-owned).
-- New migration only; does not edit applied migrations.
--
-- Goals:
--   * Assets finalized while a working draft exists are never student-visible
--     until that draft is published (same transaction as promote).
--   * Discard queues/deletes draft-bound assets before deleting the draft.
--   * Pre-existing canonical assets (working_draft_id IS NULL) stay public.
--   * Visibility authority is vacancy_assets.working_draft_id, not client lists.

begin;

-- ---------------------------------------------------------------------------
-- 1. Schema: draft ownership on vacancy_assets
-- ---------------------------------------------------------------------------
alter table public.vacancy_assets
  add column if not exists working_draft_id uuid null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'vacancy_assets_working_draft_fkey'
  ) then
    alter table public.vacancy_assets
      add constraint vacancy_assets_working_draft_fkey
      foreign key (working_draft_id)
      references public.vacancy_working_drafts (id)
      on delete restrict;
  end if;
end;
$$;

create index if not exists vacancy_assets_working_draft_idx
  on public.vacancy_assets (working_draft_id)
  where working_draft_id is not null;

comment on column public.vacancy_assets.working_draft_id is
  'When set, asset belongs to an open vacancy working draft and must not appear in student serializers until publish clears the FK.';

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
create or replace function private.vacancy_working_draft_id(p_vacancy_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select d.id
  from public.vacancy_working_drafts d
  where d.vacancy_id = p_vacancy_id
  limit 1;
$$;

revoke all on function private.vacancy_working_draft_id(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_working_draft_id(uuid) to service_role;

create or replace function private.vacancy_assert_asset_upload_allowed(
  p_vacancy_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_draft_id uuid;
begin
  select v.status into v_status
  from public.vacancies v
  where v.id = p_vacancy_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_draft_id := private.vacancy_working_draft_id(p_vacancy_id);
  if v_draft_id is not null then
    return v_draft_id;
  end if;

  perform private.vacancy_assert_editable_content(v_status);
  return null;
end;
$$;

revoke all on function private.vacancy_assert_asset_upload_allowed(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_assert_asset_upload_allowed(uuid)
  to service_role;

create or replace function private.vacancy_queue_draft_bound_assets(
  p_vacancy_id uuid,
  p_working_draft_id uuid,
  p_title text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_queued integer := 0;
  v_id uuid;
begin
  if p_working_draft_id is null then
    return 0;
  end if;

  for v_id in
    select a.id
    from public.vacancy_assets a
    where a.vacancy_id = p_vacancy_id
      and a.working_draft_id = p_working_draft_id
  loop
    insert into public.vacancy_media_cleanup_queue (
      storage_bucket, storage_path, source_vacancy_id, source_title
    )
    select a.storage_bucket, a.storage_path, p_vacancy_id,
           left(coalesce(p_title, ''), 200)
    from public.vacancy_assets a
    where a.id = v_id
    on conflict do nothing;

    delete from public.vacancy_assets where id = v_id;
    v_queued := v_queued + 1;
  end loop;

  return v_queued;
end;
$$;

revoke all on function private.vacancy_queue_draft_bound_assets(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function private.vacancy_queue_draft_bound_assets(uuid, uuid, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 3. Upload intent + finalize: bind new assets to open working draft
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
  v_mime text := lower(btrim(coalesce(p_mime_type, '')));
  v_path text;
  v_id uuid;
  v_ttl integer := greatest(60, least(coalesce(p_ttl_seconds, 900), 3600));
  v_draft_id uuid;
begin
  v_uid := private.require_admin_permission('content.write');
  v_draft_id := private.vacancy_assert_asset_upload_allowed(p_vacancy_id);

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
    'expires_at', now() + make_interval(secs => v_ttl),
    'working_draft_id', v_draft_id
  );
end;
$$;

revoke all on function public.admin_create_vacancy_asset_upload_intent(uuid, text, integer)
  from public, anon;
grant execute on function public.admin_create_vacancy_asset_upload_intent(uuid, text, integer)
  to authenticated, service_role;

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
  v_draft_id uuid;
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
      'title', coalesce(nullif(btrim(p_title), ''), v_asset.title),
      'working_draft_id', v_asset.working_draft_id,
      'is_draft_asset', (v_asset.working_draft_id is not null)
    );
  end if;
  if v_intent.expires_at < now() then
    raise exception 'intent_expired' using errcode = 'P0001';
  end if;

  -- Lock vacancy + assert upload path; bind to current open draft if any.
  v_draft_id := private.vacancy_assert_asset_upload_allowed(v_intent.vacancy_id);

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
    vacancy_id,
    title,
    storage_bucket,
    storage_path,
    mime_type,
    byte_size,
    created_by,
    working_draft_id
  ) values (
    v_intent.vacancy_id,
    left(coalesce(p_title, ''), 200),
    v_intent.storage_bucket,
    v_intent.storage_path,
    v_mime,
    v_size,
    v_uid,
    v_draft_id
  )
  returning * into v_asset;

  if v_draft_id is not null then
    update public.vacancy_working_drafts d
    set draft_asset_ids = (
          select coalesce(array_agg(distinct x), '{}'::uuid[])
          from unnest(d.draft_asset_ids || array[v_asset.id]) as x
        ),
        updated_by = v_uid,
        updated_at = now(),
        row_version = d.row_version + 1
    where d.id = v_draft_id;
  end if;

  update public.vacancy_asset_upload_intents
  set finalized_asset_id = v_asset.id
  where id = p_intent_id;

  perform private.content_write_domain_audit(
    'vacancy.finalize_asset',
    'vacancy',
    v_intent.vacancy_id,
    jsonb_build_object(
      'asset_id', v_asset.id,
      'mime_type', v_mime,
      'byte_size', v_size,
      'working_draft_id', v_draft_id
    )
  );

  return jsonb_build_object(
    'id', v_asset.id,
    'mime_type', v_asset.mime_type,
    'byte_size', v_asset.byte_size,
    'title', v_asset.title,
    'created_at', v_asset.created_at,
    'working_draft_id', v_asset.working_draft_id,
    'is_draft_asset', (v_asset.working_draft_id is not null)
  );
end;
$$;

revoke all on function public.admin_finalize_vacancy_asset_upload(uuid, text)
  from public, anon;
grant execute on function public.admin_finalize_vacancy_asset_upload(uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Student serializer: only canonical (non-draft) assets
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
                and a.working_draft_id is null
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

revoke all on function public.get_my_vacancies() from public, anon;
grant execute on function public.get_my_vacancies() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Admin JSON: all assets + draft markers
-- ---------------------------------------------------------------------------
create or replace function private.vacancy_to_admin_json(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.vacancies;
  v_has_draft boolean := false;
begin
  select * into v_row from public.vacancies where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.vacancy_working_drafts d
    where d.vacancy_id = p_id
  ) into v_has_draft;

  return jsonb_build_object(
    'id', v_row.id,
    'title', v_row.title,
    'company_name', v_row.company_name,
    'summary', v_row.summary,
    'description', v_row.description,
    'employment_type', v_row.employment_type,
    'work_format', v_row.work_format,
    'location', v_row.location,
    'salary_text', v_row.salary_text,
    'external_url', v_row.external_url,
    'contacts', v_row.contacts,
    'status', v_row.status,
    'origin', v_row.origin,
    'legacy_key', v_row.legacy_key,
    'priority', v_row.priority,
    'starts_at', v_row.starts_at,
    'ends_at', v_row.ends_at,
    'expires_at', v_row.expires_at,
    'is_hidden', v_row.is_hidden,
    'audience_mode', v_row.audience_mode,
    'version_number', v_row.version_number,
    'row_version', v_row.row_version,
    'submitted_by', v_row.submitted_by,
    'submitted_at', v_row.submitted_at,
    'moderated_by', v_row.moderated_by,
    'moderated_at', v_row.moderated_at,
    'published_at', v_row.published_at,
    'rejection_reason', v_row.rejection_reason,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at,
    'has_working_draft', v_has_draft,
    'audience_group_ids', coalesce(
      (
        select jsonb_agg(g.group_id order by g.group_id)
        from public.vacancy_audience_groups g
        where g.vacancy_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'audience_user_ids', coalesce(
      (
        select jsonb_agg(u.user_id order by u.user_id)
        from public.vacancy_audience_users u
        where u.vacancy_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'asset_ids', coalesce(
      (
        select jsonb_agg(a.id order by a.created_at, a.id)
        from public.vacancy_assets a
        where a.vacancy_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'draft_asset_ids', coalesce(
      (
        select jsonb_agg(a.id order by a.created_at, a.id)
        from public.vacancy_assets a
        where a.vacancy_id = v_row.id
          and a.working_draft_id is not null
      ),
      '[]'::jsonb
    ),
    'open_report_count', (
      select count(*)::integer
      from public.vacancy_reports r
      where r.vacancy_id = v_row.id and r.status = 'open'
    ),
    'is_demo', (v_row.origin = 'demo')
  );
end;
$$;

revoke all on function private.vacancy_to_admin_json(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_to_admin_json(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 6. Publish: promote draft-bound assets, then delete draft (RESTRICT-safe)
-- ---------------------------------------------------------------------------
create or replace function public.admin_publish_vacancy_working_draft(
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
  v_row public.vacancies;
  v_draft public.vacancy_working_drafts;
  v_promoted integer := 0;
begin
  v_uid := private.require_admin_permission('content.publish');

  if p_expected_draft_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;

  select * into v_row from public.vacancies where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.vacancy_working_drafts d
  where d.vacancy_id = p_id
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

  perform private.vacancy_assert_contacts(v_draft.contacts);

  update public.vacancies v set
    title = v_draft.title,
    company_name = v_draft.company_name,
    summary = v_draft.summary,
    description = v_draft.description,
    employment_type = v_draft.employment_type,
    work_format = v_draft.work_format,
    location = v_draft.location,
    salary_text = v_draft.salary_text,
    external_url = v_draft.external_url,
    contacts = v_draft.contacts,
    priority = v_draft.priority,
    starts_at = v_draft.starts_at,
    ends_at = v_draft.ends_at,
    expires_at = v_draft.expires_at,
    is_hidden = v_draft.is_hidden,
    audience_mode = v_draft.audience_mode,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  delete from public.vacancy_audience_groups where vacancy_id = p_id;
  insert into public.vacancy_audience_groups (vacancy_id, group_id)
  select p_id, g
  from unnest(coalesce(v_draft.audience_group_ids, '{}'::uuid[])) as g
  where exists (select 1 from public.groups gr where gr.id = g);

  delete from public.vacancy_audience_users where vacancy_id = p_id;
  insert into public.vacancy_audience_users (vacancy_id, user_id)
  select p_id, u
  from unnest(coalesce(v_draft.audience_user_ids, '{}'::uuid[])) as u
  where exists (select 1 from public.users us where us.id = u);

  perform private.vacancy_assert_audience_consistent(p_id);
  perform private.vacancy_snapshot_version(p_id);

  -- Promote retained draft assets BEFORE deleting the draft (FK ON DELETE RESTRICT).
  update public.vacancy_assets a
  set working_draft_id = null
  where a.vacancy_id = p_id
    and a.working_draft_id = v_draft.id;
  get diagnostics v_promoted = row_count;

  delete from public.vacancy_working_drafts where vacancy_id = p_id;

  -- Intentionally NO notification / outbox side effects.
  perform private.content_write_domain_audit(
    'vacancy.publish_working_draft',
    'vacancy',
    p_id,
    jsonb_build_object(
      'row_version', v_row.row_version,
      'version_number', v_row.version_number,
      'promoted_draft_assets', v_promoted
    )
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

revoke all on function public.admin_publish_vacancy_working_draft(uuid, integer)
  from public, anon;
grant execute on function public.admin_publish_vacancy_working_draft(uuid, integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Discard: remove draft-bound assets, then delete draft
-- ---------------------------------------------------------------------------
create or replace function public.admin_discard_vacancy_working_draft(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_draft public.vacancy_working_drafts;
  v_queued integer := 0;
  v_base jsonb;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_row from public.vacancies where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.vacancy_working_drafts d
  where d.vacancy_id = p_id
  for update;
  if not found then
    raise exception 'working_draft_not_found' using errcode = 'P0002';
  end if;

  v_queued := private.vacancy_queue_draft_bound_assets(
    p_id, v_draft.id, v_draft.title
  );

  delete from public.vacancy_working_drafts where vacancy_id = p_id;

  perform private.content_write_domain_audit(
    'vacancy.discard_working_draft',
    'vacancy',
    p_id,
    jsonb_build_object(
      'working_draft_id', v_draft.id,
      'queued_orphan_assets', v_queued
    )
  );

  v_base := private.vacancy_to_admin_json(p_id);
  return v_base || jsonb_build_object(
    'has_working_draft', false,
    'discarded', true,
    'queued_orphan_assets', v_queued
  );
end;
$$;

revoke all on function public.admin_discard_vacancy_working_draft(uuid)
  from public, anon;
grant execute on function public.admin_discard_vacancy_working_draft(uuid)
  to authenticated, service_role;

-- Allow deleting a draft-bound asset on a published vacancy (working-draft edit).
create or replace function public.admin_delete_vacancy_asset(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_asset public.vacancy_assets;
  v_status text;
  v_queued boolean := false;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_asset
  from public.vacancy_assets
  where id = p_asset_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select v.status into v_status
  from public.vacancies v
  where v.id = v_asset.vacancy_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_asset.working_draft_id is null then
    perform private.vacancy_assert_editable_content(v_status);
  elsif private.vacancy_working_draft_id(v_asset.vacancy_id)
        is distinct from v_asset.working_draft_id then
    raise exception 'draft_asset_mismatch' using errcode = 'P0001';
  end if;

  insert into public.vacancy_media_cleanup_queue (
    storage_bucket, storage_path, source_vacancy_id, source_title
  )
  values (
    v_asset.storage_bucket,
    v_asset.storage_path,
    v_asset.vacancy_id,
    left(v_asset.title, 200)
  )
  on conflict do nothing;
  v_queued := true;

  if v_asset.working_draft_id is not null then
    update public.vacancy_working_drafts d
    set draft_asset_ids = coalesce(
          (
            select array_agg(x)
            from unnest(d.draft_asset_ids) as x
            where x is distinct from v_asset.id
          ),
          '{}'::uuid[]
        ),
        updated_by = v_uid,
        updated_at = now(),
        row_version = d.row_version + 1
    where d.id = v_asset.working_draft_id;
  end if;

  delete from public.vacancy_assets where id = p_asset_id;

  perform private.content_write_domain_audit(
    'vacancy.delete_asset',
    'vacancy',
    v_asset.vacancy_id,
    jsonb_build_object(
      'asset_id', p_asset_id,
      'queued_media', v_queued,
      'was_draft_asset', (v_asset.working_draft_id is not null)
    )
  );

  return jsonb_build_object('deleted', true, 'id', p_asset_id);
end;
$$;

revoke all on function public.admin_delete_vacancy_asset(uuid) from public, anon;
grant execute on function public.admin_delete_vacancy_asset(uuid)
  to authenticated, service_role;

-- Students must not download draft-bound assets even if they guess the UUID.
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

  if v_asset.working_draft_id is not null then
    raise exception 'forbidden' using errcode = '42501';
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

revoke all on function public.authorize_vacancy_asset_download(uuid)
  from public, anon;
grant execute on function public.authorize_vacancy_asset_download(uuid)
  to authenticated, service_role;

commit;
