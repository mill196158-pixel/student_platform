-- Allow any chat member (DM peer or team chat member) to pin/unpin messages.
-- Direct table UPDATE stays author-only via RLS; clients must use this RPC.

create or replace function public.pin_message(
  p_message_id uuid,
  p_pinned boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_chat_id uuid;
  v_allowed boolean := false;
begin
  if v_uid is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  select m.chat_id
  into v_chat_id
  from public.messages m
  where m.id = p_message_id;

  if v_chat_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_found';
  end if;

  -- DM + any membership row
  select exists (
    select 1
    from public.chat_members cm
    where cm.chat_id = v_chat_id
      and cm.user_id = v_uid
  )
  into v_allowed;

  -- Team chats: also allow team_members even if chat_members row is missing
  if not v_allowed then
    select exists (
      select 1
      from public.chats c
      join public.team_members tm
        on tm.team_id = c.team_id
       and tm.user_id = v_uid
      where c.id = v_chat_id
        and c.team_id is not null
    )
    into v_allowed;
  end if;

  if not coalesce(v_allowed, false) then
    raise exception using
      errcode = 'P0001',
      message = 'insufficient_privilege';
  end if;

  update public.messages
  set is_pinned = p_pinned
  where id = p_message_id;

  return found;
end;
$function$;

revoke all on function public.pin_message(uuid, boolean) from public;
revoke all on function public.pin_message(uuid, boolean) from anon;
grant execute on function public.pin_message(uuid, boolean) to authenticated;
