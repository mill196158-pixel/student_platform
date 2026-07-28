-- Stage 13.12.7 follow-up (matches remote stage13_12_7_notice_upsert_harden)
-- - preserve history if user deleted (actor_id SET NULL)
-- - advisory lock + unique_violation → version_conflict on first create
-- - unchanged-body no-op before rate limit

alter table public.team_chat_notice_events
  alter column actor_id drop not null;

alter table public.team_chat_notice_events
  drop constraint if exists team_chat_notice_events_actor_id_fkey;

alter table public.team_chat_notice_events
  add constraint team_chat_notice_events_actor_id_fkey
  foreign key (actor_id) references public.users(id) on delete set null;

create or replace function public.upsert_team_chat_notice(
  p_team_id uuid,
  p_body text,
  p_expected_version integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_body text := btrim(coalesce(p_body, ''));
  v_row public.team_chat_notices%rowtype;
  v_exists boolean := false;
  v_prev text := '';
  v_display text := '';
  v_recent int := 0;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_team_id is null then
    raise exception 'team_id_required' using errcode = '22023';
  end if;
  if char_length(v_body) > 2000 then
    raise exception 'body_too_long' using errcode = '22023';
  end if;
  if not private.can_edit_team_chat_notice(p_team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_team_id::text, 0));

  select * into v_row
  from public.team_chat_notices n
  where n.team_id = p_team_id
  for update;
  v_exists := found;

  if v_exists then
    v_prev := coalesce(v_row.body, '');
    if v_prev = v_body then
      return public.get_team_chat_notice(p_team_id, 20);
    end if;
    if p_expected_version is null
       or v_row.row_version is distinct from p_expected_version then
      raise exception 'version_conflict' using errcode = '40001';
    end if;
  else
    if v_body = '' then
      return jsonb_build_object(
        'team_id', p_team_id,
        'body', '',
        'updated_by', null,
        'updated_at', null,
        'row_version', 0,
        'can_edit', true,
        'history', '[]'::jsonb
      );
    end if;
    if p_expected_version is not null and p_expected_version <> 0 then
      raise exception 'version_conflict' using errcode = '40001';
    end if;
  end if;

  select count(*)::int into v_recent
  from public.team_chat_notice_events e
  where e.team_id = p_team_id
    and e.actor_id = auth.uid()
    and e.created_at > now() - interval '15 seconds';
  if coalesce(v_recent, 0) > 0 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  select
    nullif(
      btrim(concat_ws(' ', nullif(btrim(coalesce(u.surname, '')), ''),
                           nullif(btrim(coalesce(u.name, '')), ''))),
      ''
    )
  into v_display
  from public.users u
  where u.id = auth.uid();
  v_display := coalesce(v_display, 'Участник');

  if v_exists then
    update public.team_chat_notices
    set body = v_body,
        updated_by = auth.uid(),
        updated_at = now(),
        row_version = v_row.row_version + 1
    where team_id = p_team_id
    returning * into v_row;
  else
    begin
      insert into public.team_chat_notices(team_id, body, updated_by, updated_at, row_version)
      values (p_team_id, v_body, auth.uid(), now(), 1)
      returning * into v_row;
    exception when unique_violation then
      raise exception 'version_conflict' using errcode = '40001';
    end;
  end if;

  insert into public.team_chat_notice_events(
    team_id, actor_id, actor_display_name, body, row_version
  ) values (
    p_team_id, auth.uid(), v_display, v_body, v_row.row_version
  );

  return public.get_team_chat_notice(p_team_id, 20);
end;
$$;

revoke all on function public.upsert_team_chat_notice(uuid, text, integer)
  from public, anon;
grant execute on function public.upsert_team_chat_notice(uuid, text, integer)
  to authenticated;
