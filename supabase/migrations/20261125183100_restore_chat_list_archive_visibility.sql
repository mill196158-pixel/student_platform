-- Preserve group-space summaries and the per-student personal archive/clear boundary.
create or replace function public.get_my_chat_summaries()
returns table(
  chat_id uuid, chat_type text, team_id uuid, team_kind text, team_name text,
  team_icon text, team_teacher text, team_group_name text, peer_id uuid, title text,
  avatar_url text, last_message_id uuid, last_message_at timestamptz, last_author_id uuid,
  last_author_name text, body text, content text, msg_type text, unread_count integer,
  is_pinned boolean, is_muted boolean, is_archived boolean, hidden_at timestamptz,
  cleared_at timestamptz, settings_exists boolean
)
language plpgsql security definer stable set search_path = '' as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;

  return query
  with my_teams as (
    select t.id, t.kind, t.name, t.teacher, t.icon, t.group_name
    from public.teams t
    join public.team_members tm on tm.team_id = t.id and tm.user_id = v_me
    union
    select t.id, t.kind, t.name, t.teacher, t.icon, t.group_name
    from public.teams t
    join public.users u on u.id = v_me and u.group_name = t.group_name
    where t.kind = 'subject'
  ), accessible as (
    select c.id as chat_id, c.type as chat_type, c.team_id, null::text as team_kind,
      null::text as team_name, null::text as team_icon, null::text as team_teacher,
      null::text as team_group_name
    from public.chats c
    join public.chat_members cm on cm.chat_id = c.id and cm.user_id = v_me
    where c.type = 'dm'
    union all
    select c.id, c.type, c.team_id, t.kind, t.name, t.icon, t.teacher, t.group_name
    from my_teams t
    join public.chats c on c.team_id = t.id and c.type = 'team_main'
    where not exists (select 1 from public.chat_academic_archives ar where ar.chat_id = c.id)
  )
  select a.chat_id, a.chat_type, a.team_id, coalesce(a.team_kind, 'subject'),
    a.team_name, a.team_icon, a.team_teacher, a.team_group_name, peer.id,
    case when a.chat_type = 'dm' then coalesce(nullif(peer.name, ''), 'Пользователь')
         else coalesce(a.team_name, '') end,
    case when a.chat_type = 'dm' then nullif(peer.avatar_url, '') end,
    lm.id, lm.created_at, lm.author_id,
    nullif(trim(concat(au.name, ' ', au.surname)), ''), lm.body, lm.content, lm.msg_type,
    ur.unread_count, coalesce(s.is_pinned, false), coalesce(s.is_muted, false),
    coalesce(s.is_archived, false), s.hidden_at, s.cleared_at, s.user_id is not null
  from accessible a
  left join public.chat_user_settings s on s.user_id = v_me and s.chat_id = a.chat_id
  left join lateral (
    select u.id, trim(concat(u.name, ' ', u.surname)) as name, u.avatar_url
    from public.chat_members cm
    join public.users u on u.id = cm.user_id
    where a.chat_type = 'dm' and cm.chat_id = a.chat_id and cm.user_id <> v_me
    limit 1
  ) peer on true
  left join lateral (
    select m.id, m.author_id, m.created_at, m.body, m.content, m.msg_type
    from public.messages m
    where m.chat_id = a.chat_id and (s.cleared_at is null or m.created_at > s.cleared_at)
    order by m.created_at desc, m.id desc
    limit 1
  ) lm on true
  left join public.users au on au.id = lm.author_id
  left join public.chat_reads cr on cr.chat_id = a.chat_id and cr.user_id = v_me
  cross join lateral (
    select count(*)::integer as unread_count
    from public.messages m
    where m.chat_id = a.chat_id and m.author_id <> v_me
      and m.created_at > greatest(coalesce(cr.last_read_at, to_timestamp(0)),
                                  coalesce(s.cleared_at, to_timestamp(0)))
  ) ur
  where a.chat_type <> 'dm' or (
    not coalesce(s.is_archived, false)
    and (s.hidden_at is null or lm.created_at > s.hidden_at)
  )
  order by coalesce(s.is_pinned, false) desc, lm.created_at desc nulls last, a.chat_id;
end
$$;

revoke all on function public.get_my_chat_summaries() from public, anon;
grant execute on function public.get_my_chat_summaries() to authenticated;
