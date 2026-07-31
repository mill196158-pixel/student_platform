-- Stage 13.12.4 — allow organizers/authors to reschedule a collection deadline
-- without a full collection rewrite. Narrow, reversible mutator.
-- Concurrency: expects/increments row_version (same contract as topic mutators).

create or replace function public.update_group_collection_deadline(
  p_collection_id uuid,
  p_deadline_at timestamptz,
  p_expected_version integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c public.group_collections%rowtype;
  v_new_version int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_c
  from public.group_collections
  where id = p_collection_id
  for update;
  if not found then
    raise exception 'collection_not_found' using errcode = 'P0002';
  end if;
  if v_c.status is distinct from 'open' then
    raise exception 'collection_unavailable' using errcode = '42501';
  end if;

  if p_expected_version is not null
     and v_c.row_version is distinct from p_expected_version then
    raise exception 'version_conflict' using errcode = 'P0001';
  end if;

  -- Every caller must still be an active team member.
  if not private.is_active_team_member(v_c.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if private.can_manage_team_collections(v_c.team_id) then
    null;
  elsif v_c.created_by = auth.uid() then
    null;
  else
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.group_collections
  set deadline_at = p_deadline_at,
      row_version = row_version + 1,
      updated_at = now()
  where id = p_collection_id
  returning row_version into v_new_version;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id,
    auth.uid(),
    'deadline_updated',
    jsonb_build_object(
      'deadline_at', p_deadline_at,
      'row_version', v_new_version
    )
  );

  return jsonb_build_object(
    'ok', true,
    'deadline_at', p_deadline_at,
    'row_version', v_new_version
  );
end;
$$;

revoke all on function public.update_group_collection_deadline(uuid, timestamptz, integer)
  from public, anon;
grant execute on function public.update_group_collection_deadline(uuid, timestamptz, integer)
  to authenticated, service_role;

-- Drop older 2-arg signature if a previous draft was applied locally.
drop function if exists public.update_group_collection_deadline(uuid, timestamptz);
