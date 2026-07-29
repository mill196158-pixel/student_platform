-- Stage 15.2 news audience behavioral role-play (disposable transaction).
-- Requires local apply of 20260729140000_stage15_2_news_audience_extension.sql.
-- Never run against production / never --linked.
-- Fixture absence => explicit BLOCKED / SKIP rows (never a silent PASS).
--
-- Covers the locked SPEC 15.2 semantics end to end:
--   legacy all / legacy group / junctions-as-sole-source / OR of groups+users /
--   setter invariants and validation / draft-only audience edits / preview
--   safety / draft-hidden-archived never leaking / duplicate + restore keeping
--   the junction audience / no direct table or private-helper access.

begin;

create temporary table if not exists stage15_2_roleplay_results (
  scenario text primary key,
  status text not null check (status in ('PASS', 'FAIL', 'SKIP')),
  detail text not null default ''
) on commit drop;

-- Scenarios switch to the authenticated role; keep result logging writable.
grant all on table stage15_2_roleplay_results to authenticated, anon, service_role;

create or replace function pg_temp.rp_pass(
  p_scenario text,
  p_ok boolean,
  p_detail text default ''
)
returns void
language plpgsql as $fn$
begin
  insert into stage15_2_roleplay_results(scenario, status, detail)
  values (p_scenario, case when p_ok then 'PASS' else 'FAIL' end, coalesce(p_detail, ''))
  on conflict (scenario) do update
    set status = excluded.status, detail = excluded.detail;
end;
$fn$;

create or replace function pg_temp.rp_skip(
  p_scenario text,
  p_detail text default ''
)
returns void
language plpgsql as $fn$
begin
  insert into stage15_2_roleplay_results(scenario, status, detail)
  values (p_scenario, 'SKIP', coalesce(p_detail, ''))
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

-- Visibility exactly as the mobile app sees it.
create or replace function pg_temp.rp_sees(p_user_id uuid, p_post_id uuid)
returns boolean
language plpgsql as $fn$
declare
  v_json jsonb;
begin
  perform pg_temp.rp_as_user(p_user_id);
  v_json := public.get_my_published_news();
  return exists (
    select 1 from jsonb_array_elements(v_json) e where e ->> 'id' = p_post_id::text
  );
end;
$fn$;

-- Audience edits are draft-only, so re-targeting a live post means
-- unpublish -> set audience -> publish. The admin identity is passed in.
create or replace function pg_temp.rp_retarget(
  p_admin uuid,
  p_post_id uuid,
  p_mode text,
  p_group_ids uuid[],
  p_user_ids uuid[],
  p_publish boolean default true
)
returns jsonb
language plpgsql as $fn$
declare
  v_json jsonb;
  v_status text;
  v_version integer;
begin
  perform pg_temp.rp_as_user(p_admin);
  select status, version_number into v_status, v_version
  from public.news_posts where id = p_post_id;
  if v_status = 'published' then
    perform public.admin_unpublish_news(p_post_id);
    select version_number into v_version from public.news_posts where id = p_post_id;
  end if;
  v_json := public.admin_set_news_audience(
    p_post_id, p_mode, v_version, p_group_ids, p_user_ids
  );
  if p_publish then
    perform public.admin_publish_news(p_post_id);
  end if;
  return v_json;
end;
$fn$;

do $$
declare
  v_admin uuid;
  v_student uuid;
  v_group uuid;
  v_other uuid;
  v_ineligible uuid;
  v_empty_group uuid;
  v_post uuid;
  v_post2 uuid;
  v_dup uuid;
  v_json jsonb;
  v_preview jsonb;
  v_version int;
  v_expected int;
  v_eligible int;
begin
  -- ---------------------------------------------------------------------
  -- Fixtures
  -- ---------------------------------------------------------------------
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and private.has_admin_permission(a.user_id, 'content.write', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
    and private.has_admin_permission(a.user_id, 'content.read', 'global', null)
  limit 1;

  select se.user_id, se.group_id into v_student, v_group
  from public.student_enrollments se
  join public.users u on u.id = se.user_id and u.is_active
  where se.status = 'active'
    and se.ended_at is null
    and se.user_id is distinct from v_admin
  limit 1;

  select se.user_id into v_other
  from public.student_enrollments se
  join public.users u on u.id = se.user_id and u.is_active
  where se.status = 'active'
    and se.ended_at is null
    and se.user_id is distinct from v_admin
    and se.user_id is distinct from v_student
  limit 1;

  select u.id into v_ineligible
  from public.users u
  where u.id is distinct from v_admin
    and u.id is distinct from v_student
    and (
      u.is_active is not true
      or not exists (
        select 1
        from public.student_enrollments se
        where se.user_id = u.id
          and se.status = 'active'
          and se.ended_at is null
      )
    )
  limit 1;

  if v_admin is null or v_student is null then
    raise notice 'stage15_2 roleplay BLOCKED: missing content.* admin or enrolled student fixtures';
    perform pg_temp.rp_skip(
      '00 fixtures',
      'missing content.* admin or enrolled student fixtures'
    );
    return;
  end if;

  perform pg_temp.rp_pass('00 fixtures', true, format('group=%s', v_group));

  select count(*)::int into v_eligible
  from public.users u
  where u.is_active
    and exists (
      select 1
      from public.student_enrollments se
      where se.user_id = u.id
        and se.status = 'active'
        and se.ended_at is null
    );

  -- A group with no active members: used for exclusion + zero-count checks.
  insert into public.groups(name) values ('STAGE15_2-RP-EMPTY')
  returning id into v_empty_group;

  -- ---------------------------------------------------------------------
  -- 01 Legacy audience_type='all' with empty junctions
  -- ---------------------------------------------------------------------
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_create_news_draft('RP 15.2 all', 'sub', 'body', 'gradientText');
  v_post := (v_json ->> 'id')::uuid;

  perform pg_temp.rp_pass(
    '01a fresh draft reports mode all with empty junctions',
    v_json ->> 'audience_mode' = 'all'
      and (v_json ->> 'audience_uses_junctions')::boolean = false
      and v_json -> 'audience_group_ids' = '[]'::jsonb
      and v_json -> 'audience_user_ids' = '[]'::jsonb,
    v_json::text
  );

  perform pg_temp.rp_pass(
    '01b draft is invisible to the student',
    not pg_temp.rp_sees(v_student, v_post),
    ''
  );

  perform pg_temp.rp_as_user(v_admin);
  perform public.admin_publish_news(v_post);

  perform pg_temp.rp_pass(
    '01c published legacy all post is visible to an enrolled student',
    pg_temp.rp_sees(v_student, v_post),
    ''
  );

  perform pg_temp.rp_as_user(v_admin);
  v_preview := public.admin_preview_news_audience(v_post);
  perform pg_temp.rp_pass(
    '01d preview of legacy all counts every eligible student',
    v_preview ->> 'audience_mode' = 'all'
      and (v_preview -> 'breakdown' ->> 'all')::boolean
      and coalesce((v_preview ->> 'recipient_count')::int, -1) = v_eligible,
    format('expected=%s preview=%s', v_eligible, v_preview::text)
  );

  if v_ineligible is null then
    perform pg_temp.rp_skip(
      '01e non-enrolled user never matches',
      'no inactive / non-enrolled user fixture'
    );
  else
    perform pg_temp.rp_pass(
      '01e non-enrolled user never matches',
      not private.news_audience_matches(v_post, v_ineligible),
      format('user=%s', v_ineligible)
    );
  end if;

  -- ---------------------------------------------------------------------
  -- 02 Legacy audience_type='group' (pre-15.2 shape, junctions empty)
  -- ---------------------------------------------------------------------
  perform set_config('role', 'postgres', true);
  update public.news_posts
  set audience_type = 'group', audience_group_id = v_group
  where id = v_post;

  perform pg_temp.rp_pass(
    '02a legacy single group targets its own members',
    pg_temp.rp_sees(v_student, v_post),
    ''
  );

  perform set_config('role', 'postgres', true);
  update public.news_posts
  set audience_group_id = v_empty_group
  where id = v_post;

  perform pg_temp.rp_pass(
    '02b legacy group the student is not in stays invisible',
    not pg_temp.rp_sees(v_student, v_post),
    ''
  );

  perform pg_temp.rp_as_user(v_student);
  perform pg_temp.rp_expect_exception(
    '02c mark_news_seen is denied for a post outside my audience',
    format($sql$select public.mark_news_seen(%L::uuid, false)$sql$, v_post),
    'P0002',
    'not_found'
  );

  perform pg_temp.rp_as_user(v_admin);
  v_preview := public.admin_preview_news_audience(v_post);
  perform pg_temp.rp_pass(
    '02d preview of an empty legacy group is zero and lists no students',
    coalesce((v_preview ->> 'recipient_count')::int, -1) = 0
      and v_preview ->> 'audience_mode' = 'groups'
      and not (v_preview -> 'breakdown' ? 'users')
      and jsonb_array_length(v_preview -> 'breakdown' -> 'groups') = 1,
    v_preview::text
  );

  -- Audience edits are draft-only: a live post must be unpublished first.
  perform pg_temp.rp_expect_exception(
    '02e audience of a published post cannot be edited in place',
    format(
      $sql$select public.admin_set_news_audience(%L::uuid, 'all', (select version_number from public.news_posts where id = %L::uuid), '{}'::uuid[], '{}'::uuid[])$sql$,
      v_post, v_post
    ),
    '55000',
    'draft_only'
  );

  -- ---------------------------------------------------------------------
  -- 03 Junctions become the sole match source
  -- ---------------------------------------------------------------------
  v_json := pg_temp.rp_retarget(
    v_admin, v_post, 'groups', array[v_group, v_empty_group], '{}'::uuid[]
  );

  perform pg_temp.rp_pass(
    '03a groups mode keeps a legacy single group for old clients',
    v_json ->> 'audience_mode' = 'groups'
      and v_json ->> 'audience_type' = 'group'
      and (v_json ->> 'audience_group_id')::uuid = v_group
      and jsonb_array_length(v_json -> 'audience_group_ids') = 2
      and v_json -> 'audience_user_ids' = '[]'::jsonb,
    v_json::text
  );

  perform pg_temp.rp_pass(
    '03b student matches through any targeted group',
    pg_temp.rp_sees(v_student, v_post),
    ''
  );

  perform pg_temp.rp_as_user(v_student);
  v_json := public.mark_news_seen(v_post, false);
  perform pg_temp.rp_pass(
    '03c mark_news_seen is allowed inside the junction audience',
    coalesce((v_json ->> 'ok')::boolean, false),
    v_json::text
  );

  -- Junctions win: drop the matching junction row while the legacy column
  -- still points at the student's group.
  perform set_config('role', 'postgres', true);
  delete from public.news_audience_groups
  where news_post_id = v_post and group_id = v_group;

  perform pg_temp.rp_pass(
    '03d legacy audience_group_id is ignored once junctions exist',
    not pg_temp.rp_sees(v_student, v_post)
      and (select audience_group_id from public.news_posts where id = v_post) = v_group,
    ''
  );

  -- ---------------------------------------------------------------------
  -- 04 Explicit users
  -- ---------------------------------------------------------------------
  v_json := pg_temp.rp_retarget(
    v_admin, v_post, 'users', '{}'::uuid[], array[v_student]
  );

  perform pg_temp.rp_pass(
    '04a users mode clears groups and projects fail-closed for old clients',
    v_json ->> 'audience_mode' = 'users'
      and v_json ->> 'audience_type' = 'group'
      and v_json ->> 'audience_group_id' is null
      and v_json -> 'audience_group_ids' = '[]'::jsonb
      and jsonb_array_length(v_json -> 'audience_user_ids') = 1,
    v_json::text
  );

  perform pg_temp.rp_pass(
    '04b explicitly targeted student sees the post',
    pg_temp.rp_sees(v_student, v_post),
    ''
  );

  if v_other is null then
    perform pg_temp.rp_skip(
      '04c other students never see a user-targeted post',
      'no second enrolled student fixture'
    );
  else
    perform pg_temp.rp_pass(
      '04c other students never see a user-targeted post',
      not pg_temp.rp_sees(v_other, v_post),
      format('other=%s', v_other)
    );
  end if;

  perform pg_temp.rp_as_user(v_admin);
  v_preview := public.admin_preview_news_audience(v_post);
  perform pg_temp.rp_pass(
    '04d preview reports one explicit recipient and no student list',
    coalesce((v_preview ->> 'recipient_count')::int, -1) = 1
      and coalesce((v_preview -> 'breakdown' ->> 'explicit_users_count')::int, -1) = 1
      and v_preview -> 'breakdown' -> 'groups' = '[]'::jsonb
      and not (v_preview -> 'breakdown' ? 'users')
      and not (v_preview ? 'recipients'),
    v_preview::text
  );

  -- ---------------------------------------------------------------------
  -- 05 groups_and_users is an OR
  -- ---------------------------------------------------------------------
  v_json := pg_temp.rp_retarget(
    v_admin, v_post, 'groups_and_users', array[v_empty_group], array[v_student]
  );
  perform pg_temp.rp_pass(
    '05a groups_and_users keeps both junction sets',
    v_json ->> 'audience_mode' = 'groups_and_users'
      and jsonb_array_length(v_json -> 'audience_group_ids') = 1
      and jsonb_array_length(v_json -> 'audience_user_ids') = 1,
    v_json::text
  );

  perform pg_temp.rp_pass(
    '05b explicit user matches even when the group matches nobody',
    pg_temp.rp_sees(v_student, v_post),
    ''
  );

  v_json := pg_temp.rp_retarget(
    v_admin, v_post, 'groups_and_users', array[v_group], array[v_student]
  );
  perform pg_temp.rp_as_user(v_admin);
  v_preview := public.admin_preview_news_audience(v_post);
  select count(*)::int into v_expected
  from public.users u
  join public.student_enrollments se
    on se.user_id = u.id
   and se.group_id = v_group
   and se.status = 'active'
   and se.ended_at is null
  where u.is_active;
  perform pg_temp.rp_pass(
    '05c preview never double-counts a student matched twice',
    coalesce((v_preview ->> 'recipient_count')::int, -1) = v_expected,
    format('expected=%s preview=%s', v_expected, v_preview::text)
  );

  -- ---------------------------------------------------------------------
  -- 06 Setter invariants
  -- ---------------------------------------------------------------------
  perform set_config('role', 'postgres', true);
  update public.news_posts
  set audience_type = 'all', audience_group_id = null
  where id = v_post;

  perform pg_temp.rp_expect_exception(
    '06a audience_type=all with non-empty junctions is forbidden',
    format(
      $sql$select private.news_assert_audience_consistent(%L::uuid)$sql$, v_post
    ),
    'P0001',
    'news_audience_all_must_have_empty_junctions'
  );

  perform set_config('role', 'postgres', true);
  update public.news_posts
  set audience_type = 'group', audience_group_id = null
  where id = v_post;
  delete from public.news_audience_groups where news_post_id = v_post;
  delete from public.news_audience_users where news_post_id = v_post;

  perform pg_temp.rp_expect_exception(
    '06b group with no legacy group and no junctions is forbidden',
    format(
      $sql$select private.news_assert_audience_consistent(%L::uuid)$sql$, v_post
    ),
    'P0001',
    'news_audience_group_requires_target'
  );

  perform pg_temp.rp_expect_exception(
    '06c publishing an inconsistent audience is refused',
    format($sql$select public.admin_publish_news(%L::uuid)$sql$, v_post),
    'P0001',
    'news_audience_group_requires_target'
  );

  v_json := pg_temp.rp_retarget(
    v_admin, v_post, 'groups', array[v_group], '{}'::uuid[], false
  );
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_set_news_audience(
    v_post, 'all',
    (select version_number from public.news_posts where id = v_post),
    array[v_group], array[v_student]
  );
  perform pg_temp.rp_pass(
    '06d mode all clears both junctions and the legacy group',
    v_json ->> 'audience_mode' = 'all'
      and v_json ->> 'audience_type' = 'all'
      and v_json ->> 'audience_group_id' is null
      and v_json -> 'audience_group_ids' = '[]'::jsonb
      and v_json -> 'audience_user_ids' = '[]'::jsonb
      and not private.news_audience_uses_junctions(v_post),
    v_json::text
  );

  -- ---------------------------------------------------------------------
  -- 07 Setter input validation (post is a draft here)
  -- ---------------------------------------------------------------------
  perform pg_temp.rp_expect_exception(
    '07a unknown audience mode is rejected',
    format(
      $sql$select public.admin_set_news_audience(%L::uuid, 'everyone', (select version_number from public.news_posts where id = %L::uuid), '{}'::uuid[], '{}'::uuid[])$sql$,
      v_post, v_post
    ),
    '22023',
    'invalid_audience_mode'
  );
  perform pg_temp.rp_expect_exception(
    '07b groups mode requires at least one group',
    format(
      $sql$select public.admin_set_news_audience(%L::uuid, 'groups', (select version_number from public.news_posts where id = %L::uuid), '{}'::uuid[], '{}'::uuid[])$sql$,
      v_post, v_post
    ),
    '22023',
    'audience_groups_required'
  );
  perform pg_temp.rp_expect_exception(
    '07c users mode requires at least one user',
    format(
      $sql$select public.admin_set_news_audience(%L::uuid, 'users', (select version_number from public.news_posts where id = %L::uuid), '{}'::uuid[], '{}'::uuid[])$sql$,
      v_post, v_post
    ),
    '22023',
    'audience_users_required'
  );
  perform pg_temp.rp_expect_exception(
    '07d groups_and_users requires both sides',
    format(
      $sql$select public.admin_set_news_audience(%L::uuid, 'groups_and_users', (select version_number from public.news_posts where id = %L::uuid), array[%L::uuid], '{}'::uuid[])$sql$,
      v_post, v_post, v_group
    ),
    '22023',
    'audience_groups_and_users_required'
  );
  perform pg_temp.rp_expect_exception(
    '07e unknown group id is rejected',
    format(
      $sql$select public.admin_set_news_audience(%L::uuid, 'groups', (select version_number from public.news_posts where id = %L::uuid), array['00000000-0000-0000-0000-000000000000'::uuid], '{}'::uuid[])$sql$,
      v_post, v_post
    ),
    '22023',
    'unknown_group_'
  );
  if v_ineligible is null then
    perform pg_temp.rp_skip(
      '07f ineligible explicit user is rejected',
      'no inactive / non-enrolled user fixture'
    );
  else
    perform pg_temp.rp_expect_exception(
      '07f ineligible explicit user is rejected',
      format(
        $sql$select public.admin_set_news_audience(%L::uuid, 'users', (select version_number from public.news_posts where id = %L::uuid), '{}'::uuid[], array[%L::uuid])$sql$,
        v_post, v_post, v_ineligible
      ),
      '22023',
      'ineligible_audience_user_'
    );
  end if;
  perform pg_temp.rp_expect_exception(
    '07g audience cannot be smuggled through the draft patch RPC',
    format(
      $sql$select public.admin_update_news_draft(%L::uuid, '{"audience_type":"all"}'::jsonb)$sql$,
      v_post
    ),
    '22023',
    'use_admin_set_news_audience'
  );
  perform pg_temp.rp_expect_exception(
    '07h junction arrays cannot be smuggled through the draft patch RPC',
    format(
      $sql$select public.admin_update_news_draft(
        %L::uuid, '{"audience_group_ids":["00000000-0000-0000-0000-000000000000"]}'::jsonb
      )$sql$,
      v_post
    ),
    '22023',
    'use_admin_set_news_audience'
  );

  -- ---------------------------------------------------------------------
  -- 08 Draft / hidden / archived never leak
  -- ---------------------------------------------------------------------
  v_json := pg_temp.rp_retarget(
    v_admin, v_post, 'users', '{}'::uuid[], array[v_student]
  );
  perform pg_temp.rp_pass(
    '08a targeted published post is visible before the negative checks',
    pg_temp.rp_sees(v_student, v_post),
    ''
  );

  perform pg_temp.rp_as_user(v_admin);
  perform public.admin_unpublish_news(v_post);
  perform pg_temp.rp_pass(
    '08b unpublished post disappears for its audience',
    not pg_temp.rp_sees(v_student, v_post),
    ''
  );
  perform pg_temp.rp_as_user(v_student);
  perform pg_temp.rp_expect_exception(
    '08c mark_news_seen denied on an unpublished post',
    format($sql$select public.mark_news_seen(%L::uuid, true)$sql$, v_post),
    'P0002',
    'not_found'
  );

  perform pg_temp.rp_as_user(v_admin);
  perform public.admin_update_news_draft(v_post, '{"is_hidden": true}'::jsonb);
  perform public.admin_publish_news(v_post);
  perform pg_temp.rp_pass(
    '08d hidden post never reaches its audience',
    not pg_temp.rp_sees(v_student, v_post),
    ''
  );
  perform pg_temp.rp_as_user(v_student);
  perform pg_temp.rp_expect_exception(
    '08e mark_news_seen denied on a hidden post',
    format($sql$select public.mark_news_seen(%L::uuid, true)$sql$, v_post),
    'P0002',
    'not_found'
  );

  perform pg_temp.rp_as_user(v_admin);
  perform public.admin_update_news_draft(v_post, '{"is_hidden": false}'::jsonb);
  perform public.admin_archive_news(v_post);
  perform pg_temp.rp_pass(
    '08f archived post never reaches its audience',
    not pg_temp.rp_sees(v_student, v_post),
    ''
  );

  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_exception(
    '08g archived post audience cannot be re-targeted',
    format(
      $sql$select public.admin_set_news_audience(%L::uuid, 'all', (select version_number from public.news_posts where id = %L::uuid), '{}'::uuid[], '{}'::uuid[])$sql$,
      v_post, v_post
    ),
    '55000',
    'draft_only'
  );

  -- ---------------------------------------------------------------------
  -- 09 RBAC + no direct table / helper access
  -- ---------------------------------------------------------------------
  perform pg_temp.rp_as_user(v_student);
  perform set_config('role', 'authenticated', true);
  perform pg_temp.rp_expect_exception(
    '09a student cannot select news_audience_groups directly',
    'select count(*) from public.news_audience_groups',
    '42501'
  );
  perform pg_temp.rp_expect_exception(
    '09b student cannot insert news_audience_users directly',
    format(
      $sql$insert into public.news_audience_users(news_post_id, user_id)
           values (gen_random_uuid(), %L::uuid)$sql$,
      v_student
    ),
    '42501'
  );
  perform pg_temp.rp_expect_exception(
    '09c student cannot set a news audience',
    format(
      $sql$select public.admin_set_news_audience(%L::uuid, 'all', (select version_number from public.news_posts where id = %L::uuid), '{}'::uuid[], '{}'::uuid[])$sql$,
      v_post, v_post
    ),
    '42501',
    'forbidden'
  );
  perform pg_temp.rp_expect_exception(
    '09d student cannot preview a news audience',
    format($sql$select public.admin_preview_news_audience(%L::uuid)$sql$, v_post),
    '42501',
    'forbidden'
  );
  perform pg_temp.rp_expect_exception(
    '09e student cannot call the private matcher',
    format(
      $sql$select private.news_audience_matches(%L::uuid, %L::uuid)$sql$,
      v_post, v_student
    ),
    '42501'
  );
  perform set_config('role', 'postgres', true);

  -- ---------------------------------------------------------------------
  -- 10 Duplicate + restore keep the junction audience
  -- ---------------------------------------------------------------------
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_create_news_draft('RP 15.2 targeted', 'sub', 'body', 'gradientText');
  v_post2 := (v_json ->> 'id')::uuid;
  v_json := public.admin_set_news_audience(
    v_post2, 'groups_and_users',
    (select version_number from public.news_posts where id = v_post2),
    array[v_group], array[v_student]
  );
  v_version := (v_json ->> 'version_number')::int;

  v_json := public.admin_duplicate_news(v_post2);
  v_dup := (v_json ->> 'id')::uuid;
  perform pg_temp.rp_pass(
    '10a duplicate copies both junction sets',
    v_json ->> 'audience_mode' = 'groups_and_users'
      and jsonb_array_length(v_json -> 'audience_group_ids') = 1
      and jsonb_array_length(v_json -> 'audience_user_ids') = 1
      and v_json ->> 'status' = 'draft',
    v_json::text
  );

  v_json := public.admin_set_news_audience(
    v_post2, 'all',
    (select version_number from public.news_posts where id = v_post2),
    '{}'::uuid[], '{}'::uuid[]
  );
  perform pg_temp.rp_pass(
    '10b audience really was widened before the restore',
    not private.news_audience_uses_junctions(v_post2),
    v_json::text
  );

  v_json := public.admin_restore_news_version(v_post2, v_version);
  perform pg_temp.rp_pass(
    '10c restoring a version restores its junction audience',
    v_json ->> 'audience_mode' = 'groups_and_users'
      and jsonb_array_length(v_json -> 'audience_group_ids') = 1
      and jsonb_array_length(v_json -> 'audience_user_ids') = 1,
    v_json::text
  );

  -- Optimistic concurrency guard on the setter.
  select version_number into v_version from public.news_posts where id = v_post2;
  perform pg_temp.rp_expect_exception(
    '10d stale expected_version is a conflict',
    format(
      $sql$select public.admin_set_news_audience(
        %L::uuid, 'all', %s, '{}'::uuid[], '{}'::uuid[]
      )$sql$,
      v_post2, v_version - 1
    ),
    '40001',
    'version_conflict'
  );
  perform pg_temp.rp_pass(
    '10e conflicting audience write changed nothing',
    private.news_audience_uses_junctions(v_post2)
      and (select version_number from public.news_posts where id = v_post2) = v_version,
    format('version=%s', v_version)
  );

  -- ---------------------------------------------------------------------
  -- 11 Admin list/get payloads stay parseable for every existing post
  -- ---------------------------------------------------------------------
  v_json := public.admin_list_news(null, true);
  perform pg_temp.rp_pass(
    '11a admin_list_news exposes mode + junctions for every post',
    jsonb_array_length(v_json) >= 3
      and not exists (
        select 1
        from jsonb_array_elements(v_json) e
        where not (e ? 'audience_mode')
           or not (e ? 'audience_group_ids')
           or not (e ? 'audience_user_ids')
           or not (e ? 'audience_type')
           or not (e ? 'audience_group_id')
      ),
    format('count=%s', jsonb_array_length(v_json))
  );

  v_json := public.admin_get_news(v_dup);
  perform pg_temp.rp_pass(
    '11b admin_get_news returns the same audience contract',
    v_json ->> 'audience_mode' = 'groups_and_users'
      and (v_json ->> 'audience_uses_junctions')::boolean,
    v_json::text
  );

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
end
$$;

select scenario, status, detail
from stage15_2_roleplay_results
order by scenario;

select
  count(*) filter (where status = 'PASS') as pass_count,
  count(*) filter (where status = 'FAIL') as fail_count,
  count(*) filter (where status = 'SKIP') as skip_count,
  count(*) as total
from stage15_2_roleplay_results;

do $$
declare
  v_fail int;
begin
  select count(*) into v_fail from stage15_2_roleplay_results where status = 'FAIL';
  if v_fail > 0 then
    raise exception 'stage15_2 news audience scenarios failed: %', (
      select string_agg(scenario || ': ' || detail, '; ' order by scenario)
      from stage15_2_roleplay_results where status = 'FAIL'
    );
  end if;
  raise notice 'stage15_2_news_audience_roleplay PASS';
end
$$;

rollback;
