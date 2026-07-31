-- Paginated chat messages with author/attachments/reactions in one round-trip.
-- Do not apply from the agent; ship via normal migration process.

create or replace function public.get_chat_messages_page(
  p_chat_id uuid,
  p_limit integer default 50,
  p_before_at timestamp with time zone default null,
  p_before_id uuid default null
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
  is_pinned boolean,
  has_more boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := (select auth.uid());
  v_limit integer;
  v_chat_type text;
  v_team_id uuid;
  v_cleared_at timestamptz;
  v_allowed boolean := false;
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_chat_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'chat_id_required';
  end if;

  v_limit := greatest(1, least(coalesce(p_limit, 50), 100));

  select c.type, c.team_id
    into v_chat_type, v_team_id
  from public.chats c
  where c.id = p_chat_id;

  if v_chat_type is null then
    raise exception using
      errcode = 'P0001',
      message = 'chat_not_found';
  end if;

  -- Expired academic archive: no history.
  if exists (
    select 1
    from public.chat_academic_archives a
    where a.chat_id = p_chat_id
      and a.expired_at is not null
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'academic_chat_expired';
  end if;

  if v_chat_type = 'dm' then
    v_allowed := exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = p_chat_id
        and cm.user_id = v_me
    );
  elsif v_chat_type = 'team_main' and v_team_id is not null then
    -- Same visibility as get_chat_messages_for_team / get_my_teams.
    v_allowed := exists (
      select 1
      from public.team_members tm
      where tm.team_id = v_team_id
        and tm.user_id = v_me
    ) or exists (
      select 1
      from public.teams t
      join public.users u on u.id = v_me
      where t.id = v_team_id
        and t.group_name is not null
        and t.group_name = u.group_name
    );
  end if;

  if not v_allowed then
    raise exception using
      errcode = 'P0001',
      message = 'forbidden';
  end if;

  select s.cleared_at
    into v_cleared_at
  from public.chat_user_settings s
  where s.user_id = v_me
    and s.chat_id = p_chat_id;

  return query
  with page as (
    select
      m.id,
      m.chat_id,
      m.author_id,
      u.login as author_login,
      trim(coalesce(u.name, '') || ' ' || coalesce(u.surname, '')) as author_name,
      u.avatar_url as author_avatar_url,
      coalesce(m.content, m.body, '') as text,
      coalesce(m.msg_type, m.type, 'text') as type,
      coalesce(m.msg_type, m.type, 'text') as msg_type,
      m.created_at as at,
      m.created_at,
      m.edited_at,
      m.reply_to_id,
      m.assignment_id,
      m.file_id,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', cf.id,
            'chat_id', cf.chat_id,
            'message_id', cf.message_id,
            'file_name', cf.file_name,
            'file_key', cf.file_key,
            'file_url', cf.file_url,
            'file_type', cf.file_type,
            'file_size', cf.file_size,
            'uploaded_by', cf.uploaded_by,
            'uploaded_at', cf.uploaded_at,
            'is_deleted', cf.is_deleted
          )
          order by cf.uploaded_at asc
        )
        from public.chat_files cf
        where cf.message_id = m.id
          and coalesce(cf.is_deleted, false) = false
      ), '[]'::jsonb) as attachments,
      (
        select coalesce(jsonb_object_agg(t.emoji, t.cnt), '{}'::jsonb)
        from (
          select mr.emoji, count(*)::bigint as cnt
          from public.message_reactions mr
          where mr.message_id = m.id
          group by mr.emoji
        ) t
      ) as reactions,
      (
        select array_agg(mr.emoji)
        from public.message_reactions mr
        where mr.message_id = m.id
          and mr.user_id = v_me
      ) as user_reactions,
      m.is_pinned,
      m.created_at as sort_at,
      m.id as sort_id
    from public.messages m
    left join public.users u on u.id = m.author_id
    where m.chat_id = p_chat_id
      and (v_cleared_at is null or m.created_at > v_cleared_at)
      and (
        p_before_at is null
        or m.created_at < p_before_at
        or (m.created_at = p_before_at and p_before_id is not null and m.id < p_before_id)
      )
    order by m.created_at desc, m.id desc
    limit v_limit + 1
  ),
  trimmed as (
    select *
    from page
    order by sort_at desc, sort_id desc
    limit v_limit
  ),
  meta as (
    select (select count(*)::int from page) > v_limit as has_more
  )
  select
    t.id,
    t.chat_id,
    t.author_id,
    t.author_login,
    t.author_name,
    t.author_avatar_url,
    t.text,
    t.type,
    t.msg_type,
    t.at,
    t.created_at,
    t.edited_at,
    t.reply_to_id,
    t.assignment_id,
    t.file_id,
    t.attachments,
    t.reactions,
    t.user_reactions,
    t.is_pinned,
    meta.has_more
  from trimmed t
  cross join meta
  order by t.at asc, t.id asc;
end;
$function$;

revoke all on function public.get_chat_messages_page(uuid, integer, timestamptz, uuid) from public;
revoke all on function public.get_chat_messages_page(uuid, integer, timestamptz, uuid) from anon;
grant execute on function public.get_chat_messages_page(uuid, integer, timestamptz, uuid) to authenticated;
