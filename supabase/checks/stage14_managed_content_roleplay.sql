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

-- ---------------------------------------------------------------------------
-- Asserted scenario matrix (results-table pattern, as in
-- stage13_local_runtime_roleplay.sql): direct-table denial, empty targeted
-- audience, row_version conflict, draft/hidden/archived invisibility,
-- dismiss + event dedupe via event_hour, safe-delete cleanup queue.
-- ---------------------------------------------------------------------------
create temporary table if not exists stage14_roleplay_results (
  scenario text primary key,
  status text not null check (status in ('PASS', 'FAIL', 'SKIP')),
  detail text not null default ''
) on commit drop;

-- Scenarios switch to the authenticated role; keep result logging writable.
grant all on table stage14_roleplay_results to authenticated, anon, service_role;

create or replace function pg_temp.rp_pass(
  p_scenario text,
  p_ok boolean,
  p_detail text default ''
)
returns void
language plpgsql as $fn$
begin
  insert into stage14_roleplay_results(scenario, status, detail)
  values (p_scenario, case when p_ok then 'PASS' else 'FAIL' end, coalesce(p_detail, ''))
  on conflict (scenario) do update
    set status = excluded.status, detail = excluded.detail;
end;
$fn$;

create or replace function pg_temp.rp_expect_exception(
  p_scenario text,
  p_sql text,
  p_errcode text default null,
  p_message_like text default null
)
returns void
language plpgsql as $fn$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
    perform pg_temp.rp_pass(p_scenario, false, 'expected exception, got success');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform pg_temp.rp_pass(
      p_scenario,
      (p_errcode is null or v_state = p_errcode)
        and (p_message_like is null or v_msg ilike '%' || p_message_like || '%'),
      format('state=%s msg=%s', v_state, v_msg)
    );
  end;
end;
$fn$;

create or replace function pg_temp.rp_as_user(p_user_id uuid)
returns void
language plpgsql as $fn$
begin
  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_user_id::text, 'role', 'authenticated')::text,
    true
  );
end;
$fn$;

do $$
declare
  v_admin uuid;
  v_student uuid;
  v_group uuid;
  v_empty_group uuid;
  v_item uuid;
  v_hidden uuid;
  v_rv int;
  v_json jsonb;
  v_first jsonb;
  v_second jsonb;
  v_title text;
  v_events int;
  v_queued int;
  v_asset uuid;
  v_payload jsonb := jsonb_build_object(
    'title', 'Asserted promo',
    'subtitle', 'Asserted subtitle',
    'icon_key', 'help',
    'gradient_colors', jsonb_build_array('#7367F0', '#B784F7'),
    'cta_label', 'Open',
    'cta_route', '/diary',
    'dismissible', true,
    'reshow_after_hours', 2
  );
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
  limit 1;

  select se.user_id, se.group_id into v_student, v_group
  from public.student_enrollments se
  join public.users u on u.id = se.user_id and u.is_active
  where se.status = 'active'
    and se.ended_at is null
    and se.user_id is distinct from v_admin
  limit 1;

  if v_admin is null or v_student is null then
    insert into stage14_roleplay_results(scenario, status, detail)
    values (
      '00 fixtures',
      'SKIP',
      'BLOCKED: missing content.* admin or enrolled student fixtures'
    )
    on conflict (scenario) do update
      set status = excluded.status, detail = excluded.detail;
    raise notice 'stage14 asserted scenarios BLOCKED: missing content.* admin or enrolled student fixtures';
    return;
  end if;

  -- 01 No direct table DML for a signed-in student.
  perform pg_temp.rp_as_user(v_student);
  perform set_config('role', 'authenticated', true);
  perform pg_temp.rp_expect_exception(
    '01a student cannot select content_items directly',
    'select count(*) from public.content_items',
    '42501'
  );
  perform pg_temp.rp_expect_exception(
    '01b student cannot insert content_item_events directly',
    format(
      $sql$insert into public.content_item_events(
        content_item_id, user_id, event_type, event_hour
      ) values (gen_random_uuid(), %L::uuid, 'impression', now())$sql$,
      v_student
    ),
    '42501'
  );
  perform pg_temp.rp_expect_exception(
    '01c student cannot read content_audit_log directly',
    'select count(*) from public.content_audit_log',
    '42501'
  );
  perform pg_temp.rp_expect_exception(
    '01d student cannot call an admin content RPC',
    'select public.admin_list_content_items()',
    '42501',
    'forbidden'
  );
  perform set_config('role', 'postgres', true);

  -- 02 Publish must reject a targeted audience that resolves to nobody.
  insert into public.groups(name) values ('STAGE14-RP-EMPTY')
  returning id into v_empty_group;

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_create_content_draft(
    'home_promo_v1', 1, 'Asserted promo', v_payload, 'admin'
  );
  v_item := (v_json ->> 'id')::uuid;
  v_rv := (v_json ->> 'row_version')::int;

  v_json := public.admin_set_content_placements(
    v_item,
    jsonb_build_array(jsonb_build_object('placement', 'home_promo', 'sort_order', 0)),
    v_rv
  );
  v_rv := (v_json ->> 'row_version')::int;

  v_json := public.admin_set_content_audience(
    v_item, 'groups', array[v_empty_group], '{}'::uuid[], v_rv
  );
  v_rv := (v_json ->> 'row_version')::int;

  v_json := public.admin_preview_content_audience(v_item);
  perform pg_temp.rp_pass(
    '02a preview reports zero recipients and never lists students',
    coalesce((v_json ->> 'recipient_count')::int, -1) = 0
      and v_json -> 'breakdown' ? 'groups'
      and v_json -> 'breakdown' ? 'explicit_users_count'
      and not (v_json -> 'breakdown' ? 'users'),
    v_json::text
  );

  perform pg_temp.rp_expect_exception(
    '02b publish rejected for empty targeted audience',
    format($sql$select public.admin_publish_content(%L::uuid, %s)$sql$, v_item, v_rv),
    'P0001',
    'empty_audience'
  );

  -- 03 Optimistic concurrency: stale row_version must write nothing.
  perform set_config('role', 'postgres', true);
  select title into v_title from public.content_items where id = v_item;
  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_exception(
    '03a stale row_version on update is a conflict',
    format(
      $sql$select public.admin_update_content_draft(
        %L::uuid, '{"title":"conflict write"}'::jsonb, %s
      )$sql$,
      v_item, v_rv - 1
    ),
    'P0001',
    'row_version_conflict'
  );
  perform pg_temp.rp_pass(
    '03b conflicting update left no partial write',
    (select title from public.content_items where id = v_item) = v_title
      and (select row_version from public.content_items where id = v_item) = v_rv,
    format('title=%s rv=%s', v_title, v_rv)
  );

  -- 04 Draft / hidden / archived must never reach the mobile RPC.
  perform pg_temp.rp_as_user(v_student);
  v_json := public.get_my_content_for_placement('home_promo');
  perform pg_temp.rp_pass(
    '04a draft item is not in the mobile list',
    not exists (
      select 1 from jsonb_array_elements(v_json) e where e ->> 'id' = v_item::text
    ),
    v_json::text
  );

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_set_content_audience(
    v_item, 'groups', array[v_group], '{}'::uuid[], v_rv
  );
  v_rv := (v_json ->> 'row_version')::int;
  v_json := public.admin_publish_content(v_item, v_rv);
  v_rv := (v_json ->> 'row_version')::int;

  perform pg_temp.rp_as_user(v_student);
  v_json := public.get_my_content_for_placement('home_promo');
  perform pg_temp.rp_pass(
    '04b published + targeted item is visible with typed fields',
    exists (
      select 1
      from jsonb_array_elements(v_json) e
      where e ->> 'id' = v_item::text
        and e ->> 'template_key' = 'home_promo_v1'
        and (e ->> 'dismissible')::boolean
        and e -> 'payload' ->> 'cta_route' = '/diary'
    ),
    v_json::text
  );

  -- Hidden item: is_hidden is set while still a draft, then published.
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_create_content_draft(
    'home_promo_v1', 1, 'Hidden promo', v_payload, 'admin'
  );
  v_hidden := (v_json ->> 'id')::uuid;
  v_json := public.admin_set_content_placements(
    v_hidden,
    jsonb_build_array(jsonb_build_object('placement', 'home_promo', 'sort_order', 1)),
    (v_json ->> 'row_version')::int
  );
  v_json := public.admin_update_content_draft(
    v_hidden, '{"is_hidden":true}'::jsonb, (v_json ->> 'row_version')::int
  );
  v_json := public.admin_publish_content(v_hidden, (v_json ->> 'row_version')::int);

  perform pg_temp.rp_as_user(v_student);
  v_json := public.get_my_content_for_placement('home_promo');
  perform pg_temp.rp_pass(
    '04c hidden item is not in the mobile list',
    not exists (
      select 1 from jsonb_array_elements(v_json) e where e ->> 'id' = v_hidden::text
    ),
    v_json::text
  );

  perform pg_temp.rp_as_user(v_admin);
  perform set_config('role', 'postgres', true);
  v_json := public.admin_archive_content(
    v_hidden, (select row_version from public.content_items where id = v_hidden)
  );
  perform pg_temp.rp_as_user(v_student);
  v_json := public.get_my_content_for_placement('home_promo');
  perform pg_temp.rp_pass(
    '04d archived item is not in the mobile list',
    not exists (
      select 1 from jsonb_array_elements(v_json) e where e ->> 'id' = v_hidden::text
    ),
    v_json::text
  );

  -- 05 Events: allowlist + UTC hour-bucket dedupe.
  perform pg_temp.rp_expect_exception(
    '05a event type outside the allowlist is rejected',
    format($sql$select public.record_content_event(%L::uuid, 'purchase')$sql$, v_item),
    '22023',
    'invalid_event'
  );

  v_first := public.record_content_event(v_item, 'impression');
  v_second := public.record_content_event(v_item, 'impression');
  perform pg_temp.rp_pass(
    '05b repeat event in the same hour is a no-op duplicate',
    coalesce((v_first ->> 'duplicate')::boolean, true) = false
      and coalesce((v_second ->> 'duplicate')::boolean, false) = true,
    format('%s / %s', v_first::text, v_second::text)
  );

  perform set_config('role', 'postgres', true);
  select count(*)::int into v_events
  from public.content_item_events e
  where e.content_item_id = v_item
    and e.user_id = v_student
    and e.event_type = 'impression'
    and e.event_hour = date_trunc('hour', timezone('utc', now())) at time zone 'utc';
  perform pg_temp.rp_pass(
    '05c exactly one event row exists for the UTC hour bucket',
    v_events = 1,
    format('rows=%s', v_events)
  );

  -- 06 Dismiss hides the card and blocks further events.
  perform pg_temp.rp_as_user(v_student);
  v_json := public.dismiss_content_item(v_item);
  perform pg_temp.rp_pass(
    '06a dismiss stores a reshow deadline from the payload policy',
    (v_json ->> 'can_reshow_after') is not null,
    v_json::text
  );

  v_json := public.get_my_content_for_placement('home_promo');
  perform pg_temp.rp_pass(
    '06b dismissed item disappears from the mobile list',
    not exists (
      select 1 from jsonb_array_elements(v_json) e where e ->> 'id' = v_item::text
    ),
    v_json::text
  );

  perform pg_temp.rp_expect_exception(
    '06c dismissed item cannot record events',
    format($sql$select public.record_content_event(%L::uuid, 'click')$sql$, v_item),
    'P0002',
    'not_found'
  );

  perform set_config('role', 'postgres', true);
  update public.content_item_dismissals
  set can_reshow_after = now() - interval '1 minute'
  where content_item_id = v_item and user_id = v_student;

  perform pg_temp.rp_as_user(v_student);
  v_json := public.get_my_content_for_placement('home_promo');
  perform pg_temp.rp_pass(
    '06d item reappears once can_reshow_after has passed',
    exists (
      select 1 from jsonb_array_elements(v_json) e where e ->> 'id' = v_item::text
    ),
    v_json::text
  );

  -- 07 Safe delete: archived only, and storage cleanup is queued first.
  perform set_config('role', 'postgres', true);
  insert into public.content_assets(
    content_item_id, storage_bucket, storage_path, mime_type, byte_size, created_by
  ) values (
    v_item, 'content-media', 'content/stage14-rp/asserted.png', 'image/png', 2048, v_admin
  )
  returning id into v_asset;

  select row_version into v_rv from public.content_items where id = v_item;
  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_exception(
    '07a safe delete rejected while the item is still published',
    format($sql$select public.admin_safe_delete_content(%L::uuid, %s)$sql$, v_item, v_rv),
    'P0001',
    'content_must_be_archived'
  );

  v_json := public.admin_archive_content(v_item, v_rv);
  v_rv := (v_json ->> 'row_version')::int;
  v_json := public.admin_safe_delete_content(v_item, v_rv);

  perform set_config('role', 'postgres', true);
  select count(*)::int into v_queued
  from public.content_media_cleanup_queue q
  where q.storage_path = 'content/stage14-rp/asserted.png'
    and q.processed_at is null;

  perform pg_temp.rp_pass(
    '07b safe delete queued media and removed item + children',
    coalesce((v_json ->> 'deleted')::boolean, false)
      and v_queued = 1
      and not exists (select 1 from public.content_items where id = v_item)
      and not exists (
        select 1 from public.content_item_versions where content_item_id = v_item
      )
      and not exists (select 1 from public.content_assets where id = v_asset)
      and not exists (
        select 1 from public.content_item_dismissals where content_item_id = v_item
      )
      and not exists (
        select 1 from public.content_item_events where content_item_id = v_item
      ),
    format('queued=%s result=%s', v_queued, v_json::text)
  );

  perform pg_temp.rp_pass(
    '07c safe delete wrote a domain audit tombstone',
    exists (
      select 1 from public.content_audit_log
      where entity_id = v_item and action = 'content.safe_delete'
    )
    and exists (
      select 1 from public.admin_audit_log
      where entity_id = v_item::text and action = 'content.safe_delete'
    ),
    ''
  );

  -- 08 Referenced template schema stays immutable.
  perform pg_temp.rp_expect_exception(
    '08a referenced template schema_doc is immutable',
    $sql$update public.content_templates
         set schema_doc = '{"mutated":true}'::jsonb
         where key = 'home_promo_v1' and schema_version = 1$sql$,
    '55000',
    'content_template_schema_immutable'
  );
  perform pg_temp.rp_expect_exception(
    '08b referenced template allowed_placements is immutable',
    $sql$update public.content_templates
         set allowed_placements = array['home_promo', 'reference']::text[]
         where key = 'home_promo_v1' and schema_version = 1$sql$,
    '55000',
    'content_template_schema_immutable'
  );

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
end
$$;

select scenario, status, detail
from stage14_roleplay_results
order by scenario;

select
  count(*) filter (where status = 'PASS') as pass_count,
  count(*) filter (where status = 'FAIL') as fail_count,
  count(*) filter (where status = 'SKIP') as skip_count,
  count(*) as total
from stage14_roleplay_results;

do $$
declare
  v_fail int;
  v_pass int;
  v_skip int;
  v_total int;
begin
  select
    count(*) filter (where status = 'FAIL'),
    count(*) filter (where status = 'PASS'),
    count(*) filter (where status = 'SKIP'),
    count(*)
  into v_fail, v_pass, v_skip, v_total
  from stage14_roleplay_results;

  if v_fail > 0 then
    raise exception 'stage14 asserted scenarios failed: %', (
      select string_agg(scenario || ': ' || detail, '; ' order by scenario)
      from stage14_roleplay_results where status = 'FAIL'
    );
  end if;

  -- Empty results or fixtures-only SKIP must never report PASS.
  if v_total = 0 then
    raise exception
      'stage14 asserted scenarios FAIL: results table empty (no scenarios recorded)';
  end if;
  if v_pass = 0 then
    raise exception
      'stage14 asserted scenarios BLOCKED/SKIP: pass=0 skip=% total=% (fixtures missing or no asserted run)',
      v_skip, v_total;
  end if;

  raise notice 'stage14_managed_content_roleplay ASSERTED_SCENARIOS PASS';
end
$$;

rollback;
