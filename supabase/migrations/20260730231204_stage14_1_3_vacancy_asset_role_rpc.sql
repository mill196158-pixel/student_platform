-- Stage 14.1.3: vacancy visual asset roles with working-draft isolation.
-- Does not edit applied migrations. No Edge Function changes.

-- ---------------------------------------------------------------------------
-- 1. Working-draft intent: clear logo/cover/background without touching canonical
-- ---------------------------------------------------------------------------
alter table public.vacancy_working_drafts
  add column if not exists cleared_visual_roles text[] not null default '{}'::text[];

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'vacancy_working_drafts_cleared_visual_roles_chk'
  ) then
    alter table public.vacancy_working_drafts
      add constraint vacancy_working_drafts_cleared_visual_roles_chk
      check (
        cleared_visual_roles <@ array['logo', 'cover', 'background']::text[]
      );
  end if;
end;
$$;

comment on column public.vacancy_working_drafts.cleared_visual_roles is
  'Visual roles to remove from canonical assets only when this working draft is published.';

-- ---------------------------------------------------------------------------
-- 2. Set role: demote only within the same draft/canonical cohort
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_vacancy_asset_role(
  p_asset_id uuid,
  p_role text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_asset public.vacancy_assets;
  v_role text := nullif(btrim(coalesce(p_role, '')), '');
begin
  v_uid := private.require_admin_permission('content.write');

  if v_role is null or v_role not in (
    'attachment', 'logo', 'cover', 'background'
  ) then
    raise exception 'invalid_vacancy_asset_role' using errcode = '22023';
  end if;

  select * into v_asset
  from public.vacancy_assets
  where id = p_asset_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- Keep at most one primary visual asset per role within the SAME cohort.
  -- Draft assets must not demote published canonical roles before publish.
  if v_role in ('logo', 'cover', 'background') then
    update public.vacancy_assets a
    set role = 'attachment'
    where a.vacancy_id = v_asset.vacancy_id
      and a.id <> p_asset_id
      and a.role = v_role
      and (
        (v_asset.working_draft_id is null and a.working_draft_id is null)
        or (
          v_asset.working_draft_id is not null
          and a.working_draft_id is not distinct from v_asset.working_draft_id
        )
      );

    -- Replacing a visual role undoes a pending clear intent for that role.
    if v_asset.working_draft_id is not null then
      update public.vacancy_working_drafts d
      set cleared_visual_roles = coalesce(
            (
              select array_agg(x)
              from unnest(d.cleared_visual_roles) as x
              where x is distinct from v_role
            ),
            '{}'::text[]
          ),
          updated_by = v_uid,
          updated_at = now()
      where d.id = v_asset.working_draft_id;
    end if;
  end if;

  update public.vacancy_assets
  set role = v_role
  where id = p_asset_id;

  perform private.content_write_domain_audit(
    'vacancy.set_asset_role',
    'vacancy_asset',
    p_asset_id,
    jsonb_build_object(
      'vacancy_id', v_asset.vacancy_id,
      'role', v_role,
      'previous_role', v_asset.role,
      'working_draft_id', v_asset.working_draft_id
    )
  );

  return jsonb_build_object(
    'id', p_asset_id,
    'vacancy_id', v_asset.vacancy_id,
    'role', v_role,
    'working_draft_id', v_asset.working_draft_id
  );
end;
$$;

revoke all on function public.admin_set_vacancy_asset_role(uuid, text)
  from public, anon;
grant execute on function public.admin_set_vacancy_asset_role(uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Clear visual role: draft cohort delete + deferred canonical clear intent
-- ---------------------------------------------------------------------------
create or replace function public.admin_clear_vacancy_visual_role(
  p_vacancy_id uuid,
  p_role text
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
  v_role text := nullif(btrim(coalesce(p_role, '')), '');
  v_asset public.vacancy_assets;
  v_deleted_draft integer := 0;
  v_deleted_canonical integer := 0;
  v_has_draft boolean := false;
begin
  v_uid := private.require_admin_permission('content.write');

  if v_role is null or v_role not in ('logo', 'cover', 'background') then
    raise exception 'invalid_vacancy_asset_role' using errcode = '22023';
  end if;

  select * into v_row from public.vacancies where id = p_vacancy_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.vacancy_working_drafts d
  where d.vacancy_id = p_vacancy_id
  for update;
  v_has_draft := found;

  if v_has_draft then
    for v_asset in
      select *
      from public.vacancy_assets a
      where a.vacancy_id = p_vacancy_id
        and a.working_draft_id = v_draft.id
        and a.role = v_role
      for update
    loop
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
      where d.id = v_draft.id;

      delete from public.vacancy_assets where id = v_asset.id;
      v_deleted_draft := v_deleted_draft + 1;
    end loop;

    update public.vacancy_working_drafts d
    set cleared_visual_roles = (
          select array_agg(distinct x)
          from unnest(d.cleared_visual_roles || array[v_role]) as x
        ),
        updated_by = v_uid,
        updated_at = now()
    where d.id = v_draft.id;
  else
    perform private.vacancy_assert_editable_content(v_row.status);

    for v_asset in
      select *
      from public.vacancy_assets a
      where a.vacancy_id = p_vacancy_id
        and a.working_draft_id is null
        and a.role = v_role
      for update
    loop
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
      delete from public.vacancy_assets where id = v_asset.id;
      v_deleted_canonical := v_deleted_canonical + 1;
    end loop;
  end if;

  perform private.content_write_domain_audit(
    'vacancy.clear_visual_role',
    'vacancy',
    p_vacancy_id,
    jsonb_build_object(
      'role', v_role,
      'has_working_draft', v_has_draft,
      'deleted_draft_assets', v_deleted_draft,
      'deleted_canonical_assets', v_deleted_canonical
    )
  );

  return private.vacancy_to_admin_json(p_vacancy_id) || jsonb_build_object(
    'cleared_role', v_role,
    'deleted_draft_assets', v_deleted_draft,
    'deleted_canonical_assets', v_deleted_canonical
  );
end;
$$;

revoke all on function public.admin_clear_vacancy_visual_role(uuid, text)
  from public, anon;
grant execute on function public.admin_clear_vacancy_visual_role(uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Publish: reconcile visual roles atomically after draft promotion
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
  v_role text;
  v_asset public.vacancy_assets;
  v_replaced integer := 0;
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

  -- Replace/clear visual roles: remove superseded canonical assets first.
  foreach v_role in array array['logo', 'cover', 'background']
  loop
    if v_role = any (coalesce(v_draft.cleared_visual_roles, '{}'::text[]))
       or exists (
         select 1
         from public.vacancy_assets a
         where a.vacancy_id = p_id
           and a.working_draft_id = v_draft.id
           and a.role = v_role
       )
    then
      for v_asset in
        select *
        from public.vacancy_assets a
        where a.vacancy_id = p_id
          and a.working_draft_id is null
          and a.role = v_role
        for update
      loop
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
        delete from public.vacancy_assets where id = v_asset.id;
        v_replaced := v_replaced + 1;
      end loop;
    end if;
  end loop;

  -- Promote retained draft assets BEFORE deleting the draft (FK ON DELETE RESTRICT).
  update public.vacancy_assets a
  set working_draft_id = null
  where a.vacancy_id = p_id
    and a.working_draft_id = v_draft.id;
  get diagnostics v_promoted = row_count;

  delete from public.vacancy_working_drafts where vacancy_id = p_id;

  -- Snapshot AFTER visual-role reconciliation so history matches published assets.
  perform private.vacancy_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'vacancy.publish_working_draft',
    'vacancy',
    p_id,
    jsonb_build_object(
      'row_version', v_row.row_version,
      'version_number', v_row.version_number,
      'promoted_draft_assets', v_promoted,
      'replaced_canonical_visual_assets', v_replaced
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
-- 5. Admin JSON: typed assets + cleared visual roles from working draft
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
  v_cleared text[] := '{}'::text[];
begin
  select * into v_row from public.vacancies where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.vacancy_working_drafts d
    where d.vacancy_id = p_id
  ) into v_has_draft;

  if v_has_draft then
    select coalesce(d.cleared_visual_roles, '{}'::text[])
      into v_cleared
    from public.vacancy_working_drafts d
    where d.vacancy_id = p_id;
  end if;

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
    'cleared_visual_roles', to_jsonb(coalesce(v_cleared, '{}'::text[])),
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
    'assets', private.vacancy_assets_admin_json(p_id),
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
