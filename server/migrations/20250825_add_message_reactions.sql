-- Add table to store aggregated reactions per message and RPC to toggle
create table if not exists message_reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages(id) on delete cascade,
  emoji text not null,
  user_id uuid not null,
  created_at timestamptz default now(),
  unique(message_id, emoji, user_id)
);

create or replace function public.toggle_message_reaction(
  p_message_id uuid,
  p_emoji text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  -- try delete existing
  delete from message_reactions
  where message_id = p_message_id and emoji = p_emoji and user_id = v_uid;

  if not found then
    insert into message_reactions(message_id, emoji, user_id)
    values (p_message_id, p_emoji, v_uid);
  end if;

  -- optional: update messages cache table or materialized column if you have one
end; $$;

grant execute on function public.toggle_message_reaction(uuid, text) to authenticated;







