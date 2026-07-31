-- Stage 13.12.10: group-wide starosta display + capabilities (derive, do not copy).
-- Local migration — apply remotely only with explicit OK.
--
-- Product rule: if a student is starosta of the group (shown in group space
-- member list), they appear as «Староста» in EVERY subject team chat directory
-- of that group, and can moderate topics there.
--
-- Authority stays canonical:
--   admin grant OR live starosta/owner on an active subject team.
-- Do NOT persist derived roles onto subject team_members (avoids trigger
-- recursion and irreversible promotion).

-- ---------------------------------------------------------------------------
-- 1) Arbitrary-user organizer helper (mirrors is_group_space_organizer).
-- ---------------------------------------------------------------------------
create or replace function private.is_group_space_organizer_for_user(
  p_group_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_group_id is not null
    and p_user_id is not null
    and exists (
      select 1
      from public.student_enrollments se
      where se.group_id = p_group_id
        and se.user_id = p_user_id
        and se.status = 'active'
        and se.ended_at is null
    )
    and (
      exists (
        select 1
        from public.group_space_organizer_grants g
        where g.group_id = p_group_id
          and g.user_id = p_user_id
          and g.source = 'admin'
      )
      or exists (
        select 1
        from public.team_members tm
        join public.teams t on t.id = tm.team_id
        where t.group_id = p_group_id
          and private.is_active_subject_team_for_group(t.id, p_group_id)
          and tm.user_id = p_user_id
          and lower(coalesce(tm.role, '')) in ('starosta', 'owner')
      )
    );
$$;

revoke all on function private.is_group_space_organizer_for_user(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Moderation: group organizer manages topics on ALL subject teams.
-- ---------------------------------------------------------------------------
create or replace function private.can_manage_team_topics(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_team_member(p_team_id)
    and exists (
      select 1
      from public.teams t
      where t.id = p_team_id
        and coalesce(t.kind, 'subject') = 'subject'
        and t.group_id is not null
        and (
          private.is_group_space_organizer(t.group_id)
          or exists (
            select 1
            from public.team_members tm
            where tm.team_id = t.id
              and tm.user_id = auth.uid()
              and lower(coalesce(tm.role, '')) in ('starosta', 'owner')
          )
        )
    );
$$;

revoke all on function private.can_manage_team_topics(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3) Member directory: overlay «Староста» for group organizers on subject teams.
-- ---------------------------------------------------------------------------
create or replace function public.list_team_members_directory(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_group_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_team_id is null then
    raise exception 'team_id_required' using errcode = '22023';
  end if;
  if not private.is_active_team_member(p_team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select t.group_id into v_group_id from public.teams t where t.id = p_team_id;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'user_id', x.user_id,
          'display_name', x.display_name,
          'role', x.role,
          'avatar_url', x.avatar_url
        )
        order by x.sort_key, x.user_id
      )
      from (
        select
          tm.user_id,
          case
            when lower(coalesce(nullif(btrim(tm.role), ''), 'member'))
              in ('owner', 'teacher', 'admin', 'starosta')
              then lower(nullif(btrim(tm.role), ''))
            when v_group_id is not null
              and private.is_group_space_organizer_for_user(v_group_id, tm.user_id)
              then 'starosta'
            else coalesce(nullif(btrim(lower(tm.role)), ''), 'member')
          end as role,
          nullif(btrim(coalesce(u.avatar_url, '')), '') as avatar_url,
          nullif(
            btrim(concat_ws(' ', nullif(btrim(coalesce(u.surname, '')), ''),
                                 nullif(btrim(coalesce(u.name, '')), ''))),
            ''
          ) as display_name,
          lower(
            coalesce(
              nullif(
                btrim(concat_ws(' ', nullif(btrim(coalesce(u.surname, '')), ''),
                                     nullif(btrim(coalesce(u.name, '')), ''))),
                ''
              ),
              coalesce(u.login::text, tm.user_id::text)
            )
          ) as sort_key
        from public.team_members tm
        join public.users u on u.id = tm.user_id
        where tm.team_id = p_team_id
          and tm.user_id in (
            select private.active_team_member_user_ids(p_team_id)
          )
          and coalesce(u.is_active, true) = true
      ) x
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.list_team_members_directory(uuid)
  from public, anon;
grant execute on function public.list_team_members_directory(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) Caller-scoped organizer state for Flutter (no grants-table reads).
-- ---------------------------------------------------------------------------
create or replace function public.get_my_team_organizer_state(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_team public.teams%rowtype;
  v_local_role text;
  v_is_organizer boolean := false;
  v_effective text := 'member';
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_team_id is null then
    raise exception 'team_id_required' using errcode = '22023';
  end if;
  if not private.is_active_team_member(p_team_id) then
    return jsonb_build_object(
      'is_organizer', false,
      'effective_role', 'member',
      'local_role', null
    );
  end if;

  select * into v_team from public.teams where id = p_team_id;
  if not found then
    return jsonb_build_object(
      'is_organizer', false,
      'effective_role', 'member',
      'local_role', null
    );
  end if;

  select lower(coalesce(nullif(btrim(tm.role), ''), 'member'))
    into v_local_role
  from public.team_members tm
  where tm.team_id = p_team_id
    and tm.user_id = auth.uid();

  v_local_role := coalesce(v_local_role, 'member');
  v_effective := v_local_role;

  if v_local_role in ('owner', 'teacher', 'admin', 'starosta') then
    v_is_organizer := true;
  elsif v_team.group_id is not null
    and private.is_group_space_organizer(v_team.group_id) then
    v_is_organizer := true;
    v_effective := 'starosta';
  elsif coalesce(v_team.kind, 'subject') = 'subject'
    and private.can_manage_team_topics(p_team_id) then
    v_is_organizer := true;
    v_effective := 'starosta';
  elsif coalesce(v_team.kind, '') = 'group_space'
    and private.can_manage_team_collections(p_team_id) then
    v_is_organizer := true;
    v_effective := 'starosta';
  end if;

  return jsonb_build_object(
    'is_organizer', v_is_organizer,
    'effective_role', v_effective,
    'local_role', v_local_role
  );
end;
$$;

revoke all on function public.get_my_team_organizer_state(uuid)
  from public, anon;
grant execute on function public.get_my_team_organizer_state(uuid)
  to authenticated, service_role;
