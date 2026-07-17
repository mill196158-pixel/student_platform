-- Stage 7: DM read receipts need peer.last_read_at from public.chat_reads.
-- Own-row SELECT already exists (Stage 6). This adds SELECT of the peer's row
-- for DM members only. Insert/update/delete stay own-row only.
-- Team/group chat_reads visibility is unchanged.

drop policy if exists chat_reads_select_dm_peer on public.chat_reads;

create policy chat_reads_select_dm_peer
on public.chat_reads
for select
to authenticated
using (
  chat_reads.user_id <> auth.uid()
  and exists (
    select 1
    from public.chats c
    where c.id = chat_reads.chat_id
      and c.type = 'dm'
  )
  and exists (
    select 1
    from public.chat_members cm
    where cm.chat_id = chat_reads.chat_id
      and cm.user_id = auth.uid()
  )
  and exists (
    select 1
    from public.chat_members cm
    where cm.chat_id = chat_reads.chat_id
      and cm.user_id = chat_reads.user_id
  )
);
