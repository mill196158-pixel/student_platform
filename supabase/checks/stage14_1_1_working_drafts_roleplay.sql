-- Stage 14.1.1 working-drafts behavioral role-play (disposable transaction).
-- Requires local apply of
--   20260730190000_stage14_1_1_working_drafts_and_reference_blocks.sql
-- Never run against production / never --linked.

begin;

do $$
declare
  v_admin uuid;
  v_item uuid;
  v_row_version int;
  v_draft_rv int;
  v_json jsonb;
  v_json2 jsonb;
  v_draft_id uuid;
  v_draft_id2 uuid;
  v_title text;
  v_payload jsonb := jsonb_build_object(
    'title', 'WD promo',
    'subtitle', 'Working draft test',
    'icon_key', 'help',
    'gradient_colors', jsonb_build_array('#7367F0', '#B784F7'),
    'cta_label', 'Open',
    'cta_route', '/diary',
    'dismissible', true
  );
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
  limit 1;

  if v_admin is null then
    raise exception 'stage14_1_1 roleplay BLOCKED: missing content.* admin fixture';
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  -- Create + publish a content item to edit via working draft.
  v_json := public.admin_create_content_draft(
    'home_promo_v1', 1, 'WD promo', v_payload, 'admin'
  );
  v_item := (v_json->>'id')::uuid;
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_set_content_placements(
    v_item,
    jsonb_build_array(jsonb_build_object('placement', 'home_promo', 'sort_order', 0)),
    v_row_version
  );
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_publish_content(v_item, v_row_version);
  v_row_version := (v_json->>'row_version')::int;

  if coalesce((v_json->>'has_working_draft')::boolean, true) then
    raise exception 'expected has_working_draft=false before begin_edit';
  end if;

  -- 1) begin_edit twice returns the SAME draft (no overwrite from production).
  v_json := public.admin_begin_content_edit(v_item);
  if coalesce((v_json->>'has_working_draft')::boolean, false) is not true then
    raise exception 'begin_edit missing has_working_draft';
  end if;
  if v_json->'working_draft' is null then
    raise exception 'begin_edit missing working_draft';
  end if;
  v_draft_id := (v_json->'working_draft'->>'id')::uuid;
  v_draft_rv := (v_json->'working_draft'->>'row_version')::int;
  v_title := v_json->'working_draft'->>'title';

  v_json := public.admin_save_content_working_draft(
    v_item,
    v_draft_rv,
    jsonb_build_object('title', 'WD promo EDITED')
  );
  v_draft_rv := (v_json->'working_draft'->>'row_version')::int;
  if v_json->'working_draft'->>'title' is distinct from 'WD promo EDITED' then
    raise exception 'save_working_draft did not persist title';
  end if;

  -- Canonical title must remain unchanged until publish.
  if (select title from public.content_items where id = v_item)
     is distinct from 'WD promo' then
    raise exception 'canonical title mutated before publish';
  end if;

  v_json2 := public.admin_begin_content_edit(v_item);
  v_draft_id2 := (v_json2->'working_draft'->>'id')::uuid;
  if v_draft_id2 is distinct from v_draft_id then
    raise exception 'second begin_edit created a new draft id';
  end if;
  if v_json2->'working_draft'->>'title' is distinct from 'WD promo EDITED' then
    raise exception 'second begin_edit overwrote draft from production';
  end if;

  -- 2) publish conflict when canonical row_version diverges.
  update public.content_items
  set row_version = row_version + 1,
      updated_at = now()
  where id = v_item;
  v_row_version := (
    select row_version from public.content_items where id = v_item
  );

  begin
    perform public.admin_publish_content_working_draft(v_item, v_draft_rv);
    raise exception 'expected canonical_changed_rebase_required';
  exception when others then
    if sqlerrm not like 'canonical_changed_rebase_required%' then
      raise;
    end if;
  end;

  -- Rebase: discard then begin again (simulates editor rebase).
  v_json := public.admin_discard_content_working_draft(v_item);
  if coalesce((v_json->>'has_working_draft')::boolean, true) then
    raise exception 'discard did not clear has_working_draft';
  end if;
  if exists (
    select 1 from public.content_item_working_drafts d
    where d.content_item_id = v_item
  ) then
    raise exception 'discard left working draft row';
  end if;

  v_json := public.admin_begin_content_edit(v_item);
  v_draft_id := (v_json->'working_draft'->>'id')::uuid;
  v_draft_rv := (v_json->'working_draft'->>'row_version')::int;
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_save_content_working_draft(
    v_item,
    v_draft_rv,
    jsonb_build_object('title', 'WD promo FINAL')
  );
  v_draft_rv := (v_json->'working_draft'->>'row_version')::int;

  -- 3) working_draft_exists blocks archive.
  begin
    perform public.admin_archive_content(v_item, v_row_version);
    raise exception 'expected working_draft_exists on archive';
  exception when others then
    if sqlerrm not like 'working_draft_exists%' then
      raise;
    end if;
  end;

  -- 4) publish succeeds when versions match; then archive works.
  v_json := public.admin_publish_content_working_draft(v_item, v_draft_rv);
  if coalesce((v_json->>'has_working_draft')::boolean, true) then
    raise exception 'publish left has_working_draft=true';
  end if;
  if v_json->>'title' is distinct from 'WD promo FINAL' then
    raise exception 'publish did not apply draft title';
  end if;
  v_row_version := (v_json->>'row_version')::int;

  if exists (
    select 1 from public.content_item_working_drafts d
    where d.content_item_id = v_item
  ) then
    raise exception 'publish left working draft row';
  end if;

  v_json := public.admin_archive_content(v_item, v_row_version);
  if v_json->>'status' is distinct from 'archived' then
    raise exception 'archive after discard/publish failed';
  end if;

  -- Schema v3 block validator smoke (private path).
  begin
    perform private.validate_content_payload(
      'reference_article_v1',
      3,
      jsonb_build_object(
        'icon_key', 'info',
        'short_text', 'Short',
        'blocks', jsonb_build_array(
          jsonb_build_object('type', 'heading', 'text', 'H', 'level', 2),
          jsonb_build_object('type', 'info', 'text', 'Note'),
          jsonb_build_object('type', 'warning', 'text', 'Warn'),
          jsonb_build_object(
            'type', 'list',
            'style', 'bullet',
            'items', jsonb_build_array('a', 'b')
          ),
          jsonb_build_object('type', 'text', 'text', 'Body')
        )
      )
    );
  exception when others then
    raise exception 'schema v3 validator failed: %', sqlerrm;
  end;

  -- Schema v2 must still reject heading.
  begin
    perform private.validate_content_payload(
      'reference_article_v1',
      2,
      jsonb_build_object(
        'icon_key', 'info',
        'short_text', 'Short',
        'blocks', jsonb_build_array(
          jsonb_build_object('type', 'heading', 'text', 'H', 'level', 1)
        )
      )
    );
    raise exception 'schema v2 should reject heading';
  exception when others then
    if sqlerrm like 'schema v2 should reject%' then
      raise;
    end if;
    if sqlerrm not like 'invalid_block_type_%'
       and sqlerrm not like '%heading%' then
      raise exception 'unexpected v2 rejection: %', sqlerrm;
    end if;
  end;

  raise notice 'STAGE14_1_1_WORKING_DRAFTS_ROLEPLAY PASS';
end $$;

rollback;
