-- Stage 13.2 follow-up: Admin RPC to inspect group-space organizer sources.
-- Depends on Stage 13.2 (grants / active subject-team helper) and 13.5 (stage13_5_can).
-- Do not apply remotely without owner permission.
begin;

create or replace function public.admin_list_group_space_organizer_state(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_can_read boolean := false;
  v_can_manage boolean := false;
  v_group_name text;
  v_team uuid;
  v_members jsonb := '[]'::jsonb;
begin
  if p_group_id is null then
    raise exception 'group_required' using errcode = '22023';
  end if;

  v_can_read :=
    private.stage13_5_can('students.read')
    or private.stage13_5_can('students.write')
    or private.stage13_5_can('groups.write')
    or private.stage13_5_can('terms.manage');
  v_can_manage := private.is_group_space_admin();

  if not v_can_read then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select g.name into v_group_name from public.groups g where g.id = p_group_id;
  if v_group_name is null then
    raise exception 'group_not_found' using errcode = '22023';
  end if;

  select t.id into v_team
  from public.teams t
  where t.group_id = p_group_id and t.kind = 'group_space'
  limit 1;

  select coalesce(
    jsonb_agg(row_data order by row_data ->> 'surname', row_data ->> 'name', row_data ->> 'login'),
    '[]'::jsonb
  )
  into v_members
  from (
    select jsonb_build_object(
      'user_id', u.id,
      'login', coalesce(u.login, ''),
      'name', coalesce(u.name, ''),
      'surname', coalesce(u.surname, ''),
      'is_active', coalesce(u.is_active, true),
      'has_admin_grant', exists (
        select 1 from public.group_space_organizer_grants g
        where g.group_id = p_group_id
          and g.user_id = se.user_id
          and g.source = 'admin'
      ),
      'has_subject_team_authority', exists (
        select 1
        from public.team_members tm
        join public.teams t on t.id = tm.team_id
        where t.group_id = p_group_id
          and private.is_active_subject_team_for_group(t.id, p_group_id)
          and tm.user_id = se.user_id
          and tm.role in ('starosta', 'owner')
      ),
      'subject_team_roles', coalesce(
        (
          select jsonb_agg(distinct tm.role order by tm.role)
          from public.team_members tm
          join public.teams t on t.id = tm.team_id
          where t.group_id = p_group_id
            and private.is_active_subject_team_for_group(t.id, p_group_id)
            and tm.user_id = se.user_id
            and tm.role in ('starosta', 'owner')
        ),
        '[]'::jsonb
      ),
      'is_organizer', (
        exists (
          select 1 from public.group_space_organizer_grants g
          where g.group_id = p_group_id
            and g.user_id = se.user_id
            and g.source = 'admin'
        )
        or exists (
          select 1
          from public.team_members tm
          join public.teams t on t.id = tm.team_id
          where t.group_id = p_group_id
            and private.is_active_subject_team_for_group(t.id, p_group_id)
            and tm.user_id = se.user_id
            and tm.role in ('starosta', 'owner')
        )
      ),
      'sources', (
        select coalesce(jsonb_agg(src order by src), '[]'::jsonb)
        from (
          select 'admin'::text as src
          where exists (
            select 1 from public.group_space_organizer_grants g
            where g.group_id = p_group_id
              and g.user_id = se.user_id
              and g.source = 'admin'
          )
          union all
          select 'subject_team'::text as src
          where exists (
            select 1
            from public.team_members tm
            join public.teams t on t.id = tm.team_id
            where t.group_id = p_group_id
              and private.is_active_subject_team_for_group(t.id, p_group_id)
              and tm.user_id = se.user_id
              and tm.role in ('starosta', 'owner')
          )
        ) s
      )
    ) as row_data
    from public.student_enrollments se
    join public.users u on u.id = se.user_id
    where se.group_id = p_group_id
      and se.status = 'active'
      and se.ended_at is null
  ) members;

  return jsonb_build_object(
    'group_id', p_group_id,
    'group_name', v_group_name,
    'space_exists', v_team is not null,
    'team_id', v_team,
    'can_manage', v_can_manage,
    'members', v_members,
    'assistants_supported', false
  );
end;
$$;

revoke all on function public.admin_list_group_space_organizer_state(uuid)
  from public, anon;
grant execute on function public.admin_list_group_space_organizer_state(uuid)
  to authenticated, service_role;

-- Thin admin-facing alias that documents intent; same auth as set_group_space_organizer.
create or replace function public.admin_set_group_space_organizer(
  p_group_id uuid,
  p_user_id uuid,
  p_is_organizer boolean
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Ensures space exists before grant (manage path only).
  if private.is_group_space_admin() then
    perform public.admin_ensure_group_space_for_group(p_group_id);
  end if;
  perform public.set_group_space_organizer(p_group_id, p_user_id, p_is_organizer);
end;
$$;

revoke all on function public.admin_set_group_space_organizer(uuid, uuid, boolean)
  from public, anon;
grant execute on function public.admin_set_group_space_organizer(uuid, uuid, boolean)
  to authenticated, service_role;

commit;
