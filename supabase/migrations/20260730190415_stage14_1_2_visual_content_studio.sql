-- Stage 14.1.2 — Visual Content Studio (schema v2 drafts + gated publish).
-- NEW migration only. Does not edit applied migrations.
--
-- Contracts (Codex APPROVE_WITH_NOTES):
--   * home_slot in payload (not placement CHECK expansion)
--   * structured action + legacy cta_route/cta_url projection
--   * publish of schema v2 / non-default slots / variants gated OFF by default
--   * vacancy_assets.role for logo/cover/background
--   * reference_categories description/color/is_hidden + safe delete RPC
--   * audience preview RPC (masked)

begin;

-- ---------------------------------------------------------------------------
-- 1. Feature flag — server publish gate (default OFF)
-- ---------------------------------------------------------------------------
insert into public.app_feature_flags (key, enabled, description)
values (
  'content_visual_studio_v2_publish',
  false,
  'Stage 14.1.2: allow publishing home_promo/profile_feed schema_version=2, non-default home_slot, card_variant, structured action'
)
on conflict (key) do nothing;

create or replace function private.content_visual_studio_v2_publish_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select enabled from public.app_feature_flags
     where key = 'content_visual_studio_v2_publish'),
    false
  );
$$;

revoke all on function private.content_visual_studio_v2_publish_enabled()
  from public, anon, authenticated;
grant execute on function private.content_visual_studio_v2_publish_enabled()
  to service_role;

-- ---------------------------------------------------------------------------
-- 2. Templates: home_promo_v1@2, profile_feed_card_v1@2
-- ---------------------------------------------------------------------------
insert into public.content_templates (
  key, schema_version, title, allowed_placements, schema_doc, is_active
) values
(
  'home_promo_v1', 2, 'Home promo card v2',
  array['home_promo']::text[],
  jsonb_build_object(
    'notes',
    'Additive v2: home_slot, card_variant, icon_asset_id, bg_*, action. Publish gated.'
  ),
  true
),
(
  'profile_feed_card_v1', 2, 'Profile feed card v2',
  array['profile_feed']::text[],
  jsonb_build_object(
    'notes',
    'Additive v2: card_variant, icon_key, icon_asset_id, bg_*, action. Publish gated.'
  ),
  true
)
on conflict (key, schema_version) do update
  set title = excluded.title,
      allowed_placements = excluded.allowed_placements,
      schema_doc = excluded.schema_doc,
      is_active = excluded.is_active;

-- ---------------------------------------------------------------------------
-- 3. Vacancy asset roles
-- ---------------------------------------------------------------------------
alter table public.vacancy_assets
  add column if not exists role text not null default 'attachment';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'vacancy_assets_role_chk'
  ) then
    alter table public.vacancy_assets
      add constraint vacancy_assets_role_chk
      check (role in ('attachment', 'logo', 'cover', 'background'));
  end if;
end;
$$;

create index if not exists vacancy_assets_vacancy_role_idx
  on public.vacancy_assets (vacancy_id, role);

-- ---------------------------------------------------------------------------
-- 4. Reference categories visual fields
-- ---------------------------------------------------------------------------
alter table public.reference_categories
  add column if not exists description text not null default '',
  add column if not exists color text null,
  add column if not exists is_hidden boolean not null default false;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'reference_categories_description_len'
  ) then
    alter table public.reference_categories
      add constraint reference_categories_description_len
      check (char_length(description) <= 600);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'reference_categories_color_hex'
  ) then
    alter table public.reference_categories
      add constraint reference_categories_color_hex
      check (
        color is null
        or color ~ '^#[0-9A-Fa-f]{6}$'
      );
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Allowed app screens + structured action helpers
-- ---------------------------------------------------------------------------
create or replace function private.content_allowed_app_screens()
returns text[]
language sql
immutable
as $$
  select array[
    'home', 'diary', 'schedule', 'info', 'help', 'profile', 'learning'
  ]::text[];
$$;

revoke all on function private.content_allowed_app_screens()
  from public, anon, authenticated;
grant execute on function private.content_allowed_app_screens() to service_role;

create or replace function private.content_legacy_route_for_screen(p_screen text)
returns text
language sql
immutable
as $$
  select case p_screen
    when 'home' then '/home'
    when 'diary' then '/diary'
    when 'schedule' then '/schedule'
    when 'info' then '/info'
    when 'help' then '/help'
    when 'profile' then '/profile'
    when 'learning' then '/learning'
    else null
  end;
$$;

revoke all on function private.content_legacy_route_for_screen(text)
  from public, anon, authenticated;
grant execute on function private.content_legacy_route_for_screen(text)
  to service_role;

create or replace function private.content_assert_structured_action(p_payload jsonb)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_action jsonb;
  v_kind text;
  v_screen text;
  v_target uuid;
  v_url text;
  v_route text;
  v_legacy_url text;
begin
  if not (p_payload ? 'action') then
    return;
  end if;
  v_action := p_payload -> 'action';
  if jsonb_typeof(v_action) <> 'object' then
    raise exception 'invalid_action_object' using errcode = '22023';
  end if;

  perform private.content_assert_allowed_keys(v_action, array[
    'kind', 'screen_key', 'target_id', 'url'
  ]);

  v_kind := nullif(btrim(coalesce(v_action ->> 'kind', '')), '');
  if v_kind is null or v_kind not in (
    'app_screen', 'reference_article', 'subject', 'vacancy', 'external_url', 'none'
  ) then
    raise exception 'invalid_action_kind' using errcode = '22023';
  end if;

  v_screen := nullif(btrim(coalesce(v_action ->> 'screen_key', '')), '');
  v_url := nullif(btrim(coalesce(v_action ->> 'url', '')), '');
  begin
    v_target := nullif(btrim(coalesce(v_action ->> 'target_id', '')), '')::uuid;
  exception when others then
    raise exception 'invalid_action_target_id' using errcode = '22023';
  end;

  if v_kind = 'none' then
    if v_screen is not null or v_target is not null or v_url is not null then
      raise exception 'action_none_has_targets' using errcode = '22023';
    end if;
  elsif v_kind = 'app_screen' then
    if v_screen is null or v_screen <> all (private.content_allowed_app_screens()) then
      raise exception 'invalid_action_screen' using errcode = '22023';
    end if;
    if v_target is not null or v_url is not null then
      raise exception 'action_screen_extra_targets' using errcode = '22023';
    end if;
  elsif v_kind in ('reference_article', 'subject', 'vacancy') then
    if v_target is null then
      raise exception 'action_target_required' using errcode = '22023';
    end if;
    if v_screen is not null or v_url is not null then
      raise exception 'action_entity_extra_targets' using errcode = '22023';
    end if;
    if v_kind = 'reference_article' then
      if not exists (
        select 1 from public.content_items c
        where c.id = v_target
          and c.template_key = 'reference_article_v1'
          and c.status = 'published'
      ) then
        raise exception 'action_reference_not_published' using errcode = 'P0001';
      end if;
    elsif v_kind = 'subject' then
      if not exists (
        select 1 from public.subject_catalog s where s.id = v_target
      ) then
        raise exception 'action_subject_not_found' using errcode = 'P0002';
      end if;
    elsif v_kind = 'vacancy' then
      if not exists (
        select 1 from public.vacancies v
        where v.id = v_target and v.status = 'published'
      ) then
        raise exception 'action_vacancy_not_published' using errcode = 'P0001';
      end if;
    end if;
  elsif v_kind = 'external_url' then
    if v_url is null or char_length(v_url) > 500
       or v_url !~* '^https://' then
      raise exception 'invalid_action_url' using errcode = '22023';
    end if;
    if v_screen is not null or v_target is not null then
      raise exception 'action_url_extra_targets' using errcode = '22023';
    end if;
  end if;

  -- Conflict check vs legacy projection fields when both present.
  v_route := private.content_optional_text(p_payload, 'cta_route', 300);
  v_legacy_url := private.content_optional_text(p_payload, 'cta_url', 500);
  if v_kind = 'app_screen' then
    if v_route is not null
       and v_route is distinct from private.content_legacy_route_for_screen(v_screen) then
      raise exception 'action_legacy_route_conflict' using errcode = '22023';
    end if;
    if v_legacy_url is not null then
      raise exception 'action_legacy_url_conflict' using errcode = '22023';
    end if;
  elsif v_kind = 'external_url' then
    if v_legacy_url is not null and v_legacy_url is distinct from v_url then
      raise exception 'action_legacy_url_conflict' using errcode = '22023';
    end if;
    if v_route is not null then
      raise exception 'action_legacy_route_conflict' using errcode = '22023';
    end if;
  elsif v_kind = 'none' then
    if v_route is not null or v_legacy_url is not null then
      raise exception 'action_legacy_conflict' using errcode = '22023';
    end if;
  end if;
end;
$$;

revoke all on function private.content_assert_structured_action(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_assert_structured_action(jsonb)
  to service_role;

create or replace function private.content_project_legacy_cta(p_payload jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_action jsonb;
  v_kind text;
  v_screen text;
  v_url text;
  v_route text;
begin
  if not (v_payload ? 'action') then
    return v_payload;
  end if;
  v_action := v_payload -> 'action';
  if jsonb_typeof(v_action) <> 'object' then
    return v_payload;
  end if;
  v_kind := v_action ->> 'kind';
  v_screen := nullif(btrim(coalesce(v_action ->> 'screen_key', '')), '');
  v_url := nullif(btrim(coalesce(v_action ->> 'url', '')), '');

  if v_kind = 'app_screen' and v_screen is not null then
    v_route := private.content_legacy_route_for_screen(v_screen);
    if v_route is not null then
      v_payload := v_payload || jsonb_build_object('cta_route', v_route);
      v_payload := v_payload - 'cta_url';
    end if;
  elsif v_kind = 'external_url' and v_url is not null then
    v_payload := v_payload || jsonb_build_object('cta_url', v_url);
    v_payload := v_payload - 'cta_route';
  elsif v_kind = 'none' then
    v_payload := v_payload - 'cta_route' - 'cta_url';
  end if;
  return v_payload;
end;
$$;

revoke all on function private.content_project_legacy_cta(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_project_legacy_cta(jsonb)
  to service_role;

create or replace function private.content_assert_visual_v2_fields(p_payload jsonb)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_slot text;
  v_variant text;
  v_bg text;
  v_fit text;
  v_angle integer;
  v_op numeric;
begin
  v_slot := nullif(btrim(coalesce(p_payload ->> 'home_slot', '')), '');
  if v_slot is not null and v_slot not in (
    'after_news', 'after_day_summary', 'after_assignments',
    'before_bottom_info', 'end_of_page'
  ) then
    raise exception 'invalid_home_slot' using errcode = '22023';
  end if;

  v_variant := nullif(btrim(coalesce(p_payload ->> 'card_variant', '')), '');
  if v_variant is not null and v_variant not in (
    'gradient_text', 'image_full', 'image_overlay', 'image_top_text',
    'compact_icon', 'accent_info', 'no_image'
  ) then
    raise exception 'invalid_card_variant' using errcode = '22023';
  end if;

  v_bg := nullif(btrim(coalesce(p_payload ->> 'bg_mode', '')), '');
  if v_bg is not null and v_bg not in (
    'none', 'solid', 'gradient', 'image', 'image_dim', 'image_overlay'
  ) then
    raise exception 'invalid_bg_mode' using errcode = '22023';
  end if;

  if p_payload ? 'bg_color' then
    if coalesce(p_payload ->> 'bg_color', '') !~ '^#[0-9A-Fa-f]{6}$' then
      raise exception 'invalid_bg_color' using errcode = '22023';
    end if;
  end if;

  if p_payload ? 'gradient_angle' then
    begin
      v_angle := (p_payload ->> 'gradient_angle')::integer;
    exception when others then
      raise exception 'invalid_gradient_angle' using errcode = '22023';
    end;
    if v_angle not in (0, 45, 90, 135, 180, 225, 270, 315) then
      raise exception 'invalid_gradient_angle' using errcode = '22023';
    end if;
  end if;

  if p_payload ? 'overlay_opacity' then
    begin
      v_op := (p_payload ->> 'overlay_opacity')::numeric;
    exception when others then
      raise exception 'invalid_overlay_opacity' using errcode = '22023';
    end;
    if v_op < 0 or v_op > 1 then
      raise exception 'invalid_overlay_opacity' using errcode = '22023';
    end if;
  end if;

  if p_payload ? 'focal_x' or p_payload ? 'focal_y' then
    perform private.content_optional_int(p_payload, 'focal_x', 0, 100);
    perform private.content_optional_int(p_payload, 'focal_y', 0, 100);
  end if;

  v_fit := nullif(btrim(coalesce(p_payload ->> 'image_fit', '')), '');
  if v_fit is not null and v_fit not in ('cover', 'contain') then
    raise exception 'invalid_image_fit' using errcode = '22023';
  end if;

  perform private.content_optional_uuid(p_payload, 'icon_asset_id');
  perform private.content_assert_structured_action(p_payload);
end;
$$;

revoke all on function private.content_assert_visual_v2_fields(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_assert_visual_v2_fields(jsonb)
  to service_role;

create or replace function private.content_assert_v2_publish_allowed(
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
  v_slot text;
  v_variant text;
begin
  if private.content_visual_studio_v2_publish_enabled() then
    return;
  end if;

  if p_template_key in ('home_promo_v1', 'profile_feed_card_v1')
     and p_schema_version >= 2 then
    raise exception 'visual_studio_v2_publish_disabled' using errcode = 'P0001';
  end if;

  v_slot := nullif(btrim(coalesce(p_payload ->> 'home_slot', '')), '');
  if v_slot is not null and v_slot <> 'after_assignments' then
    raise exception 'visual_studio_v2_publish_disabled' using errcode = 'P0001';
  end if;

  v_variant := nullif(btrim(coalesce(p_payload ->> 'card_variant', '')), '');
  if v_variant is not null and v_variant <> 'gradient_text' then
    raise exception 'visual_studio_v2_publish_disabled' using errcode = 'P0001';
  end if;

  if p_payload ? 'action' then
    raise exception 'visual_studio_v2_publish_disabled' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on function private.content_assert_v2_publish_allowed(text, integer, jsonb)
  from public, anon, authenticated;
grant execute on function private.content_assert_v2_publish_allowed(text, integer, jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- 6. Replace validate_content_payload with v1 + v2 branches
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

  elsif p_template_key = 'home_promo_v1' and p_schema_version = 2 then
    perform private.content_assert_allowed_keys(v_payload, array[
      'title', 'subtitle', 'icon_key', 'icon_asset_id', 'gradient_colors',
      'image_asset_id', 'cta_label', 'cta_route', 'cta_url', 'dismissible',
      'reshow_after_hours', 'home_slot', 'card_variant', 'bg_mode', 'bg_color',
      'gradient_angle', 'overlay_opacity', 'focal_x', 'focal_y', 'image_fit',
      'action'
    ]);
    perform private.content_require_text(v_payload, 'title', 120);
    perform private.content_require_text(v_payload, 'subtitle', 240);
    if private.content_optional_text(v_payload, 'icon_key', 60) is null
       and private.content_optional_uuid(v_payload, 'icon_asset_id') is null then
      raise exception 'icon_required' using errcode = '22023';
    end if;
    if v_payload ? 'icon_key' then
      perform private.content_require_text(v_payload, 'icon_key', 60);
    end if;
    if v_payload ? 'gradient_colors' then
      perform private.content_assert_gradient(v_payload);
    end if;
    perform private.content_require_text(v_payload, 'cta_label', 60);
    perform private.content_require_bool(v_payload, 'dismissible');
    perform private.content_optional_uuid(v_payload, 'image_asset_id');
    perform private.content_optional_uuid(v_payload, 'icon_asset_id');
    perform private.content_optional_int(v_payload, 'reshow_after_hours', 1, 8760);
    perform private.content_assert_visual_v2_fields(v_payload);
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

  elsif p_template_key = 'profile_feed_card_v1' and p_schema_version = 2 then
    perform private.content_assert_allowed_keys(v_payload, array[
      'title', 'subtitle', 'image_asset_id', 'cta_label', 'cta_route', 'cta_url',
      'icon_key', 'icon_asset_id', 'card_variant', 'bg_mode', 'bg_color',
      'gradient_colors', 'gradient_angle', 'overlay_opacity', 'focal_x',
      'focal_y', 'image_fit', 'action'
    ]);
    perform private.content_require_text(v_payload, 'title', 120);
    perform private.content_require_text(v_payload, 'subtitle', 240);
    perform private.content_require_text(v_payload, 'cta_label', 60);
    perform private.content_optional_uuid(v_payload, 'image_asset_id');
    perform private.content_optional_uuid(v_payload, 'icon_asset_id');
    if v_payload ? 'icon_key' then
      perform private.content_require_text(v_payload, 'icon_key', 60);
    end if;
    if v_payload ? 'gradient_colors' then
      perform private.content_assert_gradient(v_payload);
    end if;
    perform private.content_assert_visual_v2_fields(v_payload);
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

-- Extend asset id extraction for icon_asset_id
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
    select private.content_optional_uuid(coalesce(p_payload, '{}'::jsonb), 'icon_asset_id')
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

-- ---------------------------------------------------------------------------
-- 7. Gate publish paths (canonical + working draft)
-- ---------------------------------------------------------------------------
create or replace function private.content_gate_visual_publish(p_id uuid)
returns void
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
  perform private.content_assert_v2_publish_allowed(
    v_row.template_key, v_row.schema_version, v_row.payload
  );
end;
$$;

revoke all on function private.content_gate_visual_publish(uuid)
  from public, anon, authenticated;
grant execute on function private.content_gate_visual_publish(uuid) to service_role;

-- Patch admin_publish_content: inject gate before status flip.
-- Full function body from latest applied migration with gate + legacy CTA project.
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
  v_projected jsonb;
begin
  v_uid := private.require_admin_permission('content.publish');
  perform private.content_assert_no_working_draft(p_id);
  v_row := private.content_item_lock(p_id, p_expected_row_version);

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;
  if v_row.status = 'published' then
    raise exception 'already_published' using errcode = 'P0001';
  end if;

  v_projected := private.content_project_legacy_cta(v_row.payload);
  if v_projected is distinct from v_row.payload then
    update public.content_items c
    set payload = v_projected,
        updated_by = v_uid,
        updated_at = now()
    where c.id = p_id
    returning * into v_row;
  end if;

  perform private.validate_content_payload(
    v_row.template_key, v_row.schema_version, v_row.payload
  );
  perform private.content_gate_visual_publish(p_id);
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

revoke all on function public.admin_publish_content(uuid, integer)
  from public, anon;
grant execute on function public.admin_publish_content(uuid, integer)
  to authenticated, service_role;

-- Working-draft publish: project CTA + gate after draft applied to row
-- We wrap by replacing the publish working draft function's validation section
-- via a helper called from an updated function body excerpt.
-- Safer approach: add gate call inside a thin override that re-reads draft.

create or replace function private.content_working_draft_gate_publish(
  p_draft public.content_item_working_drafts
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_schema integer;
  v_payload jsonb;
begin
  v_schema := coalesce(p_draft.target_schema_version, (
    select c.schema_version from public.content_items c
    where c.id = p_draft.content_item_id
  ));
  v_payload := private.content_project_legacy_cta(p_draft.payload);
  perform private.validate_content_payload(
    (select c.template_key from public.content_items c
     where c.id = p_draft.content_item_id),
    v_schema,
    v_payload
  );
  perform private.content_assert_v2_publish_allowed(
    (select c.template_key from public.content_items c
     where c.id = p_draft.content_item_id),
    v_schema,
    v_payload
  );
end;
$$;

revoke all on function private.content_working_draft_gate_publish(
  public.content_item_working_drafts
) from public, anon, authenticated;
grant execute on function private.content_working_draft_gate_publish(
  public.content_item_working_drafts
) to service_role;

-- ---------------------------------------------------------------------------
-- 8. Category upsert extensions + safe delete
-- ---------------------------------------------------------------------------
-- Keep existing signature (uuid, integer, jsonb); extend patch keys.

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
  v_desc text;
  v_color text;
  v_hidden boolean;
begin
  v_uid := private.require_admin_permission('content.write');
  v_title := nullif(btrim(coalesce(p_patch->>'title', '')), '');
  v_icon := nullif(btrim(coalesce(p_patch->>'icon_key', '')), '');
  v_status := coalesce(nullif(btrim(coalesce(p_patch->>'status', '')), ''), 'draft');
  v_sort := coalesce((p_patch->>'sort_order')::integer, 0);
  v_key := nullif(btrim(coalesce(p_patch->>'key', '')), '');
  v_desc := coalesce(p_patch->>'description', '');
  v_color := nullif(btrim(coalesce(p_patch->>'color', '')), '');
  v_hidden := coalesce((p_patch->>'is_hidden')::boolean, false);

  if v_title is null or v_icon is null then
    raise exception 'title_and_icon_required' using errcode = '22023';
  end if;
  if v_status not in ('draft', 'published', 'archived') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if char_length(v_desc) > 600 then
    raise exception 'invalid_description' using errcode = '22023';
  end if;
  if v_color is not null and v_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'invalid_color' using errcode = '22023';
  end if;

  if p_id is null then
    if v_status is distinct from 'draft' then
      perform private.require_admin_permission('content.publish');
    end if;
    v_key := coalesce(v_key, lower(regexp_replace(v_title, '[^a-zA-Z0-9]+', '_', 'g')));
    insert into public.reference_categories (
      key, title, icon_key, status, sort_order, description, color, is_hidden,
      created_by, updated_by
    ) values (
      left(v_key, 80), left(v_title, 120), left(v_icon, 60), v_status, v_sort,
      v_desc, v_color, v_hidden, v_uid, v_uid
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
    if v_status is distinct from v_row.status then
      perform private.require_admin_permission('content.publish');
    end if;
    update public.reference_categories c set
      title = left(v_title, 120),
      icon_key = left(v_icon, 60),
      status = v_status,
      sort_order = v_sort,
      description = v_desc,
      color = v_color,
      is_hidden = v_hidden,
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
    jsonb_build_object(
      'status', v_row.status,
      'is_hidden', v_row.is_hidden,
      'row_version', v_row.row_version
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'key', v_row.key,
    'title', v_row.title,
    'icon_key', v_row.icon_key,
    'status', v_row.status,
    'sort_order', v_row.sort_order,
    'description', v_row.description,
    'color', v_row.color,
    'is_hidden', v_row.is_hidden,
    'row_version', v_row.row_version,
    'article_count', (
      select count(*)::integer
      from public.content_item_reference_categories l
      where l.reference_category_id = v_row.id
    )
  );
end;
$$;

revoke all on function public.admin_upsert_reference_category(uuid, integer, jsonb)
  from public, anon;
grant execute on function public.admin_upsert_reference_category(uuid, integer, jsonb)
  to authenticated, service_role;

create or replace function public.admin_safe_delete_reference_category(
  p_id uuid,
  p_expected_row_version integer,
  p_mode text,
  p_reassign_to uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.reference_categories;
  v_mode text := nullif(btrim(coalesce(p_mode, '')), '');
  v_published integer := 0;
  v_total integer := 0;
  v_moved integer := 0;
begin
  v_uid := private.require_admin_permission('content.publish');

  if v_mode is null or v_mode not in ('reassign', 'archive_articles', 'cancel') then
    raise exception 'invalid_delete_mode' using errcode = '22023';
  end if;
  if v_mode = 'cancel' then
    raise exception 'delete_cancelled' using errcode = 'P0001';
  end if;

  select * into v_row from public.reference_categories
  where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_expected_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;
  if v_row.row_version <> p_expected_row_version then
    raise exception 'row_version_conflict' using errcode = 'P0001';
  end if;

  select count(*)::integer into v_total
  from public.content_item_reference_categories l
  where l.reference_category_id = p_id;

  select count(*)::integer into v_published
  from public.content_item_reference_categories l
  join public.content_items c on c.id = l.content_item_id
  where l.reference_category_id = p_id
    and c.status = 'published';

  if v_mode = 'reassign' then
    if p_reassign_to is null or p_reassign_to = p_id then
      raise exception 'reassign_target_required' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.reference_categories c where c.id = p_reassign_to
    ) then
      raise exception 'reassign_target_not_found' using errcode = 'P0002';
    end if;
    update public.content_item_reference_categories l
    set reference_category_id = p_reassign_to
    where l.reference_category_id = p_id;
    get diagnostics v_moved = row_count;
  elsif v_mode = 'archive_articles' then
    if v_published > 0 then
      -- Refuse silent wipe of live articles; archive them first.
      update public.content_items c set
        status = 'archived',
        row_version = c.row_version + 1,
        version_number = c.version_number + 1,
        updated_by = v_uid,
        updated_at = now()
      where c.id in (
        select l.content_item_id
        from public.content_item_reference_categories l
        where l.reference_category_id = p_id
      ) and c.status <> 'archived';
      get diagnostics v_moved = row_count;
    end if;
    delete from public.content_item_reference_categories
    where reference_category_id = p_id;
  end if;

  -- Tombstone bootstrap identity when key looks like legacy.
  if v_row.key like 'legacy:%' or v_row.key like 'demo:%' then
    insert into public.content_legacy_tombstones (
      resource_kind, legacy_key, deleted_by, meta
    ) values (
      'reference_category', v_row.key, v_uid,
      jsonb_build_object('title', v_row.title)
    )
    on conflict (resource_kind, legacy_key) do update
      set deleted_at = now(),
          deleted_by = excluded.deleted_by,
          meta = excluded.meta;
  end if;

  delete from public.reference_categories where id = p_id;

  perform private.content_write_domain_audit(
    'reference.safe_delete_category',
    'reference_category',
    p_id,
    jsonb_build_object(
      'mode', v_mode,
      'article_total', v_total,
      'published_before', v_published,
      'moved_or_archived', v_moved,
      'reassign_to', p_reassign_to,
      'legacy_key', v_row.key
    )
  );

  return jsonb_build_object(
    'deleted', true,
    'id', p_id,
    'mode', v_mode,
    'article_total', v_total,
    'moved_or_archived', v_moved
  );
end;
$$;

revoke all on function public.admin_safe_delete_reference_category(
  uuid, integer, text, uuid
) from public, anon;
grant execute on function public.admin_safe_delete_reference_category(
  uuid, integer, text, uuid
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Audience preview lens (masked)
-- ---------------------------------------------------------------------------
create or replace function public.admin_preview_content_audience_lens(
  p_id uuid,
  p_lens text default 'self',
  p_group_id uuid default null,
  p_user_id uuid default null,
  p_at timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_lens text := nullif(btrim(coalesce(p_lens, '')), '');
  v_at timestamptz := coalesce(p_at, now());
  v_row public.content_items;
  v_visible boolean := false;
  v_label text := '';
  v_mask text := '';
begin
  v_uid := private.require_admin_permission('content.read');
  if v_lens is null or v_lens not in ('self', 'group', 'user') then
    raise exception 'invalid_lens' using errcode = '22023';
  end if;

  select * into v_row from public.content_items where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_lens = 'user' then
    -- Stricter permission for peering into another user's eligibility.
    perform private.require_admin_permission('content.publish');
    if p_user_id is null then
      raise exception 'user_id_required' using errcode = '22023';
    end if;
    select left(coalesce(nullif(btrim(u.name || ' ' || u.surname), ''), u.login, 'u'), 1) || '***'
      into v_mask
    from public.users u where u.id = p_user_id;
    if v_mask is null then
      raise exception 'user_not_found' using errcode = 'P0002';
    end if;
    v_label := 'Пользователь ' || v_mask;
    -- Schedule window approximated via deliverable + dismissal rules at now();
    -- p_at is returned for client display; full as-of schedule is a follow-up.
    v_visible := private.content_item_visible_to_user(p_id, p_user_id)
      and (v_row.starts_at is null or v_row.starts_at <= v_at)
      and (v_row.ends_at is null or v_row.ends_at > v_at);
  elsif v_lens = 'group' then
    if p_group_id is null then
      raise exception 'group_id_required' using errcode = '22023';
    end if;
    select coalesce(g.name, 'группа') into v_label
    from public.groups g where g.id = p_group_id;
    if v_label is null then
      raise exception 'group_not_found' using errcode = 'P0002';
    end if;
    v_visible := (
      v_row.status = 'published'
      and not v_row.is_hidden
      and (v_row.starts_at is null or v_row.starts_at <= v_at)
      and (v_row.ends_at is null or v_row.ends_at > v_at)
      and (
        v_row.audience_mode = 'all'
        or (
          v_row.audience_mode in ('groups', 'groups_and_users')
          and exists (
            select 1 from public.content_item_audience_groups ag
            where ag.content_item_id = p_id and ag.group_id = p_group_id
          )
        )
      )
    );
  else
    v_label := 'Текущий администратор';
    v_visible := private.content_item_visible_to_user(p_id, v_uid)
      and (v_row.starts_at is null or v_row.starts_at <= v_at)
      and (v_row.ends_at is null or v_row.ends_at > v_at);
  end if;

  return jsonb_build_object(
    'content_item_id', p_id,
    'lens', v_lens,
    'label', v_label,
    'visible', v_visible,
    'at', v_at,
    'status', v_row.status,
    'audience_mode', v_row.audience_mode
  );
end;
$$;

revoke all on function public.admin_preview_content_audience_lens(
  uuid, text, uuid, uuid, timestamptz
) from public, anon;
grant execute on function public.admin_preview_content_audience_lens(
  uuid, text, uuid, uuid, timestamptz
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Vacancy admin JSON: expose asset roles
-- ---------------------------------------------------------------------------
-- Soft: vacancy_to_admin_json already lists asset_ids; extend with typed assets
-- when function exists. Recreate thin enrichment via new helper used by clients.

create or replace function private.vacancy_assets_admin_json(p_vacancy_id uuid)
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
        'role', a.role,
        'is_draft_asset', (a.working_draft_id is not null)
      )
      order by a.created_at, a.id
    ),
    '[]'::jsonb
  )
  from public.vacancy_assets a
  where a.vacancy_id = p_vacancy_id;
$$;

revoke all on function private.vacancy_assets_admin_json(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_assets_admin_json(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 11. Working-draft publish: project CTA + v2 gate (extends 14.1.1 body)
-- ---------------------------------------------------------------------------
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
  v_eff integer;
  v_payload jsonb;
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

  v_payload := private.content_project_legacy_cta(v_draft.payload);
  v_eff := private.content_validate_working_draft_payload(
    v_row.template_key,
    v_row.schema_version,
    v_draft.target_schema_version,
    v_payload
  );
  perform private.content_assert_v2_publish_allowed(
    v_row.template_key, v_eff, v_payload
  );

  if v_draft.placement is not null then
    select t.allowed_placements into v_allowed
    from public.content_templates t
    where t.key = v_row.template_key
      and t.schema_version = v_eff;
    if v_allowed is null then
      select t.allowed_placements into v_allowed
      from public.content_templates t
      where t.key = v_row.template_key
        and t.schema_version = v_row.schema_version;
    end if;
    if not (v_draft.placement = any (coalesce(v_allowed, '{}'::text[]))) then
      raise exception 'placement_not_allowed_for_template' using errcode = '22023';
    end if;
  end if;

  update public.content_items c set
    schema_version = v_eff,
    title = v_draft.title,
    payload = v_payload,
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

  v_queued := private.content_queue_orphan_draft_assets(
    p_id, v_draft.draft_asset_ids, v_draft.title
  );

  delete from public.content_item_working_drafts where content_item_id = p_id;

  perform private.content_write_domain_audit(
    'content.publish_working_draft',
    'content_item',
    p_id,
    jsonb_build_object(
      'row_version', v_row.row_version,
      'version_number', v_row.version_number,
      'schema_version', v_row.schema_version,
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

commit;
