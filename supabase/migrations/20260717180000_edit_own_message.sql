-- Stage 8: safe edit of own plain-text messages (DM + team/group).
-- Adds edited_at and SECURITY DEFINER RPCs. No new client UPDATE grants.

alter table public.messages
  add column if not exists edited_at timestamptz null;

comment on column public.messages.edited_at is
  'Set when the author edits the message via edit_own_message; null means never edited.';

drop function if exists public.get_chat_messages_for_team(uuid, integer, timestamptz);

create function public.get_chat_messages_for_team(
  p_team_id uuid,
  p_limit integer default 400,
  p_since timestamp with time zone default '1970-01-01 00:00:00+00'::timestamptz
)
returns table (
  id uuid,
  chat_id uuid,
  author_id uuid,
  author_login text,
  author_name text,
  author_avatar_url text,
  text text,
  type text,
  msg_type text,
  at timestamptz,
  created_at timestamptz,
  edited_at timestamptz,
  reply_to_id uuid,
  assignment_id uuid,
  file_id uuid,
  attachments jsonb,
  reactions jsonb,
  user_reactions text[],
  is_pinned boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  -- Same visibility as public.get_my_teams(): membership ∪ teams of my group.
  if not exists (
    select 1
    from public.team_members tm
    where tm.team_id = p_team_id
      and tm.user_id = v_me
  ) and not exists (
    select 1
    from public.teams t
    join public.users u on u.id = v_me
    where t.id = p_team_id
      and t.group_name is not null
      and t.group_name = u.group_name
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'forbidden';
  end if;

  return query
  with main_chat as (
    select c.id
    from public.chats c
    where c.team_id = p_team_id
      and c.type = 'team_main'
    limit 1
  )
  select
    m.id,
    m.chat_id,
    m.author_id,
    u.login,
    trim(coalesce(u.name, '') || ' ' || coalesce(u.surname, '')),
    u.avatar_url,
    coalesce(m.content, m.body, ''),
    coalesce(m.msg_type, m.type, 'text'),
    coalesce(m.msg_type, m.type, 'text'),
    m.created_at,
    m.created_at,
    m.edited_at,
    m.reply_to_id,
    m.assignment_id,
    m.file_id,
    coalesce(m.attachments, '[]'::jsonb),
    (
      select coalesce(jsonb_object_agg(t.emoji, t.cnt), '{}'::jsonb)
      from (
        select mr.emoji, count(*)::bigint as cnt
        from public.message_reactions mr
        where mr.message_id = m.id
        group by mr.emoji
      ) t
    ),
    (
      select array_agg(mr.emoji)
      from public.message_reactions mr
      where mr.message_id = m.id
        and mr.user_id = v_me
    ),
    m.is_pinned
  from public.messages m
  join main_chat c on c.id = m.chat_id
  left join public.users u on u.id = m.author_id
  where m.created_at >= p_since
  order by m.created_at asc
  limit coalesce(p_limit, 400);
end;
$function$;

revoke all on function public.get_chat_messages_for_team(uuid, integer, timestamptz) from public;
revoke all on function public.get_chat_messages_for_team(uuid, integer, timestamptz) from anon;
grant execute on function public.get_chat_messages_for_team(uuid, integer, timestamptz) to authenticated;

create or replace function public.edit_own_message(
  p_message_id uuid,
  p_text text
)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
  v_msg public.messages;
  v_text text;
  v_msg_type text;
  v_payload jsonb;
  v_has_attachments boolean;
  c_max_len constant integer := 4096;
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_message_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'message_not_found';
  end if;

  select m.*
  into v_msg
  from public.messages m
  where m.id = p_message_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'message_not_found';
  end if;

  if v_msg.author_id is distinct from v_me then
    raise exception using
      errcode = 'P0001',
      message = 'not_author';
  end if;

  if exists (
    select 1
    from public.users u
    where u.id = v_msg.author_id
      and lower(coalesce(u.login, '')) = 'system'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'not_editable_type';
  end if;

  v_msg_type := coalesce(v_msg.msg_type, v_msg.type, '');
  if v_msg_type is distinct from 'text' then
    raise exception using
      errcode = 'P0001',
      message = 'not_editable_type';
  end if;

  if v_msg.assignment_id is not null or v_msg.file_id is not null then
    raise exception using
      errcode = 'P0001',
      message = 'not_editable_type';
  end if;

  v_has_attachments := case
    when v_msg.attachments is null then false
    when jsonb_typeof(v_msg.attachments) = 'array'
      then jsonb_array_length(v_msg.attachments) > 0
    when jsonb_typeof(v_msg.attachments) = 'object'
      then v_msg.attachments <> '{}'::jsonb
    else true
  end;

  if v_has_attachments then
    raise exception using
      errcode = 'P0001',
      message = 'not_editable_type';
  end if;

  if strpos(coalesce(v_msg.content, v_msg.body, ''), '__FG__:') > 0 then
    raise exception using
      errcode = 'P0001',
      message = 'not_editable_type';
  end if;

  if left(btrim(coalesce(v_msg.content, v_msg.body, '')), 1) = '{' then
    begin
      v_payload := coalesce(v_msg.content, v_msg.body, '')::jsonb;
    exception
      when invalid_text_representation then
        v_payload := null;
      when others then
        v_payload := null;
    end;

    if v_payload is not null
       and ((v_payload ? 'forward') or (v_payload ? 'from_chat_id')) then
      raise exception using
        errcode = 'P0001',
        message = 'not_editable_type';
    end if;
  end if;

  if v_msg.created_at <= (pg_catalog.now() - interval '12 hours') then
    raise exception using
      errcode = 'P0001',
      message = 'edit_window_expired';
  end if;

  v_text := btrim(coalesce(p_text, ''));
  if v_text = '' then
    raise exception using
      errcode = 'P0001',
      message = 'empty_text';
  end if;

  if char_length(v_text) > c_max_len then
    raise exception using
      errcode = 'P0001',
      message = 'text_too_long';
  end if;

  update public.messages m
  set
    content = v_text,
    body = v_text,
    edited_at = pg_catalog.now()
  where m.id = v_msg.id
  returning m.* into v_msg;

  return v_msg;
end;
$function$;

revoke all on function public.edit_own_message(uuid, text) from public;
revoke all on function public.edit_own_message(uuid, text) from anon;
grant execute on function public.edit_own_message(uuid, text) to authenticated;
