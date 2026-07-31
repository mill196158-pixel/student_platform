-- Stage 6: Realtime for chat list + tighten chat_reads RLS/grants.
-- - add chat_reads / chat_members to supabase_realtime (idempotent)
-- - own read-state only, and only if team member OR DM chat_member
-- - authenticated: SELECT/INSERT/UPDATE/DELETE only; no anon/PUBLIC

-- Realtime publication (idempotent; messages/chats/chat_user_settings already present)
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_reads'
  ) then
    alter publication supabase_realtime add table public.chat_reads;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_members'
  ) then
    alter publication supabase_realtime add table public.chat_members;
  end if;
end $$;

alter table public.chat_reads enable row level security;

revoke all privileges on table public.chat_reads from public;
revoke all privileges on table public.chat_reads from anon;
revoke all privileges on table public.chat_reads from authenticated;

grant select, insert, update, delete on table public.chat_reads to authenticated;

drop policy if exists "chat_reads - own & member" on public.chat_reads;
drop policy if exists chat_reads_select_own_member on public.chat_reads;
drop policy if exists chat_reads_insert_own_member on public.chat_reads;
drop policy if exists chat_reads_update_own_member on public.chat_reads;
drop policy if exists chat_reads_delete_own_member on public.chat_reads;

create policy chat_reads_select_own_member
on public.chat_reads
for select
to authenticated
using (
  user_id = auth.uid()
  and (
    exists (
      select 1
      from public.chats c
      join public.team_members tm on tm.team_id = c.team_id
      where c.id = chat_reads.chat_id
        and tm.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = chat_reads.chat_id
        and cm.user_id = auth.uid()
    )
  )
);

create policy chat_reads_insert_own_member
on public.chat_reads
for insert
to authenticated
with check (
  user_id = auth.uid()
  and (
    exists (
      select 1
      from public.chats c
      join public.team_members tm on tm.team_id = c.team_id
      where c.id = chat_reads.chat_id
        and tm.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = chat_reads.chat_id
        and cm.user_id = auth.uid()
    )
  )
);

create policy chat_reads_update_own_member
on public.chat_reads
for update
to authenticated
using (
  user_id = auth.uid()
  and (
    exists (
      select 1
      from public.chats c
      join public.team_members tm on tm.team_id = c.team_id
      where c.id = chat_reads.chat_id
        and tm.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = chat_reads.chat_id
        and cm.user_id = auth.uid()
    )
  )
)
with check (
  user_id = auth.uid()
  and (
    exists (
      select 1
      from public.chats c
      join public.team_members tm on tm.team_id = c.team_id
      where c.id = chat_reads.chat_id
        and tm.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = chat_reads.chat_id
        and cm.user_id = auth.uid()
    )
  )
);

create policy chat_reads_delete_own_member
on public.chat_reads
for delete
to authenticated
using (
  user_id = auth.uid()
  and (
    exists (
      select 1
      from public.chats c
      join public.team_members tm on tm.team_id = c.team_id
      where c.id = chat_reads.chat_id
        and tm.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = chat_reads.chat_id
        and cm.user_id = auth.uid()
    )
  )
);
