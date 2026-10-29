create table private.dm_send_receipts (
  actor_id uuid not null references auth.users(id) on delete cascade,
  client_key text not null check (length(client_key) between 1 and 128),
  chat_id uuid not null references public.chats(id) on delete cascade,
  payload jsonb not null,
  message_id uuid not null references public.messages(id) on delete cascade,
  primary key (actor_id, client_key)
);
alter table private.dm_send_receipts enable row level security;
alter table private.dm_send_receipts force row level security;
revoke all on private.dm_send_receipts from public, anon, authenticated;

create or replace function public.send_dm_message_once(
  p_chat_id uuid, p_client_key text, p_text text,
  p_reply_to uuid default null, p_file_ids uuid[] default '{}'::uuid[]
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_payload jsonb := jsonb_build_object('text',p_text,'reply',p_reply_to,
    'files',coalesce(p_file_ids,'{}'::uuid[]));
  v_prior private.dm_send_receipts%rowtype;
  v_id uuid;
begin
  if v_actor is null then raise exception 'not_authenticated' using errcode='28000'; end if;
  if p_client_key is null or length(p_client_key) not between 1 and 128 then
    raise exception 'invalid_client_key' using errcode='22023';
  end if;
  if not exists(select 1 from public.chats c join public.chat_members cm on cm.chat_id=c.id
      where c.id=p_chat_id and c.type='dm' and cm.user_id=v_actor) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_actor::text || ':' || p_client_key,0));
  select * into v_prior from private.dm_send_receipts
    where actor_id=v_actor and client_key=p_client_key;
  if found then
    if v_prior.chat_id <> p_chat_id or v_prior.payload <> v_payload then
      raise exception 'idempotency_key_reused' using errcode='22023';
    end if;
    -- Acknowledgement replay performs no write, including after a later block.
    return v_prior.message_id;
  end if;
  v_id := public.send_message_in_chat_with_files(p_chat_id,p_text,p_reply_to,coalesce(p_file_ids,'{}'::uuid[]));
  insert into private.dm_send_receipts(actor_id,client_key,chat_id,payload,message_id)
    values(v_actor,p_client_key,p_chat_id,v_payload,v_id);
  return v_id;
end $$;
revoke all on function public.send_dm_message_once(uuid,text,text,uuid,uuid[]) from public,anon;
grant execute on function public.send_dm_message_once(uuid,text,text,uuid,uuid[]) to authenticated;
