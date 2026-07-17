-- Unified chat summaries for the current user (DM + team_main).
-- Replaces N+1 client calls with a single SECURITY DEFINER RPC.

-- Indexes required by the summaries query (create only if missing).
-- messages(chat_id, created_at) already exists (e.g. messages_chat_created_idx).
create index if not exists chat_members_user_chat_idx
  on public.chat_members (user_id, chat_id);

create index if not exists chat_reads_user_chat_idx
  on public.chat_reads (user_id, chat_id);

create or replace function public.get_my_chat_summaries()
returns table (
  chat_id uuid,
  chat_type text,
  team_id uuid,
  team_name text,
  team_icon text,
  team_teacher text,
  team_group_name text,
  peer_id uuid,
  title text,
  avatar_url text,
  last_message_id uuid,
  last_message_at timestamptz,
  last_author_id uuid,
  last_author_name text,
  body text,
  content text,
  msg_type text,
  unread_count integer,
  is_pinned boolean,
  is_muted boolean,
  is_archived boolean,
  hidden_at timestamptz,
  cleared_at timestamptz,
  settings_exists boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  return query
  with me as (
    select u.id, u.group_name
    from public.users u
    where u.id = v_me
    limit 1
  ),
  -- Same visibility as public.get_my_teams(): membership ∪ teams of my group.
  my_teams as (
    select t.id, t.name, t.teacher, t.icon, t.group_name
    from public.teams t
    join public.team_members tm on tm.team_id = t.id
    join me on tm.user_id = me.id
    union
    select t.id, t.name, t.teacher, t.icon, t.group_name
    from public.teams t
    join me on t.group_name = me.group_name
  ),
  accessible as (
    select
      c.id as chat_id,
      c.type as chat_type,
      c.team_id,
      null::text as team_name,
      null::text as team_icon,
      null::text as team_teacher,
      null::text as team_group_name
    from public.chats c
    join public.chat_members cm
      on cm.chat_id = c.id
     and cm.user_id = v_me
    where c.type = 'dm'

    union all

    select
      c.id as chat_id,
      c.type as chat_type,
      c.team_id,
      mt.name as team_name,
      mt.icon as team_icon,
      mt.teacher as team_teacher,
      mt.group_name as team_group_name
    from my_teams mt
    join public.chats c
      on c.team_id = mt.id
     and c.type = 'team_main'
  )
  select
    a.chat_id,
    a.chat_type,
    a.team_id,
    a.team_name,
    a.team_icon,
    a.team_teacher,
    a.team_group_name,
    peer.peer_id,
    case
      when a.chat_type = 'dm' then
        coalesce(nullif(trim(peer.title), ''), 'Личный чат')
      else
        coalesce(a.team_name, '')
    end as title,
    case
      when a.chat_type = 'dm' then nullif(peer.avatar_url, '')
      else null
    end as avatar_url,
    lm.id as last_message_id,
    lm.created_at as last_message_at,
    lm.author_id as last_author_id,
    case
      when au.id is null then null
      else nullif(
        trim(concat(coalesce(au.name, ''), ' ', coalesce(au.surname, ''))),
        ''
      )
    end as last_author_name,
    lm.body,
    lm.content,
    lm.msg_type,
    coalesce(ur.unread_count, 0) as unread_count,
    coalesce(s.is_pinned, false) as is_pinned,
    coalesce(s.is_muted, false) as is_muted,
    coalesce(s.is_archived, false) as is_archived,
    s.hidden_at,
    s.cleared_at,
    (s.user_id is not null) as settings_exists
  from accessible a
  left join lateral (
    select
      u.id as peer_id,
      trim(concat(coalesce(u.name, ''), ' ', coalesce(u.surname, ''))) as title,
      coalesce(u.avatar_url, '') as avatar_url
    from public.chat_members cm_peer
    join public.users u on u.id = cm_peer.user_id
    where a.chat_type = 'dm'
      and cm_peer.chat_id = a.chat_id
      and cm_peer.user_id <> v_me
    limit 1
  ) peer on true
  left join lateral (
    select
      m.id,
      m.author_id,
      m.created_at,
      m.body,
      m.content,
      m.msg_type
    from public.messages m
    where m.chat_id = a.chat_id
    order by m.created_at desc
    limit 1
  ) lm on true
  left join public.users au on au.id = lm.author_id
  left join lateral (
    select count(*)::integer as unread_count
    from public.messages m
    where m.chat_id = a.chat_id
      and m.author_id <> v_me
      and m.created_at > coalesce(
        (
          select cr.last_read_at
          from public.chat_reads cr
          where cr.chat_id = a.chat_id
            and cr.user_id = v_me
          limit 1
        ),
        to_timestamp(0)
      )
  ) ur on true
  left join public.chat_user_settings s
    on s.user_id = v_me
   and s.chat_id = a.chat_id
  order by
    coalesce(s.is_pinned, false) desc,
    lm.created_at desc nulls last;
end;
$function$;

revoke execute on function public.get_my_chat_summaries() from PUBLIC, anon;
grant execute on function public.get_my_chat_summaries() to authenticated;
