-- Stage 14.1.1 — Working drafts (content + vacancies) + reference schema v3 blocks
-- NEW migration only. Does not edit applied Stage 14–19 / 14.1 files.
--
-- Contracts:
--   * Working drafts never mutate live published rows until publish RPC
--   * admin_begin_* returns existing draft unchanged (never overwrite from production)
--   * Publish checks draft.row_version + base_canonical_row_version
--   * Lifecycle with open draft: unpublish/archive/restore → working_draft_exists
--   * Safe-delete requires discard first
--   * Promote demo allowed with open draft
--   * Reference schema_version=3 adds heading/info/warning/list; v1/v2 unchanged

begin;

create schema if not exists private;

-- ===========================================================================
-- 1. content_item_working_drafts
-- ===========================================================================
create table if not exists public.content_item_working_drafts (
  id uuid primary key default gen_random_uuid(),
  content_item_id uuid not null unique
    references public.content_items (id) on delete cascade,
  base_canonical_row_version integer not null,
  title text not null,
  payload jsonb not null,
  priority integer not null default 0,
  starts_at timestamptz null,
  ends_at timestamptz null,
  is_hidden boolean not null default false,
  audience_mode text not null
    check (audience_mode in ('all', 'groups', 'users', 'groups_and_users')),
  audience_group_ids uuid[] not null default '{}'::uuid[],
  audience_user_ids uuid[] not null default '{}'::uuid[],
  placement text null
    check (
      placement is null
      or placement in ('home_promo', 'profile_feed', 'reference')
    ),
  sort_order integer not null default 0,
  reference_category_id uuid null
    references public.reference_categories (id) on delete set null,
  draft_asset_ids uuid[] not null default '{}'::uuid[],
  row_version integer not null default 1 check (row_version >= 1),
  created_by uuid null references public.users (id) on delete set null,
  updated_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint content_item_working_drafts_schedule_chk check (
    ends_at is null or starts_at is null or ends_at > starts_at
  ),
  constraint content_item_working_drafts_title_len check (
    char_length(title) <= 200
  )
);

comment on table public.content_item_working_drafts is
  'Stage 14.1.1: mutable working copy for content edits. Canonical content_items stay live until admin_publish_content_working_draft.';

create index if not exists content_item_working_drafts_updated_idx
  on public.content_item_working_drafts (updated_at desc);

alter table public.content_item_working_drafts enable row level security;
alter table public.content_item_working_drafts force row level security;
revoke all on table public.content_item_working_drafts
  from public, anon, authenticated;
grant select, insert, update, delete on table public.content_item_working_drafts
  to service_role;

-- ===========================================================================
-- 2. vacancy_working_drafts
-- ===========================================================================
create table if not exists public.vacancy_working_drafts (
  id uuid primary key default gen_random_uuid(),
  vacancy_id uuid not null unique
    references public.vacancies (id) on delete cascade,
  base_canonical_row_version integer not null,
  title text not null,
  company_name text not null default '',
  summary text not null default '',
  description text not null default '',
  employment_type text null check (
    employment_type is null
    or employment_type in ('internship', 'part_time', 'full_time', 'project', 'volunteer')
  ),
  work_format text null check (
    work_format is null or work_format in ('onsite', 'remote', 'hybrid')
  ),
  location text null,
  salary_text text null,
  external_url text null,
  contacts jsonb not null default '{}'::jsonb,
  priority integer not null default 0,
  starts_at timestamptz null,
  ends_at timestamptz null,
  expires_at timestamptz null,
  is_hidden boolean not null default false,
  audience_mode text not null
    check (audience_mode in ('all', 'groups', 'users', 'groups_and_users')),
  audience_group_ids uuid[] not null default '{}'::uuid[],
  audience_user_ids uuid[] not null default '{}'::uuid[],
  draft_asset_ids uuid[] not null default '{}'::uuid[],
  row_version integer not null default 1 check (row_version >= 1),
  created_by uuid null references public.users (id) on delete set null,
  updated_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vacancy_working_drafts_title_len check (
    btrim(title) <> '' and char_length(title) <= 200
  ),
  constraint vacancy_working_drafts_text_len check (
    char_length(company_name) <= 200
    and char_length(summary) <= 600
    and char_length(description) <= 12000
    and (location is null or char_length(location) <= 200)
    and (salary_text is null or char_length(salary_text) <= 120)
    and (external_url is null or char_length(external_url) <= 500)
  ),
  constraint vacancy_working_drafts_schedule_chk check (
    ends_at is null or starts_at is null or ends_at > starts_at
  ),
  constraint vacancy_working_drafts_expiry_chk check (
    expires_at is null or starts_at is null or expires_at > starts_at
  ),
  constraint vacancy_working_drafts_contacts_object_chk check (
    jsonb_typeof(contacts) = 'object'
  )
);

comment on table public.vacancy_working_drafts is
  'Stage 14.1.1: mutable working copy for vacancy edits. Canonical vacancies stay live until admin_publish_vacancy_working_draft.';

create index if not exists vacancy_working_drafts_updated_idx
  on public.vacancy_working_drafts (updated_at desc);

alter table public.vacancy_working_drafts enable row level security;
alter table public.vacancy_working_drafts force row level security;
revoke all on table public.vacancy_working_drafts
  from public, anon, authenticated;
grant select, insert, update, delete on table public.vacancy_working_drafts
  to service_role;

-- ===========================================================================
-- 3. Reference schema v3 — new block types (v1/v2 validators unchanged)
-- ===========================================================================
insert into public.content_templates (
  key, schema_version, title, allowed_placements, schema_doc, is_active
) values (
  'reference_article_v1',
  3,
  'Материал справочника v3',
  array['reference']::text[],
  jsonb_build_object(
    'required', jsonb_build_array('icon_key', 'short_text', 'blocks'),
    'optional', jsonb_build_array('cta_label', 'cta_route', 'cta_url'),
    'notes',
    'Category SoT is reference_categories FK. blocks: text|image|file|link|cta|heading|info|warning|list.'
  ),
  true
)
on conflict (key, schema_version) do update
  set is_active = true,
      title = excluded.title,
      allowed_placements = excluded.allowed_placements,
      schema_doc = excluded.schema_doc;

create or replace function private.content_assert_reference_blocks_v3(p_payload jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_blocks jsonb;
  v_block jsonb;
  v_type text;
  v_level integer;
  v_style text;
  v_items jsonb;
  v_item text;
  v_idx integer;
begin
  if not (coalesce(p_payload, '{}'::jsonb) ? 'blocks') then
    raise exception 'missing_field_blocks' using errcode = '22023';
  end if;
  v_blocks := p_payload -> 'blocks';
  if jsonb_typeof(v_blocks) <> 'array' then
    raise exception 'invalid_type_blocks' using errcode = '22023';
  end if;
  if jsonb_array_length(v_blocks) > 50 then
    raise exception 'too_many_blocks' using errcode = '22023';
  end if;

  for v_block in select value from jsonb_array_elements(v_blocks) loop
    if jsonb_typeof(v_block) <> 'object' then
      raise exception 'invalid_block_not_object' using errcode = '22023';
    end if;
    v_type := private.content_require_text(v_block, 'type', 20);
    if v_type not in (
      'text', 'image', 'file', 'link', 'cta',
      'heading', 'info', 'warning', 'list'
    ) then
      raise exception 'invalid_block_type_%', v_type using errcode = '22023';
    end if;

    if v_type = 'text' then
      perform private.content_assert_allowed_keys(v_block, array['type', 'text']);
      perform private.content_require_text(v_block, 'text', 4000);
    elsif v_type = 'image' then
      perform private.content_assert_allowed_keys(
        v_block, array['type', 'asset_id', 'caption']
      );
      if private.content_optional_uuid(v_block, 'asset_id') is null then
        raise exception 'missing_field_asset_id' using errcode = '22023';
      end if;
      perform private.content_optional_text(v_block, 'caption', 240);
    elsif v_type = 'file' then
      perform private.content_assert_allowed_keys(
        v_block, array['type', 'asset_id', 'title']
      );
      if private.content_optional_uuid(v_block, 'asset_id') is null then
        raise exception 'missing_field_asset_id' using errcode = '22023';
      end if;
      perform private.content_optional_text(v_block, 'title', 200);
    elsif v_type = 'link' then
      perform private.content_assert_allowed_keys(
        v_block, array['type', 'label', 'url']
      );
      perform private.content_require_text(v_block, 'label', 200);
      perform private.content_assert_cta(
        null,
        private.content_require_text(v_block, 'url', 500)
      );
    elsif v_type = 'cta' then
      perform private.content_assert_allowed_keys(
        v_block, array['type', 'label', 'route', 'url']
      );
      perform private.content_require_text(v_block, 'label', 120);
      perform private.content_assert_cta(
        private.content_optional_text(v_block, 'route', 300),
        private.content_optional_text(v_block, 'url', 500)
      );
    elsif v_type = 'heading' then
      perform private.content_assert_allowed_keys(
        v_block, array['type', 'text', 'level']
      );
      perform private.content_require_text(v_block, 'text', 200);
      v_level := private.content_optional_int(v_block, 'level', 1, 3);
      if v_level is null then
        raise exception 'missing_field_level' using errcode = '22023';
      end if;
    elsif v_type = 'info' then
      perform private.content_assert_allowed_keys(v_block, array['type', 'text']);
      perform private.content_require_text(v_block, 'text', 2000);
    elsif v_type = 'warning' then
      perform private.content_assert_allowed_keys(v_block, array['type', 'text']);
      perform private.content_require_text(v_block, 'text', 2000);
    else
      -- list
      perform private.content_assert_allowed_keys(
        v_block, array['type', 'style', 'items']
      );
      v_style := private.content_require_text(v_block, 'style', 20);
      if v_style not in ('bullet', 'numbered') then
        raise exception 'invalid_list_style' using errcode = '22023';
      end if;
      if not (v_block ? 'items') or jsonb_typeof(v_block -> 'items') <> 'array' then
        raise exception 'invalid_type_items' using errcode = '22023';
      end if;
      v_items := v_block -> 'items';
      if jsonb_array_length(v_items) < 1 then
        raise exception 'empty_list_items' using errcode = '22023';
      end if;
      if jsonb_array_length(v_items) > 30 then
        raise exception 'too_many_list_items' using errcode = '22023';
      end if;
      for v_idx in 0 .. jsonb_array_length(v_items) - 1 loop
        if jsonb_typeof(v_items -> v_idx) <> 'string' then
          raise exception 'invalid_list_item_type' using errcode = '22023';
        end if;
        v_item := v_items ->> v_idx;
        if btrim(coalesce(v_item, '')) = '' then
          raise exception 'empty_list_item' using errcode = '22023';
        end if;
        if char_length(v_item) > 500 then
          raise exception 'too_long_list_item' using errcode = '22023';
        end if;
      end loop;
    end if;
  end loop;
end;
$$;

revoke all on function private.content_assert_reference_blocks_v3(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_assert_reference_blocks_v3(jsonb)
  to service_role;

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

  elsif p_template_key = 'reference_article_v1' and p_schema_version = 3 then
    perform private.content_assert_allowed_keys(v_payload, array[
      'icon_key', 'short_text', 'blocks',
      'cta_label', 'cta_route', 'cta_url'
    ]);
    perform private.content_require_text(v_payload, 'icon_key', 60);
    perform private.content_require_text(v_payload, 'short_text', 600);
    perform private.content_assert_reference_blocks_v3(v_payload);
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

revoke all on function private.validate_content_payload(text, integer, jsonb)
  from public, anon, authenticated;
grant execute on function private.validate_content_payload(text, integer, jsonb)
  to service_role;

-- ===========================================================================
-- 4. Admin JSON helpers — has_working_draft
-- ===========================================================================
create or replace function private.content_working_draft_to_json(
  p_draft public.content_item_working_drafts
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_draft.id,
    'content_item_id', p_draft.content_item_id,
    'base_canonical_row_version', p_draft.base_canonical_row_version,
    'title', p_draft.title,
    'payload', p_draft.payload,
    'priority', p_draft.priority,
    'starts_at', p_draft.starts_at,
    'ends_at', p_draft.ends_at,
    'is_hidden', p_draft.is_hidden,
    'audience_mode', p_draft.audience_mode,
    'audience_group_ids', to_jsonb(p_draft.audience_group_ids),
    'audience_user_ids', to_jsonb(p_draft.audience_user_ids),
    'placement', p_draft.placement,
    'sort_order', p_draft.sort_order,
    'reference_category_id', p_draft.reference_category_id,
    'draft_asset_ids', to_jsonb(p_draft.draft_asset_ids),
    'row_version', p_draft.row_version,
    'created_by', p_draft.created_by,
    'updated_by', p_draft.updated_by,
    'created_at', p_draft.created_at,
    'updated_at', p_draft.updated_at
  );
$$;

revoke all on function private.content_working_draft_to_json(public.content_item_working_drafts)
  from public, anon, authenticated;
grant execute on function private.content_working_draft_to_json(public.content_item_working_drafts)
  to service_role;

create or replace function private.vacancy_working_draft_to_json(
  p_draft public.vacancy_working_drafts
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_draft.id,
    'vacancy_id', p_draft.vacancy_id,
    'base_canonical_row_version', p_draft.base_canonical_row_version,
    'title', p_draft.title,
    'company_name', p_draft.company_name,
    'company', p_draft.company_name,
    'summary', p_draft.summary,
    'description', p_draft.description,
    'employment_type', p_draft.employment_type,
    'work_format', p_draft.work_format,
    'location', p_draft.location,
    'salary_text', p_draft.salary_text,
    'external_url', p_draft.external_url,
    'application_url', p_draft.external_url,
    'contacts', p_draft.contacts,
    'priority', p_draft.priority,
    'starts_at', p_draft.starts_at,
    'ends_at', p_draft.ends_at,
    'expires_at', p_draft.expires_at,
    'is_hidden', p_draft.is_hidden,
    'audience_mode', p_draft.audience_mode,
    'audience_group_ids', to_jsonb(p_draft.audience_group_ids),
    'audience_user_ids', to_jsonb(p_draft.audience_user_ids),
    'draft_asset_ids', to_jsonb(p_draft.draft_asset_ids),
    'row_version', p_draft.row_version,
    'created_by', p_draft.created_by,
    'updated_by', p_draft.updated_by,
    'created_at', p_draft.created_at,
    'updated_at', p_draft.updated_at
  );
$$;

revoke all on function private.vacancy_working_draft_to_json(public.vacancy_working_drafts)
  from public, anon, authenticated;
grant execute on function private.vacancy_working_draft_to_json(public.vacancy_working_drafts)
  to service_role;

create or replace function private.content_item_to_admin_json(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.content_items;
  v_has_draft boolean := false;
begin
  select * into v_row from public.content_items where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.content_item_working_drafts d
    where d.content_item_id = p_id
  ) into v_has_draft;

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
    'has_working_draft', v_has_draft,
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

-- ===========================================================================
-- 5. Draft asset cleanup helpers (queue only; never delete storage from SQL)
-- ===========================================================================
create or replace function private.content_referenced_asset_ids(p_item_id uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids uuid[] := '{}'::uuid[];
  v_payload jsonb;
  v_snap jsonb;
begin
  select payload into v_payload from public.content_items where id = p_item_id;
  if found then
    v_ids := v_ids || private.content_payload_asset_ids(v_payload);
  end if;

  for v_snap in
    select v.snapshot
    from public.content_item_versions v
    where v.content_item_id = p_item_id
  loop
    v_ids := v_ids || private.content_payload_asset_ids(
      coalesce(v_snap -> 'payload', '{}'::jsonb)
    );
  end loop;

  select coalesce(array_agg(distinct x), '{}'::uuid[])
    into v_ids
  from unnest(v_ids) as x
  where x is not null;

  return coalesce(v_ids, '{}'::uuid[]);
end;
$$;

revoke all on function private.content_referenced_asset_ids(uuid)
  from public, anon, authenticated;
grant execute on function private.content_referenced_asset_ids(uuid) to service_role;

create or replace function private.content_queue_orphan_draft_assets(
  p_item_id uuid,
  p_draft_asset_ids uuid[],
  p_title text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_keep uuid[];
  v_queued integer := 0;
  v_id uuid;
begin
  v_keep := private.content_referenced_asset_ids(p_item_id);

  foreach v_id in array coalesce(p_draft_asset_ids, '{}'::uuid[]) loop
    if v_id is null or v_id = any (v_keep) then
      continue;
    end if;
    if not exists (
      select 1 from public.content_assets a
      where a.id = v_id and a.content_item_id = p_item_id
    ) then
      continue;
    end if;

    insert into public.content_media_cleanup_queue (
      storage_bucket, storage_path, source_content_item_id, source_title
    )
    select a.storage_bucket, a.storage_path, p_item_id, left(coalesce(p_title, ''), 200)
    from public.content_assets a
    where a.id = v_id
    on conflict do nothing;

    -- Remove DB row after queueing; storage object cleaned by worker.
    perform set_config('app.content_cascade_delete', 'on', true);
    delete from public.content_assets where id = v_id;
    perform set_config('app.content_cascade_delete', 'off', true);
    v_queued := v_queued + 1;
  end loop;

  return v_queued;
end;
$$;

revoke all on function private.content_queue_orphan_draft_assets(uuid, uuid[], text)
  from public, anon, authenticated;
grant execute on function private.content_queue_orphan_draft_assets(uuid, uuid[], text)
  to service_role;

create or replace function private.vacancy_queue_orphan_draft_assets(
  p_vacancy_id uuid,
  p_draft_asset_ids uuid[],
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
  -- Vacancy assets are not embedded in payload JSON the same way; treat
  -- draft_asset_ids as the sole orphan candidates for this discard path.
  foreach v_id in array coalesce(p_draft_asset_ids, '{}'::uuid[]) loop
    if v_id is null then
      continue;
    end if;
    if not exists (
      select 1 from public.vacancy_assets a
      where a.id = v_id and a.vacancy_id = p_vacancy_id
    ) then
      continue;
    end if;

    insert into public.vacancy_media_cleanup_queue (
      storage_bucket, storage_path, source_vacancy_id, source_title
    )
    select a.storage_bucket, a.storage_path, p_vacancy_id, left(coalesce(p_title, ''), 200)
    from public.vacancy_assets a
    where a.id = v_id
    on conflict do nothing;

    delete from public.vacancy_assets where id = v_id;
    v_queued := v_queued + 1;
  end loop;

  return v_queued;
end;
$$;

revoke all on function private.vacancy_queue_orphan_draft_assets(uuid, uuid[], text)
  from public, anon, authenticated;
grant execute on function private.vacancy_queue_orphan_draft_assets(uuid, uuid[], text)
  to service_role;

create or replace function private.content_assert_no_working_draft(p_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.content_item_working_drafts d
    where d.content_item_id = p_id
  ) then
    raise exception 'working_draft_exists' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on function private.content_assert_no_working_draft(uuid)
  from public, anon, authenticated;
grant execute on function private.content_assert_no_working_draft(uuid)
  to service_role;

create or replace function private.vacancy_assert_no_working_draft(p_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.vacancy_working_drafts d
    where d.vacancy_id = p_id
  ) then
    raise exception 'working_draft_exists' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on function private.vacancy_assert_no_working_draft(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_assert_no_working_draft(uuid)
  to service_role;

-- ===========================================================================
-- 6. Content working-draft RPCs
-- ===========================================================================
create or replace function public.admin_begin_content_edit(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
  v_draft public.content_item_working_drafts;
  v_place text;
  v_sort integer := 0;
  v_cat uuid;
  v_groups uuid[] := '{}'::uuid[];
  v_users uuid[] := '{}'::uuid[];
  v_base jsonb;
begin
  v_uid := private.require_admin_permission('content.write');

  if p_id is null then
    raise exception 'invalid_id' using errcode = '22023';
  end if;

  select * into v_row from public.content_items where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.content_item_working_drafts d
  where d.content_item_id = p_id;

  if found then
    -- Never overwrite an existing working draft from production.
    if v_row.template_key = 'reference_article_v1' then
      v_base := private.reference_article_admin_json(p_id);
    else
      v_base := private.content_item_to_admin_json(p_id);
    end if;
    return v_base || jsonb_build_object(
      'has_working_draft', true,
      'working_draft', private.content_working_draft_to_json(v_draft)
    );
  end if;

  select p.placement, p.sort_order
    into v_place, v_sort
  from public.content_item_placements p
  where p.content_item_id = p_id
  order by p.sort_order, p.placement
  limit 1;

  select c.reference_category_id into v_cat
  from public.content_item_reference_categories c
  where c.content_item_id = p_id;

  select coalesce(array_agg(g.group_id order by g.group_id), '{}'::uuid[])
    into v_groups
  from public.content_item_audience_groups g
  where g.content_item_id = p_id;

  select coalesce(array_agg(u.user_id order by u.user_id), '{}'::uuid[])
    into v_users
  from public.content_item_audience_users u
  where u.content_item_id = p_id;

  insert into public.content_item_working_drafts (
    content_item_id,
    base_canonical_row_version,
    title,
    payload,
    priority,
    starts_at,
    ends_at,
    is_hidden,
    audience_mode,
    audience_group_ids,
    audience_user_ids,
    placement,
    sort_order,
    reference_category_id,
    draft_asset_ids,
    row_version,
    created_by,
    updated_by
  ) values (
    p_id,
    v_row.row_version,
    v_row.title,
    v_row.payload,
    v_row.priority,
    v_row.starts_at,
    v_row.ends_at,
    v_row.is_hidden,
    v_row.audience_mode,
    coalesce(v_groups, '{}'::uuid[]),
    coalesce(v_users, '{}'::uuid[]),
    v_place,
    coalesce(v_sort, 0),
    v_cat,
    '{}'::uuid[],
    1,
    v_uid,
    v_uid
  )
  returning * into v_draft;

  perform private.content_write_domain_audit(
    'content.begin_edit',
    'content_item',
    p_id,
    jsonb_build_object(
      'working_draft_id', v_draft.id,
      'base_canonical_row_version', v_draft.base_canonical_row_version
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    v_base := private.reference_article_admin_json(p_id);
  else
    v_base := private.content_item_to_admin_json(p_id);
  end if;

  return v_base || jsonb_build_object(
    'has_working_draft', true,
    'working_draft', private.content_working_draft_to_json(v_draft)
  );
end;
$$;

revoke all on function public.admin_begin_content_edit(uuid) from public, anon;
grant execute on function public.admin_begin_content_edit(uuid)
  to authenticated, service_role;

create or replace function public.admin_save_content_working_draft(
  p_id uuid,
  p_expected_draft_row_version integer,
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
  v_draft public.content_item_working_drafts;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_mode text;
  v_place text;
  v_cat uuid;
  v_groups uuid[];
  v_users uuid[];
  v_assets uuid[];
  v_base jsonb;
begin
  v_uid := private.require_admin_permission('content.write');

  if jsonb_typeof(v_patch) <> 'object' then
    raise exception 'invalid_patch' using errcode = '22023';
  end if;
  if p_expected_draft_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;

  perform private.content_assert_allowed_keys(v_patch, array[
    'title', 'payload', 'priority', 'starts_at', 'ends_at', 'is_hidden',
    'audience_mode', 'audience_group_ids', 'audience_user_ids',
    'placement', 'sort_order', 'reference_category_id', 'draft_asset_ids'
  ]);

  select * into v_row from public.content_items where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.content_item_working_drafts d
  where d.content_item_id = p_id
  for update;
  if not found then
    raise exception 'working_draft_not_found' using errcode = 'P0002';
  end if;
  if v_draft.row_version <> p_expected_draft_row_version then
    raise exception 'row_version_conflict' using errcode = 'P0001';
  end if;

  if v_patch ? 'payload' then
    if jsonb_typeof(v_patch -> 'payload') <> 'object' then
      raise exception 'invalid_payload_not_object' using errcode = '22023';
    end if;
    perform private.validate_content_payload(
      v_row.template_key, v_row.schema_version, v_patch -> 'payload'
    );
  end if;

  if v_patch ? 'audience_mode' then
    v_mode := nullif(btrim(coalesce(v_patch ->> 'audience_mode', '')), '');
    if v_mode is null
       or v_mode not in ('all', 'groups', 'users', 'groups_and_users') then
      raise exception 'invalid_audience_mode' using errcode = '22023';
    end if;
  end if;

  if v_patch ? 'placement' then
    v_place := nullif(btrim(coalesce(v_patch ->> 'placement', '')), '');
    if v_place is not null
       and v_place not in ('home_promo', 'profile_feed', 'reference') then
      raise exception 'invalid_placement' using errcode = '22023';
    end if;
  end if;

  if v_patch ? 'reference_category_id' then
    v_cat := nullif(v_patch ->> 'reference_category_id', '')::uuid;
    if v_cat is not null
       and not exists (select 1 from public.reference_categories c where c.id = v_cat) then
      raise exception 'reference_category_missing' using errcode = 'P0002';
    end if;
  end if;

  if v_patch ? 'audience_group_ids' then
    if jsonb_typeof(v_patch -> 'audience_group_ids') <> 'array' then
      raise exception 'invalid_audience_group_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_groups
    from jsonb_array_elements_text(v_patch -> 'audience_group_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  if v_patch ? 'audience_user_ids' then
    if jsonb_typeof(v_patch -> 'audience_user_ids') <> 'array' then
      raise exception 'invalid_audience_user_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_users
    from jsonb_array_elements_text(v_patch -> 'audience_user_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  if v_patch ? 'draft_asset_ids' then
    if jsonb_typeof(v_patch -> 'draft_asset_ids') <> 'array' then
      raise exception 'invalid_draft_asset_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_assets
    from jsonb_array_elements_text(v_patch -> 'draft_asset_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  update public.content_item_working_drafts d set
    title = case
      when v_patch ? 'title' then left(coalesce(v_patch ->> 'title', ''), 200)
      else d.title
    end,
    payload = case when v_patch ? 'payload' then v_patch -> 'payload' else d.payload end,
    priority = case
      when v_patch ? 'priority' then coalesce((v_patch ->> 'priority')::integer, 0)
      else d.priority
    end,
    starts_at = case
      when v_patch ? 'starts_at' then nullif(v_patch ->> 'starts_at', '')::timestamptz
      else d.starts_at
    end,
    ends_at = case
      when v_patch ? 'ends_at' then nullif(v_patch ->> 'ends_at', '')::timestamptz
      else d.ends_at
    end,
    is_hidden = case
      when v_patch ? 'is_hidden' then coalesce((v_patch ->> 'is_hidden')::boolean, false)
      else d.is_hidden
    end,
    audience_mode = case when v_patch ? 'audience_mode' then v_mode else d.audience_mode end,
    audience_group_ids = case
      when v_patch ? 'audience_group_ids' then coalesce(v_groups, '{}'::uuid[])
      else d.audience_group_ids
    end,
    audience_user_ids = case
      when v_patch ? 'audience_user_ids' then coalesce(v_users, '{}'::uuid[])
      else d.audience_user_ids
    end,
    placement = case when v_patch ? 'placement' then v_place else d.placement end,
    sort_order = case
      when v_patch ? 'sort_order' then coalesce((v_patch ->> 'sort_order')::integer, 0)
      else d.sort_order
    end,
    reference_category_id = case
      when v_patch ? 'reference_category_id' then v_cat
      else d.reference_category_id
    end,
    draft_asset_ids = case
      when v_patch ? 'draft_asset_ids' then (
        select coalesce(array_agg(distinct x), '{}'::uuid[])
        from unnest(d.draft_asset_ids || coalesce(v_assets, '{}'::uuid[])) as x
        where x is not null
      )
      else d.draft_asset_ids
    end,
    row_version = d.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where d.content_item_id = p_id
  returning * into v_draft;

  perform private.content_write_domain_audit(
    'content.save_working_draft',
    'content_item',
    p_id,
    jsonb_build_object(
      'draft_row_version', v_draft.row_version,
      'patched_keys', (
        select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
        from jsonb_object_keys(v_patch) as k
      )
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    v_base := private.reference_article_admin_json(p_id);
  else
    v_base := private.content_item_to_admin_json(p_id);
  end if;

  return v_base || jsonb_build_object(
    'has_working_draft', true,
    'working_draft', private.content_working_draft_to_json(v_draft)
  );
end;
$$;

revoke all on function public.admin_save_content_working_draft(uuid, integer, jsonb)
  from public, anon;
grant execute on function public.admin_save_content_working_draft(uuid, integer, jsonb)
  to authenticated, service_role;

create or replace function public.admin_publish_content_working_draft(
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
  v_row public.content_items;
  v_draft public.content_item_working_drafts;
  v_allowed text[];
  v_queued integer := 0;
begin
  v_uid := private.require_admin_permission('content.publish');

  if p_expected_draft_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;

  select * into v_row from public.content_items where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.content_item_working_drafts d
  where d.content_item_id = p_id
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

  perform private.validate_content_payload(
    v_row.template_key, v_row.schema_version, v_draft.payload
  );

  if v_draft.placement is not null then
    select t.allowed_placements into v_allowed
    from public.content_templates t
    where t.key = v_row.template_key
      and t.schema_version = v_row.schema_version;
    if not (v_draft.placement = any (coalesce(v_allowed, '{}'::text[]))) then
      raise exception 'placement_not_allowed_for_template' using errcode = '22023';
    end if;
  end if;

  update public.content_items c set
    title = v_draft.title,
    payload = v_draft.payload,
    priority = v_draft.priority,
    starts_at = v_draft.starts_at,
    ends_at = v_draft.ends_at,
    is_hidden = v_draft.is_hidden,
    audience_mode = v_draft.audience_mode,
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  if v_draft.placement is not null then
    delete from public.content_item_placements where content_item_id = p_id;
    insert into public.content_item_placements (content_item_id, placement, sort_order)
    values (p_id, v_draft.placement, v_draft.sort_order);
  end if;

  delete from public.content_item_audience_groups where content_item_id = p_id;
  insert into public.content_item_audience_groups (content_item_id, group_id)
  select p_id, g
  from unnest(coalesce(v_draft.audience_group_ids, '{}'::uuid[])) as g
  where exists (select 1 from public.groups gr where gr.id = g);

  delete from public.content_item_audience_users where content_item_id = p_id;
  insert into public.content_item_audience_users (content_item_id, user_id)
  select p_id, u
  from unnest(coalesce(v_draft.audience_user_ids, '{}'::uuid[])) as u
  where exists (select 1 from public.users us where us.id = u);

  if v_row.template_key = 'reference_article_v1' then
    if v_draft.reference_category_id is null then
      raise exception 'reference_category_required' using errcode = 'P0001';
    end if;
    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (p_id, v_draft.reference_category_id)
    on conflict (content_item_id) do update
      set reference_category_id = excluded.reference_category_id;
  elsif v_draft.reference_category_id is not null then
    insert into public.content_item_reference_categories (
      content_item_id, reference_category_id
    ) values (p_id, v_draft.reference_category_id)
    on conflict (content_item_id) do update
      set reference_category_id = excluded.reference_category_id;
  end if;

  perform private.content_assert_payload_assets(p_id);
  perform private.content_assert_audience_consistent(p_id);
  perform private.reference_assert_publishable(p_id);

  perform private.content_snapshot_version(p_id);

  -- Orphan draft-only assets not referenced by canonical/versions after publish.
  v_queued := private.content_queue_orphan_draft_assets(
    p_id, v_draft.draft_asset_ids, v_draft.title
  );

  delete from public.content_item_working_drafts where content_item_id = p_id;

  -- Intentionally NO notification / outbox side effects.
  perform private.content_write_domain_audit(
    'content.publish_working_draft',
    'content_item',
    p_id,
    jsonb_build_object(
      'row_version', v_row.row_version,
      'version_number', v_row.version_number,
      'queued_orphan_assets', v_queued
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    return private.reference_article_admin_json(p_id);
  end if;
  return private.content_item_to_admin_json(p_id);
end;
$$;

revoke all on function public.admin_publish_content_working_draft(uuid, integer)
  from public, anon;
grant execute on function public.admin_publish_content_working_draft(uuid, integer)
  to authenticated, service_role;

create or replace function public.admin_discard_content_working_draft(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
  v_draft public.content_item_working_drafts;
  v_queued integer := 0;
  v_base jsonb;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_row from public.content_items where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.content_item_working_drafts d
  where d.content_item_id = p_id
  for update;
  if not found then
    raise exception 'working_draft_not_found' using errcode = 'P0002';
  end if;

  v_queued := private.content_queue_orphan_draft_assets(
    p_id, v_draft.draft_asset_ids, v_draft.title
  );

  delete from public.content_item_working_drafts where content_item_id = p_id;

  perform private.content_write_domain_audit(
    'content.discard_working_draft',
    'content_item',
    p_id,
    jsonb_build_object(
      'working_draft_id', v_draft.id,
      'queued_orphan_assets', v_queued
    )
  );

  if v_row.template_key = 'reference_article_v1' then
    v_base := private.reference_article_admin_json(p_id);
  else
    v_base := private.content_item_to_admin_json(p_id);
  end if;

  return v_base || jsonb_build_object(
    'has_working_draft', false,
    'discarded', true,
    'queued_orphan_assets', v_queued
  );
end;
$$;

revoke all on function public.admin_discard_content_working_draft(uuid)
  from public, anon;
grant execute on function public.admin_discard_content_working_draft(uuid)
  to authenticated, service_role;

-- ===========================================================================
-- 7. Vacancy working-draft RPCs
-- ===========================================================================
create or replace function public.admin_begin_vacancy_edit(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_draft public.vacancy_working_drafts;
  v_groups uuid[] := '{}'::uuid[];
  v_users uuid[] := '{}'::uuid[];
  v_base jsonb;
begin
  v_uid := private.require_admin_permission('content.write');

  if p_id is null then
    raise exception 'invalid_id' using errcode = '22023';
  end if;

  select * into v_row from public.vacancies where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.vacancy_working_drafts d
  where d.vacancy_id = p_id;

  if found then
    v_base := private.vacancy_to_admin_json(p_id);
    return v_base || jsonb_build_object(
      'has_working_draft', true,
      'working_draft', private.vacancy_working_draft_to_json(v_draft)
    );
  end if;

  select coalesce(array_agg(g.group_id order by g.group_id), '{}'::uuid[])
    into v_groups
  from public.vacancy_audience_groups g
  where g.vacancy_id = p_id;

  select coalesce(array_agg(u.user_id order by u.user_id), '{}'::uuid[])
    into v_users
  from public.vacancy_audience_users u
  where u.vacancy_id = p_id;

  insert into public.vacancy_working_drafts (
    vacancy_id,
    base_canonical_row_version,
    title,
    company_name,
    summary,
    description,
    employment_type,
    work_format,
    location,
    salary_text,
    external_url,
    contacts,
    priority,
    starts_at,
    ends_at,
    expires_at,
    is_hidden,
    audience_mode,
    audience_group_ids,
    audience_user_ids,
    draft_asset_ids,
    row_version,
    created_by,
    updated_by
  ) values (
    p_id,
    v_row.row_version,
    v_row.title,
    v_row.company_name,
    v_row.summary,
    v_row.description,
    v_row.employment_type,
    v_row.work_format,
    v_row.location,
    v_row.salary_text,
    v_row.external_url,
    v_row.contacts,
    v_row.priority,
    v_row.starts_at,
    v_row.ends_at,
    v_row.expires_at,
    v_row.is_hidden,
    v_row.audience_mode,
    coalesce(v_groups, '{}'::uuid[]),
    coalesce(v_users, '{}'::uuid[]),
    '{}'::uuid[],
    1,
    v_uid,
    v_uid
  )
  returning * into v_draft;

  perform private.content_write_domain_audit(
    'vacancy.begin_edit',
    'vacancy',
    p_id,
    jsonb_build_object(
      'working_draft_id', v_draft.id,
      'base_canonical_row_version', v_draft.base_canonical_row_version
    )
  );

  v_base := private.vacancy_to_admin_json(p_id);
  return v_base || jsonb_build_object(
    'has_working_draft', true,
    'working_draft', private.vacancy_working_draft_to_json(v_draft)
  );
end;
$$;

revoke all on function public.admin_begin_vacancy_edit(uuid) from public, anon;
grant execute on function public.admin_begin_vacancy_edit(uuid)
  to authenticated, service_role;

create or replace function public.admin_save_vacancy_working_draft(
  p_id uuid,
  p_expected_draft_row_version integer,
  p_patch jsonb
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
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_mode text;
  v_groups uuid[];
  v_users uuid[];
  v_assets uuid[];
  v_contacts jsonb;
  v_base jsonb;
begin
  v_uid := private.require_admin_permission('content.write');

  if jsonb_typeof(v_patch) <> 'object' then
    raise exception 'invalid_patch' using errcode = '22023';
  end if;
  if p_expected_draft_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;

  -- Aliases: company → company_name, application_url → external_url
  if v_patch ? 'company' and not (v_patch ? 'company_name') then
    v_patch := v_patch || jsonb_build_object('company_name', v_patch -> 'company');
  end if;
  if v_patch ? 'application_url' and not (v_patch ? 'external_url') then
    v_patch := v_patch || jsonb_build_object('external_url', v_patch -> 'application_url');
  end if;
  v_patch := v_patch - 'company' - 'application_url' - 'requirements';

  perform private.content_assert_allowed_keys(v_patch, array[
    'title', 'company_name', 'summary', 'description', 'employment_type',
    'work_format', 'location', 'salary_text', 'external_url', 'contacts',
    'priority', 'starts_at', 'ends_at', 'expires_at', 'is_hidden',
    'audience_mode', 'audience_group_ids', 'audience_user_ids', 'draft_asset_ids'
  ]);

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

  if v_patch ? 'audience_mode' then
    v_mode := nullif(btrim(coalesce(v_patch ->> 'audience_mode', '')), '');
    if v_mode is null
       or v_mode not in ('all', 'groups', 'users', 'groups_and_users') then
      raise exception 'invalid_audience_mode' using errcode = '22023';
    end if;
  end if;

  if v_patch ? 'contacts' then
    v_contacts := private.vacancy_assert_contacts(
      coalesce(v_patch -> 'contacts', '{}'::jsonb)
    );
  end if;

  if v_patch ? 'audience_group_ids' then
    if jsonb_typeof(v_patch -> 'audience_group_ids') <> 'array' then
      raise exception 'invalid_audience_group_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_groups
    from jsonb_array_elements_text(v_patch -> 'audience_group_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  if v_patch ? 'audience_user_ids' then
    if jsonb_typeof(v_patch -> 'audience_user_ids') <> 'array' then
      raise exception 'invalid_audience_user_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_users
    from jsonb_array_elements_text(v_patch -> 'audience_user_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  if v_patch ? 'draft_asset_ids' then
    if jsonb_typeof(v_patch -> 'draft_asset_ids') <> 'array' then
      raise exception 'invalid_draft_asset_ids' using errcode = '22023';
    end if;
    select coalesce(array_agg(distinct x::uuid), '{}'::uuid[]) into v_assets
    from jsonb_array_elements_text(v_patch -> 'draft_asset_ids') as t(x)
    where nullif(btrim(x), '') is not null;
  end if;

  update public.vacancy_working_drafts d set
    title = case
      when v_patch ? 'title' then btrim(coalesce(v_patch ->> 'title', ''))
      else d.title
    end,
    company_name = case
      when v_patch ? 'company_name' then coalesce(v_patch ->> 'company_name', '')
      else d.company_name
    end,
    summary = case
      when v_patch ? 'summary' then coalesce(v_patch ->> 'summary', '')
      else d.summary
    end,
    description = case
      when v_patch ? 'description' then coalesce(v_patch ->> 'description', '')
      else d.description
    end,
    employment_type = case
      when v_patch ? 'employment_type'
        then nullif(btrim(coalesce(v_patch ->> 'employment_type', '')), '')
      else d.employment_type
    end,
    work_format = case
      when v_patch ? 'work_format'
        then nullif(btrim(coalesce(v_patch ->> 'work_format', '')), '')
      else d.work_format
    end,
    location = case
      when v_patch ? 'location'
        then nullif(btrim(coalesce(v_patch ->> 'location', '')), '')
      else d.location
    end,
    salary_text = case
      when v_patch ? 'salary_text'
        then nullif(btrim(coalesce(v_patch ->> 'salary_text', '')), '')
      else d.salary_text
    end,
    external_url = case
      when v_patch ? 'external_url'
        then nullif(btrim(coalesce(v_patch ->> 'external_url', '')), '')
      else d.external_url
    end,
    contacts = case when v_patch ? 'contacts' then v_contacts else d.contacts end,
    priority = case
      when v_patch ? 'priority' then coalesce((v_patch ->> 'priority')::integer, 0)
      else d.priority
    end,
    starts_at = case
      when v_patch ? 'starts_at' then nullif(v_patch ->> 'starts_at', '')::timestamptz
      else d.starts_at
    end,
    ends_at = case
      when v_patch ? 'ends_at' then nullif(v_patch ->> 'ends_at', '')::timestamptz
      else d.ends_at
    end,
    expires_at = case
      when v_patch ? 'expires_at' then nullif(v_patch ->> 'expires_at', '')::timestamptz
      else d.expires_at
    end,
    is_hidden = case
      when v_patch ? 'is_hidden' then coalesce((v_patch ->> 'is_hidden')::boolean, false)
      else d.is_hidden
    end,
    audience_mode = case when v_patch ? 'audience_mode' then v_mode else d.audience_mode end,
    audience_group_ids = case
      when v_patch ? 'audience_group_ids' then coalesce(v_groups, '{}'::uuid[])
      else d.audience_group_ids
    end,
    audience_user_ids = case
      when v_patch ? 'audience_user_ids' then coalesce(v_users, '{}'::uuid[])
      else d.audience_user_ids
    end,
    draft_asset_ids = case
      when v_patch ? 'draft_asset_ids' then (
        select coalesce(array_agg(distinct x), '{}'::uuid[])
        from unnest(d.draft_asset_ids || coalesce(v_assets, '{}'::uuid[])) as x
        where x is not null
      )
      else d.draft_asset_ids
    end,
    row_version = d.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where d.vacancy_id = p_id
  returning * into v_draft;

  perform private.content_write_domain_audit(
    'vacancy.save_working_draft',
    'vacancy',
    p_id,
    jsonb_build_object(
      'draft_row_version', v_draft.row_version,
      'patched_keys', (
        select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
        from jsonb_object_keys(v_patch) as k
      )
    )
  );

  v_base := private.vacancy_to_admin_json(p_id);
  return v_base || jsonb_build_object(
    'has_working_draft', true,
    'working_draft', private.vacancy_working_draft_to_json(v_draft)
  );
end;
$$;

revoke all on function public.admin_save_vacancy_working_draft(uuid, integer, jsonb)
  from public, anon;
grant execute on function public.admin_save_vacancy_working_draft(uuid, integer, jsonb)
  to authenticated, service_role;

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
  v_queued integer := 0;
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

  v_queued := private.vacancy_queue_orphan_draft_assets(
    p_id, v_draft.draft_asset_ids, v_draft.title
  );

  delete from public.vacancy_working_drafts where vacancy_id = p_id;

  -- Intentionally NO notification / outbox side effects.
  perform private.content_write_domain_audit(
    'vacancy.publish_working_draft',
    'vacancy',
    p_id,
    jsonb_build_object(
      'row_version', v_row.row_version,
      'version_number', v_row.version_number,
      'queued_orphan_assets', v_queued
    )
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

revoke all on function public.admin_publish_vacancy_working_draft(uuid, integer)
  from public, anon;
grant execute on function public.admin_publish_vacancy_working_draft(uuid, integer)
  to authenticated, service_role;

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

  v_queued := private.vacancy_queue_orphan_draft_assets(
    p_id, v_draft.draft_asset_ids, v_draft.title
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

-- ===========================================================================
-- 8. Lifecycle guards — working_draft_exists
-- ===========================================================================
create or replace function public.admin_unpublish_content(
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
  perform private.content_assert_no_working_draft(p_id);
  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
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
    'content.unpublish',
    'content_item',
    p_id,
    jsonb_build_object(
      'status', v_row.status,
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
  perform private.content_assert_no_working_draft(p_id);
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
  perform private.content_assert_no_working_draft(p_id);
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
  perform private.content_assert_no_working_draft(p_id);
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
  perform private.content_assert_no_working_draft(p_id);
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

create or replace function public.admin_set_vacancy_lifecycle(
  p_id uuid,
  p_action text,
  p_expected_row_version integer,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_action text := nullif(btrim(coalesce(p_action, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_from text;
  v_to text;
begin
  v_uid := private.require_admin_permission('content.publish');

  if v_action is null or v_action not in ('unpublish', 'expire', 'archive') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;

  -- Block lifecycle transitions that conflict with an open working draft.
  if v_action in ('unpublish', 'archive') then
    perform private.vacancy_assert_no_working_draft(p_id);
  end if;

  v_row := private.vacancy_lock(p_id, p_expected_row_version);
  v_from := v_row.status;

  v_to := case v_action
    when 'unpublish' then 'approved'
    when 'expire' then 'expired'
    else 'archived'
  end;

  perform private.vacancy_assert_transition(v_from, v_to);

  update public.vacancies v set
    status = v_to,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(
    p_id, v_action, v_from, v_to, coalesce(v_reason, '')
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

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
  perform private.vacancy_assert_no_working_draft(p_id);
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

-- Grants for lifecycle RPCs that may already exist (idempotent re-grant)
revoke all on function public.admin_unpublish_content(uuid, integer)
  from public, anon;
grant execute on function public.admin_unpublish_content(uuid, integer)
  to authenticated, service_role;

revoke all on function public.admin_archive_content(uuid, integer)
  from public, anon;
grant execute on function public.admin_archive_content(uuid, integer)
  to authenticated, service_role;

revoke all on function public.admin_restore_content_version(uuid, integer, integer)
  from public, anon;
grant execute on function public.admin_restore_content_version(uuid, integer, integer)
  to authenticated, service_role;

revoke all on function public.admin_set_vacancy_lifecycle(uuid, text, integer, text)
  from public, anon;
grant execute on function public.admin_set_vacancy_lifecycle(uuid, text, integer, text)
  to authenticated, service_role;

commit;
