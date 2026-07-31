-- Per-user dialog settings for chats (pin / mute / archive / hide / clear).

create table if not exists public.chat_user_settings (
  user_id uuid not null references public.users(id) on delete cascade,
  chat_id uuid not null references public.chats(id) on delete cascade,
  is_pinned boolean not null default false,
  is_muted boolean not null default false,
  is_archived boolean not null default false,
  hidden_at timestamptz null,
  cleared_at timestamptz null,
  updated_at timestamptz not null default now(),
  primary key (user_id, chat_id)
);

create index if not exists chat_user_settings_user_id_idx
  on public.chat_user_settings (user_id);

alter table public.chat_user_settings enable row level security;

revoke all privileges on table public.chat_user_settings from public;
revoke all privileges on table public.chat_user_settings from anon;
revoke all privileges on table public.chat_user_settings from authenticated;

grant select, insert, update, delete on table public.chat_user_settings to authenticated;

drop policy if exists chat_user_settings_select_own on public.chat_user_settings;
create policy chat_user_settings_select_own
on public.chat_user_settings
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists chat_user_settings_insert_own on public.chat_user_settings;
create policy chat_user_settings_insert_own
on public.chat_user_settings
for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists chat_user_settings_update_own on public.chat_user_settings;
create policy chat_user_settings_update_own
on public.chat_user_settings
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists chat_user_settings_delete_own on public.chat_user_settings;
create policy chat_user_settings_delete_own
on public.chat_user_settings
for delete
to authenticated
using (user_id = auth.uid());

-- Realtime publication (idempotent)
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_user_settings'
  ) then
    alter publication supabase_realtime add table public.chat_user_settings;
  end if;
end $$;
