-- Server setup for message pinning visible to everyone
-- Safe, idempotent. Run in Supabase SQL editor.

set search_path = public;

begin;

-- 1) Column for server-side pins
alter table public.messages
  add column if not exists is_pinned boolean not null default false;

-- 2) RLS policy to allow pin/unpin by author or team roles (owner/starosta)
-- Ensure RLS is enabled
alter table public.messages enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='messages' and policyname='messages_update_pin'
  ) then
    execute format(
      'create policy %I on public.messages for update to authenticated using (%s) with check (%s)',
      'messages_update_pin',
      'author_id = auth.uid() or exists (select 1 from public.chats c join public.team_members tm on tm.team_id = c.team_id where c.id = messages.chat_id and tm.user_id = auth.uid() and tm.role in (''owner'',''starosta''))',
      'author_id = auth.uid() or exists (select 1 from public.chats c join public.team_members tm on tm.team_id = c.team_id where c.id = messages.chat_id and tm.user_id = auth.uid() and tm.role in (''owner'',''starosta''))'
    );
  end if;
end$$;

-- 3) RPC to pin/unpin a message (uses same permission logic)
create or replace function public.pin_message(
  p_message_id uuid,
  p_pinned boolean
) returns boolean
language plpgsql
security definer
set search_path = public as $$
declare
  v_allowed boolean;
begin
  if auth.uid() is null then
    raise exception 'auth.uid() is null';
  end if;

  select (
           m.author_id = auth.uid()
           or exists (
             select 1 from public.chats c
             join public.team_members tm on tm.team_id = c.team_id
             where c.id = m.chat_id
               and tm.user_id = auth.uid()
               and tm.role in ('owner','starosta')
           )
         )
  into v_allowed
  from public.messages m
  where m.id = p_message_id;

  if not coalesce(v_allowed, false) then
    raise exception 'insufficient_privilege';
  end if;

  update public.messages
  set is_pinned = p_pinned
  where id = p_message_id;

  return found;
end
$$;

grant execute on function public.pin_message(uuid, boolean) to authenticated;

-- 4) Ensure messages are in realtime publication (no-op if already there)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'messages'
  ) then
    execute 'alter publication supabase_realtime add table public.messages';
  end if;
end$$;

commit;


