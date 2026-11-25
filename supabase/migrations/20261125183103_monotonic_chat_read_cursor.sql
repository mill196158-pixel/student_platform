-- Preserve the existing function owner and execute grants.
begin;
do $guard$
begin
  if pg_catalog.to_regprocedure('public.mark_chat_read(uuid,uuid)') is null then
    raise exception 'Expected existing chat read RPC';
  end if;
end
$guard$;

create or replace function public.mark_chat_read(p_chat_id uuid, p_message_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $function$
declare
  actor uuid := auth.uid();
  read_at timestamptz;
begin
  -- Match the chat history read scope, including retained team archives.
  if actor is null or not exists (
    select 1 from public.chats c
    where c.id = p_chat_id
      and not exists (select 1 from public.chat_academic_archives a
                      where a.chat_id = c.id and a.expired_at is not null)
      and (
        (c.type = 'dm' and exists (select 1 from public.chat_members cm
                                  where cm.chat_id = c.id and cm.user_id = actor))
        or (c.type = 'team_main' and c.team_id is not null and (
          exists (select 1 from public.team_members tm where tm.team_id = c.team_id and tm.user_id = actor)
          or exists (select 1 from public.teams t join public.users u on u.id = actor
                     where t.id = c.team_id and t.group_name = u.group_name)
        ))
      )
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_message_id is null then
    read_at := now();
  else
    select m.created_at into strict read_at
    from public.messages m
    where m.id = p_message_id and m.chat_id = p_chat_id;
  end if;

  insert into public.chat_reads as previous (chat_id, user_id, last_read_at, last_read_message_id)
  values (p_chat_id, actor, read_at, p_message_id)
  on conflict (chat_id, user_id) do update
  set last_read_at = excluded.last_read_at,
      last_read_message_id = coalesce(excluded.last_read_message_id, previous.last_read_message_id)
  where previous.last_read_at is null
     or excluded.last_read_at > previous.last_read_at
     or (excluded.last_read_at = previous.last_read_at and excluded.last_read_message_id is not null
         and (previous.last_read_message_id is null or excluded.last_read_message_id > previous.last_read_message_id));
end
$function$;
commit;
