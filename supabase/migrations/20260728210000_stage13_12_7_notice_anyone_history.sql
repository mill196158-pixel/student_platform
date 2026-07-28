-- Stage 13.12.7
-- - any active member may edit team chat notice
-- - append-only edit history with FORCE RLS
-- - rate limit per actor/team
--
-- NOTE: concurrency/history FK hardening is in the follow-up migration
-- 20260728211500_stage13_12_7_notice_upsert_harden.sql

create table if not exists public.team_chat_notice_events (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  actor_id uuid not null references public.users(id) on delete cascade,
  actor_display_name text not null default '',
  body text not null default '',
  row_version integer not null,
  created_at timestamptz not null default now(),
  constraint team_chat_notice_events_body_len check (char_length(body) <= 2000)
);

create index if not exists team_chat_notice_events_team_created_idx
  on public.team_chat_notice_events (team_id, created_at desc);

comment on table public.team_chat_notice_events is
  'Append-only history of team_chat_notices edits (body snapshots).';

alter table public.team_chat_notice_events enable row level security;
alter table public.team_chat_notice_events force row level security;

drop policy if exists team_chat_notice_events_select on public.team_chat_notice_events;
create policy team_chat_notice_events_select
  on public.team_chat_notice_events
  for select
  to authenticated
  using (private.is_active_team_member(team_id));

revoke all on table public.team_chat_notice_events from public, anon, authenticated;
grant select on table public.team_chat_notice_events to authenticated;

create or replace function private.can_edit_team_chat_notice(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_team_member(p_team_id);
$$;

revoke all on function private.can_edit_team_chat_notice(uuid)
  from public, anon, authenticated;

drop function if exists public.get_team_chat_notice(uuid);

create or replace function public.get_team_chat_notice(
  p_team_id uuid,
  p_history_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.team_chat_notices%rowtype;
  v_exists boolean := false;
  v_limit int := greatest(1, least(coalesce(p_history_limit, 20), 50));
  v_history jsonb := '[]'::jsonb;
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

  select * into v_row
  from public.team_chat_notices n
  where n.team_id = p_team_id;
  v_exists := found;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', e.id,
        'actor_id', e.actor_id,
        'actor_display_name', e.actor_display_name,
        'body', e.body,
        'row_version', e.row_version,
        'created_at', e.created_at,
        'cleared', btrim(e.body) = ''
      )
      order by e.created_at desc
    ),
    '[]'::jsonb
  )
  into v_history
  from (
    select *
    from public.team_chat_notice_events ev
    where ev.team_id = p_team_id
    order by ev.created_at desc
    limit v_limit
  ) e;

  if not v_exists then
    return jsonb_build_object(
      'team_id', p_team_id,
      'body', '',
      'updated_by', null,
      'updated_at', null,
      'row_version', 0,
      'can_edit', true,
      'history', coalesce(v_history, '[]'::jsonb)
    );
  end if;

  return jsonb_build_object(
    'team_id', v_row.team_id,
    'body', coalesce(v_row.body, ''),
    'updated_by', v_row.updated_by,
    'updated_at', v_row.updated_at,
    'row_version', v_row.row_version,
    'can_edit', true,
    'history', coalesce(v_history, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_team_chat_notice(uuid, integer) from public, anon;
grant execute on function public.get_team_chat_notice(uuid, integer) to authenticated;

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

  select * into v_row
  from public.team_chat_notices n
  where n.team_id = p_team_id
  for update;
  v_exists := found;

  if v_exists then
    if p_expected_version is null
       or v_row.row_version is distinct from p_expected_version then
      raise exception 'version_conflict' using errcode = '40001';
    end if;
    v_prev := coalesce(v_row.body, '');
    if v_prev = v_body then
      return public.get_team_chat_notice(p_team_id, 20);
    end if;
    update public.team_chat_notices
    set body = v_body,
        updated_by = auth.uid(),
        updated_at = now(),
        row_version = v_row.row_version + 1
    where team_id = p_team_id
    returning * into v_row;
  else
    if p_expected_version is not null and p_expected_version <> 0 then
      raise exception 'version_conflict' using errcode = '40001';
    end if;
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
    insert into public.team_chat_notices(team_id, body, updated_by, updated_at, row_version)
    values (p_team_id, v_body, auth.uid(), now(), 1)
    returning * into v_row;
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
