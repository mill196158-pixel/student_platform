-- Stage 13.12.8: server SoT for printable roster export + directory payload.

create or replace function private.can_export_team_roster(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_team_member(p_team_id)
    and (
      private.can_manage_team_topics(p_team_id)
      or private.can_manage_team_collections(p_team_id)
      or exists (
        select 1
        from public.team_members tm
        where tm.team_id = p_team_id
          and tm.user_id = auth.uid()
          and lower(coalesce(tm.role, '')) in ('owner', 'starosta', 'teacher', 'admin')
      )
    );
$$;

revoke all on function private.can_export_team_roster(uuid)
  from public, anon, authenticated;

create or replace function public.get_team_members_directory(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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

  return jsonb_build_object(
    'can_export_roster', private.can_export_team_roster(p_team_id),
    'members', public.list_team_members_directory(p_team_id)
  );
end;
$$;

revoke all on function public.get_team_members_directory(uuid)
  from public, anon;
grant execute on function public.get_team_members_directory(uuid)
  to authenticated;
