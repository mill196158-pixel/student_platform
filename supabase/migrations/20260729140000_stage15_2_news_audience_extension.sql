-- Stage 15.2: news audience extension (SPEC section 3, 15.2).
--
-- Adds news_audience_groups / news_audience_users junctions on top of the
-- existing news_posts audience columns and routes EVERY visibility decision
-- (mobile RPC, seen-marking, admin preview) through ONE private helper:
-- private.news_audience_matches(post, user).
--
-- Locked semantics (SPEC 15.2):
--   1. audience_type='all'   + both junctions empty          -> all students
--   2. audience_type='group' + audience_group_id + empty      -> that group
--   3. ANY junction row                                       -> junctions are
--      the SOLE match source (legacy columns ignored for matching);
--      match = active group membership OR explicit user row.
--   4. Invariant: audience_type='all' with non-empty junctions is forbidden.
--
-- Backward compatibility:
--   * existing posts / images / versions are untouched (no data migration);
--   * legacy audience columns keep being maintained so old clients that only
--     understand all|group degrade fail-closed (never wider than intended);
--   * news_audience_type stays the live enum ('all','group'); the richer
--     audience "mode" is derived, not stored.
--
-- Local only. Not applied to remote in this session.

begin;

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. Junction tables
-- ---------------------------------------------------------------------------
create table if not exists public.news_audience_groups (
  news_post_id uuid not null references public.news_posts (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  primary key (news_post_id, group_id)
);

comment on table public.news_audience_groups is
  'Stage 15.2 news audience: targeted groups. Any row here makes the junctions the sole audience source for the post (legacy audience_type/audience_group_id are ignored for matching).';

create index if not exists news_audience_groups_group_idx
  on public.news_audience_groups (group_id);

create table if not exists public.news_audience_users (
  news_post_id uuid not null references public.news_posts (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  primary key (news_post_id, user_id)
);

comment on table public.news_audience_users is
  'Stage 15.2 news audience: explicitly targeted students. Explicit users still require active platform + enrollment eligibility.';

create index if not exists news_audience_users_user_idx
  on public.news_audience_users (user_id);

-- ---------------------------------------------------------------------------
-- 2. Lock down the new tables (RLS + FORCE RLS, no client DML)
-- ---------------------------------------------------------------------------
alter table public.news_audience_groups enable row level security;
alter table public.news_audience_groups force row level security;
alter table public.news_audience_users enable row level security;
alter table public.news_audience_users force row level security;

revoke all on table public.news_audience_groups from public, anon, authenticated;
revoke all on table public.news_audience_users from public, anon, authenticated;

grant select, insert, update, delete on table public.news_audience_groups to service_role;
grant select, insert, update, delete on table public.news_audience_users to service_role;

-- ---------------------------------------------------------------------------
-- 3. Legacy row-level check: allow the "no legacy group" shape.
--
-- A users-only audience has no group to advertise to old clients. Such a post
-- is stored as ('group', null): old clients evaluate
-- `audience_group_id = any(my_groups)` -> NULL -> not visible (fail-closed),
-- while the junction predicate below resolves the real recipients. The
-- junction-aware invariant lives in private.news_assert_audience_consistent
-- (a row-level CHECK cannot see other tables).
-- ---------------------------------------------------------------------------
alter table public.news_posts drop constraint if exists news_posts_audience_chk;
alter table public.news_posts add constraint news_posts_audience_chk check (
  (audience_type = 'all' and audience_group_id is null)
  or audience_type = 'group'
);

-- ---------------------------------------------------------------------------
-- 4. THE visibility helper (used by mobile RPC + preview + seen-marking)
-- ---------------------------------------------------------------------------
create or replace function private.news_audience_matches(
  p_post_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type public.news_audience_type;
  v_group uuid;
  v_has_groups boolean;
  v_has_users boolean;
begin
  if p_post_id is null or p_user_id is null then
    return false;
  end if;

  select n.audience_type, n.audience_group_id
  into v_type, v_group
  from public.news_posts n
  where n.id = p_post_id;

  if not found then
    return false;
  end if;

  -- Eligibility gate (same rule as Stage 14 managed content): only an active
  -- platform user with at least one active, non-ended enrollment can match.
  if not exists (
    select 1
    from public.users u
    join public.student_enrollments se
      on se.user_id = u.id
     and se.status = 'active'
     and se.ended_at is null
    where u.id = p_user_id
      and u.is_active
  ) then
    return false;
  end if;

  v_has_groups := exists (
    select 1 from public.news_audience_groups g where g.news_post_id = p_post_id
  );
  v_has_users := exists (
    select 1 from public.news_audience_users au where au.news_post_id = p_post_id
  );

  -- Rule 3: junctions win outright; legacy columns are ignored for matching.
  if v_has_groups or v_has_users then
    return exists (
      select 1
      from public.news_audience_groups g
      join public.student_enrollments se
        on se.group_id = g.group_id
       and se.user_id = p_user_id
       and se.status = 'active'
       and se.ended_at is null
      where g.news_post_id = p_post_id
    )
    or exists (
      select 1
      from public.news_audience_users au
      where au.news_post_id = p_post_id
        and au.user_id = p_user_id
    );
  end if;

  -- Rule 1: legacy "all".
  if v_type = 'all' then
    return true;
  end if;

  -- Rule 2: legacy single group. ('group', null) with empty junctions targets
  -- nobody, which is also what old clients resolve.
  return v_group is not null
    and exists (
      select 1
      from public.student_enrollments se
      where se.user_id = p_user_id
        and se.group_id = v_group
        and se.status = 'active'
        and se.ended_at is null
    );
end;
$$;

revoke all on function private.news_audience_matches(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.news_audience_matches(uuid, uuid) to service_role;

comment on function private.news_audience_matches(uuid, uuid) is
  'Stage 15.2 single source of truth for news audience matching (locked SPEC 15.2 semantics). Used by get_my_published_news, mark_news_seen and admin preview.';

-- Published + not hidden + inside the schedule window + audience match.
create or replace function private.news_post_deliverable_to_user(
  p_post_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.news_posts;
  v_now timestamptz := now();
begin
  if p_post_id is null or p_user_id is null then
    return false;
  end if;

  select * into v_row from public.news_posts where id = p_post_id;
  if not found then
    return false;
  end if;

  -- Draft / archived / hidden never leak.
  if v_row.status <> 'published' or v_row.is_hidden then
    return false;
  end if;
  if v_row.starts_at is not null and v_row.starts_at > v_now then
    return false;
  end if;
  if v_row.ends_at is not null and v_row.ends_at < v_now then
    return false;
  end if;

  return private.news_audience_matches(p_post_id, p_user_id);
end;
$$;

revoke all on function private.news_post_deliverable_to_user(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.news_post_deliverable_to_user(uuid, uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- 5. Derived audience mode + junction-aware invariant
-- ---------------------------------------------------------------------------
create or replace function private.news_audience_mode(p_post_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type public.news_audience_type;
  v_has_groups boolean;
  v_has_users boolean;
begin
  select n.audience_type into v_type
  from public.news_posts n
  where n.id = p_post_id;

  if not found then
    return null;
  end if;

  v_has_groups := exists (
    select 1 from public.news_audience_groups g where g.news_post_id = p_post_id
  );
  v_has_users := exists (
    select 1 from public.news_audience_users au where au.news_post_id = p_post_id
  );

  if v_has_groups and v_has_users then
    return 'groups_and_users';
  elsif v_has_groups then
    return 'groups';
  elsif v_has_users then
    return 'users';
  end if;

  -- Legacy shape.
  return case when v_type = 'all' then 'all' else 'groups' end;
end;
$$;

revoke all on function private.news_audience_mode(uuid)
  from public, anon, authenticated;
grant execute on function private.news_audience_mode(uuid) to service_role;

create or replace function private.news_audience_uses_junctions(p_post_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.news_audience_groups g where g.news_post_id = p_post_id
  )
  or exists (
    select 1 from public.news_audience_users au where au.news_post_id = p_post_id
  );
$$;

revoke all on function private.news_audience_uses_junctions(uuid)
  from public, anon, authenticated;
grant execute on function private.news_audience_uses_junctions(uuid) to service_role;

create or replace function private.news_assert_audience_consistent(p_post_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type public.news_audience_type;
  v_group uuid;
  v_groups integer;
  v_users integer;
begin
  select n.audience_type, n.audience_group_id
  into v_type, v_group
  from public.news_posts n
  where n.id = p_post_id;

  if not found then
    -- Post was removed in the same transaction: nothing left to constrain.
    return;
  end if;

  select count(*) into v_groups
  from public.news_audience_groups g
  where g.news_post_id = p_post_id;

  select count(*) into v_users
  from public.news_audience_users au
  where au.news_post_id = p_post_id;

  -- SPEC 15.2 rule 5.
  if v_type = 'all' and (v_groups > 0 or v_users > 0) then
    raise exception 'news_audience_all_must_have_empty_junctions'
      using errcode = 'P0001';
  end if;

  -- ('group', null) is only legal as the old-client projection of a junction
  -- audience; without junctions it would silently target nobody.
  if v_type = 'group' and v_group is null and v_groups = 0 and v_users = 0 then
    raise exception 'news_audience_group_requires_target' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on function private.news_assert_audience_consistent(uuid)
  from public, anon, authenticated;
grant execute on function private.news_assert_audience_consistent(uuid)
  to service_role;

-- Deferred constraint triggers: the invariant holds at COMMIT even when a
-- caller bypasses admin_set_news_audience (e.g. a legacy patch RPC or a
-- service_role script). Deferral is required because a transactional audience
-- swap must be allowed to touch news_posts and the junctions in any order.
create or replace function private.news_audience_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_post_id uuid;
begin
  if tg_table_name = 'news_posts' then
    v_post_id := case when tg_op = 'DELETE' then old.id else new.id end;
  else
    v_post_id := case
      when tg_op = 'DELETE' then old.news_post_id
      else new.news_post_id
    end;
  end if;
  perform private.news_assert_audience_consistent(v_post_id);
  return null;
end;
$$;

revoke all on function private.news_audience_guard() from public, anon, authenticated;

drop trigger if exists trg_news_posts_audience_invariant on public.news_posts;
create constraint trigger trg_news_posts_audience_invariant
after insert or update on public.news_posts
deferrable initially deferred
for each row execute function private.news_audience_guard();

drop trigger if exists trg_news_audience_groups_invariant on public.news_audience_groups;
create constraint trigger trg_news_audience_groups_invariant
after insert or update or delete on public.news_audience_groups
deferrable initially deferred
for each row execute function private.news_audience_guard();

drop trigger if exists trg_news_audience_users_invariant on public.news_audience_users;
create constraint trigger trg_news_audience_users_invariant
after insert or update or delete on public.news_audience_users
deferrable initially deferred
for each row execute function private.news_audience_guard();

-- ---------------------------------------------------------------------------
-- 6. Audience preview: recipient count + safe breakdown (never student PII)
-- ---------------------------------------------------------------------------
create or replace function private.news_preview_audience_count(p_post_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type public.news_audience_type;
  v_legacy_group uuid;
  v_uses_junctions boolean;
  v_mode text;
  v_group_ids uuid[];
  v_groups jsonb;
  v_explicit integer := 0;
  v_count integer := 0;
begin
  select n.audience_type, n.audience_group_id
  into v_type, v_legacy_group
  from public.news_posts n
  where n.id = p_post_id;

  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_uses_junctions := private.news_audience_uses_junctions(p_post_id);
  v_mode := private.news_audience_mode(p_post_id);

  -- Recipient count comes from the same helper the students go through, so
  -- preview can never disagree with delivery. Candidates are pre-filtered by
  -- the helper's own eligibility gate (active user + active enrollment).
  select count(*)::integer into v_count
  from public.users u
  where u.is_active
    and exists (
      select 1
      from public.student_enrollments se
      where se.user_id = u.id
        and se.status = 'active'
        and se.ended_at is null
    )
    and private.news_audience_matches(p_post_id, u.id);

  if v_uses_junctions then
    select coalesce(array_agg(g.group_id), '{}'::uuid[]) into v_group_ids
    from public.news_audience_groups g
    where g.news_post_id = p_post_id;
  else
    v_group_ids := case
      when v_type = 'group' and v_legacy_group is not null then array[v_legacy_group]
      else '{}'::uuid[]
    end;
  end if;

  -- Group name + member count only. No student identities are ever returned.
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
    from unnest(v_group_ids) as t(group_id)
    join public.groups g0 on g0.id = t.group_id
  ) gr;

  select count(distinct au.user_id)::integer into v_explicit
  from public.news_audience_users au
  join public.users u on u.id = au.user_id and u.is_active
  join public.student_enrollments se
    on se.user_id = au.user_id
   and se.status = 'active'
   and se.ended_at is null
  where au.news_post_id = p_post_id;

  return jsonb_build_object(
    'news_post_id', p_post_id,
    'audience_mode', v_mode,
    'legacy_audience_type', v_type,
    'legacy_audience_group_id', v_legacy_group,
    'uses_junctions', v_uses_junctions,
    'recipient_count', coalesce(v_count, 0),
    'breakdown', jsonb_build_object(
      'all', (v_mode = 'all'),
      'groups', v_groups,
      'explicit_users_count', coalesce(v_explicit, 0)
    )
  );
end;
$$;

revoke all on function private.news_preview_audience_count(uuid)
  from public, anon, authenticated;
grant execute on function private.news_preview_audience_count(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 7. Admin serialization: junctions + derived mode in every admin payload.
--    news_post_to_json also feeds private.news_snapshot_version, so versions
--    now carry the audience junctions too.
-- ---------------------------------------------------------------------------
create or replace function private.news_post_to_json(p_row public.news_posts)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_row.id,
    'status', p_row.status,
    'sort_order', p_row.sort_order,
    'priority', p_row.priority,
    'starts_at', p_row.starts_at,
    'ends_at', p_row.ends_at,
    'audience_type', p_row.audience_type,
    'audience_group_id', p_row.audience_group_id,
    'audience_mode', private.news_audience_mode(p_row.id),
    'audience_uses_junctions', private.news_audience_uses_junctions(p_row.id),
    'audience_group_ids', coalesce(
      (
        select jsonb_agg(g.group_id order by g.group_id)
        from public.news_audience_groups g
        where g.news_post_id = p_row.id
      ),
      '[]'::jsonb
    ),
    'audience_user_ids', coalesce(
      (
        select jsonb_agg(au.user_id order by au.user_id)
        from public.news_audience_users au
        where au.news_post_id = p_row.id
      ),
      '[]'::jsonb
    ),
    'variant', p_row.variant,
    'title', p_row.title,
    'subtitle', p_row.subtitle,
    'body', p_row.body,
    'gradient_colors', to_jsonb(p_row.gradient_colors),
    'image_path', p_row.image_path,
    'image_focus_x', p_row.image_focus_x,
    'image_focus_y', p_row.image_focus_y,
    'overlay_opacity', p_row.overlay_opacity,
    'is_hidden', p_row.is_hidden,
    'version_number', p_row.version_number,
    'created_by', p_row.created_by,
    'updated_by', p_row.updated_by,
    'published_by', p_row.published_by,
    'published_at', p_row.published_at,
    'created_at', p_row.created_at,
    'updated_at', p_row.updated_at
  );
$$;

-- ---------------------------------------------------------------------------
-- 8. Admin RPC: transactional audience setter
-- ---------------------------------------------------------------------------
-- Local drafts of this migration shipped setters without p_expected_version and
-- with it in trailing position. Dropping those overloads keeps every call site
-- unambiguous: exactly one admin_set_news_audience exists after this migration.
drop function if exists public.admin_set_news_audience(uuid, text, uuid[], uuid[]);
drop function if exists public.admin_set_news_audience(uuid, text, uuid[], uuid[], integer);

create or replace function public.admin_set_news_audience(
  p_id uuid,
  p_mode text,
  p_expected_version integer,
  p_group_ids uuid[] default '{}'::uuid[],
  p_user_ids uuid[] default '{}'::uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
  v_mode text := nullif(btrim(coalesce(p_mode, '')), '');
  v_groups uuid[];
  v_users uuid[];
  v_primary_group uuid;
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

  -- Old clients only understand a single group: keep the caller's first group.
  select x into v_primary_group
  from unnest(coalesce(p_group_ids, '{}'::uuid[])) with ordinality as t(x, ord)
  where x is not null
  order by ord
  limit 1;

  if v_mode = 'all' then
    v_groups := '{}'::uuid[];
    v_users := '{}'::uuid[];
    v_primary_group := null;
  elsif v_mode = 'groups' then
    v_users := '{}'::uuid[];
    if coalesce(array_length(v_groups, 1), 0) = 0 then
      raise exception 'audience_groups_required' using errcode = '22023';
    end if;
  elsif v_mode = 'users' then
    v_groups := '{}'::uuid[];
    v_primary_group := null;
    if coalesce(array_length(v_users, 1), 0) = 0 then
      raise exception 'audience_users_required' using errcode = '22023';
    end if;
  else
    if coalesce(array_length(v_groups, 1), 0) = 0
       or coalesce(array_length(v_users, 1), 0) = 0 then
      raise exception 'audience_groups_and_users_required' using errcode = '22023';
    end if;
  end if;

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_row.status <> 'draft' then
    raise exception 'draft_only' using errcode = '55000';
  end if;

  if p_expected_version is null then
    raise exception 'expected_version_required' using errcode = '22023';
  end if;
  if v_row.version_number is distinct from p_expected_version then
    raise exception 'version_conflict' using errcode = '40001';
  end if;

  select g into v_missing
  from unnest(v_groups) as g
  where not exists (select 1 from public.groups gr where gr.id = g)
  limit 1;
  if v_missing is not null then
    raise exception 'unknown_group_%', v_missing using errcode = '22023';
  end if;

  -- Explicit users must be eligible students, exactly like the matcher demands.
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

  -- Snapshot the pre-change audience (junctions included) before mutating.
  perform private.news_snapshot_version(v_row.id);

  -- Transactional replace.
  delete from public.news_audience_groups where news_post_id = p_id;
  delete from public.news_audience_users where news_post_id = p_id;

  insert into public.news_audience_groups (news_post_id, group_id)
  select p_id, g from unnest(v_groups) as g;

  insert into public.news_audience_users (news_post_id, user_id)
  select p_id, u from unnest(v_users) as u;

  update public.news_posts n set
    audience_type = case
      when v_mode = 'all' then 'all'::public.news_audience_type
      else 'group'::public.news_audience_type
    end,
    audience_group_id = v_primary_group,
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  -- Immediate, precise failure (the deferred triggers are the backstop).
  perform private.news_assert_audience_consistent(p_id);

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.set_audience',
    'news_post',
    p_id::text,
    jsonb_build_object(
      'audience_mode', v_mode,
      'group_count', coalesce(array_length(v_groups, 1), 0),
      'user_count', coalesce(array_length(v_users, 1), 0),
      'legacy_audience_type', v_row.audience_type,
      'legacy_audience_group_id', v_row.audience_group_id,
      'version_number', v_row.version_number
    )
  );

  return private.news_post_to_json(v_row);
end;
$$;

comment on function public.admin_set_news_audience(uuid, text, integer, uuid[], uuid[]) is
  'Stage 15.2 transactional news audience setter. Draft-only; required expected_version; never leaves audience_type=all with non-empty junctions.';

-- ---------------------------------------------------------------------------
-- 8b. Reject direct audience patches; validate audience on publish
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_news_draft(
  p_id uuid,
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
  p jsonb := coalesce(p_patch, '{}'::jsonb);
begin
  v_uid := private.require_admin_permission('content.write');

  if p ? 'audience_type'
     or p ? 'audience_group_id'
     or p ? 'audience_group_ids'
     or p ? 'audience_user_ids'
     or p ? 'audience_mode' then
    raise exception 'use_admin_set_news_audience' using errcode = '22023';
  end if;

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    title = case when p ? 'title' then coalesce(p->>'title', '') else n.title end,
    subtitle = case when p ? 'subtitle' then coalesce(p->>'subtitle', '') else n.subtitle end,
    body = case when p ? 'body' then coalesce(p->>'body', '') else n.body end,
    variant = case
      when p ? 'variant' then (p->>'variant')::public.news_card_variant
      else n.variant
    end,
    gradient_colors = case
      when p ? 'gradient_colors' then array(
        select jsonb_array_elements_text(p->'gradient_colors')
      )
      else n.gradient_colors
    end,
    image_path = case
      when p ? 'image_path' then nullif(p->>'image_path', '')
      else n.image_path
    end,
    image_focus_x = case
      when p ? 'image_focus_x' then (p->>'image_focus_x')::double precision
      else n.image_focus_x
    end,
    image_focus_y = case
      when p ? 'image_focus_y' then (p->>'image_focus_y')::double precision
      else n.image_focus_y
    end,
    overlay_opacity = case
      when p ? 'overlay_opacity' then (p->>'overlay_opacity')::double precision
      else n.overlay_opacity
    end,
    is_hidden = case
      when p ? 'is_hidden' then (p->>'is_hidden')::boolean
      else n.is_hidden
    end,
    priority = case
      when p ? 'priority' then (p->>'priority')::integer
      else n.priority
    end,
    starts_at = case
      when p ? 'starts_at' then nullif(p->>'starts_at', '')::timestamptz
      else n.starts_at
    end,
    ends_at = case
      when p ? 'ends_at' then nullif(p->>'ends_at', '')::timestamptz
      else n.ends_at
    end,
    sort_order = case
      when p ? 'sort_order' then (p->>'sort_order')::integer
      else n.sort_order
    end,
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.update_draft',
    'news_post',
    p_id::text,
    jsonb_build_object('version_number', v_row.version_number)
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_publish_news(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
  v_mode text;
  v_recipients integer;
begin
  v_uid := private.require_admin_permission('content.publish');

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  -- Reject invalid / empty targeted audiences before going live.
  perform private.news_assert_audience_consistent(p_id);
  v_mode := private.news_audience_mode(p_id);
  v_recipients := coalesce(
    (private.news_preview_audience_count(p_id) ->> 'recipient_count')::integer,
    0
  );
  if v_mode in ('groups', 'users', 'groups_and_users') and v_recipients < 1 then
    raise exception 'audience_empty_recipients' using errcode = '22023';
  end if;

  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    status = 'published',
    published_by = v_uid,
    published_at = coalesce(n.published_at, now()),
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.publish',
    'news_post',
    p_id::text,
    jsonb_build_object(
      'version_number', v_row.version_number,
      'audience_mode', private.news_audience_mode(p_id)
    )
  );

  return private.news_post_to_json(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Admin RPC: audience preview (count + safe breakdown, no student PII)
-- ---------------------------------------------------------------------------
create or replace function public.admin_preview_news_audience(p_id uuid)
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

  if not exists (select 1 from public.news_posts where id = p_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_result := private.news_preview_audience_count(p_id);

  perform private.admin_write_audit(
    'news.preview_audience',
    'news_post',
    p_id::text,
    jsonb_build_object('recipient_count', v_result -> 'recipient_count')
  );

  return v_result;
end;
$$;

comment on function public.admin_preview_news_audience(uuid) is
  'Stage 15.2 news audience preview: recipient_count + group/explicit-count breakdown. Never returns a student list.';

-- ---------------------------------------------------------------------------
-- 10. Duplicate / restore must carry the junctions, otherwise a targeted post
--     would silently fall back to legacy semantics.
-- ---------------------------------------------------------------------------
create or replace function public.admin_duplicate_news(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_src public.news_posts;
  v_row public.news_posts;
  v_sort integer;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_src from public.news_posts where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select coalesce(max(sort_order), -1) + 1 into v_sort from public.news_posts;

  insert into public.news_posts (
    status, sort_order, priority, starts_at, ends_at,
    audience_type, audience_group_id, variant,
    title, subtitle, body, gradient_colors,
    image_path, image_focus_x, image_focus_y, overlay_opacity,
    is_hidden, created_by, updated_by
  ) values (
    'draft', v_sort, v_src.priority, v_src.starts_at, v_src.ends_at,
    v_src.audience_type, v_src.audience_group_id, v_src.variant,
    v_src.title || ' (копия)', v_src.subtitle, v_src.body, v_src.gradient_colors,
    v_src.image_path, v_src.image_focus_x, v_src.image_focus_y, v_src.overlay_opacity,
    v_src.is_hidden, v_uid, v_uid
  )
  returning * into v_row;

  insert into public.news_audience_groups (news_post_id, group_id)
  select v_row.id, g.group_id
  from public.news_audience_groups g
  where g.news_post_id = p_id;

  insert into public.news_audience_users (news_post_id, user_id)
  select v_row.id, au.user_id
  from public.news_audience_users au
  where au.news_post_id = p_id;

  perform private.news_assert_audience_consistent(v_row.id);

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.duplicate',
    'news_post',
    v_row.id::text,
    jsonb_build_object(
      'source_id', p_id,
      'audience_mode', private.news_audience_mode(v_row.id)
    )
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_restore_news_version(
  p_id uuid,
  p_version_number integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_snap jsonb;
  v_row public.news_posts;
begin
  v_uid := private.require_admin_permission('content.write');

  select snapshot into v_snap
  from public.news_versions
  where news_post_id = p_id and version_number = p_version_number;

  if v_snap is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    -- restore content fields; keep status unless snapshot had draft/published and not archived force
    title = coalesce(v_snap->>'title', ''),
    subtitle = coalesce(v_snap->>'subtitle', ''),
    body = coalesce(v_snap->>'body', ''),
    variant = coalesce(v_snap->>'variant', 'gradientText')::public.news_card_variant,
    gradient_colors = coalesce(
      array(select jsonb_array_elements_text(v_snap->'gradient_colors')),
      n.gradient_colors
    ),
    image_path = nullif(v_snap->>'image_path', ''),
    image_focus_x = coalesce((v_snap->>'image_focus_x')::double precision, 0),
    image_focus_y = coalesce((v_snap->>'image_focus_y')::double precision, 0),
    overlay_opacity = coalesce((v_snap->>'overlay_opacity')::double precision, 0.42),
    is_hidden = coalesce((v_snap->>'is_hidden')::boolean, false),
    priority = coalesce((v_snap->>'priority')::integer, 0),
    starts_at = nullif(v_snap->>'starts_at', '')::timestamptz,
    ends_at = nullif(v_snap->>'ends_at', '')::timestamptz,
    audience_type = coalesce(v_snap->>'audience_type', 'all')::public.news_audience_type,
    audience_group_id = nullif(v_snap->>'audience_group_id', '')::uuid,
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  -- Audience junctions are part of the snapshot. Pre-15.2 snapshots have no
  -- junction keys, which correctly restores an empty junction set.
  delete from public.news_audience_groups where news_post_id = p_id;
  insert into public.news_audience_groups (news_post_id, group_id)
  select p_id, g.value::uuid
  from jsonb_array_elements_text(
    coalesce(v_snap -> 'audience_group_ids', '[]'::jsonb)
  ) as g(value)
  where exists (select 1 from public.groups gr where gr.id = g.value::uuid);

  delete from public.news_audience_users where news_post_id = p_id;
  insert into public.news_audience_users (news_post_id, user_id)
  select p_id, u.value::uuid
  from jsonb_array_elements_text(
    coalesce(v_snap -> 'audience_user_ids', '[]'::jsonb)
  ) as u(value)
  where exists (select 1 from public.users us where us.id = u.value::uuid);

  -- Loud failure instead of a silently widened or empty audience.
  perform private.news_assert_audience_consistent(p_id);

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.restore_version',
    'news_post',
    p_id::text,
    jsonb_build_object(
      'restored_version', p_version_number,
      'new_version', v_row.version_number,
      'audience_mode', private.news_audience_mode(p_id)
    )
  );

  return private.news_post_to_json(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. Student RPCs now go through the single helper.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_published_news()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', n.id,
          'status', n.status,
          'sort_order', n.sort_order,
          'priority', n.priority,
          'starts_at', n.starts_at,
          'ends_at', n.ends_at,
          'audience_type', n.audience_type,
          'audience_group_id', n.audience_group_id,
          'variant', n.variant,
          'title', n.title,
          'subtitle', n.subtitle,
          'body', n.body,
          'gradient_colors', to_jsonb(n.gradient_colors),
          'image_path', n.image_path,
          'image_focus_x', n.image_focus_x,
          'image_focus_y', n.image_focus_y,
          'overlay_opacity', n.overlay_opacity,
          'published_at', n.published_at,
          'created_at', n.created_at,
          'updated_at', n.updated_at,
          'seen', (nv.seen_at is not null),
          'closed', (nv.closed_at is not null)
        )
        order by n.sort_order, n.priority desc, n.published_at desc nulls last
      )
      from public.news_posts n
      left join public.news_views nv
        on nv.news_post_id = n.id and nv.user_id = v_uid
      where n.status = 'published'
        and not n.is_hidden
        and (n.starts_at is null or n.starts_at <= now())
        and (n.ends_at is null or n.ends_at >= now())
        and private.news_audience_matches(n.id, v_uid)
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.mark_news_seen(
  p_news_id uuid,
  p_closed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not private.news_post_deliverable_to_user(p_news_id, v_uid) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  insert into public.news_views (news_post_id, user_id, seen_at, closed_at)
  values (
    p_news_id,
    v_uid,
    now(),
    case when p_closed then now() else null end
  )
  on conflict (news_post_id, user_id) do update
    set seen_at = public.news_views.seen_at,
        closed_at = case
          when p_closed then coalesce(public.news_views.closed_at, now())
          else public.news_views.closed_at
        end;

  return jsonb_build_object('ok', true, 'news_id', p_news_id, 'closed', p_closed);
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. Grants (RBAC is enforced inside each function body)
-- ---------------------------------------------------------------------------
revoke all on function private.news_post_to_json(public.news_posts)
  from public, anon, authenticated;
grant execute on function private.news_post_to_json(public.news_posts)
  to service_role;

revoke all on function public.admin_set_news_audience(uuid, text, integer, uuid[], uuid[])
  from public, anon;
grant execute on function public.admin_set_news_audience(uuid, text, integer, uuid[], uuid[])
  to authenticated, service_role;

revoke all on function public.admin_update_news_draft(uuid, jsonb) from public, anon;
grant execute on function public.admin_update_news_draft(uuid, jsonb)
  to authenticated, service_role;

revoke all on function public.admin_publish_news(uuid) from public, anon;
grant execute on function public.admin_publish_news(uuid)
  to authenticated, service_role;

revoke all on function public.admin_preview_news_audience(uuid) from public, anon;
grant execute on function public.admin_preview_news_audience(uuid)
  to authenticated, service_role;

revoke all on function public.admin_duplicate_news(uuid) from public, anon;
grant execute on function public.admin_duplicate_news(uuid)
  to authenticated, service_role;

revoke all on function public.admin_restore_news_version(uuid, integer)
  from public, anon;
grant execute on function public.admin_restore_news_version(uuid, integer)
  to authenticated, service_role;

revoke all on function public.get_my_published_news() from public, anon;
grant execute on function public.get_my_published_news() to authenticated, service_role;

revoke all on function public.mark_news_seen(uuid, boolean) from public, anon;
grant execute on function public.mark_news_seen(uuid, boolean)
  to authenticated, service_role;

commit;
