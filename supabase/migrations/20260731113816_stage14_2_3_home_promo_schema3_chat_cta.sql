-- Stage 14.2.3: home_promo_v1@3 (chat CTA), WD JSON overlay, chat resolve/list RPCs,
-- legacy projection strips chat without exposing UUIDs, HTTPS corpus helper.
-- Does NOT mutate schema-2 validators/allowlists. Does NOT delete live content.
-- Publish of schema >=2 remains gated by content_visual_studio_v2_publish.

-- ---------------------------------------------------------------------------
-- 1. Template: home_promo_v1 schema 3
-- ---------------------------------------------------------------------------
insert into public.content_templates (
  key, schema_version, title, allowed_placements, schema_doc, is_active
) values (
  'home_promo_v1', 3, 'Home promo card v3',
  array['home_promo']::text[],
  jsonb_build_object(
    'notes',
    'Additive v3: schema 2 visual fields + chat CTA (target_mode chat_id|current_group_chat). Publish gated by visual studio v2 flag.'
  ),
  true
)
on conflict (key, schema_version) do update
set title = excluded.title,
    allowed_placements = excluded.allowed_placements,
    schema_doc = excluded.schema_doc,
    is_active = true;

-- ---------------------------------------------------------------------------
-- 2. Shared HTTPS assert (schema-3 / corpus). Schema-2 URL checks unchanged.
-- ---------------------------------------------------------------------------
create or replace function private.content_assert_safe_https_url(p_url text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_url text := nullif(btrim(coalesce(p_url, '')), '');
  v_parsed text;
begin
  if v_url is null then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  if char_length(v_url) > 2048 then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  if v_url ~ '[[:cntrl:]]' then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  -- Reject any whitespace/control separators anywhere (parity with Flutter).
  if v_url ~ '[[:space:]]' then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  if v_url ~* '^(javascript|data|file|http):' then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  if left(v_url, 2) = '//' then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  if v_url !~* '^https://' then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  -- Reject credentials in authority (user:pass@host).
  if v_url ~* '^https://[^/]*@' then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  -- Non-empty host required (https:///path and https:// are invalid).
  v_parsed := substring(v_url from '^https://([^/?#]+)');
  if v_parsed is null or btrim(v_parsed) = '' then
    raise exception 'invalid_action_url' using errcode = '22023';
  end if;
  return v_url;
end;
$$;

revoke all on function private.content_assert_safe_https_url(text)
  from public, anon, authenticated;
grant execute on function private.content_assert_safe_https_url(text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 3. Structured action: optional chat kinds (schema 3 only via p_allow_chat)
-- ---------------------------------------------------------------------------
drop function if exists private.content_assert_structured_action(jsonb);

create or replace function private.content_assert_structured_action(
  p_payload jsonb,
  p_allow_chat boolean
)
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
  v_target_mode text;
  v_keys text[];
begin
  if not (p_payload ? 'action') then
    return;
  end if;
  v_action := p_payload -> 'action';
  if jsonb_typeof(v_action) <> 'object' then
    raise exception 'invalid_action_object' using errcode = '22023';
  end if;

  v_keys := array['kind', 'screen_key', 'target_id', 'url'];
  if p_allow_chat then
    v_keys := v_keys || array['target_mode'];
  end if;
  perform private.content_assert_allowed_keys(v_action, v_keys);

  v_kind := nullif(btrim(coalesce(v_action ->> 'kind', '')), '');
  if v_kind is null then
    raise exception 'invalid_action_kind' using errcode = '22023';
  end if;

  if p_allow_chat then
    if v_kind not in (
      'app_screen', 'reference_article', 'subject', 'vacancy',
      'external_url', 'none', 'chat'
    ) then
      raise exception 'invalid_action_kind' using errcode = '22023';
    end if;
  else
    if v_kind not in (
      'app_screen', 'reference_article', 'subject', 'vacancy',
      'external_url', 'none'
    ) then
      raise exception 'invalid_action_kind' using errcode = '22023';
    end if;
  end if;

  v_screen := nullif(btrim(coalesce(v_action ->> 'screen_key', '')), '');
  v_url := nullif(btrim(coalesce(v_action ->> 'url', '')), '');
  v_target_mode := nullif(btrim(coalesce(v_action ->> 'target_mode', '')), '');
  begin
    v_target := nullif(btrim(coalesce(v_action ->> 'target_id', '')), '')::uuid;
  exception when others then
    raise exception 'invalid_action_target_id' using errcode = '22023';
  end;

  if v_kind = 'none' then
    if v_screen is not null or v_target is not null or v_url is not null
       or v_target_mode is not null then
      raise exception 'action_none_has_targets' using errcode = '22023';
    end if;
  elsif v_kind = 'app_screen' then
    if v_screen is null or v_screen <> all (private.content_allowed_app_screens()) then
      raise exception 'invalid_action_screen' using errcode = '22023';
    end if;
    if v_target is not null or v_url is not null or v_target_mode is not null then
      raise exception 'action_screen_extra_targets' using errcode = '22023';
    end if;
  elsif v_kind in ('reference_article', 'subject', 'vacancy') then
    if v_target is null then
      raise exception 'action_target_required' using errcode = '22023';
    end if;
    if v_screen is not null or v_url is not null or v_target_mode is not null then
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
    if v_screen is not null or v_target is not null or v_target_mode is not null then
      raise exception 'action_url_extra_targets' using errcode = '22023';
    end if;
    if p_allow_chat then
      perform private.content_assert_safe_https_url(v_url);
    else
      if v_url is null or char_length(v_url) > 500
         or v_url !~* '^https://' then
        raise exception 'invalid_action_url' using errcode = '22023';
      end if;
    end if;
  elsif v_kind = 'chat' then
    if not p_allow_chat then
      raise exception 'invalid_action_kind' using errcode = '22023';
    end if;
    if v_screen is not null or v_url is not null then
      raise exception 'action_chat_extra_targets' using errcode = '22023';
    end if;
    if v_target_mode is null
       or v_target_mode not in ('chat_id', 'current_group_chat') then
      raise exception 'invalid_action_chat_target_mode' using errcode = '22023';
    end if;
    if v_target_mode = 'chat_id' then
      if v_target is null then
        raise exception 'action_target_required' using errcode = '22023';
      end if;
      if not exists (
        select 1
        from public.chats c
        join public.teams t on t.id = c.team_id
        where c.id = v_target
          and c.type = 'team_main'
          and t.kind in ('group_space', 'subject')
          and not exists (
            select 1 from public.chat_academic_archives a
            where a.chat_id = c.id
          )
      ) then
        raise exception 'action_chat_not_found' using errcode = 'P0002';
      end if;
    else
      if v_target is not null then
        raise exception 'action_chat_current_group_has_target' using errcode = '22023';
      end if;
    end if;
  end if;

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
  elsif v_kind in ('none', 'chat') then
    if v_route is not null or v_legacy_url is not null then
      raise exception 'action_legacy_conflict' using errcode = '22023';
    end if;
  end if;
end;
$$;

revoke all on function private.content_assert_structured_action(jsonb, boolean)
  from public, anon, authenticated;
grant execute on function private.content_assert_structured_action(jsonb, boolean)
  to service_role;

-- Keep single-arg call sites working (schema 2: no chat).
create or replace function private.content_assert_structured_action(p_payload jsonb)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.content_assert_structured_action(p_payload, false);
end;
$$;

revoke all on function private.content_assert_structured_action(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_assert_structured_action(jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- 4. Legacy CTA projection: chat → strip route/url (CTA disabled for legacy)
-- ---------------------------------------------------------------------------
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
  elsif v_kind in ('none', 'chat') then
    v_payload := v_payload - 'cta_route' - 'cta_url';
  end if;
  return v_payload;
end;
$$;

revoke all on function private.content_project_legacy_cta(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_project_legacy_cta(jsonb)
  to service_role;

-- Student wire helper: for chat actions, strip legacy cta_route/cta_url so
-- UUIDs never appear in legacy fields. Keeps action.chat for updated Mobile;
-- legacy apps fail-closed on unknown kind.
create or replace function private.content_sanitize_student_home_payload(p_payload jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_action jsonb;
  v_kind text;
begin
  if not (v_payload ? 'action') then
    return v_payload;
  end if;
  v_action := v_payload -> 'action';
  if jsonb_typeof(v_action) <> 'object' then
    return v_payload - 'action';
  end if;
  v_kind := nullif(btrim(coalesce(v_action ->> 'kind', '')), '');
  if v_kind = 'chat' then
    v_payload := v_payload - 'cta_route' - 'cta_url';
  end if;
  return v_payload;
end;
$$;

revoke all on function private.content_sanitize_student_home_payload(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_sanitize_student_home_payload(jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- 5. Visual v2 fields: optional allow_chat for schema 3
-- Body matches Stage 14.1.2 production allowlists; only adds p_allow_chat.
-- ---------------------------------------------------------------------------
drop function if exists private.content_assert_visual_v2_fields(jsonb);

create or replace function private.content_assert_visual_v2_fields(
  p_payload jsonb,
  p_allow_chat boolean
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
  perform private.content_assert_structured_action(p_payload, p_allow_chat);
end;
$$;

revoke all on function private.content_assert_visual_v2_fields(jsonb, boolean)
  from public, anon, authenticated;
grant execute on function private.content_assert_visual_v2_fields(jsonb, boolean)
  to service_role;

create or replace function private.content_assert_visual_v2_fields(p_payload jsonb)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.content_assert_visual_v2_fields(p_payload, false);
end;
$$;

revoke all on function private.content_assert_visual_v2_fields(jsonb)
  from public, anon, authenticated;
grant execute on function private.content_assert_visual_v2_fields(jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- 6. WD effective schema: home 1→2, 2→3, 1→3
-- ---------------------------------------------------------------------------
create or replace function private.content_working_draft_effective_schema(
  p_canonical_template text,
  p_canonical_schema integer,
  p_target integer
)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_target is null then
    return p_canonical_schema;
  end if;

  if p_canonical_template = 'reference_article_v1'
     and p_canonical_schema in (1, 2)
     and p_target = 3 then
    return 3;
  end if;

  if p_canonical_template = 'home_promo_v1' then
    if p_canonical_schema = 1 and p_target = 2 then
      return 2;
    end if;
    if p_canonical_schema in (1, 2) and p_target = 3 then
      return 3;
    end if;
    if p_canonical_schema = 2 and p_target = 2 then
      return 2;
    end if;
    if p_canonical_schema = 3 and p_target = 3 then
      return 3;
    end if;
  end if;

  if p_canonical_template = 'profile_feed_card_v1'
     and p_canonical_schema = 1
     and p_target = 2 then
    return 2;
  end if;

  if p_target = p_canonical_schema then
    return p_target;
  end if;

  raise exception 'invalid_schema_upgrade' using errcode = '22023';
end;
$$;

revoke all on function private.content_working_draft_effective_schema(text, integer, integer)
  from public, anon, authenticated;
grant execute on function private.content_working_draft_effective_schema(text, integer, integer)
  to service_role;

comment on function private.content_working_draft_effective_schema(text, integer, integer) is
  'Stage 14.2.3: WD schema; home_promo 1→2|3 and 2→3; profile 1→2; reference →3.';

-- ---------------------------------------------------------------------------
-- 7. validate_content_payload: add home_promo schema 3 (schema 2 unchanged)
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
    perform private.content_assert_visual_v2_fields(v_payload, false);
    perform private.content_assert_cta(
      private.content_optional_text(v_payload, 'cta_route', 300),
      private.content_optional_text(v_payload, 'cta_url', 500)
    );

  elsif p_template_key = 'home_promo_v1' and p_schema_version = 3 then
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
    perform private.content_assert_visual_v2_fields(v_payload, true);
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
    perform private.content_assert_visual_v2_fields(v_payload, false);
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

-- ---------------------------------------------------------------------------
-- 8. Admin JSON: include working_draft object for list overlay / resume
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
  v_draft public.content_item_working_drafts;
  v_has_draft boolean := false;
  v_base jsonb;
begin
  select * into v_row from public.content_items where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_draft
  from public.content_item_working_drafts d
  where d.content_item_id = p_id;
  v_has_draft := found;

  v_base := jsonb_build_object(
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

  if v_has_draft then
    v_base := v_base || jsonb_build_object(
      'working_draft', private.content_working_draft_to_json(v_draft)
    );
  end if;

  return v_base;
end;
$$;

revoke all on function private.content_item_to_admin_json(uuid)
  from public, anon, authenticated;
grant execute on function private.content_item_to_admin_json(uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- 9. Student placement feed: project schema 2|3 → wire 1; sanitize chat
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

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', ci.id,
          'template_key', ci.template_key,
          'schema_version', case
            when ci.template_key in ('home_promo_v1', 'profile_feed_card_v1')
                 and ci.schema_version in (2, 3)
              then 1
            else ci.schema_version
          end,
          'placement', pl.placement,
          'sort_order', pl.sort_order,
          'priority', ci.priority,
          'origin', ci.origin,
          'title', ci.title,
          'payload', case
            when ci.template_key = 'home_promo_v1'
              then private.content_sanitize_student_home_payload(ci.payload)
            else ci.payload
          end,
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

comment on function public.get_my_content_for_placement(text) is
  'Student placement feed. Stage 14.2.3: wire schema 2|3 home/profile as 1; payload keeps dual-read action (legacy apps fail-closed on unknown chat; no chat UUID in cta_route/url).';

-- ---------------------------------------------------------------------------
-- 10. Admin chat target picker (content.write)
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_content_chat_targets(p_query text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
begin
  v_uid := private.require_admin_permission('content.write');
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'chat_id', s.chat_id,
          'title', s.title,
          'chat_kind_label', s.chat_kind_label,
          'is_active', true
        )
        order by s.title, s.chat_id
      )
      from (
        select
          c.id as chat_id,
          coalesce(nullif(btrim(t.name), ''), 'Чат') as title,
          case
            when t.kind = 'group_space' then 'Общий чат группы'
            when t.kind = 'subject' then 'Предметный чат'
            else 'Командный чат'
          end as chat_kind_label
        from public.chats c
        join public.teams t on t.id = c.team_id
        where c.type = 'team_main'
          and t.kind in ('group_space', 'subject')
          and not exists (
            select 1 from public.chat_academic_archives a where a.chat_id = c.id
          )
          and (
            v_q is null
            or t.name ilike ('%' || v_q || '%')
          )
        order by t.name, c.id
        limit 100
      ) s
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.admin_list_content_chat_targets(text)
  from public, anon;
grant execute on function public.admin_list_content_chat_targets(text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 11. Mobile atomic chat CTA authorize/resolve
-- ---------------------------------------------------------------------------
create or replace function public.content_resolve_chat_cta(
  p_target_mode text,
  p_target_id uuid default null
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_mode text := nullif(btrim(coalesce(p_target_mode, '')), '');
  v_chat uuid;
  v_team uuid;
  v_kind text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.users u where u.id = v_uid and u.is_active) then
    raise exception 'chat_cta_unavailable' using errcode = 'P0001';
  end if;

  if v_mode is null or v_mode not in ('chat_id', 'current_group_chat') then
    raise exception 'chat_cta_unavailable' using errcode = 'P0001';
  end if;

  if v_mode = 'current_group_chat' then
    if p_target_id is not null then
      raise exception 'chat_cta_unavailable' using errcode = 'P0001';
    end if;
    select (public.get_my_group_space() ->> 'chat_id')::uuid into v_chat;
    if v_chat is null then
      raise exception 'chat_cta_unavailable' using errcode = 'P0001';
    end if;
  else
    if p_target_id is null then
      raise exception 'chat_cta_unavailable' using errcode = 'P0001';
    end if;
    v_chat := p_target_id;
  end if;

  select c.team_id, t.kind
    into v_team, v_kind
  from public.chats c
  join public.teams t on t.id = c.team_id
  where c.id = v_chat
    and c.type = 'team_main'
    and t.kind in ('group_space', 'subject');

  if v_team is null then
    raise exception 'chat_cta_unavailable' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.chat_academic_archives a where a.chat_id = v_chat
  ) then
    raise exception 'chat_cta_unavailable' using errcode = 'P0001';
  end if;

  if not exists (
    select 1 from public.team_members tm
    where tm.team_id = v_team and tm.user_id = v_uid
  ) and not exists (
    select 1 from public.chat_members cm
    where cm.chat_id = v_chat and cm.user_id = v_uid
  ) then
    raise exception 'chat_cta_unavailable' using errcode = 'P0001';
  end if;

  return v_chat;
end;
$$;

revoke all on function public.content_resolve_chat_cta(text, uuid)
  from public, anon;
grant execute on function public.content_resolve_chat_cta(text, uuid)
  to authenticated, service_role;

comment on function public.content_resolve_chat_cta(text, uuid) is
  'Stage 14.2.3: atomic membership+archive authorize for content chat CTA; returns concrete chat_id only.';
