-- Close cross-chat reaction writes while preserving participant behavior.
begin;
CREATE OR REPLACE FUNCTION public.toggle_message_reaction(p_message_id uuid, p_emoji text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_chat_id uuid;
  v_chat_type text;
  v_team_id uuid;
  v_allowed boolean := false;
  v_old_emoji text;
  v_counts jsonb;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using hint = 'login required';
  end if;


  -- Authorize against the same visibility as get_chat_messages_page.
  -- Never read or mutate reaction state before this check.
  select c.id, c.type, c.team_id into v_chat_id, v_chat_type, v_team_id
  from public.messages m join public.chats c on c.id = m.chat_id
  where m.id = p_message_id;
  if v_chat_type = 'dm' then
    v_allowed := exists (
      select 1 from public.chat_members cm
      where cm.chat_id = v_chat_id and cm.user_id = v_uid);
  elsif v_chat_type = 'team_main' and v_team_id is not null then
    v_allowed := exists (
      select 1 from public.team_members tm
      where tm.team_id = v_team_id and tm.user_id = v_uid
    ) or exists (
      select 1 from public.teams t join public.users u on u.id = v_uid
      where t.id = v_team_id and t.group_name is not null
        and t.group_name = u.group_name);
  end if;
  if not v_allowed then
    raise exception using errcode = 'P0001', message = 'forbidden';
  end if;
  -- Existing archive write-block triggers remain authoritative.

  -- Читаем, есть ли уже реакция этого пользователя на это сообщение
  select emoji into v_old_emoji
  from public.message_reactions
  where message_id = p_message_id and user_id = v_uid
  limit 1;

  if v_old_emoji is null then
    -- нет записи: вставляем
    insert into public.message_reactions(message_id, user_id, emoji)
    values (p_message_id, v_uid, p_emoji);
  elsif v_old_emoji = p_emoji then
    -- тот же emoji: считаем это toggle off — удаляем запись
    delete from public.message_reactions
    where message_id = p_message_id and user_id = v_uid;
  else
    -- другой emoji: обновляем запись на новый emoji (меняем created_at)
    update public.message_reactions
    set emoji = p_emoji, created_at = now()
    where message_id = p_message_id and user_id = v_uid;
  end if;

  -- пересчитать агрегаты для этого сообщения
  select coalesce(jsonb_object_agg(emoji, cnt), '{}'::jsonb) into v_counts
  from (
    select emoji, count(*) as cnt
    from public.message_reactions
    where message_id = p_message_id
    group by emoji
  ) s;

  -- обновить кеш в messages.reactions (удобно для чтения)
  update public.messages set reactions = coalesce(v_counts, '{}'::jsonb)
  where id = p_message_id;

  return coalesce(v_counts, '{}'::jsonb);
end;
$function$
;
revoke all on function public.toggle_message_reaction(uuid,text) from PUBLIC, anon;
grant execute on function public.toggle_message_reaction(uuid,text) to authenticated;
commit;
