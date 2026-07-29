-- Stage 16.3 hardening (LOCAL ONLY). Codex plan APPROVE contracts.
-- Depends on: Stage 14 foundation, 20260729150700_stage16_3_reference_corrections.sql
--
-- Adds: reference_categories + article FK, schema_version=2 validator,
-- correction hardening (SET NULL + snapshots + rate-limit lock + reference-only),
-- batched get_my_reference_bundle, Admin category/article RPCs,
-- publish/safe-delete gates, snapshot includes reference_category_id.

begin;

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- Template seed: reference_article_v1 schema_version=2
-- ---------------------------------------------------------------------------
insert into public.content_templates (
  key, schema_version, title, allowed_placements, schema_doc
) values (
  'reference_article_v1',
  2,
  'Материал справочника v2',
  array['reference']::text[],
  jsonb_build_object(
    'required', jsonb_build_array('icon_key', 'short_text', 'blocks'),
    'optional', jsonb_build_array('cta_label', 'cta_route', 'cta_url'),
    'notes', 'Category SoT is reference_categories FK. No client category in payload. blocks: text|image|file|link|cta only.'
  )
)
on conflict (key, schema_version) do nothing;

-- ---------------------------------------------------------------------------
-- Categories SoT
-- ---------------------------------------------------------------------------
create table if not exists public.reference_categories (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  title text not null,
  icon_key text not null,
  status text not null default 'draft'
    check (status in ('draft', 'published', 'archived')),
  sort_order integer not null default 0,
  row_version integer not null default 1 check (row_version >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid null references public.users (id) on delete set null,
  updated_by uuid null references public.users (id) on delete set null,
  constraint reference_categories_key_unique unique (key),
  constraint reference_categories_key_len check (
    btrim(key) <> '' and char_length(key) <= 80
  ),
  constraint reference_categories_title_len check (
    btrim(title) <> '' and char_length(title) <= 120
  ),
  constraint reference_categories_icon_len check (
    btrim(icon_key) <> '' and char_length(icon_key) <= 60
  )
);

create index if not exists reference_categories_status_sort_idx
  on public.reference_categories (status, sort_order, title);

alter table public.reference_categories enable row level security;
alter table public.reference_categories force row level security;
revoke all on table public.reference_categories from public, anon, authenticated;
grant select, insert, update, delete on table public.reference_categories to service_role;

create table if not exists public.content_item_reference_categories (
  content_item_id uuid primary key
    references public.content_items (id) on delete cascade,
  reference_category_id uuid not null
    references public.reference_categories (id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists content_item_reference_categories_cat_idx
  on public.content_item_reference_categories (reference_category_id);

alter table public.content_item_reference_categories enable row level security;
alter table public.content_item_reference_categories force row level security;
revoke all on table public.content_item_reference_categories
  from public, anon, authenticated;
grant select, insert, update, delete on table public.content_item_reference_categories
  to service_role;

-- Default published category (idempotent)
insert into public.reference_categories (key, title, icon_key, status, sort_order)
values ('general', 'Общее', 'info', 'published', 0)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Correction history: SET NULL + snapshots
-- ---------------------------------------------------------------------------
alter table public.content_corrections
  add column if not exists item_title text null,
  add column if not exists item_template_key text null,
  add column if not exists item_schema_version integer null;

alter table public.content_corrections
  alter column content_item_id drop not null;

do $$
begin
  if exists (
    select 1 from information_schema.table_constraints
    where table_schema = 'public'
      and table_name = 'content_corrections'
      and constraint_name = 'content_corrections_content_item_id_fkey'
  ) then
    alter table public.content_corrections
      drop constraint content_corrections_content_item_id_fkey;
  end if;
end $$;

alter table public.content_corrections
  add constraint content_corrections_content_item_id_fkey
  foreign key (content_item_id)
  references public.content_items (id)
  on delete set null;

-- ---------------------------------------------------------------------------
-- Schema v2 validator branch (replace full function with v2 added)
-- ---------------------------------------------------------------------------
create or replace function private.validate_content_payload(
  p_template_key text,
  p_schema_version integer,
  p_payload jsonb
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_template public.content_templates;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if jsonb_typeof(v_payload) <> 'object' then
    raise exception 'invalid_payload_not_object' using errcode = '22023';
  end if;

  select * into v_template
  from public.content_templates t
  where t.key = p_template_key
    and t.schema_version = p_schema_version;

  if not found then
    raise exception 'unknown_template' using errcode = '22023';
  end if;
  if not v_template.is_active then
    raise exception 'inactive_template' using errcode = '22023';
  end if;

  if p_template_key = 'home_promo_v1' and p_schema_version = 1 then
    perform private.content_assert_allowed_keys(v_payload, array[
      'title', 'subtitle', 'icon_key', 'gradient_colors', 'image_asset_id',
      'cta_label', 'cta_route', 'cta_url', 'dismissible', 'reshow_after_hours'
    ]);
    perform private.content_require_text(v_payload, 'title', 120);
    perform private.content_require_text(v_payload, 'subtitle', 240);
    perform private.content_require_text(v_payload, 'icon_key', 60);
    perform private.content_assert_gradient(v_payload);
    perform private.content_require_text(v_payload, 'cta_label', 60);
    perform private.content_require_bool(v_payload, 'dismissible');
    perform private.content_optional_uuid(v_payload, 'image_asset_id');
    perform private.content_optional_int(v_payload, 'reshow_after_hours', 1, 8760);
    perform private.content_assert_cta(
      private.content_optional_text(v_payload, 'cta_route', 300),
      private.content_optional_text(v_payload, 'cta_url', 500)
    );

  elsif p_template_key = 'profile_feed_card_v1' and p_schema_version = 1 then
    perform private.content_assert_allowed_keys(v_payload, array[
      'title', 'subtitle', 'image_asset_id', 'cta_label', 'cta_route', 'cta_url'
    ]);
    perform private.content_require_text(v_payload, 'title', 120);
    perform private.content_require_text(v_payload, 'subtitle', 240);
    perform private.content_require_text(v_payload, 'cta_label', 60);
    perform private.content_optional_uuid(v_payload, 'image_asset_id');
    perform private.content_assert_cta(
      private.content_optional_text(v_payload, 'cta_route', 300),
      private.content_optional_text(v_payload, 'cta_url', 500)
    );

  elsif p_template_key = 'reference_article_v1' and p_schema_version = 1 then
    perform private.content_assert_allowed_keys(v_payload, array[
      'category', 'icon_key', 'short_text', 'blocks',
      'cta_label', 'cta_route', 'cta_url'
    ]);
    perform private.content_require_text(v_payload, 'category', 80);
    perform private.content_require_text(v_payload, 'icon_key', 60);
    perform private.content_require_text(v_payload, 'short_text', 600);
    perform private.content_assert_reference_blocks(v_payload);
    perform private.content_optional_text(v_payload, 'cta_label', 60);
    perform private.content_assert_cta(
      private.content_optional_text(v_payload, 'cta_route', 300),
      private.content_optional_text(v_payload, 'cta_url', 500)
    );

  elsif p_template_key = 'reference_article_v1' and p_schema_version = 2 then
    perform private.content_assert_allowed_keys(v_payload, array[
      'icon_key', 'short_text', 'blocks',
      'cta_label', 'cta_route', 'cta_url'
    ]);
    perform private.content_require_text(v_payload, 'icon_key', 60);
    perform private.content_require_text(v_payload, 'short_text', 600);
    perform private.content_assert_reference_blocks(v_payload);
    perform private.content_optional_text(v_payload, 'cta_label', 60);
    perform private.content_assert_cta(
      private.content_optional_text(v_payload, 'cta_route', 300),
      private.content_optional_text(v_payload, 'cta_url', 500)
    );

  else
    raise exception 'no_validator_for_template' using errcode = '22023';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Snapshot includes reference_category_id
-- ---------------------------------------------------------------------------
create or replace function private.content_snapshot_version(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.content_items;
  v_snapshot jsonb;
  v_cat uuid;
begin
  select * into v_row from public.content_items where id = p_id;
  if not found then
    return;
  end if;

  select reference_category_id into v_cat
  from public.content_item_reference_categories
  where content_item_id = v_row.id;

  v_snapshot := jsonb_build_object(
    'template_key', v_row.template_key,
    'schema_version', v_row.schema_version,
    'title', v_row.title,
    'payload', v_row.payload,
    'priority', v_row.priority,
    'starts_at', v_row.starts_at,
    'ends_at', v_row.ends_at,
    'is_hidden', v_row.is_hidden,
    'status', v_row.status,
    'origin', v_row.origin,
    'audience_mode', v_row.audience_mode,
    'reference_category_id', v_cat,
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

  insert into public.content_item_versions (
    content_item_id, version_number, snapshot, created_by
  ) values (
    v_row.id,
    v_row.version_number,
    v_snapshot,
    auth.uid()
  )
  on conflict (content_item_id, version_number) do update
    set snapshot = excluded.snapshot,
        created_by = excluded.created_by,
        created_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.reference_article_admin_json(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_base jsonb;
  v_cat_id uuid;
  v_cat_title text;
  v_sort integer := 0;
begin
  v_base := private.content_item_to_admin_json(p_id);

  select c.reference_category_id, rc.title, coalesce(p.sort_order, 0)
    into v_cat_id, v_cat_title, v_sort
  from public.content_item_reference_categories c
  join public.reference_categories rc on rc.id = c.reference_category_id
  left join public.content_item_placements p
    on p.content_item_id = c.content_item_id and p.placement = 'reference'
  where c.content_item_id = p_id;

  return v_base
    || jsonb_build_object(
      'reference_category_id', v_cat_id,
      'category_id', v_cat_id,
      'category_title', v_cat_title,
      'sort_order', v_sort
    );
end;
$$;

revoke all on function private.reference_article_admin_json(uuid)
  from public, anon, authenticated;
grant execute on function private.reference_article_admin_json(uuid) to service_role;

create or replace function private.reference_assert_publishable(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.content_items;
  v_cat public.reference_categories;
begin
  select * into v_row from public.content_items where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.template_key is distinct from 'reference_article_v1' then
    return;
  end if;

  if not exists (
    select 1 from public.content_item_placements p
    where p.content_item_id = p_id and p.placement = 'reference'
  ) then
    raise exception 'reference_placement_required' using errcode = 'P0001';
  end if;

  select rc.* into v_cat
  from public.content_item_reference_categories link
  join public.reference_categories rc on rc.id = link.reference_category_id
  where link.content_item_id = p_id;
  if not found then
    raise exception 'reference_category_required' using errcode = 'P0001';
  end if;
  if v_cat.status is distinct from 'published' then
    raise exception 'reference_category_not_published' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on function private.reference_assert_publishable(uuid)
  from public, anon, authenticated;
grant execute on function private.reference_assert_publishable(uuid) to service_role;

-- Wrap publish with reference gates
create or replace function public.admin_publish_content(
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
  v_preview jsonb;
  v_count integer;
begin
  v_uid := private.require_admin_permission('content.publish');
  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  perform private.validate_content_payload(
    v_row.template_key, v_row.schema_version, v_row.payload
  );
  perform private.content_assert_payload_assets(p_id);
  perform private.content_assert_audience_consistent(p_id);
  perform private.reference_assert_publishable(p_id);

  v_preview := private.content_preview_audience_count(p_id);
  v_count := coalesce((v_preview ->> 'recipient_count')::integer, 0);

  if v_row.audience_mode <> 'all' and v_count = 0 then
    raise exception 'empty_audience' using errcode = 'P0001';
  end if;

  update public.content_items c set
    status = 'published',
    published_by = v_uid,
    published_at = coalesce(c.published_at, now()),
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  perform private.content_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'content.publish',
    'content_item',
    p_id,
    jsonb_build_object(
      'audience_mode', v_row.audience_mode,
      'recipient_count', v_count,
      'version_number', v_row.version_number,
      'row_version', v_row.row_version
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    return private.reference_article_admin_json(p_id);
  end if;
  return private.content_item_to_admin_json(p_id);
end;
$$;

-- Safe delete rejects open corrections
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
      'tombstone', true
    )
  );

  return jsonb_build_object(
    'deleted', true,
    'id', p_id,
    'queued_media', v_queued
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Corrections: reference-only + advisory lock + snapshots
-- ---------------------------------------------------------------------------
create or replace function public.submit_content_correction(
  p_content_item_id uuid,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
  v_item public.content_items;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if v_note is null then
    raise exception 'note_required' using errcode = '22023';
  end if;
  if char_length(v_note) > 1000 then
    raise exception 'note_too_long' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_uid::text));

  select * into v_item from public.content_items where id = p_content_item_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_item.template_key is distinct from 'reference_article_v1' then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.content_item_placements p
    where p.content_item_id = p_content_item_id
      and p.placement = 'reference'
  ) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not private.content_item_deliverable_to_user(p_content_item_id, v_uid) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.content_corrections c
    where c.reporter_user_id = v_uid
      and c.created_at > now() - interval '60 seconds'
  ) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.content_corrections (
    content_item_id, reporter_user_id, note,
    item_title, item_template_key, item_schema_version
  ) values (
    p_content_item_id, v_uid, v_note,
    left(v_item.title, 200), v_item.template_key, v_item.schema_version
  )
  on conflict (content_item_id, reporter_user_id) where (status = 'open')
  do update set note = excluded.note
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.admin_list_content_corrections(
  p_status text default 'open',
  p_content_item_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  v_uid := private.require_admin_permission('moderation.read');

  if v_status is not null
     and v_status not in ('open', 'resolved', 'rejected', 'all') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', c.id,
          'content_item_id', c.content_item_id,
          'content_title', coalesce(ci.title, c.item_title),
          'template_key', coalesce(ci.template_key, c.item_template_key),
          'schema_version', coalesce(ci.schema_version, c.item_schema_version),
          'content_status', ci.status,
          'note', c.note,
          'status', c.status,
          'resolution_note', c.resolution_note,
          'resolved_at', c.resolved_at,
          'created_at', c.created_at
        )
        order by c.created_at desc
      )
      from (
        select *
        from public.content_corrections c0
        where (
            coalesce(v_status, 'open') = 'all'
            or c0.status = coalesce(v_status, 'open')
          )
          and (p_content_item_id is null or c0.content_item_id = p_content_item_id)
        order by c0.created_at desc
        limit v_limit offset v_offset
      ) c
      left join public.content_items ci on ci.id = c.content_item_id
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin category RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_reference_categories()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin_permission('content.read');
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', c.id,
          'key', c.key,
          'title', c.title,
          'icon_key', c.icon_key,
          'status', c.status,
          'sort_order', c.sort_order,
          'row_version', c.row_version
        )
        order by c.sort_order, c.title
      )
      from public.reference_categories c
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_upsert_reference_category(
  p_id uuid default null,
  p_expected_row_version integer default 0,
  p_patch jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.reference_categories;
  v_key text;
  v_title text;
  v_icon text;
  v_status text;
  v_sort integer;
begin
  v_uid := private.require_admin_permission('content.write');
  v_title := nullif(btrim(coalesce(p_patch->>'title', '')), '');
  v_icon := nullif(btrim(coalesce(p_patch->>'icon_key', '')), '');
  v_status := coalesce(nullif(btrim(coalesce(p_patch->>'status', '')), ''), 'draft');
  v_sort := coalesce((p_patch->>'sort_order')::integer, 0);
  v_key := nullif(btrim(coalesce(p_patch->>'key', '')), '');

  if v_title is null or v_icon is null then
    raise exception 'title_and_icon_required' using errcode = '22023';
  end if;
  if v_status not in ('draft', 'published', 'archived') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  if p_id is null then
    -- Non-draft create is a publish/archive transition → content.publish.
    if v_status is distinct from 'draft' then
      perform private.require_admin_permission('content.publish');
    end if;
    v_key := coalesce(v_key, lower(regexp_replace(v_title, '[^a-zA-Z0-9]+', '_', 'g')));
    insert into public.reference_categories (
      key, title, icon_key, status, sort_order, created_by, updated_by
    ) values (
      left(v_key, 80), left(v_title, 120), left(v_icon, 60), v_status, v_sort, v_uid, v_uid
    )
    returning * into v_row;
  else
    select * into v_row from public.reference_categories where id = p_id for update;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    if v_row.row_version is distinct from p_expected_row_version then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
    -- Any status transition requires content.publish (draft→published/archived etc).
    if v_status is distinct from v_row.status then
      perform private.require_admin_permission('content.publish');
    end if;
    -- Stable category key is immutable after creation (ignore patch key).
    update public.reference_categories c set
      title = left(v_title, 120),
      icon_key = left(v_icon, 60),
      status = v_status,
      sort_order = v_sort,
      row_version = c.row_version + 1,
      updated_by = v_uid,
      updated_at = now()
    where c.id = p_id
    returning * into v_row;
  end if;

  perform private.admin_write_audit(
    'reference_category.upsert',
    'reference_category',
    v_row.id::text,
    jsonb_build_object('status', v_row.status, 'row_version', v_row.row_version)
  );

  return jsonb_build_object(
    'id', v_row.id,
    'key', v_row.key,
    'title', v_row.title,
    'icon_key', v_row.icon_key,
    'status', v_row.status,
    'sort_order', v_row.sort_order,
    'row_version', v_row.row_version
  );
end;
$$;

create or replace function public.admin_reorder_reference_categories(
  p_ordered_ids uuid[],
  p_expected_row_versions integer[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  i integer;
  n integer;
  v_id uuid;
  v_exp integer;
  v_row public.reference_categories;
  v_sorted uuid[];
begin
  v_uid := private.require_admin_permission('content.write');
  n := coalesce(array_length(p_ordered_ids, 1), 0);
  if p_ordered_ids is null or p_expected_row_versions is null
     or n = 0
     or n is distinct from coalesce(array_length(p_expected_row_versions, 1), 0) then
    raise exception 'invalid_reorder_payload' using errcode = '22023';
  end if;
  if (select count(distinct x) from unnest(p_ordered_ids) as t(x)) <> n then
    raise exception 'duplicate_reorder_ids' using errcode = '22023';
  end if;

  -- Lock in deterministic UUID order to avoid deadlocks.
  v_sorted := (
    select array_agg(x order by x)
    from unnest(p_ordered_ids) as t(x)
  );
  for i in 1 .. n loop
    select * into v_row
    from public.reference_categories
    where id = v_sorted[i]
    for update;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  end loop;

  -- Validate expected versions against caller order before mutating.
  for i in 1 .. n loop
    v_id := p_ordered_ids[i];
    v_exp := p_expected_row_versions[i];
    select * into v_row from public.reference_categories where id = v_id;
    if v_row.row_version is distinct from v_exp then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
  end loop;

  for i in 1 .. n loop
    update public.reference_categories c set
      sort_order = i - 1,
      row_version = c.row_version + 1,
      updated_by = v_uid,
      updated_at = now()
    where c.id = p_ordered_ids[i];
  end loop;

  perform private.admin_write_audit(
    'reference_category.reorder',
    'reference_category',
    'batch',
    jsonb_build_object('count', n)
  );

  return public.admin_list_reference_categories();
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin article RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_reference_articles(
  p_status text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
begin
  perform private.require_admin_permission('content.read');
  return coalesce(
    (
      select jsonb_agg(private.reference_article_admin_json(i.id) order by coalesce(p.sort_order, 0), i.title)
      from public.content_items i
      join public.content_item_placements p
        on p.content_item_id = i.id and p.placement = 'reference'
      where i.template_key = 'reference_article_v1'
        and (v_status is null or i.status = v_status)
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_upsert_reference_article(
  p_id uuid default null,
  p_expected_row_version integer default 0,
  p_patch jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_created jsonb;
  v_item_id uuid;
  v_title text;
  v_payload jsonb;
  v_cat uuid;
  v_sort integer;
  v_origin text;
  v_schema integer;
  v_row public.content_items;
  v_update jsonb := '{}'::jsonb;
begin
  v_uid := private.require_admin_permission('content.write');
  v_title := nullif(btrim(coalesce(p_patch->>'title', '')), '');
  v_cat := nullif(p_patch->>'reference_category_id', '')::uuid;
  v_sort := coalesce((p_patch->>'sort_order')::integer, 0);
  v_origin := coalesce(nullif(btrim(coalesce(p_patch->>'origin', '')), ''), 'admin');
  v_schema := coalesce((p_patch->>'schema_version')::integer, 2);
  v_payload := p_patch->'payload';

  if p_id is null then
    if v_title is null or v_cat is null or v_payload is null then
      raise exception 'title_category_payload_required' using errcode = '22023';
    end if;
    if not exists (select 1 from public.reference_categories where id = v_cat) then
      raise exception 'not_found' using errcode = 'P0002';
    end if;

    v_created := public.admin_create_content_draft(
      'reference_article_v1', v_schema, v_title, v_payload, v_origin
    );
    v_item_id := (v_created->>'id')::uuid;

    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (v_item_id, v_cat);

    perform public.admin_set_content_placements(
      v_item_id,
      jsonb_build_array(
        jsonb_build_object('placement', 'reference', 'sort_order', v_sort)
      ),
      (v_created->>'row_version')::integer
    );

    return private.reference_article_admin_json(v_item_id);
  end if;

  select * into v_row from public.content_items where id = p_id for update;
  if not found or v_row.template_key is distinct from 'reference_article_v1' then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.row_version is distinct from p_expected_row_version then
    raise exception 'row_version_conflict' using errcode = '40001';
  end if;
  if v_row.status is distinct from 'draft' then
    raise exception 'draft_only' using errcode = '55000';
  end if;

  if v_title is not null then
    v_update := v_update || jsonb_build_object('title', v_title);
  end if;
  if v_payload is not null then
    v_update := v_update || jsonb_build_object('payload', v_payload);
  end if;
  if p_patch ? 'origin' then
    v_update := v_update || jsonb_build_object('origin', v_origin);
  end if;

  -- Category FK first so subsequent draft/placement snapshots include it.
  if v_cat is not null then
    if not exists (select 1 from public.reference_categories where id = v_cat) then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (p_id, v_cat)
    on conflict (content_item_id) do update
      set reference_category_id = excluded.reference_category_id;
  end if;

  if v_update <> '{}'::jsonb then
    perform public.admin_update_content_draft(p_id, v_update, p_expected_row_version);
    select row_version into p_expected_row_version
    from public.content_items where id = p_id;
  elsif v_cat is not null and not (p_patch ? 'sort_order') then
    -- Category-only mutation still participates in optimistic concurrency + snapshot.
    update public.content_items c set
      version_number = c.version_number + 1,
      row_version = c.row_version + 1,
      updated_by = v_uid,
      updated_at = now()
    where c.id = p_id
    returning * into v_row;
    perform private.content_snapshot_version(p_id);
    perform private.content_write_domain_audit(
      'content.set_reference_category',
      'content_item',
      p_id,
      jsonb_build_object(
        'reference_category_id', v_cat,
        'row_version', v_row.row_version,
        'version_number', v_row.version_number
      )
    );
    p_expected_row_version := v_row.row_version;
  end if;

  if p_patch ? 'sort_order' then
    select row_version into p_expected_row_version
    from public.content_items where id = p_id;
    perform public.admin_set_content_placements(
      p_id,
      jsonb_build_array(
        jsonb_build_object('placement', 'reference', 'sort_order', v_sort)
      ),
      p_expected_row_version
    );
  end if;

  return private.reference_article_admin_json(p_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Mobile batched bundle
-- ---------------------------------------------------------------------------
create or replace function public.get_my_reference_bundle()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  return jsonb_build_object(
    'categories', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', c.id,
            'key', c.key,
            'title', c.title,
            'icon_key', c.icon_key,
            'status', c.status,
            'sort_order', c.sort_order
          )
          order by c.sort_order, c.title
        )
        from public.reference_categories c
        where c.status = 'published'
          and exists (
            select 1
            from public.content_item_reference_categories link
            join public.content_items i on i.id = link.content_item_id
            join public.content_item_placements p
              on p.content_item_id = i.id and p.placement = 'reference'
            where link.reference_category_id = c.id
              and i.status = 'published'
              and i.template_key = 'reference_article_v1'
              and coalesce(i.is_hidden, false) = false
              and (i.starts_at is null or i.starts_at <= v_now)
              and (i.ends_at is null or i.ends_at > v_now)
              and private.content_item_visible_to_user(i.id, v_uid)
          )
      ),
      '[]'::jsonb
    ),
    'articles', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'title', i.title,
            'template_key', i.template_key,
            'schema_version', i.schema_version,
            'origin', i.origin,
            'payload', i.payload,
            'category_id', link.reference_category_id,
            'category_title', c.title,
            'sort_order', p.sort_order,
            'status', i.status
          )
          order by p.sort_order, i.title
        )
        from public.content_items i
        join public.content_item_placements p
          on p.content_item_id = i.id and p.placement = 'reference'
        join public.content_item_reference_categories link
          on link.content_item_id = i.id
        join public.reference_categories c
          on c.id = link.reference_category_id and c.status = 'published'
        where i.template_key = 'reference_article_v1'
          and i.status = 'published'
          and coalesce(i.is_hidden, false) = false
          and (i.starts_at is null or i.starts_at <= v_now)
          and (i.ends_at is null or i.ends_at > v_now)
          and private.content_item_visible_to_user(i.id, v_uid)
      ),
      '[]'::jsonb
    )
  );
end;
$$;

create or replace function public.admin_restore_content_version(
  p_id uuid,
  p_version_number integer,
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
  v_snapshot jsonb;
  v_template_key text;
  v_schema_version integer;
  v_previous text;
  v_entry jsonb;
  v_cat uuid;
begin
  v_uid := private.require_admin_permission('content.write');
  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  select v.snapshot into v_snapshot
  from public.content_item_versions v
  where v.content_item_id = p_id
    and v.version_number = p_version_number;
  if v_snapshot is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_template_key := v_snapshot ->> 'template_key';
  v_schema_version := (v_snapshot ->> 'schema_version')::integer;
  if v_template_key is distinct from v_row.template_key
     or v_schema_version is distinct from v_row.schema_version then
    raise exception 'template_mismatch' using errcode = '22023';
  end if;

  perform private.validate_content_payload(
    v_template_key, v_schema_version, coalesce(v_snapshot -> 'payload', '{}'::jsonb)
  );

  v_previous := v_row.status;

  update public.content_items c set
    title = left(coalesce(v_snapshot ->> 'title', ''), 200),
    payload = coalesce(v_snapshot -> 'payload', '{}'::jsonb),
    priority = coalesce((v_snapshot ->> 'priority')::integer, 0),
    starts_at = nullif(v_snapshot ->> 'starts_at', '')::timestamptz,
    ends_at = nullif(v_snapshot ->> 'ends_at', '')::timestamptz,
    is_hidden = coalesce((v_snapshot ->> 'is_hidden')::boolean, false),
    audience_mode = coalesce(v_snapshot ->> 'audience_mode', 'all'),
    status = 'draft',
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  delete from public.content_item_placements where content_item_id = p_id;
  for v_entry in
    select value
    from jsonb_array_elements(coalesce(v_snapshot -> 'placements', '[]'::jsonb))
  loop
    insert into public.content_item_placements (content_item_id, placement, sort_order)
    values (
      p_id,
      v_entry ->> 'placement',
      coalesce((v_entry ->> 'sort_order')::integer, 0)
    );
  end loop;

  delete from public.content_item_audience_groups where content_item_id = p_id;
  insert into public.content_item_audience_groups (content_item_id, group_id)
  select p_id, g.value::uuid
  from jsonb_array_elements_text(
    coalesce(v_snapshot -> 'audience_group_ids', '[]'::jsonb)
  ) as g(value)
  where exists (select 1 from public.groups gr where gr.id = g.value::uuid);

  delete from public.content_item_audience_users where content_item_id = p_id;
  insert into public.content_item_audience_users (content_item_id, user_id)
  select p_id, u.value::uuid
  from jsonb_array_elements_text(
    coalesce(v_snapshot -> 'audience_user_ids', '[]'::jsonb)
  ) as u(value)
  where exists (select 1 from public.users us where us.id = u.value::uuid);

  if v_template_key = 'reference_article_v1' then
    v_cat := nullif(v_snapshot ->> 'reference_category_id', '')::uuid;
    if v_cat is null then
      raise exception 'reference_category_missing_in_snapshot' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.reference_categories where id = v_cat) then
      raise exception 'reference_category_missing' using errcode = 'P0002';
    end if;
    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (p_id, v_cat)
    on conflict (content_item_id) do update
      set reference_category_id = excluded.reference_category_id;
  end if;

  perform private.content_assert_payload_assets(p_id);
  perform private.content_assert_audience_consistent(p_id);
  perform private.content_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'content.restore_version',
    'content_item',
    p_id,
    jsonb_build_object(
      'restored_version', p_version_number,
      'previous_status', v_previous,
      'new_status', 'draft',
      'row_version', v_row.row_version
    )
  );

  if v_template_key = 'reference_article_v1' then
    return private.reference_article_admin_json(p_id);
  end if;
  return private.content_item_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_resolve_content_correction(
  p_id uuid,
  p_action text,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_corrections;
  v_action text := nullif(btrim(coalesce(p_action, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  v_uid := private.require_any_admin_permission(
    array['moderation.action', 'moderation.write']
  );

  if v_action is null or v_action not in ('resolve', 'reject') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_action = 'reject' and v_reason is null then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;

  select * into v_row from public.content_corrections where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'open' then
    raise exception 'already_closed' using errcode = '55000';
  end if;

  update public.content_corrections c set
    status = case when v_action = 'resolve' then 'resolved' else 'rejected' end,
    resolved_by = v_uid,
    resolved_at = now(),
    resolution_note = v_reason
  where c.id = p_id
  returning * into v_row;

  perform private.admin_write_audit(
    'content_correction.' || v_action,
    'content_correction',
    p_id::text,
    jsonb_build_object(
      'content_item_id', v_row.content_item_id,
      'status', v_row.status
    )
  );

  return jsonb_build_object('ok', true, 'id', p_id, 'status', v_row.status);
end;
$$;

create or replace function public.admin_archive_content(
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
  v_previous text;
begin
  v_uid := private.require_admin_permission('content.publish');
  v_row := private.content_item_lock(p_id, p_expected_row_version);
  v_previous := v_row.status;

  update public.content_items c set
    status = 'archived',
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  perform private.content_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'content.archive',
    'content_item',
    p_id,
    jsonb_build_object(
      'previous_status', v_previous,
      'version_number', v_row.version_number,
      'row_version', v_row.row_version
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    return private.reference_article_admin_json(p_id);
  end if;
  return private.content_item_to_admin_json(p_id);
end;
$$;

-- Mirror publish/archive: audience RPC must return reference admin JSON
-- (category_id / category_title) so Admin save can re-parse the article.
create or replace function public.admin_set_content_audience(
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
  v_row public.content_items;
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

  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status <> 'draft' then
    raise exception 'draft_only' using errcode = '55000';
  end if;

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

  delete from public.content_item_audience_groups where content_item_id = p_id;
  delete from public.content_item_audience_users where content_item_id = p_id;

  insert into public.content_item_audience_groups (content_item_id, group_id)
  select p_id, g from unnest(v_groups) as g;

  insert into public.content_item_audience_users (content_item_id, user_id)
  select p_id, u from unnest(v_users) as u;

  update public.content_items c set
    audience_mode = v_mode,
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  perform private.content_assert_audience_consistent(p_id);
  perform private.content_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'content.set_audience',
    'content_item',
    p_id,
    jsonb_build_object(
      'audience_mode', v_mode,
      'group_count', coalesce(array_length(v_groups, 1), 0),
      'user_count', coalesce(array_length(v_users, 1), 0),
      'row_version', v_row.row_version
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    return private.reference_article_admin_json(p_id);
  end if;
  return private.content_item_to_admin_json(p_id);
end;
$$;

-- Grants
revoke all on function public.admin_list_reference_categories() from public, anon;
grant execute on function public.admin_list_reference_categories() to authenticated, service_role;

revoke all on function public.admin_upsert_reference_category(uuid, integer, jsonb) from public, anon;
grant execute on function public.admin_upsert_reference_category(uuid, integer, jsonb)
  to authenticated, service_role;

revoke all on function public.admin_reorder_reference_categories(uuid[], integer[]) from public, anon;
grant execute on function public.admin_reorder_reference_categories(uuid[], integer[])
  to authenticated, service_role;

revoke all on function public.admin_list_reference_articles(text) from public, anon;
grant execute on function public.admin_list_reference_articles(text)
  to authenticated, service_role;

revoke all on function public.admin_upsert_reference_article(uuid, integer, jsonb) from public, anon;
grant execute on function public.admin_upsert_reference_article(uuid, integer, jsonb)
  to authenticated, service_role;

revoke all on function public.get_my_reference_bundle() from public, anon;
grant execute on function public.get_my_reference_bundle() to authenticated, service_role;

comment on function public.get_my_reference_bundle() is
  'Stage 16.3 batched Mobile reference categories+articles. No signed URLs/paths.';

-- ---------------------------------------------------------------------------
-- Content-media signed download authorize (paths never returned to clients)
-- Upload intent/finalize for content_assets remains Edge+service_role local;
-- Admin may attach assets via Stage 14 content_assets once objects exist.
-- ---------------------------------------------------------------------------
create or replace function public.authorize_content_asset_download(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_asset public.content_assets;
  v_item public.content_items;
  v_is_admin boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select * into v_asset from public.content_assets where id = p_asset_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_is_admin := private.has_admin_permission(v_uid, 'content.read', 'global', null)
    or private.has_admin_permission(v_uid, 'content.write', 'global', null);

  if v_is_admin then
    return jsonb_build_object(
      'authorized', true,
      'mime_type', v_asset.mime_type,
      'byte_size', v_asset.byte_size
    );
  end if;

  if not private.content_item_deliverable_to_user(v_asset.content_item_id, v_uid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_item from public.content_items where id = v_asset.content_item_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- Non-admin: asset must still be referenced by the current published payload.
  if not (p_asset_id = any (private.content_payload_asset_ids(v_item.payload))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'authorized', true,
    'mime_type', v_asset.mime_type,
    'byte_size', v_asset.byte_size
  );
end;
$$;

create or replace function public.service_content_asset_storage_path(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_asset public.content_assets;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  select * into v_asset from public.content_assets where id = p_asset_id;
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

revoke all on function public.authorize_content_asset_download(uuid) from public, anon;
grant execute on function public.authorize_content_asset_download(uuid)
  to authenticated, service_role;

revoke all on function public.service_content_asset_storage_path(uuid)
  from public, anon, authenticated;
grant execute on function public.service_content_asset_storage_path(uuid) to service_role;

commit;
