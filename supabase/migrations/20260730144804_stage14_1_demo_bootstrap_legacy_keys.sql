-- Stage 14.1 — Demo bootstrap + legacy keys + tombstones + Design Z RPC support
-- NEW migration only. Does not edit applied Stage 14–19 files.
-- Bootstrap is idempotent by prefixed legacy_key; dry-run writes nothing.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.content_items
  add column if not exists legacy_key text null;

alter table public.vacancies
  add column if not exists legacy_key text null;

alter table public.reference_categories
  add column if not exists legacy_key text null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'content_items_legacy_key_len'
  ) then
    alter table public.content_items
      add constraint content_items_legacy_key_len check (
        legacy_key is null
        or (btrim(legacy_key) <> '' and char_length(legacy_key) <= 120)
      );
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'vacancies_legacy_key_len'
  ) then
    alter table public.vacancies
      add constraint vacancies_legacy_key_len check (
        legacy_key is null
        or (btrim(legacy_key) <> '' and char_length(legacy_key) <= 120)
      );
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'reference_categories_legacy_key_len'
  ) then
    alter table public.reference_categories
      add constraint reference_categories_legacy_key_len check (
        legacy_key is null
        or (btrim(legacy_key) <> '' and char_length(legacy_key) <= 120)
      );
  end if;
end $$;

create unique index if not exists content_items_legacy_key_uidx
  on public.content_items (legacy_key)
  where legacy_key is not null;

create unique index if not exists vacancies_legacy_key_uidx
  on public.vacancies (legacy_key)
  where legacy_key is not null;

create unique index if not exists reference_categories_legacy_key_uidx
  on public.reference_categories (legacy_key)
  where legacy_key is not null;

-- ---------------------------------------------------------------------------
-- Tombstones (permanent delete of demo-derived legacy identities)
-- ---------------------------------------------------------------------------
create table if not exists public.content_legacy_tombstones (
  resource_kind text not null
    check (resource_kind in (
      'content_item', 'vacancy', 'reference_category'
    )),
  legacy_key text not null,
  deleted_at timestamptz not null default now(),
  deleted_by uuid null references public.users (id) on delete set null,
  meta jsonb not null default '{}'::jsonb,
  primary key (resource_kind, legacy_key),
  constraint content_legacy_tombstones_key_len check (
    btrim(legacy_key) <> '' and char_length(legacy_key) <= 120
  )
);

comment on table public.content_legacy_tombstones is
  'Permanent deletion markers for demo/legacy bootstrap identities. Archive/unpublish does NOT tombstone. Bootstrap skips tombstoned keys.';

alter table public.content_legacy_tombstones enable row level security;
alter table public.content_legacy_tombstones force row level security;
revoke all on table public.content_legacy_tombstones
  from public, anon, authenticated;
grant select, insert, update, delete on table public.content_legacy_tombstones
  to service_role;

-- ---------------------------------------------------------------------------
-- CTA allowlist: include /help used by historic Home promo demo
-- ---------------------------------------------------------------------------
create or replace function private.content_assert_cta(
  p_route text,
  p_url text
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_prefixes text[] := array[
    '/diary', '/info', '/profile', '/schedule', '/home', '/learning',
    '/chat', '/help'
  ];
  v_prefix text;
  v_ok boolean := false;
begin
  if p_route is not null and p_url is not null then
    raise exception 'invalid_cta_route_and_url' using errcode = '22023';
  end if;

  if p_route is not null then
    foreach v_prefix in array v_prefixes loop
      if p_route = v_prefix or p_route like v_prefix || '/%' then
        v_ok := true;
      end if;
    end loop;
    if not v_ok then
      raise exception 'invalid_cta_route' using errcode = '22023';
    end if;
    if p_route ~ '[[:space:]]' or length(p_route) > 300 then
      raise exception 'invalid_cta_route' using errcode = '22023';
    end if;
  end if;

  if p_url is not null then
    if length(p_url) > 500
       or p_url !~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9](:[0-9]{1,5})?(/[^[:space:]]*)?$' then
      raise exception 'invalid_cta_url' using errcode = '22023';
    end if;
  end if;
end;
$$;

revoke all on function private.content_assert_cta(text, text)
  from public, anon, authenticated;
grant execute on function private.content_assert_cta(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Admin JSON: expose legacy_key
-- ---------------------------------------------------------------------------
create or replace function private.content_item_to_admin_json(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.content_items;
begin
  select * into v_row from public.content_items where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'template_key', v_row.template_key,
    'schema_version', v_row.schema_version,
    'status', v_row.status,
    'origin', v_row.origin,
    'legacy_key', v_row.legacy_key,
    'title', v_row.title,
    'payload', v_row.payload,
    'priority', v_row.priority,
    'starts_at', v_row.starts_at,
    'ends_at', v_row.ends_at,
    'is_hidden', v_row.is_hidden,
    'audience_mode', v_row.audience_mode,
    'version_number', v_row.version_number,
    'row_version', v_row.row_version,
    'created_by', v_row.created_by,
    'updated_by', v_row.updated_by,
    'published_by', v_row.published_by,
    'published_at', v_row.published_at,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at,
    'placements', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object('placement', p.placement, 'sort_order', p.sort_order)
          order by p.sort_order, p.placement
        )
        from public.content_item_placements p
        where p.content_item_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'audience_group_ids', coalesce(
      (
        select jsonb_agg(g.group_id order by g.group_id)
        from public.content_item_audience_groups g
        where g.content_item_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'audience_user_ids', coalesce(
      (
        select jsonb_agg(u.user_id order by u.user_id)
        from public.content_item_audience_users u
        where u.content_item_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'asset_ids', coalesce(
      (
        select jsonb_agg(a.id order by a.created_at, a.id)
        from public.content_assets a
        where a.content_item_id = v_row.id
      ),
      '[]'::jsonb
    )
  );
end;
$$;

revoke all on function private.content_item_to_admin_json(uuid)
  from public, anon, authenticated;
grant execute on function private.content_item_to_admin_json(uuid) to service_role;

create or replace function private.vacancy_to_admin_json(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.vacancies;
begin
  select * into v_row from public.vacancies where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
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
-- Safe-delete: tombstone demo/legacy identities (archive restore stays OK)
-- ---------------------------------------------------------------------------
create or replace function public.admin_safe_delete_content(
  p_id uuid,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
  v_queued integer := 0;
begin
  v_uid := private.require_admin_permission('content.publish');
  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status is distinct from 'archived' then
    raise exception 'content_must_be_archived' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.content_corrections c
    where c.content_item_id = p_id and c.status = 'open'
  ) then
    raise exception 'open_corrections_block_delete' using errcode = 'P0001';
  end if;

  if v_row.legacy_key is not null then
    insert into public.content_legacy_tombstones (
      resource_kind, legacy_key, deleted_by, meta
    ) values (
      'content_item',
      v_row.legacy_key,
      v_uid,
      jsonb_build_object(
        'previous_origin', v_row.origin,
        'template_key', v_row.template_key
      )
    )
    on conflict (resource_kind, legacy_key) do update
      set deleted_at = now(),
          deleted_by = excluded.deleted_by,
          meta = excluded.meta;
  end if;

  with queued as (
    insert into public.content_media_cleanup_queue (
      storage_bucket, storage_path, source_content_item_id, source_title
    )
    select a.storage_bucket, a.storage_path, v_row.id, left(v_row.title, 200)
    from public.content_assets a
    where a.content_item_id = p_id
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_queued from queued;

  perform set_config('app.content_cascade_delete', 'on', true);
  delete from public.content_items where id = p_id;
  perform set_config('app.content_cascade_delete', 'off', true);

  perform private.content_write_domain_audit(
    'content.safe_delete',
    'content_item',
    p_id,
    jsonb_build_object(
      'previous_status', 'archived',
      'queued_media', v_queued,
      'legacy_key', v_row.legacy_key,
      'tombstone', v_row.legacy_key is not null
    )
  );

  return jsonb_build_object(
    'deleted', true,
    'id', p_id,
    'queued_media', v_queued,
    'legacy_key', v_row.legacy_key
  );
end;
$$;

revoke all on function public.admin_safe_delete_content(uuid, integer)
  from public, anon;
grant execute on function public.admin_safe_delete_content(uuid, integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Unarchive archived → draft (Design Z restore)
-- ---------------------------------------------------------------------------
create or replace function public.admin_unarchive_content(
  p_id uuid,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
begin
  v_uid := private.require_admin_permission('content.publish');
  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status is distinct from 'archived' then
    raise exception 'content_must_be_archived' using errcode = 'P0001';
  end if;

  update public.content_items c set
    status = 'draft',
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  perform private.content_snapshot_version(p_id);
  perform private.content_write_domain_audit(
    'content.unarchive',
    'content_item',
    p_id,
    jsonb_build_object(
      'status', 'draft',
      'row_version', v_row.row_version
    )
  );

  return private.content_item_to_admin_json(p_id);
end;
$$;

revoke all on function public.admin_unarchive_content(uuid, integer)
  from public, anon;
grant execute on function public.admin_unarchive_content(uuid, integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Promote demo → managed admin (keeps legacy_key; no duplicate on bootstrap)
-- ---------------------------------------------------------------------------
create or replace function public.admin_promote_demo_content(
  p_id uuid,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
begin
  v_uid := private.require_admin_permission('content.write');
  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.origin is distinct from 'demo' then
    raise exception 'not_demo_origin' using errcode = 'P0001';
  end if;

  update public.content_items c set
    origin = 'admin',
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  perform private.content_snapshot_version(p_id);
  perform private.content_write_domain_audit(
    'content.promote_demo',
    'content_item',
    p_id,
    jsonb_build_object(
      'legacy_key', v_row.legacy_key,
      'origin', 'admin',
      'row_version', v_row.row_version
    )
  );

  return private.content_item_to_admin_json(p_id);
end;
$$;

revoke all on function public.admin_promote_demo_content(uuid, integer)
  from public, anon;
grant execute on function public.admin_promote_demo_content(uuid, integer)
  to authenticated, service_role;

create or replace function public.admin_promote_demo_vacancy(
  p_id uuid,
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
begin
  v_uid := private.require_admin_permission('content.write');
  v_row := private.vacancy_lock(p_id, p_expected_row_version);

  if v_row.origin is distinct from 'demo' then
    raise exception 'not_demo_origin' using errcode = 'P0001';
  end if;

  update public.vacancies v set
    origin = 'admin',
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);
  perform private.content_write_domain_audit(
    'vacancy.promote_demo',
    'vacancy',
    p_id,
    jsonb_build_object(
      'legacy_key', v_row.legacy_key,
      'origin', 'admin',
      'row_version', v_row.row_version
    )
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

revoke all on function public.admin_promote_demo_vacancy(uuid, integer)
  from public, anon;
grant execute on function public.admin_promote_demo_vacancy(uuid, integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Duplicate content item (news-parity)
-- ---------------------------------------------------------------------------
create or replace function public.admin_duplicate_content(
  p_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_src public.content_items;
  v_row public.content_items;
  v_place record;
  v_cat uuid;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_src from public.content_items where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.validate_content_payload(
    v_src.template_key, v_src.schema_version, v_src.payload
  );

  insert into public.content_items (
    template_key, schema_version, status, origin, title, payload,
    priority, starts_at, ends_at, is_hidden, audience_mode,
    created_by, updated_by
  ) values (
    v_src.template_key,
    v_src.schema_version,
    'draft',
    'admin',
    left('Копия: ' || coalesce(v_src.title, ''), 200),
    v_src.payload,
    v_src.priority,
    v_src.starts_at,
    v_src.ends_at,
    v_src.is_hidden,
    'all',
    v_uid,
    v_uid
  )
  returning * into v_row;

  for v_place in
    select placement, sort_order
    from public.content_item_placements
    where content_item_id = p_id
  loop
    insert into public.content_item_placements (
      content_item_id, placement, sort_order
    ) values (v_row.id, v_place.placement, v_place.sort_order);
  end loop;

  select reference_category_id into v_cat
  from public.content_item_reference_categories
  where content_item_id = p_id;
  if v_cat is not null then
    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (v_row.id, v_cat);
  end if;

  perform private.content_snapshot_version(v_row.id);
  perform private.content_write_domain_audit(
    'content.duplicate',
    'content_item',
    v_row.id,
    jsonb_build_object('source_id', p_id)
  );

  return private.content_item_to_admin_json(v_row.id);
end;
$$;

revoke all on function public.admin_duplicate_content(uuid) from public, anon;
grant execute on function public.admin_duplicate_content(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Bootstrap helpers (private)
-- ---------------------------------------------------------------------------
create or replace function private.content_legacy_is_tombstoned(
  p_kind text,
  p_legacy_key text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.content_legacy_tombstones t
    where t.resource_kind = p_kind
      and t.legacy_key = p_legacy_key
  );
$$;

revoke all on function private.content_legacy_is_tombstoned(text, text)
  from public, anon, authenticated;
grant execute on function private.content_legacy_is_tombstoned(text, text)
  to service_role;

create or replace function private.bootstrap_plan_entry(
  p_resource text,
  p_legacy_key text,
  p_action text,
  p_detail text default null
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'resource', p_resource,
    'legacy_key', p_legacy_key,
    'action', p_action,
    'detail', p_detail
  );
$$;

-- Create-only by legacy_key. Never overwrites existing rows (demo edits, archive,
-- promote, or foreign ownership). Direct status write (no notification/outbox).
create or replace function private.bootstrap_upsert_content_item(
  p_dry_run boolean,
  p_legacy_key text,
  p_template_key text,
  p_schema_version integer,
  p_title text,
  p_payload jsonb,
  p_placement text,
  p_sort_order integer,
  p_status text,
  p_uid uuid,
  p_reference_category_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.content_items;
  v_id uuid;
begin
  if private.content_legacy_is_tombstoned('content_item', p_legacy_key) then
    return private.bootstrap_plan_entry(
      'content_item', p_legacy_key, 'skip_tombstoned', null
    );
  end if;

  select * into v_existing
  from public.content_items
  where legacy_key = p_legacy_key;

  if found then
    if v_existing.origin is distinct from 'demo' then
      return private.bootstrap_plan_entry(
        'content_item', p_legacy_key, 'conflict',
        'origin=' || v_existing.origin
      );
    end if;
    -- Existing demo identity: never rewrite (archive/edit must stick).
    return private.bootstrap_plan_entry(
      'content_item', p_legacy_key, 'skip_existing',
      v_existing.id::text || '|status=' || v_existing.status
    );
  end if;

  if p_dry_run then
    return private.bootstrap_plan_entry(
      'content_item', p_legacy_key, 'create', null
    );
  end if;

  perform private.validate_content_payload(
    p_template_key, p_schema_version, p_payload
  );

  insert into public.content_items (
    template_key, schema_version, status, origin, legacy_key, title, payload,
    audience_mode, published_at, published_by, created_by, updated_by
  ) values (
    p_template_key,
    p_schema_version,
    p_status,
    'demo',
    p_legacy_key,
    left(p_title, 200),
    p_payload,
    'all',
    case when p_status = 'published' then now() else null end,
    case when p_status = 'published' then p_uid else null end,
    p_uid,
    p_uid
  )
  returning id into v_id;

  insert into public.content_item_placements (
    content_item_id, placement, sort_order
  ) values (v_id, p_placement, p_sort_order);

  if p_reference_category_id is not null then
    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (v_id, p_reference_category_id);
  end if;

  perform private.content_snapshot_version(v_id);
  return private.bootstrap_plan_entry(
    'content_item', p_legacy_key, 'create', v_id::text
  );
end;
$$;

revoke all on function private.bootstrap_upsert_content_item(
  boolean, text, text, integer, text, jsonb, text, integer, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function private.bootstrap_upsert_content_item(
  boolean, text, text, integer, text, jsonb, text, integer, text, uuid, uuid
) to service_role;

create or replace function private.bootstrap_upsert_reference_category(
  p_dry_run boolean,
  p_legacy_key text,
  p_category_key text,
  p_title text,
  p_icon_key text,
  p_sort_order integer,
  p_uid uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_by_legacy public.reference_categories;
  v_by_key public.reference_categories;
  v_id uuid;
begin
  if private.content_legacy_is_tombstoned('reference_category', p_legacy_key) then
    return private.bootstrap_plan_entry(
      'reference_category', p_legacy_key, 'skip_tombstoned', null
    );
  end if;

  select * into v_by_legacy
  from public.reference_categories
  where legacy_key = p_legacy_key;

  if found then
    return private.bootstrap_plan_entry(
      'reference_category', p_legacy_key, 'skip_existing',
      v_by_legacy.id::text || '|status=' || v_by_legacy.status
    );
  end if;

  select * into v_by_key
  from public.reference_categories
  where key = p_category_key;

  if found then
    -- Unowned key collision: do not rename/republish foreign categories.
    return private.bootstrap_plan_entry(
      'reference_category', p_legacy_key, 'conflict',
      'key_owned_by=' || v_by_key.id::text
    );
  end if;

  if p_dry_run then
    return private.bootstrap_plan_entry(
      'reference_category', p_legacy_key, 'create', null
    );
  end if;

  insert into public.reference_categories (
    key, title, icon_key, status, sort_order, legacy_key, created_by, updated_by
  ) values (
    left(p_category_key, 80),
    left(p_title, 120),
    left(p_icon_key, 60),
    'published',
    p_sort_order,
    p_legacy_key,
    p_uid,
    p_uid
  )
  returning id into v_id;

  return private.bootstrap_plan_entry(
    'reference_category', p_legacy_key, 'create', v_id::text
  );
end;
$$;

revoke all on function private.bootstrap_upsert_reference_category(
  boolean, text, text, text, text, integer, uuid
) from public, anon, authenticated;
grant execute on function private.bootstrap_upsert_reference_category(
  boolean, text, text, text, text, integer, uuid
) to service_role;

create or replace function private.bootstrap_upsert_vacancy(
  p_dry_run boolean,
  p_legacy_key text,
  p_patch jsonb,
  p_uid uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.vacancies;
  v_id uuid;
begin
  if private.content_legacy_is_tombstoned('vacancy', p_legacy_key) then
    return private.bootstrap_plan_entry(
      'vacancy', p_legacy_key, 'skip_tombstoned', null
    );
  end if;

  select * into v_existing
  from public.vacancies
  where legacy_key = p_legacy_key;

  if found then
    if v_existing.origin is distinct from 'demo' then
      return private.bootstrap_plan_entry(
        'vacancy', p_legacy_key, 'conflict',
        'origin=' || v_existing.origin
      );
    end if;
    -- Existing demo identity: never rewrite (archive/edit must stick).
    return private.bootstrap_plan_entry(
      'vacancy', p_legacy_key, 'skip_existing',
      v_existing.id::text || '|status=' || v_existing.status
    );
  end if;

  if p_dry_run then
    return private.bootstrap_plan_entry(
      'vacancy', p_legacy_key, 'create', null
    );
  end if;

  insert into public.vacancies (
    title, company_name, summary, description, employment_type, work_format,
    location, salary_text, status, origin, legacy_key, audience_mode,
    created_by, updated_by
  ) values (
    btrim(p_patch ->> 'title'),
    coalesce(p_patch ->> 'company_name', ''),
    coalesce(p_patch ->> 'summary', ''),
    coalesce(p_patch ->> 'description', ''),
    nullif(btrim(coalesce(p_patch ->> 'employment_type', '')), ''),
    nullif(btrim(coalesce(p_patch ->> 'work_format', '')), ''),
    nullif(btrim(coalesce(p_patch ->> 'location', '')), ''),
    nullif(btrim(coalesce(p_patch ->> 'salary_text', '')), ''),
    'draft',
    'demo',
    p_legacy_key,
    'all',
    p_uid,
    p_uid
  )
  returning id into v_id;

  perform private.vacancy_snapshot_version(v_id);
  return private.bootstrap_plan_entry(
    'vacancy', p_legacy_key, 'create', v_id::text
  );
end;
$$;

revoke all on function private.bootstrap_upsert_vacancy(
  boolean, text, jsonb, uuid
) from public, anon, authenticated;
grant execute on function private.bootstrap_upsert_vacancy(
  boolean, text, jsonb, uuid
) to service_role;

-- Reference article create gated on parent category availability.
create or replace function private.bootstrap_upsert_reference_article(
  p_dry_run boolean,
  p_legacy_key text,
  p_title text,
  p_payload jsonb,
  p_sort_order integer,
  p_uid uuid,
  p_category_legacy_key text,
  p_category_action text,
  p_category_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_category_action = 'skip_tombstoned' then
    return private.bootstrap_plan_entry(
      'content_item', p_legacy_key, 'skip_tombstoned',
      'dependency=' || p_category_legacy_key
    );
  end if;
  if p_category_action = 'conflict' then
    return private.bootstrap_plan_entry(
      'content_item', p_legacy_key, 'conflict',
      'dependency=' || p_category_legacy_key
    );
  end if;
  -- On apply, category id is mandatory for reference articles.
  if not p_dry_run and p_category_id is null then
    return private.bootstrap_plan_entry(
      'content_item', p_legacy_key, 'conflict',
      'category_missing=' || p_category_legacy_key
    );
  end if;

  return private.bootstrap_upsert_content_item(
    p_dry_run,
    p_legacy_key,
    'reference_article_v1',
    2,
    p_title,
    p_payload,
    'reference',
    p_sort_order,
    'published',
    p_uid,
    p_category_id
  );
end;
$$;

revoke all on function private.bootstrap_upsert_reference_article(
  boolean, text, text, jsonb, integer, uuid, text, text, uuid
) from public, anon, authenticated;
grant execute on function private.bootstrap_upsert_reference_article(
  boolean, text, text, jsonb, integer, uuid, text, text, uuid
) to service_role;

-- ---------------------------------------------------------------------------
-- Public bootstrap RPC
-- ---------------------------------------------------------------------------
create or replace function public.admin_bootstrap_demo_content(
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_plan jsonb := '[]'::jsonb;
  v_entry jsonb;
  v_cat_dostupy uuid;
  v_cat_dokumenty uuid;
  v_cat_programmy uuid;
  v_cat_karta uuid;
  v_cat_faq uuid;
  v_act_dostupy text;
  v_act_dokumenty text;
  v_act_programmy text;
  v_act_karta text;
  v_act_faq text;
  v_payload jsonb;
begin
  -- Publish capability: bootstrap may create published promo/feed/reference.
  v_uid := private.require_admin_permission('content.publish');
  -- Serialize concurrent bootstrap attempts within the transaction.
  perform pg_advisory_xact_lock(hashtext('admin_bootstrap_demo_content'));

  -- Categories (stable key = content_ref_cat_*)
  v_entry := private.bootstrap_upsert_reference_category(
    p_dry_run, 'content:reference_category:dostupy',
    'content_ref_cat_dostupy', 'Доступы', 'login', 0, v_uid
  );
  v_act_dostupy := v_entry->>'action';
  v_plan := v_plan || jsonb_build_array(v_entry);
  v_entry := private.bootstrap_upsert_reference_category(
    p_dry_run, 'content:reference_category:dokumenty',
    'content_ref_cat_dokumenty', 'Документы', 'description', 1, v_uid
  );
  v_act_dokumenty := v_entry->>'action';
  v_plan := v_plan || jsonb_build_array(v_entry);
  v_entry := private.bootstrap_upsert_reference_category(
    p_dry_run, 'content:reference_category:programmy',
    'content_ref_cat_programmy', 'Программы', 'computer', 2, v_uid
  );
  v_act_programmy := v_entry->>'action';
  v_plan := v_plan || jsonb_build_array(v_entry);
  v_entry := private.bootstrap_upsert_reference_category(
    p_dry_run, 'content:reference_category:karta',
    'content_ref_cat_karta', 'Карта и аудитории', 'map', 3, v_uid
  );
  v_act_karta := v_entry->>'action';
  v_plan := v_plan || jsonb_build_array(v_entry);
  v_entry := private.bootstrap_upsert_reference_category(
    p_dry_run, 'content:reference_category:faq',
    'content_ref_cat_faq', 'Частые вопросы', 'help', 4, v_uid
  );
  v_act_faq := v_entry->>'action';
  v_plan := v_plan || jsonb_build_array(v_entry);

  if not p_dry_run then
    select id into v_cat_dostupy from public.reference_categories
      where legacy_key = 'content:reference_category:dostupy';
    select id into v_cat_dokumenty from public.reference_categories
      where legacy_key = 'content:reference_category:dokumenty';
    select id into v_cat_programmy from public.reference_categories
      where legacy_key = 'content:reference_category:programmy';
    select id into v_cat_karta from public.reference_categories
      where legacy_key = 'content:reference_category:karta';
    select id into v_cat_faq from public.reference_categories
      where legacy_key = 'content:reference_category:faq';
  end if;

  -- Home promo (published, audience all) — 1:1 student_ui demoStuckWithAssignment
  v_payload := jsonb_build_object(
    'title', 'Застрял с заданием?',
    'subtitle', 'Можно разобрать задачу, подготовиться к сдаче или понять, с чего начать.',
    'icon_key', 'psychology',
    'gradient_colors', jsonb_build_array('#FFFBFF', '#F3EEF9'),
    'cta_label', 'Получить помощь',
    'dismissible', false,
    'cta_route', '/help'
  );
  v_entry := private.bootstrap_upsert_content_item(
    p_dry_run,
    'content:home_promo:stuck_with_assignment',
    'home_promo_v1', 1,
    'Застрял с заданием?',
    v_payload,
    'home_promo', 0, 'published', v_uid, null
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  -- Profile feed ×3 (published)
  v_payload := jsonb_build_object(
    'title', 'О нас',
    'subtitle', 'Команда Студент Платформ',
    'cta_label', 'Открыть',
    'cta_url', 'https://example.com/about'
  );
  v_entry := private.bootstrap_upsert_content_item(
    p_dry_run, 'content:profile_feed:about',
    'profile_feed_card_v1', 1, 'О нас', v_payload,
    'profile_feed', 0, 'published', v_uid, null
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_payload := jsonb_build_object(
    'title', 'Расписание занятий',
    'subtitle', 'Твое расписание всегда под рукой',
    'cta_label', 'К расписанию',
    'cta_route', '/schedule'
  );
  v_entry := private.bootstrap_upsert_content_item(
    p_dry_run, 'content:profile_feed:schedule',
    'profile_feed_card_v1', 1, 'Расписание занятий', v_payload,
    'profile_feed', 1, 'published', v_uid, null
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_payload := jsonb_build_object(
    'title', 'Скидки для студентов',
    'subtitle', 'Обновляем лучшие предложения',
    'cta_label', 'Смотреть',
    'cta_url', 'https://example.com/discounts'
  );
  v_entry := private.bootstrap_upsert_content_item(
    p_dry_run, 'content:profile_feed:discounts',
    'profile_feed_card_v1', 1, 'Скидки для студентов', v_payload,
    'profile_feed', 2, 'published', v_uid, null
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  -- Reference articles ×6 (published, schema v2) — placeholder bodies match mobile demo
  v_payload := jsonb_build_object(
    'icon_key', 'login',
    'short_text', 'Краткая инструкция по входу и восстановлению доступа.',
    'blocks', jsonb_build_array(
      jsonb_build_object(
        'type', 'text',
        'text', 'Краткая инструкция по входу и восстановлению доступа.'
      ),
      jsonb_build_object(
        'type', 'text',
        'text', 'Подробную инструкцию добавим в справочник.'
      )
    )
  );
  v_entry := private.bootstrap_upsert_reference_article(
    p_dry_run, 'content:reference_article:login_cabinet',
    'Как зайти в личный кабинет', v_payload, 0, v_uid,
    'content:reference_category:dostupy', v_act_dostupy, v_cat_dostupy
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_payload := jsonb_build_object(
    'icon_key', 'download',
    'short_text', 'Где искать файлы, методички и шаблоны.',
    'blocks', jsonb_build_array(
      jsonb_build_object('type', 'text', 'text', 'Где искать файлы, методички и шаблоны.'),
      jsonb_build_object('type', 'text', 'text', 'Подробную инструкцию добавим в справочник.')
    )
  );
  v_entry := private.bootstrap_upsert_reference_article(
    p_dry_run, 'content:reference_article:download_materials',
    'Как скачать нужные материалы', v_payload, 1, v_uid,
    'content:reference_category:dostupy', v_act_dostupy, v_cat_dostupy
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_payload := jsonb_build_object(
    'icon_key', 'description',
    'short_text', 'Основные действия для получения справки в университете.',
    'blocks', jsonb_build_array(
      jsonb_build_object(
        'type', 'text',
        'text', 'Основные действия для получения справки в университете.'
      ),
      jsonb_build_object('type', 'text', 'text', 'Подробную инструкцию добавим в справочник.')
    )
  );
  v_entry := private.bootstrap_upsert_reference_article(
    p_dry_run, 'content:reference_article:order_certificate',
    'Как заказать справку', v_payload, 2, v_uid,
    'content:reference_category:dokumenty', v_act_dokumenty, v_cat_dokumenty
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_payload := jsonb_build_object(
    'icon_key', 'computer',
    'short_text', 'AutoCAD, Revit, офисные программы и другое ПО.',
    'blocks', jsonb_build_array(
      jsonb_build_object(
        'type', 'text',
        'text', 'AutoCAD, Revit, офисные программы и другое ПО.'
      ),
      jsonb_build_object('type', 'text', 'text', 'Подробную инструкцию добавим в справочник.')
    )
  );
  v_entry := private.bootstrap_upsert_reference_article(
    p_dry_run, 'content:reference_article:install_software',
    'Как установить нужные программы', v_payload, 3, v_uid,
    'content:reference_category:programmy', v_act_programmy, v_cat_programmy
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_payload := jsonb_build_object(
    'icon_key', 'map',
    'short_text', 'Как найти корпус, кабинет или аудиторию.',
    'blocks', jsonb_build_array(
      jsonb_build_object(
        'type', 'text',
        'text', 'Как найти корпус, кабинет или аудиторию.'
      ),
      jsonb_build_object('type', 'text', 'text', 'Подробную инструкцию добавим в справочник.')
    )
  );
  v_entry := private.bootstrap_upsert_reference_article(
    p_dry_run, 'content:reference_article:campus_map',
    'Карта и аудитории', v_payload, 4, v_uid,
    'content:reference_category:karta', v_act_karta, v_cat_karta
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_payload := jsonb_build_object(
    'icon_key', 'help',
    'short_text', 'Ответы на бытовые вопросы по учёбе.',
    'blocks', jsonb_build_array(
      jsonb_build_object(
        'type', 'text',
        'text', 'Ответы на бытовые вопросы по учёбе.'
      ),
      jsonb_build_object('type', 'text', 'text', 'Подробную инструкцию добавим в справочник.')
    )
  );
  v_entry := private.bootstrap_upsert_reference_article(
    p_dry_run, 'content:reference_article:faq',
    'Частые вопросы', v_payload, 5, v_uid,
    'content:reference_category:faq', v_act_faq, v_cat_faq
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  -- Vacancies ×3 as DRAFT demo (not published; no moderation fixtures)
  v_entry := private.bootstrap_upsert_vacancy(
    p_dry_run, 'vacancy:junior_flutter',
    jsonb_build_object(
      'title', 'Junior Flutter Developer',
      'company_name', 'Campus Lab',
      'summary',
        'Помощь с мобильным приложением, простые экраны, фиксы UI и работа с наставником.',
      'description',
        'Помощь с мобильным приложением, простые экраны, фиксы UI и работа с наставником.'
        || E'\n\n---\nТребования:\n'
        || 'Базовый Flutter, аккуратность, желание учиться.',
      'employment_type', 'internship',
      'work_format', 'hybrid',
      'location', 'Гибрид',
      'salary_text', 'от 35 000 ₽'
    ),
    v_uid
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_entry := private.bootstrap_upsert_vacancy(
    p_dry_run, 'vacancy:teaching_assistant',
    jsonb_build_object(
      'title', 'Ассистент преподавателя по программированию',
      'company_name', 'Кафедра ИТ',
      'summary',
        'Проверка лабораторных, помощь первокурсникам и подготовка коротких материалов.',
      'description',
        'Проверка лабораторных, помощь первокурсникам и подготовка коротких материалов.',
      'employment_type', 'part_time',
      'work_format', 'onsite',
      'location', 'Университет',
      'salary_text', 'по договорённости'
    ),
    v_uid
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  v_entry := private.bootstrap_upsert_vacancy(
    p_dry_run, 'vacancy:presentation_designer',
    jsonb_build_object(
      'title', 'Дизайнер презентаций и лендингов',
      'company_name', 'Студенческий проект',
      'summary',
        'Нужно красиво упаковывать идеи: презентации, простые макеты и визуалы для демо.',
      'description',
        'Нужно красиво упаковывать идеи: презентации, простые макеты и визуалы для демо.',
      'employment_type', 'project',
      'work_format', 'remote',
      'location', 'Удалённо',
      'salary_text', 'за задачу'
    ),
    v_uid
  );
  v_plan := v_plan || jsonb_build_array(v_entry);

  if not p_dry_run then
    perform private.content_write_domain_audit(
      'content.bootstrap_demo',
      'bootstrap',
      null,
      jsonb_build_object(
        'dry_run', false,
        'entry_count', jsonb_array_length(v_plan),
        'notifications_suppressed', true
      )
    );
  end if;

  return jsonb_build_object(
    'dry_run', p_dry_run,
    'entries', v_plan,
    'notifications_suppressed', true,
    'notes', jsonb_build_array(
      'promo+feed+reference published to match existing mobile fallback visibility',
      'vacancies remain draft origin=demo',
      'vacancy demo tags/accentColor are student_ui presentation-only and not vacancy domain columns; static fallback retains them until a future presentation field',
      'subject_info_screen._HelpCard is an explicit residual outside this bootstrap',
      'bootstrap is create-only: never overwrites archive/edit/promote'
    )
  );
end;
$$;

revoke all on function public.admin_bootstrap_demo_content(boolean)
  from public, anon;
grant execute on function public.admin_bootstrap_demo_content(boolean)
  to authenticated, service_role;

comment on function public.admin_bootstrap_demo_content(boolean) is
  'Idempotent demo/legacy bootstrap. dry_run=true performs zero writes. Requires content.publish. Create-only; never overwrites existing rows. Skips tombstoned and conflicts on foreign ownership.';

-- ---------------------------------------------------------------------------
-- Vacancy safe delete (archived-only) + tombstone
-- ---------------------------------------------------------------------------
create or replace function public.admin_safe_delete_vacancy(
  p_id uuid,
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
  v_queued integer := 0;
begin
  v_uid := private.require_admin_permission('content.publish');
  v_row := private.vacancy_lock(p_id, p_expected_row_version);

  if v_row.status is distinct from 'archived' then
    raise exception 'vacancy_must_be_archived' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.vacancy_reports r
    where r.vacancy_id = p_id and r.status = 'open'
  ) then
    raise exception 'open_reports_block_delete' using errcode = 'P0001';
  end if;

  if v_row.legacy_key is not null then
    insert into public.content_legacy_tombstones (
      resource_kind, legacy_key, deleted_by, meta
    ) values (
      'vacancy',
      v_row.legacy_key,
      v_uid,
      jsonb_build_object('previous_origin', v_row.origin)
    )
    on conflict (resource_kind, legacy_key) do update
      set deleted_at = now(),
          deleted_by = excluded.deleted_by,
          meta = excluded.meta;
  end if;

  with queued as (
    insert into public.vacancy_media_cleanup_queue (
      storage_bucket, storage_path, source_vacancy_id, source_title
    )
    select a.storage_bucket, a.storage_path, v_row.id, left(v_row.title, 200)
    from public.vacancy_assets a
    where a.vacancy_id = p_id
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_queued from queued;

  delete from public.vacancies where id = p_id;

  perform private.content_write_domain_audit(
    'vacancy.safe_delete',
    'vacancy',
    p_id,
    jsonb_build_object(
      'previous_status', 'archived',
      'queued_media', v_queued,
      'legacy_key', v_row.legacy_key,
      'tombstone', v_row.legacy_key is not null
    )
  );

  return jsonb_build_object(
    'deleted', true,
    'id', p_id,
    'queued_media', v_queued,
    'legacy_key', v_row.legacy_key
  );
end;
$$;

revoke all on function public.admin_safe_delete_vacancy(uuid, integer)
  from public, anon;
grant execute on function public.admin_safe_delete_vacancy(uuid, integer)
  to authenticated, service_role;
