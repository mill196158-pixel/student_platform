-- Stage 14A behavioral role-play (disposable transaction).
-- Requires local apply of 20260729133000_stage14_managed_content_foundation.sql
-- Never run against production / never --linked.
-- Fixture absence => explicit BLOCKED notice (not silent PASS).

begin;

do $$
declare
  v_admin uuid;
  v_student uuid;
  v_blocked uuid;
  v_item uuid;
  v_item2 uuid;
  v_row_version int;
  v_rv2 int;
  v_json jsonb;
  v_preview jsonb;
  v_payload jsonb := jsonb_build_object(
    'title', 'Test promo',
    'subtitle', 'Hello subtitle',
    'icon_key', 'help',
    'gradient_colors', jsonb_build_array('#7367F0', '#B784F7'),
    'cta_label', 'Open',
    'cta_route', '/diary',
    'dismissible', true
  );
  v_payload2 jsonb := jsonb_build_object(
    'title', 'No dismiss',
    'subtitle', 'Locked card',
    'icon_key', 'info',
    'gradient_colors', jsonb_build_array('#7367F0', '#B784F7'),
    'cta_label', 'Go',
    'cta_route', '/info',
    'dismissible', false
  );
begin
  -- Admin must have content.write + content.publish
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
  limit 1;

  select se.user_id into v_student
  from public.student_enrollments se
  join public.users u on u.id = se.user_id and u.is_active
  where se.status = 'active'
    and se.ended_at is null
    and se.user_id is distinct from v_admin
  limit 1;

  select u.id into v_blocked
  from public.users u
  where u.is_active is not true
     or not exists (
       select 1 from public.student_enrollments se
       where se.user_id = u.id and se.status = 'active' and se.ended_at is null
     )
  limit 1;

  if v_admin is null or v_student is null then
    raise notice 'stage14 roleplay BLOCKED: missing content.* admin or enrolled student fixtures';
    return;
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_json := public.admin_create_content_draft(
    'home_promo_v1', 1, 'Test promo', v_payload, 'admin'
  );
  v_item := (v_json->>'id')::uuid;
  v_row_version := (v_json->>'row_version')::int;

  v_json := public.admin_set_content_placements(
    v_item,
    jsonb_build_array(jsonb_build_object('placement', 'home_promo', 'sort_order', 0)),
    v_row_version
  );
  v_row_version := (v_json->>'row_version')::int;

  begin
    perform public.admin_update_content_draft(
      v_item,
      jsonb_build_object(
        'payload', v_payload || jsonb_build_object('evil', true)
      ),
      v_row_version
    );
    raise exception 'expected unknown payload field failure';
  exception when others then
    if sqlerrm not like '%unknown%'
       and sqlerrm not like '%invalid%'
       and sqlerrm not like '%field%'
       and sqlerrm not like '%allowed%' then
      raise;
    end if;
  end;

  if v_blocked is not null then
    begin
      perform public.admin_set_content_audience(
        v_item, 'users', '{}'::uuid[], array[v_blocked], v_row_version
      );
      raise exception 'expected ineligible audience user failure';
    exception when others then
      if sqlerrm not like 'ineligible_audience_user%'
         and sqlerrm not like 'unknown_or_inactive_user%' then
        raise;
      end if;
    end;
  end if;

  v_json := public.admin_set_content_audience(
    v_item, 'users', '{}'::uuid[], array[v_student], v_row_version
  );
  v_row_version := (v_json->>'row_version')::int;

  v_preview := public.admin_preview_content_audience(v_item);
  if coalesce((v_preview->>'recipient_count')::int, 0) < 1 then
    raise exception 'preview count expected >= 1 for eligible student';
  end if;
  if coalesce((v_preview->'breakdown'->>'explicit_users_count')::int, 0) < 1 then
    raise exception 'explicit_users_count expected >= 1';
  end if;

  v_json := public.admin_publish_content(v_item, v_row_version);
  v_row_version := (v_json->>'row_version')::int;

  begin
    perform public.admin_update_content_draft(
      v_item, jsonb_build_object('title', 'hack live'), v_row_version
    );
    raise exception 'expected draft_only on published update';
  exception when others then
    if sqlerrm not like 'draft_only%' then
      raise;
    end if;
  end;

  perform set_config('request.jwt.claim.sub', v_student::text, true);
  v_json := public.get_my_content_for_placement('home_promo');
  if not exists (
    select 1 from jsonb_array_elements(v_json) e where e->>'id' = v_item::text
  ) then
    raise exception 'student should see targeted promo';
  end if;

  perform public.dismiss_content_item(v_item);

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_json := public.admin_create_content_draft(
    'home_promo_v1', 1, 'No dismiss', v_payload2, 'admin'
  );
  v_item2 := (v_json->>'id')::uuid;
  v_rv2 := (v_json->>'row_version')::int;

  v_json := public.admin_set_content_placements(
    v_item2,
    jsonb_build_array(jsonb_build_object('placement', 'home_promo', 'sort_order', 1)),
    v_rv2
  );
  v_rv2 := (v_json->>'row_version')::int;

  v_json := public.admin_set_content_audience(
    v_item2, 'all', '{}'::uuid[], '{}'::uuid[], v_rv2
  );
  v_rv2 := (v_json->>'row_version')::int;
  v_json := public.admin_publish_content(v_item2, v_rv2);
  v_rv2 := (v_json->>'row_version')::int;

  perform set_config('request.jwt.claim.sub', v_student::text, true);
  begin
    perform public.dismiss_content_item(v_item2);
    raise exception 'expected not_dismissible';
  exception when others then
    if sqlerrm not like 'not_dismissible%' then
      raise;
    end if;
  end;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_json := public.admin_archive_content(v_item2, v_rv2);
  v_rv2 := (v_json->>'row_version')::int;
  perform public.admin_safe_delete_content(v_item2, v_rv2);

  begin
    perform public.admin_safe_delete_content(v_item, v_row_version);
    raise exception 'safe_delete should require archived';
  exception when others then
    if sqlerrm not like '%archiv%' and sqlerrm not like 'safe_delete%' then
      raise;
    end if;
  end;

  v_json := public.admin_archive_content(v_item, v_row_version);
  v_row_version := (v_json->>'row_version')::int;
  v_json := public.admin_safe_delete_content(v_item, v_row_version);
  if coalesce((v_json->>'deleted')::boolean, false) is not true
     and coalesce((v_json->>'ok')::boolean, false) is not true then
    raise exception 'safe_delete failed: %', v_json;
  end if;

  perform private.content_purge_old_events(30);

  raise notice 'stage14_managed_content_roleplay PASS';
end
$$;

rollback;
