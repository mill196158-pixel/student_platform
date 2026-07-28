-- Stage 13.12.8 follow-up: any active member may export the printable roster.
-- Names are already visible in the in-app members directory.

create or replace function private.can_export_team_roster(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_team_member(p_team_id);
$$;

revoke all on function private.can_export_team_roster(uuid)
  from public, anon, authenticated;
