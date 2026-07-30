-- Stage 14A: managed content foundation (SPEC section 2).
--
-- Templates + content items + placements + audience junctions + assets +
-- versions + dismissals + events + domain audit, plus SECURITY DEFINER RPCs.
-- Clients never get table DML: every read/write goes through RBAC-gated RPCs
-- (content.read / content.write / content.publish).
--
-- Local only. Not applied to remote in this session.

begin;

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Tables (SPEC 2.3)
-- ---------------------------------------------------------------------------
create table if not exists public.content_templates (
  key text not null,
  schema_version integer not null,
  title text not null,
  allowed_placements text[] not null,
  schema_doc jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  primary key (key, schema_version),
  constraint content_templates_key_chk check (btrim(key) <> ''),
  constraint content_templates_schema_version_chk check (schema_version >= 1),
  constraint content_templates_placements_chk check (
    array_length(allowed_placements, 1) >= 1
    and allowed_placements <@ array['home_promo', 'profile_feed', 'reference']::text[]
  )
);

comment on table public.content_templates is
  'Approved content templates. (key, schema_version) is immutable once referenced; evolution = new schema_version. schema_doc is Admin documentation only, never a runtime schema engine.';

create table if not exists public.content_items (
  id uuid primary key default gen_random_uuid(),
  template_key text not null,
  schema_version integer not null,
  status text not null default 'draft'
    check (status in ('draft', 'published', 'archived')),
  origin text not null default 'admin'
    check (origin in ('demo', 'admin', 'import', 'user_submission')),
  title text not null default '',
  payload jsonb not null default '{}'::jsonb,
  priority integer not null default 0,
  starts_at timestamptz null,
  ends_at timestamptz null,
  is_hidden boolean not null default false,
  audience_mode text not null default 'all'
    check (audience_mode in ('all', 'groups', 'users', 'groups_and_users')),
  version_number integer not null default 1,
  row_version integer not null default 1,
  created_by uuid null references public.users (id) on delete set null,
  updated_by uuid null references public.users (id) on delete set null,
  published_by uuid null references public.users (id) on delete set null,
  published_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint content_items_template_fk foreign key (template_key, schema_version)
    references public.content_templates (key, schema_version),
  constraint content_items_schedule_chk check (
    ends_at is null or starts_at is null or ends_at > starts_at
  )
);

comment on table public.content_items is
  'Managed content items. Ordering never lives here: sort_order belongs to content_item_placements. row_version is the optimistic-concurrency token.';

create index if not exists content_items_status_idx
  on public.content_items (status, priority desc, published_at desc nulls last);
create index if not exists content_items_template_idx
  on public.content_items (template_key, schema_version);
create index if not exists content_items_origin_idx
  on public.content_items (origin);
create index if not exists content_items_schedule_idx
  on public.content_items (starts_at, ends_at)
  where status = 'published';

create table if not exists public.content_item_versions (
  id uuid primary key default gen_random_uuid(),
  content_item_id uuid not null references public.content_items (id) on delete cascade,
  version_number integer not null,
  snapshot jsonb not null,
  created_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint content_item_versions_unique unique (content_item_id, version_number)
);

create index if not exists content_item_versions_item_idx
  on public.content_item_versions (content_item_id, version_number desc);

create table if not exists public.content_item_placements (
  content_item_id uuid not null references public.content_items (id) on delete cascade,
  placement text not null
    check (placement in ('home_promo', 'profile_feed', 'reference')),
  sort_order integer not null default 0,
  primary key (content_item_id, placement)
);

comment on table public.content_item_placements is
  'Sole ordering source per placement. Mobile/admin lists sort by sort_order, then priority desc, then published_at desc.';

create index if not exists content_item_placements_order_idx
  on public.content_item_placements (placement, sort_order);

create table if not exists public.content_item_audience_groups (
  content_item_id uuid not null references public.content_items (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  primary key (content_item_id, group_id)
);

create index if not exists content_item_audience_groups_group_idx
  on public.content_item_audience_groups (group_id);

create table if not exists public.content_item_audience_users (
  content_item_id uuid not null references public.content_items (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  primary key (content_item_id, user_id)
);

create index if not exists content_item_audience_users_user_idx
  on public.content_item_audience_users (user_id);

create table if not exists public.content_assets (
  id uuid primary key default gen_random_uuid(),
  content_item_id uuid not null references public.content_items (id) on delete cascade,
  storage_bucket text not null,
  storage_path text not null,
  mime_type text not null,
  byte_size bigint not null check (byte_size >= 0),
  checksum text null,
  created_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint content_assets_object_unique unique (storage_bucket, storage_path)
);

comment on table public.content_assets is
  'Stage 14: assets belong to a content_item via FK only. No polymorphic owner_kind.';

create index if not exists content_assets_item_idx
  on public.content_assets (content_item_id);

create table if not exists public.content_media_cleanup_queue (
  id uuid primary key default gen_random_uuid(),
  storage_bucket text not null,
  storage_path text not null,
  source_content_item_id uuid null,
  source_title text null,
  enqueued_at timestamptz not null default now(),
  attempts integer not null default 0,
  last_error text null,
  processed_at timestamptz null
);

comment on table public.content_media_cleanup_queue is
  'Pending private content-media object cleanup after safe delete. Never store signed URLs or secrets.';

create unique index if not exists content_media_cleanup_queue_pending_uidx
  on public.content_media_cleanup_queue (storage_bucket, storage_path)
  where processed_at is null;

create index if not exists content_media_cleanup_queue_pending_idx
  on public.content_media_cleanup_queue (enqueued_at)
  where processed_at is null;

create table if not exists public.content_item_dismissals (
  content_item_id uuid not null references public.content_items (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  dismissed_at timestamptz not null default now(),
  can_reshow_after timestamptz null,
  primary key (content_item_id, user_id)
);

create index if not exists content_item_dismissals_user_idx
  on public.content_item_dismissals (user_id);

create table if not exists public.content_item_events (
  id uuid primary key default gen_random_uuid(),
  content_item_id uuid not null references public.content_items (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  event_type text not null check (event_type in ('impression', 'click')),
  event_hour timestamptz not null,
  created_at timestamptz not null default now(),
  constraint content_item_events_dedupe_unique
    unique (content_item_id, user_id, event_type, event_hour)
);

comment on table public.content_item_events is
  'Allowlisted impression/click events. event_hour is a UTC hour bucket written by record_content_event only. No device/location/free-text/CTA URL data.';

create index if not exists content_item_events_item_idx
  on public.content_item_events (content_item_id, event_type, event_hour desc);
create index if not exists content_item_events_created_idx
  on public.content_item_events (created_at);

create table if not exists public.content_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid null,
  action text not null,
  entity_type text not null,
  entity_id uuid null,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.content_audit_log is
  'Managed content domain audit. Store ids/status only, never PII dumps or CTA URLs.';

create index if not exists content_audit_log_entity_idx
  on public.content_audit_log (entity_type, entity_id, created_at desc);
create index if not exists content_audit_log_created_idx
  on public.content_audit_log (created_at desc);

-- ---------------------------------------------------------------------------
-- Lock down tables: RLS + FORCE RLS, no client DML, service_role only.
-- ---------------------------------------------------------------------------
alter table public.content_templates enable row level security;
alter table public.content_templates force row level security;
alter table public.content_items enable row level security;
alter table public.content_items force row level security;
alter table public.content_item_versions enable row level security;
alter table public.content_item_versions force row level security;
alter table public.content_item_placements enable row level security;
alter table public.content_item_placements force row level security;
alter table public.content_item_audience_groups enable row level security;
alter table public.content_item_audience_groups force row level security;
alter table public.content_item_audience_users enable row level security;
alter table public.content_item_audience_users force row level security;
alter table public.content_assets enable row level security;
alter table public.content_assets force row level security;
alter table public.content_media_cleanup_queue enable row level security;
alter table public.content_media_cleanup_queue force row level security;
alter table public.content_item_dismissals enable row level security;
alter table public.content_item_dismissals force row level security;
alter table public.content_item_events enable row level security;
alter table public.content_item_events force row level security;
alter table public.content_audit_log enable row level security;
alter table public.content_audit_log force row level security;

revoke all on table public.content_templates from public, anon, authenticated;
revoke all on table public.content_items from public, anon, authenticated;
revoke all on table public.content_item_versions from public, anon, authenticated;
revoke all on table public.content_item_placements from public, anon, authenticated;
revoke all on table public.content_item_audience_groups from public, anon, authenticated;
revoke all on table public.content_item_audience_users from public, anon, authenticated;
revoke all on table public.content_assets from public, anon, authenticated;
revoke all on table public.content_media_cleanup_queue from public, anon, authenticated;
revoke all on table public.content_item_dismissals from public, anon, authenticated;
revoke all on table public.content_item_events from public, anon, authenticated;
revoke all on table public.content_audit_log from public, anon, authenticated;

grant select, insert, update, delete on table public.content_templates to service_role;
grant select, insert, update, delete on table public.content_items to service_role;
grant select, insert, update, delete on table public.content_item_versions to service_role;
grant select, insert, update, delete on table public.content_item_placements to service_role;
grant select, insert, update, delete on table public.content_item_audience_groups to service_role;
grant select, insert, update, delete on table public.content_item_audience_users to service_role;
grant select, insert, update, delete on table public.content_assets to service_role;
grant select, insert, update, delete on table public.content_media_cleanup_queue to service_role;
grant select, insert, update, delete on table public.content_item_dismissals to service_role;
grant select, insert, update, delete on table public.content_item_events to service_role;
grant select, insert, update, delete on table public.content_audit_log to service_role;

-- ---------------------------------------------------------------------------
-- Template immutability guard (SPEC 2.3)
-- ---------------------------------------------------------------------------
create or replace function private.content_template_is_referenced(
  p_key text,
  p_schema_version integer
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.content_items ci
    where ci.template_key = p_key
      and ci.schema_version = p_schema_version
  )
  or exists (
    select 1
    from public.content_item_versions v
    where v.snapshot ->> 'template_key' = p_key
      and v.snapshot ->> 'schema_version' = p_schema_version::text
  );
$$;

revoke all on function private.content_template_is_referenced(text, integer)
  from public, anon, authenticated;
grant execute on function private.content_template_is_referenced(text, integer)
  to service_role;

create or replace function private.content_templates_guard_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if private.content_template_is_referenced(old.key, old.schema_version) then
      raise exception 'content_template_referenced' using errcode = '55000';
    end if;
    return old;
  end if;

  if new.key is distinct from old.key
     or new.schema_version is distinct from old.schema_version then
    raise exception 'content_template_identity_immutable' using errcode = '55000';
  end if;

  if private.content_template_is_referenced(old.key, old.schema_version)
     and (
       new.schema_doc is distinct from old.schema_doc
       or new.allowed_placements is distinct from old.allowed_placements
     ) then
    raise exception 'content_template_schema_immutable' using errcode = '55000';
  end if;

  return new;
end;
$$;

revoke all on function private.content_templates_guard_immutability()
  from public, anon, authenticated;

drop trigger if exists trg_content_templates_immutable on public.content_templates;
create trigger trg_content_templates_immutable
before update or delete on public.content_templates
for each row execute function private.content_templates_guard_immutability();

-- ---------------------------------------------------------------------------
-- Seed templates v1 (SPEC 2.8). schema_doc is Admin documentation only.
-- ---------------------------------------------------------------------------
insert into public.content_templates (key, schema_version, title, allowed_placements, schema_doc)
values
  (
    'home_promo_v1',
    1,
    'Промо на главной',
    array['home_promo']::text[],
    jsonb_build_object(
      'required', jsonb_build_array(
        'title', 'subtitle', 'icon_key', 'gradient_colors', 'cta_label', 'dismissible'
      ),
      'optional', jsonb_build_array(
        'image_asset_id', 'cta_route', 'cta_url', 'reshow_after_hours'
      ),
      'notes', 'gradient_colors: 2..4 hex #RRGGBB. CTA: at most one of cta_route (allowlisted internal prefix) or cta_url (https).'
    )
  ),
  (
    'profile_feed_card_v1',
    1,
    'Карточка ленты профиля',
    array['profile_feed']::text[],
    jsonb_build_object(
      'required', jsonb_build_array('title', 'subtitle', 'cta_label'),
      'optional', jsonb_build_array('image_asset_id', 'cta_route', 'cta_url'),
      'notes', 'CTA: at most one of cta_route (allowlisted internal prefix) or cta_url (https).'
    )
  ),
  (
    'reference_article_v1',
    1,
    'Материал справочника',
    array['reference']::text[],
    jsonb_build_object(
      'required', jsonb_build_array('category', 'icon_key', 'short_text', 'blocks'),
      'optional', jsonb_build_array('cta_label', 'cta_route', 'cta_url'),
      'notes', 'blocks[]: objects with type in text|image|file|link|cta only. No HTML/JS.'
    )
  )
on conflict (key, schema_version) do nothing;

-- ---------------------------------------------------------------------------
-- Payload validation primitives (fail-closed, no pg_jsonschema)
-- ---------------------------------------------------------------------------
create or replace function private.content_assert_allowed_keys(
  p_payload jsonb,
  p_allowed text[]
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_bad text;
begin
  select string_agg(t.key, ',' order by t.key)
  into v_bad
  from jsonb_object_keys(coalesce(p_payload, '{}'::jsonb)) as t(key)
  where not (t.key = any (p_allowed));

  if v_bad is not null then
    raise exception 'unknown_payload_keys: %', v_bad using errcode = '22023';
  end if;
end;
$$;

revoke all on function private.content_assert_allowed_keys(jsonb, text[])
  from public, anon, authenticated;
grant execute on function private.content_assert_allowed_keys(jsonb, text[])
  to service_role;

create or replace function private.content_require_text(
  p_payload jsonb,
  p_key text,
  p_max_len integer
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text;
begin
  if not (coalesce(p_payload, '{}'::jsonb) ? p_key) then
    raise exception 'missing_field_%', p_key using errcode = '22023';
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'string' then
    raise exception 'invalid_type_%', p_key using errcode = '22023';
  end if;
  v_value := p_payload ->> p_key;
  if btrim(v_value) = '' then
    raise exception 'empty_field_%', p_key using errcode = '22023';
  end if;
  if length(v_value) > p_max_len then
    raise exception 'too_long_%', p_key using errcode = '22023';
  end if;
  return v_value;
end;
$$;

revoke all on function private.content_require_text(jsonb, text, integer)
  from public, anon, authenticated;
grant execute on function private.content_require_text(jsonb, text, integer)
  to service_role;

create or replace function private.content_optional_text(
  p_payload jsonb,
  p_key text,
  p_max_len integer
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text;
begin
  if not (coalesce(p_payload, '{}'::jsonb) ? p_key)
     or jsonb_typeof(p_payload -> p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'string' then
    raise exception 'invalid_type_%', p_key using errcode = '22023';
  end if;
  v_value := p_payload ->> p_key;
  if length(v_value) > p_max_len then
    raise exception 'too_long_%', p_key using errcode = '22023';
  end if;
  return nullif(btrim(v_value), '');
end;
$$;

revoke all on function private.content_optional_text(jsonb, text, integer)
  from public, anon, authenticated;
grant execute on function private.content_optional_text(jsonb, text, integer)
  to service_role;

create or replace function private.content_require_bool(
  p_payload jsonb,
  p_key text
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if not (coalesce(p_payload, '{}'::jsonb) ? p_key) then
    raise exception 'missing_field_%', p_key using errcode = '22023';
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'boolean' then
    raise exception 'invalid_type_%', p_key using errcode = '22023';
  end if;
  return (p_payload ->> p_key)::boolean;
end;
$$;

revoke all on function private.content_require_bool(jsonb, text)
  from public, anon, authenticated;
grant execute on function private.content_require_bool(jsonb, text) to service_role;

create or replace function private.content_optional_int(
  p_payload jsonb,
  p_key text,
  p_min integer,
  p_max integer
)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value numeric;
begin
  if not (coalesce(p_payload, '{}'::jsonb) ? p_key)
     or jsonb_typeof(p_payload -> p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'number' then
    raise exception 'invalid_type_%', p_key using errcode = '22023';
  end if;
  v_value := (p_payload ->> p_key)::numeric;
  if v_value <> trunc(v_value) then
    raise exception 'invalid_integer_%', p_key using errcode = '22023';
  end if;
  if v_value < p_min or v_value > p_max then
    raise exception 'out_of_range_%', p_key using errcode = '22023';
  end if;
  return v_value::integer;
end;
$$;

revoke all on function private.content_optional_int(jsonb, text, integer, integer)
  from public, anon, authenticated;
grant execute on function private.content_optional_int(jsonb, text, integer, integer)
  to service_role;

create or replace function private.content_optional_uuid(
  p_payload jsonb,
  p_key text
)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text;
begin
  if not (coalesce(p_payload, '{}'::jsonb) ? p_key)
     or jsonb_typeof(p_payload -> p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'string' then
    raise exception 'invalid_type_%', p_key using errcode = '22023';
  end if;
  v_value := nullif(btrim(p_payload ->> p_key), '');
  if v_value is null then
    return null;
  end if;
  begin
    return v_value::uuid;
  exception when others then
    raise exception 'invalid_uuid_%', p_key using errcode = '22023';
  end;
end;
$$;

revoke all on function private.content_optional_uuid(jsonb, text)
  from public, anon, authenticated;
grant execute on function private.content_optional_uuid(jsonb, text) to service_role;

create or replace function private.content_assert_gradient(p_payload jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_colors jsonb;
  v_len integer;
  v_color jsonb;
begin
  if not (coalesce(p_payload, '{}'::jsonb) ? 'gradient_colors') then
    raise exception 'missing_field_gradient_colors' using errcode = '22023';
  end if;
  v_colors := p_payload -> 'gradient_colors';
  if jsonb_typeof(v_colors) <> 'array' then
    raise exception 'invalid_type_gradient_colors' using errcode = '22023';
  end if;
  v_len := jsonb_array_length(v_colors);
  if v_len < 2 or v_len > 4 then
    raise exception 'invalid_gradient_colors_count' using errcode = '22023';
  end if;
  for v_color in select value from jsonb_array_elements(v_colors) loop
    if jsonb_typeof(v_color) <> 'string'
       or (v_color #>> '{}') !~ '^#[0-9A-Fa-f]{6}$' then
      raise exception 'invalid_gradient_color' using errcode = '22023';
    end if;
  end loop;
end;
$$;

revoke all on function private.content_assert_gradient(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_assert_gradient(jsonb) to service_role;

-- CTA rules v1: at most one of internal allowlisted route or https URL.
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
    '/diary', '/info', '/profile', '/schedule', '/home', '/learning', '/chat'
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

create or replace function private.content_assert_reference_blocks(p_payload jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_blocks jsonb;
  v_block jsonb;
  v_type text;
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
    if v_type not in ('text', 'image', 'file', 'link', 'cta') then
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
    else
      perform private.content_assert_allowed_keys(
        v_block, array['type', 'label', 'route', 'url']
      );
      perform private.content_require_text(v_block, 'label', 120);
      perform private.content_assert_cta(
        private.content_optional_text(v_block, 'route', 300),
        private.content_optional_text(v_block, 'url', 500)
      );
    end if;
  end loop;
end;
$$;

revoke all on function private.content_assert_reference_blocks(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_assert_reference_blocks(jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- private.validate_content_payload (SPEC 2.7) — versioned PL/pgSQL per template
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

  else
    -- Fail closed: a template without a versioned validator cannot be used.
    raise exception 'no_validator_for_template' using errcode = '22023';
  end if;
end;
$$;

revoke all on function private.validate_content_payload(text, integer, jsonb)
  from public, anon, authenticated;
grant execute on function private.validate_content_payload(text, integer, jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- Asset invariants (SPEC 2.7 / 2.11)
-- ---------------------------------------------------------------------------
create or replace function private.content_payload_asset_ids(p_payload jsonb)
returns uuid[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct s.asset_id), '{}'::uuid[])
  from (
    select private.content_optional_uuid(coalesce(p_payload, '{}'::jsonb), 'image_asset_id') as asset_id
    union all
    select private.content_optional_uuid(b.value, 'asset_id')
    from jsonb_array_elements(
      case
        when jsonb_typeof(coalesce(p_payload, '{}'::jsonb) -> 'blocks') = 'array'
          then p_payload -> 'blocks'
        else '[]'::jsonb
      end
    ) as b(value)
    where jsonb_typeof(b.value) = 'object'
  ) s
  where s.asset_id is not null;
$$;

revoke all on function private.content_payload_asset_ids(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_payload_asset_ids(jsonb) to service_role;

create or replace function private.content_assert_payload_assets(p_item_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_item public.content_items;
  v_asset public.content_assets;
  v_id uuid;
  v_block jsonb;
begin
  select * into v_item from public.content_items where id = p_item_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  foreach v_id in array private.content_payload_asset_ids(v_item.payload) loop
    select * into v_asset from public.content_assets a where a.id = v_id;
    if not found then
      raise exception 'asset_not_found_%', v_id using errcode = 'P0001';
    end if;
    if v_asset.content_item_id is distinct from p_item_id then
      raise exception 'asset_foreign_owner_%', v_id using errcode = 'P0001';
    end if;
  end loop;

  -- Template MIME rules: image slots must hold images.
  v_id := private.content_optional_uuid(v_item.payload, 'image_asset_id');
  if v_id is not null then
    select * into v_asset from public.content_assets a where a.id = v_id;
    if v_asset.mime_type not like 'image/%' then
      raise exception 'asset_wrong_mime_%', v_id using errcode = 'P0001';
    end if;
  end if;

  if jsonb_typeof(v_item.payload -> 'blocks') = 'array' then
    for v_block in select value from jsonb_array_elements(v_item.payload -> 'blocks') loop
      v_id := private.content_optional_uuid(v_block, 'asset_id');
      if v_id is null then
        continue;
      end if;
      select * into v_asset from public.content_assets a where a.id = v_id;
      if v_block ->> 'type' = 'image' and v_asset.mime_type not like 'image/%' then
        raise exception 'asset_wrong_mime_%', v_id using errcode = 'P0001';
      end if;
      if v_block ->> 'type' = 'file'
         and v_asset.mime_type not in (
           'application/pdf', 'image/jpeg', 'image/png', 'image/webp'
         ) then
        raise exception 'asset_wrong_mime_%', v_id using errcode = 'P0001';
      end if;
    end loop;
  end if;
end;
$$;

revoke all on function private.content_assert_payload_assets(uuid)
  from public, anon, authenticated;
grant execute on function private.content_assert_payload_assets(uuid) to service_role;

-- Individual asset deletion is forbidden while the owning item still
-- references it. Whole-item safe delete sets the cascade guard first.
create or replace function private.content_assets_guard_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
begin
  if coalesce(current_setting('app.content_cascade_delete', true), '') = 'on' then
    return old;
  end if;

  select ci.payload into v_payload
  from public.content_items ci
  where ci.id = old.content_item_id;

  if not found then
    return old;
  end if;

  if old.id = any (private.content_payload_asset_ids(v_payload)) then
    raise exception 'asset_still_referenced' using errcode = '55000';
  end if;

  return old;
end;
$$;

revoke all on function private.content_assets_guard_delete()
  from public, anon, authenticated;

drop trigger if exists trg_content_assets_guard_delete on public.content_assets;
create trigger trg_content_assets_guard_delete
before delete on public.content_assets
for each row execute function private.content_assets_guard_delete();

-- ---------------------------------------------------------------------------
-- Optimistic concurrency helpers (SPEC 2.6)
-- ---------------------------------------------------------------------------
create or replace function private.content_item_lock(
  p_id uuid,
  p_expected_row_version integer
)
returns public.content_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.content_items;
begin
  if p_id is null then
    raise exception 'invalid_id' using errcode = '22023';
  end if;
  if p_expected_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;

  select * into v_row from public.content_items where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_row.row_version <> p_expected_row_version then
    raise exception 'row_version_conflict' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

revoke all on function private.content_item_lock(uuid, integer)
  from public, anon, authenticated;
grant execute on function private.content_item_lock(uuid, integer) to service_role;

create or replace function private.content_item_bump(
  p_id uuid,
  p_bump_version_number boolean default false
)
returns public.content_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.content_items;
begin
  update public.content_items c set
    row_version = c.row_version + 1,
    version_number = c.version_number + case when p_bump_version_number then 1 else 0 end,
    updated_by = auth.uid(),
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return v_row;
end;
$$;

revoke all on function private.content_item_bump(uuid, boolean)
  from public, anon, authenticated;
grant execute on function private.content_item_bump(uuid, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- Audience resolution (SPEC 2.5). One resolver for preview + mobile.
-- ---------------------------------------------------------------------------
create or replace function private.content_item_audience_matches(
  p_item_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text;
begin
  if p_item_id is null or p_user_id is null then
    return false;
  end if;

  select ci.audience_mode into v_mode
  from public.content_items ci
  where ci.id = p_item_id;
  if not found then
    return false;
  end if;

  -- Only active platform users ever match.
  if not exists (
    select 1 from public.users u where u.id = p_user_id and u.is_active
  ) then
    return false;
  end if;

  if v_mode = 'all' then
    -- Eligible student = at least one active, non-ended enrollment.
    return exists (
      select 1
      from public.student_enrollments se
      where se.user_id = p_user_id
        and se.status = 'active'
        and se.ended_at is null
    );
  end if;

  if v_mode in ('groups', 'groups_and_users') then
    if exists (
      select 1
      from public.content_item_audience_groups g
      join public.student_enrollments se
        on se.group_id = g.group_id
       and se.user_id = p_user_id
       and se.status = 'active'
       and se.ended_at is null
      where g.content_item_id = p_item_id
    ) then
      return true;
    end if;
  end if;

  if v_mode in ('users', 'groups_and_users') then
    -- Explicit users still require active student eligibility (not blocked / no enrollment).
    if exists (
      select 1
      from public.content_item_audience_users au
      join public.users u on u.id = au.user_id and u.is_active
      join public.student_enrollments se
        on se.user_id = au.user_id
       and se.status = 'active'
       and se.ended_at is null
      where au.content_item_id = p_item_id
        and au.user_id = p_user_id
    ) then
      return true;
    end if;
  end if;

  return false;
end;
$$;

revoke all on function private.content_item_audience_matches(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.content_item_audience_matches(uuid, uuid)
  to service_role;

-- Published + not hidden + in schedule + audience match (ignores dismissals).
create or replace function private.content_item_deliverable_to_user(
  p_item_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.content_items;
  v_now timestamptz := now();
begin
  if p_item_id is null or p_user_id is null then
    return false;
  end if;

  select * into v_row from public.content_items where id = p_item_id;
  if not found then
    return false;
  end if;
  if v_row.status <> 'published' or v_row.is_hidden then
    return false;
  end if;
  if v_row.starts_at is not null and v_row.starts_at > v_now then
    return false;
  end if;
  if v_row.ends_at is not null and v_row.ends_at <= v_now then
    return false;
  end if;

  return private.content_item_audience_matches(p_item_id, p_user_id);
end;
$$;

revoke all on function private.content_item_deliverable_to_user(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.content_item_deliverable_to_user(uuid, uuid)
  to service_role;

create or replace function private.content_item_visible_to_user(
  p_item_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := now();
begin
  if not private.content_item_deliverable_to_user(p_item_id, p_user_id) then
    return false;
  end if;

  -- A dismissal hides the item until can_reshow_after is due.
  if exists (
    select 1
    from public.content_item_dismissals d
    where d.content_item_id = p_item_id
      and d.user_id = p_user_id
      and (d.can_reshow_after is null or d.can_reshow_after > v_now)
  ) then
    return false;
  end if;

  return true;
end;
$$;

revoke all on function private.content_item_visible_to_user(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.content_item_visible_to_user(uuid, uuid)
  to service_role;

create or replace function private.content_assert_audience_consistent(p_item_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text;
  v_groups integer;
  v_users integer;
begin
  select ci.audience_mode into v_mode
  from public.content_items ci
  where ci.id = p_item_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select count(*) into v_groups
  from public.content_item_audience_groups g
  where g.content_item_id = p_item_id;

  select count(*) into v_users
  from public.content_item_audience_users u
  where u.content_item_id = p_item_id;

  if v_mode = 'all' and (v_groups > 0 or v_users > 0) then
    raise exception 'audience_all_must_have_empty_junctions' using errcode = 'P0001';
  end if;
  if v_mode = 'groups' and (v_groups < 1 or v_users > 0) then
    raise exception 'audience_groups_invalid' using errcode = 'P0001';
  end if;
  if v_mode = 'users' and (v_users < 1 or v_groups > 0) then
    raise exception 'audience_users_invalid' using errcode = 'P0001';
  end if;
  if v_mode = 'groups_and_users' and (v_groups < 1 or v_users < 1) then
    raise exception 'audience_groups_and_users_invalid' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on function private.content_assert_audience_consistent(uuid)
  from public, anon, authenticated;
grant execute on function private.content_assert_audience_consistent(uuid)
  to service_role;

-- Recipient count + safe breakdown. Never returns a list of students.
create or replace function private.content_preview_audience_count(p_item_id uuid)
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
  select ci.audience_mode into v_mode
  from public.content_items ci
  where ci.id = p_item_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select count(*)::integer into v_count
  from public.users u
  where u.is_active
    and (
      (
        v_mode = 'all'
        and exists (
          select 1
          from public.student_enrollments se
          where se.user_id = u.id
            and se.status = 'active'
            and se.ended_at is null
        )
      )
      or (
        v_mode in ('groups', 'groups_and_users')
        and exists (
          select 1
          from public.content_item_audience_groups g
          join public.student_enrollments se
            on se.group_id = g.group_id
           and se.user_id = u.id
           and se.status = 'active'
           and se.ended_at is null
          where g.content_item_id = p_item_id
        )
      )
      or (
        v_mode in ('users', 'groups_and_users')
        and exists (
          select 1
          from public.content_item_audience_users au
          join public.student_enrollments se
            on se.user_id = au.user_id
           and se.status = 'active'
           and se.ended_at is null
          where au.content_item_id = p_item_id
            and au.user_id = u.id
        )
      )
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', gr.id,
        'name', gr.name,
        'member_count', gr.member_count
      )
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
    from public.content_item_audience_groups ag
    join public.groups g0 on g0.id = ag.group_id
    where ag.content_item_id = p_item_id
  ) gr;

  select count(distinct au.user_id)::integer into v_explicit
  from public.content_item_audience_users au
  join public.users u on u.id = au.user_id and u.is_active
  join public.student_enrollments se
    on se.user_id = au.user_id
   and se.status = 'active'
   and se.ended_at is null
  where au.content_item_id = p_item_id;

  return jsonb_build_object(
    'content_item_id', p_item_id,
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

revoke all on function private.content_preview_audience_count(uuid)
  from public, anon, authenticated;
grant execute on function private.content_preview_audience_count(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Admin serialization + version snapshot (SPEC 2.9)
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

create or replace function private.content_snapshot_version(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.content_items;
  v_snapshot jsonb;
begin
  select * into v_row from public.content_items where id = p_id;
  if not found then
    return;
  end if;

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

revoke all on function private.content_snapshot_version(uuid)
  from public, anon, authenticated;
grant execute on function private.content_snapshot_version(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Domain audit: content_audit_log + shared admin audit trail
-- ---------------------------------------------------------------------------
create or replace function private.content_write_domain_audit(
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_meta jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.content_audit_log (
    actor_user_id, action, entity_type, entity_id, meta
  ) values (
    auth.uid(),
    p_action,
    p_entity_type,
    p_entity_id,
    coalesce(p_meta, '{}'::jsonb)
  );

  perform private.admin_write_audit(
    p_action,
    p_entity_type,
    p_entity_id::text,
    coalesce(p_meta, '{}'::jsonb)
  );
end;
$$;

revoke all on function private.content_write_domain_audit(text, text, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function private.content_write_domain_audit(text, text, uuid, jsonb)
  to service_role;

-- Retention helper for raw events (SPEC 2.10). Cron wiring comes later.
create or replace function private.content_purge_old_events(p_keep_days integer default 30)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer := 0;
  v_days integer := greatest(coalesce(p_keep_days, 30), 1);
begin
  delete from public.content_item_events
  where created_at < now() - make_interval(days => v_days);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function private.content_purge_old_events(integer)
  from public, anon, authenticated;
grant execute on function private.content_purge_old_events(integer) to service_role;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_content_items(
  p_status text default null,
  p_placement text default null,
  p_origin text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_placement text := nullif(btrim(coalesce(p_placement, '')), '');
  v_origin text := nullif(btrim(coalesce(p_origin, '')), '');
begin
  v_uid := private.require_admin_permission('content.read');

  if v_status is not null and v_status not in ('draft', 'published', 'archived') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if v_placement is not null
     and v_placement not in ('home_promo', 'profile_feed', 'reference') then
    raise exception 'invalid_placement' using errcode = '22023';
  end if;
  if v_origin is not null
     and v_origin not in ('demo', 'admin', 'import', 'user_submission') then
    raise exception 'invalid_origin' using errcode = '22023';
  end if;

  perform private.admin_write_audit(
    'content.list',
    'content_item',
    null,
    jsonb_build_object('status', v_status, 'placement', v_placement, 'origin', v_origin)
  );

  return coalesce(
    (
      select jsonb_agg(
        private.content_item_to_admin_json(ci.id)
        order by
          coalesce(
            (
              select p.sort_order
              from public.content_item_placements p
              where p.content_item_id = ci.id
                and p.placement = v_placement
            ),
            2147483647
          ),
          ci.priority desc,
          ci.published_at desc nulls last,
          ci.updated_at desc
      )
      from public.content_items ci
      where (v_status is null or ci.status = v_status)
        and (v_origin is null or ci.origin = v_origin)
        and (
          v_placement is null
          or exists (
            select 1
            from public.content_item_placements p
            where p.content_item_id = ci.id
              and p.placement = v_placement
          )
        )
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_get_content_item(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  v_uid := private.require_admin_permission('content.read');

  if not exists (select 1 from public.content_items where id = p_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.admin_write_audit(
    'content.get',
    'content_item',
    p_id::text,
    '{}'::jsonb
  );

  return private.content_item_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_create_content_draft(
  p_template_key text,
  p_schema_version integer,
  p_title text,
  p_payload jsonb,
  p_origin text default 'admin'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.content_items;
  v_origin text := coalesce(nullif(btrim(coalesce(p_origin, '')), ''), 'admin');
  v_template public.content_templates;
begin
  v_uid := private.require_admin_permission('content.write');

  if v_origin not in ('demo', 'admin', 'import', 'user_submission') then
    raise exception 'invalid_origin' using errcode = '22023';
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

  perform private.validate_content_payload(
    p_template_key, p_schema_version, coalesce(p_payload, '{}'::jsonb)
  );

  insert into public.content_items (
    template_key, schema_version, status, origin, title, payload,
    audience_mode, created_by, updated_by
  ) values (
    p_template_key,
    p_schema_version,
    'draft',
    v_origin,
    left(coalesce(p_title, ''), 200),
    coalesce(p_payload, '{}'::jsonb),
    'all',
    v_uid,
    v_uid
  )
  returning * into v_row;

  perform private.content_snapshot_version(v_row.id);

  perform private.content_write_domain_audit(
    'content.create_draft',
    'content_item',
    v_row.id,
    jsonb_build_object(
      'template_key', v_row.template_key,
      'schema_version', v_row.schema_version,
      'origin', v_row.origin,
      'status', v_row.status
    )
  );

  return private.content_item_to_admin_json(v_row.id);
end;
$$;

create or replace function public.admin_update_content_draft(
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
  v_row public.content_items;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_origin text;
begin
  v_uid := private.require_admin_permission('content.write');

  if jsonb_typeof(v_patch) <> 'object' then
    raise exception 'invalid_patch' using errcode = '22023';
  end if;

  perform private.content_assert_allowed_keys(v_patch, array[
    'title', 'payload', 'priority', 'starts_at', 'ends_at', 'is_hidden', 'origin'
  ]);

  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status <> 'draft' then
    raise exception 'draft_only' using errcode = '55000';
  end if;

  if v_patch ? 'payload' then
    if jsonb_typeof(v_patch -> 'payload') <> 'object' then
      raise exception 'invalid_payload_not_object' using errcode = '22023';
    end if;
    perform private.validate_content_payload(
      v_row.template_key, v_row.schema_version, v_patch -> 'payload'
    );
    -- Asset invariant checked against the would-be payload for this item.
    -- Temporary apply via validate-only path: assert uses current DB assets + new payload keys.
  end if;

  if v_patch ? 'origin' then
    v_origin := nullif(btrim(coalesce(v_patch ->> 'origin', '')), '');
    if v_origin is null
       or v_origin not in ('demo', 'admin', 'import', 'user_submission') then
      raise exception 'invalid_origin' using errcode = '22023';
    end if;
  end if;

  update public.content_items c set
    title = case
      when v_patch ? 'title' then left(coalesce(v_patch ->> 'title', ''), 200)
      else c.title
    end,
    payload = case
      when v_patch ? 'payload' then v_patch -> 'payload'
      else c.payload
    end,
    priority = case
      when v_patch ? 'priority' then coalesce((v_patch ->> 'priority')::integer, 0)
      else c.priority
    end,
    starts_at = case
      when v_patch ? 'starts_at' then nullif(v_patch ->> 'starts_at', '')::timestamptz
      else c.starts_at
    end,
    ends_at = case
      when v_patch ? 'ends_at' then nullif(v_patch ->> 'ends_at', '')::timestamptz
      else c.ends_at
    end,
    is_hidden = case
      when v_patch ? 'is_hidden' then coalesce((v_patch ->> 'is_hidden')::boolean, false)
      else c.is_hidden
    end,
    origin = case when v_patch ? 'origin' then v_origin else c.origin end,
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  perform private.content_assert_payload_assets(v_row.id);

  perform private.content_snapshot_version(v_row.id);

  perform private.content_write_domain_audit(
    'content.update_draft',
    'content_item',
    v_row.id,
    jsonb_build_object(
      'version_number', v_row.version_number,
      'row_version', v_row.row_version,
      'patched_keys', (
        select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
        from jsonb_object_keys(v_patch) as k
      )
    )
  );

  return private.content_item_to_admin_json(v_row.id);
end;
$$;

create or replace function public.admin_set_content_placements(
  p_id uuid,
  p_placements jsonb,
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
  v_input jsonb := coalesce(p_placements, '[]'::jsonb);
  v_allowed text[];
  v_entry jsonb;
  v_placement text;
  v_seen text[] := '{}'::text[];
begin
  v_uid := private.require_admin_permission('content.write');

  if jsonb_typeof(v_input) <> 'array' then
    raise exception 'invalid_placements' using errcode = '22023';
  end if;

  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status <> 'draft' then
    raise exception 'draft_only' using errcode = '55000';
  end if;

  select t.allowed_placements into v_allowed
  from public.content_templates t
  where t.key = v_row.template_key
    and t.schema_version = v_row.schema_version;

  delete from public.content_item_placements where content_item_id = p_id;

  for v_entry in select value from jsonb_array_elements(v_input) loop
    if jsonb_typeof(v_entry) <> 'object' then
      raise exception 'invalid_placement_entry' using errcode = '22023';
    end if;
    perform private.content_assert_allowed_keys(
      v_entry, array['placement', 'sort_order']
    );
    v_placement := private.content_require_text(v_entry, 'placement', 40);

    if v_placement not in ('home_promo', 'profile_feed', 'reference') then
      raise exception 'invalid_placement' using errcode = '22023';
    end if;
    if not (v_placement = any (coalesce(v_allowed, '{}'::text[]))) then
      raise exception 'placement_not_allowed_for_template' using errcode = '22023';
    end if;
    if v_placement = any (v_seen) then
      raise exception 'duplicate_placement' using errcode = '22023';
    end if;
    v_seen := array_append(v_seen, v_placement);

    insert into public.content_item_placements (content_item_id, placement, sort_order)
    values (
      p_id,
      v_placement,
      coalesce(private.content_optional_int(v_entry, 'sort_order', 0, 100000), 0)
    );
  end loop;

  v_row := private.content_item_bump(p_id, true);

  perform private.content_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'content.set_placements',
    'content_item',
    p_id,
    jsonb_build_object(
      'placements', v_seen,
      'row_version', v_row.row_version
    )
  );

  return private.content_item_to_admin_json(p_id);
end;
$$;

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

  -- Transactional replace.
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

  return private.content_item_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_preview_content_audience(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_result jsonb;
begin
  v_uid := private.require_admin_permission('content.read');

  if not exists (select 1 from public.content_items where id = p_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_result := private.content_preview_audience_count(p_id);

  perform private.admin_write_audit(
    'content.preview_audience',
    'content_item',
    p_id::text,
    jsonb_build_object('recipient_count', v_result -> 'recipient_count')
  );

  return v_result;
end;
$$;

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

  -- Re-validate on the publish path (SPEC 2.7).
  perform private.validate_content_payload(
    v_row.template_key, v_row.schema_version, v_row.payload
  );
  perform private.content_assert_payload_assets(p_id);
  perform private.content_assert_audience_consistent(p_id);

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

  return private.content_item_to_admin_json(p_id);
end;
$$;

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

  return private.content_item_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_list_content_versions(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  v_uid := private.require_admin_permission('content.read');

  if not exists (select 1 from public.content_items where id = p_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.admin_write_audit(
    'content.list_versions',
    'content_item',
    p_id::text,
    '{}'::jsonb
  );

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', v.id,
          'content_item_id', v.content_item_id,
          'version_number', v.version_number,
          'created_by', v.created_by,
          'created_at', v.created_at,
          'snapshot', v.snapshot
        )
        order by v.version_number desc
      )
      from public.content_item_versions v
      where v.content_item_id = p_id
    ),
    '[]'::jsonb
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
    -- Restore never auto-publishes (SPEC 2.9).
    status = 'draft',
    version_number = c.version_number + 1,
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = p_id
  returning * into v_row;

  -- Placements and audience are part of the snapshot: replace transactionally.
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

  -- Loud failure on missing/foreign assets referenced by the restored payload.
  perform private.content_assert_payload_assets(p_id);
  perform private.content_assert_audience_consistent(p_id);

  perform private.content_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'content.restore_version',
    'content_item',
    p_id,
    jsonb_build_object(
      'restored_version', p_version_number,
      'new_version', v_row.version_number,
      'previous_status', v_previous,
      'row_version', v_row.row_version
    )
  );

  return private.content_item_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_reorder_content_placement(
  p_placement text,
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
  v_placement text := nullif(btrim(coalesce(p_placement, '')), '');
  v_len integer;
  v_locked integer := 0;
  v_rec record;
begin
  v_uid := private.require_admin_permission('content.write');

  if v_placement is null
     or v_placement not in ('home_promo', 'profile_feed', 'reference') then
    raise exception 'invalid_placement' using errcode = '22023';
  end if;
  if p_ordered_ids is null or p_expected_row_versions is null then
    raise exception 'invalid_order' using errcode = '22023';
  end if;

  v_len := coalesce(array_length(p_ordered_ids, 1), 0);
  if v_len = 0 then
    raise exception 'invalid_order' using errcode = '22023';
  end if;
  if v_len <> coalesce(array_length(p_expected_row_versions, 1), 0) then
    raise exception 'row_version_array_length_mismatch' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_ordered_ids) as t(id) where t.id is null) then
    raise exception 'invalid_order' using errcode = '22023';
  end if;
  if v_len <> (select count(distinct t.id) from unnest(p_ordered_ids) as t(id)) then
    raise exception 'duplicate_item_ids' using errcode = '22023';
  end if;

  -- Deterministic lock order (by uuid) to avoid deadlocks.
  for v_rec in
    select c.id
    from public.content_items c
    where c.id = any (p_ordered_ids)
    order by c.id
    for update
  loop
    v_locked := v_locked + 1;
  end loop;

  if v_locked <> v_len then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from unnest(p_ordered_ids) as t(id)
    where not exists (
      select 1
      from public.content_item_placements p
      where p.content_item_id = t.id
        and p.placement = v_placement
    )
  ) then
    raise exception 'placement_not_found' using errcode = 'P0002';
  end if;

  -- Validate every expected row_version before touching any row.
  if exists (
    select 1
    from unnest(p_ordered_ids, p_expected_row_versions)
      with ordinality as t(id, expected_row_version, ord)
    join public.content_items c on c.id = t.id
    where t.expected_row_version is null
       or c.row_version <> t.expected_row_version
  ) then
    raise exception 'row_version_conflict' using errcode = 'P0001';
  end if;

  update public.content_item_placements p set
    sort_order = t.ord - 1
  from unnest(p_ordered_ids) with ordinality as t(id, ord)
  where p.content_item_id = t.id
    and p.placement = v_placement;

  update public.content_items c set
    row_version = c.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where c.id = any (p_ordered_ids);

  perform private.content_write_domain_audit(
    'content.reorder_placement',
    'content_item',
    null,
    jsonb_build_object('placement', v_placement, 'count', v_len)
  );

  return coalesce(
    (
      select jsonb_agg(
        private.content_item_to_admin_json(ci.id)
        order by p.sort_order, ci.priority desc, ci.published_at desc nulls last
      )
      from public.content_items ci
      join public.content_item_placements p
        on p.content_item_id = ci.id
       and p.placement = v_placement
    ),
    '[]'::jsonb
  );
end;
$$;

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

  -- 1) Queue storage cleanup before the rows disappear.
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

  -- 2) Cascade delete item + versions/placements/audience/assets/events/dismissals.
  perform set_config('app.content_cascade_delete', 'on', true);
  delete from public.content_items where id = p_id;
  perform set_config('app.content_cascade_delete', 'off', true);

  -- 3) Audit (tombstone).
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
-- Mobile RPCs
-- ---------------------------------------------------------------------------
create or replace function public.get_my_content_for_placement(p_placement text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_placement text := nullif(btrim(coalesce(p_placement, '')), '');
  v_groups uuid[];
  v_eligible boolean;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if v_placement is null
     or v_placement not in ('home_promo', 'profile_feed', 'reference') then
    raise exception 'invalid_placement' using errcode = '22023';
  end if;

  if not exists (select 1 from public.users u where u.id = v_uid and u.is_active) then
    return '[]'::jsonb;
  end if;

  v_groups := private.current_user_active_group_ids();
  v_eligible := coalesce(array_length(v_groups, 1), 0) > 0;

  -- Set-based: one statement, no per-item round trips.
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', ci.id,
          'template_key', ci.template_key,
          'schema_version', ci.schema_version,
          'placement', pl.placement,
          'sort_order', pl.sort_order,
          'priority', ci.priority,
          'origin', ci.origin,
          'title', ci.title,
          'payload', ci.payload,
          'dismissible', coalesce((ci.payload ->> 'dismissible')::boolean, false),
          'starts_at', ci.starts_at,
          'ends_at', ci.ends_at,
          'published_at', ci.published_at
        )
        order by pl.sort_order, ci.priority desc, ci.published_at desc nulls last
      )
      from public.content_items ci
      join public.content_item_placements pl
        on pl.content_item_id = ci.id
       and pl.placement = v_placement
      left join public.content_item_dismissals d
        on d.content_item_id = ci.id
       and d.user_id = v_uid
      where ci.status = 'published'
        and not ci.is_hidden
        and (ci.starts_at is null or ci.starts_at <= v_now)
        and (ci.ends_at is null or ci.ends_at > v_now)
        and (
          d.content_item_id is null
          or (d.can_reshow_after is not null and d.can_reshow_after <= v_now)
        )
        and (
          (ci.audience_mode = 'all' and v_eligible)
          or (
            ci.audience_mode in ('groups', 'groups_and_users')
            and exists (
              select 1
              from public.content_item_audience_groups g
              where g.content_item_id = ci.id
                and g.group_id = any (v_groups)
            )
          )
          or (
            ci.audience_mode in ('users', 'groups_and_users')
            and v_eligible
            and exists (
              select 1
              from public.content_item_audience_users au
              where au.content_item_id = ci.id
                and au.user_id = v_uid
            )
          )
        )
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.dismiss_content_item(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_hours integer;
  v_reshow timestamptz;
  v_payload jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  -- Deliverable (published / in schedule / audience) so re-dismiss stays safe.
  if not private.content_item_deliverable_to_user(p_id, v_uid) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select ci.payload into v_payload from public.content_items ci where ci.id = p_id;
  if coalesce((v_payload ->> 'dismissible')::boolean, false) is not true then
    raise exception 'not_dismissible' using errcode = '55000';
  end if;

  v_hours := private.content_optional_int(v_payload, 'reshow_after_hours', 1, 8760);
  if v_hours is not null then
    v_reshow := now() + make_interval(hours => v_hours);
  end if;

  insert into public.content_item_dismissals (
    content_item_id, user_id, dismissed_at, can_reshow_after
  ) values (
    p_id, v_uid, now(), v_reshow
  )
  on conflict (content_item_id, user_id) do update
    set dismissed_at = now(),
        can_reshow_after = excluded.can_reshow_after;

  return jsonb_build_object(
    'ok', true,
    'content_item_id', p_id,
    'can_reshow_after', v_reshow
  );
end;
$$;

create or replace function public.record_content_event(
  p_id uuid,
  p_event text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_event text := nullif(btrim(coalesce(p_event, '')), '');
  v_hour timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if v_event is null or v_event not in ('impression', 'click') then
    raise exception 'invalid_event' using errcode = '22023';
  end if;

  if not private.content_item_visible_to_user(p_id, v_uid) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- UTC hour bucket, independent of session TimeZone.
  v_hour := date_trunc('hour', timezone('utc', now())) at time zone 'utc';

  begin
    insert into public.content_item_events (
      content_item_id, user_id, event_type, event_hour
    ) values (
      p_id, v_uid, v_event, v_hour
    );
  exception when unique_violation then
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'content_item_id', p_id,
      'event_type', v_event,
      'event_hour', v_hour
    );
  end;

  return jsonb_build_object(
    'ok', true,
    'duplicate', false,
    'content_item_id', p_id,
    'event_type', v_event,
    'event_hour', v_hour
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants for RPCs (RBAC is enforced inside each function body)
-- ---------------------------------------------------------------------------
revoke all on function public.admin_list_content_items(text, text, text)
  from public, anon;
grant execute on function public.admin_list_content_items(text, text, text)
  to authenticated, service_role;

revoke all on function public.admin_get_content_item(uuid) from public, anon;
grant execute on function public.admin_get_content_item(uuid)
  to authenticated, service_role;

revoke all on function public.admin_create_content_draft(text, integer, text, jsonb, text)
  from public, anon;
grant execute on function public.admin_create_content_draft(text, integer, text, jsonb, text)
  to authenticated, service_role;

revoke all on function public.admin_update_content_draft(uuid, jsonb, integer)
  from public, anon;
grant execute on function public.admin_update_content_draft(uuid, jsonb, integer)
  to authenticated, service_role;

revoke all on function public.admin_set_content_placements(uuid, jsonb, integer)
  from public, anon;
grant execute on function public.admin_set_content_placements(uuid, jsonb, integer)
  to authenticated, service_role;

revoke all on function public.admin_set_content_audience(uuid, text, uuid[], uuid[], integer)
  from public, anon;
grant execute on function public.admin_set_content_audience(uuid, text, uuid[], uuid[], integer)
  to authenticated, service_role;

revoke all on function public.admin_preview_content_audience(uuid) from public, anon;
grant execute on function public.admin_preview_content_audience(uuid)
  to authenticated, service_role;

revoke all on function public.admin_publish_content(uuid, integer) from public, anon;
grant execute on function public.admin_publish_content(uuid, integer)
  to authenticated, service_role;

revoke all on function public.admin_unpublish_content(uuid, integer) from public, anon;
grant execute on function public.admin_unpublish_content(uuid, integer)
  to authenticated, service_role;

revoke all on function public.admin_archive_content(uuid, integer) from public, anon;
grant execute on function public.admin_archive_content(uuid, integer)
  to authenticated, service_role;

revoke all on function public.admin_list_content_versions(uuid) from public, anon;
grant execute on function public.admin_list_content_versions(uuid)
  to authenticated, service_role;

revoke all on function public.admin_restore_content_version(uuid, integer, integer)
  from public, anon;
grant execute on function public.admin_restore_content_version(uuid, integer, integer)
  to authenticated, service_role;

revoke all on function public.admin_reorder_content_placement(text, uuid[], integer[])
  from public, anon;
grant execute on function public.admin_reorder_content_placement(text, uuid[], integer[])
  to authenticated, service_role;

revoke all on function public.admin_safe_delete_content(uuid, integer) from public, anon;
grant execute on function public.admin_safe_delete_content(uuid, integer)
  to authenticated, service_role;

revoke all on function public.get_my_content_for_placement(text) from public, anon;
grant execute on function public.get_my_content_for_placement(text)
  to authenticated, service_role;

revoke all on function public.dismiss_content_item(uuid) from public, anon;
grant execute on function public.dismiss_content_item(uuid)
  to authenticated, service_role;

revoke all on function public.record_content_event(uuid, text) from public, anon;
grant execute on function public.record_content_event(uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Private storage bucket (no public/anon object access), mirrors news-media.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'content-media',
  'content-media',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Deny direct client access; Edge Function uses service_role.
-- No permissive policies for anon/authenticated on content-media: access is
-- denied by the absence of policies plus RLS on storage.objects.

comment on function public.admin_safe_delete_content(uuid, integer) is
  'Delete an archived content item + history/assets after queueing storage cleanup.';
comment on function public.get_my_content_for_placement(text) is
  'Published, in-schedule, audience-matched, non-dismissed items for one placement.';
comment on function public.record_content_event(uuid, text) is
  'Allowlisted impression/click with UTC hour-bucket dedupe. Requires visibility.';

commit;
