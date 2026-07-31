-- Check pin_message setup, RLS and realtime for server-side message pinning
-- Safe to run in Supabase SQL editor. Uses auth.uid() of current session.

set search_path = public;

-- 1) Summary of prerequisites (column, function, publication, RLS, update policies)
with has_col as (
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'messages'
      and column_name = 'is_pinned'
  ) as has
), func_exists as (
  select exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'pin_message'
  ) as has
), in_pub as (
  select exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'messages'
  ) as has
), rls as (
  select c.relrowsecurity
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'messages'
), pol as (
  select count(*) filter (where cmd = 'UPDATE') as update_policies
  from pg_policies
  where schemaname = 'public' and tablename = 'messages'
)
select jsonb_build_object(
  'has_is_pinned', has_col.has,
  'has_pin_message', func_exists.has,
  'in_realtime_pub', in_pub.has,
  'rls_enabled', rls.relrowsecurity,
  'update_policy_count', pol.update_policies
) as summary
from has_col, func_exists, in_pub, rls, pol;

-- 2) Show pin_message definition if present
select coalesce(pg_get_functiondef(p.oid), '') as pin_message_def
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'pin_message';

-- 3) List RLS policies on messages (to verify UPDATE rights for pinning)
select policyname, cmd, permissive, roles, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'messages'
order by policyname;

-- 4) Who am I, and what is my team role for a recent message?
with my_msg as (
  select m.id, m.chat_id
  from public.messages m
  where m.author_id = auth.uid()
  order by m.created_at desc
  limit 1
), role_cte as (
  select tm.team_id, tm.user_id, tm.role
  from my_msg mm
  join public.chats c on c.id = mm.chat_id
  join public.team_members tm on tm.team_id = c.team_id and tm.user_id = auth.uid()
)
select jsonb_build_object(
  'auth_uid', auth.uid(),
  'team_id', role_cte.team_id,
  'role', role_cte.role
) as current_role
from role_cte;

-- 5) Test UPDATE of is_pinned on my last message (rolled back)
begin;
with my_msg as (
  select id from public.messages where author_id = auth.uid() order by created_at desc limit 1
)
update public.messages m
set is_pinned = not coalesce(is_pinned, false)
from my_msg
where m.id = my_msg.id
returning m.id, m.is_pinned as toggled_is_pinned;
rollback;

-- 6) Test RPC pin_message if exists (rolled back)
begin;
select case
  when exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'pin_message'
  ) then (
    select public.pin_message(
      (select id from public.messages where author_id = auth.uid() order by created_at desc limit 1),
      true
    )
  )
  else null
end as rpc_pin_message_result;
rollback;

-- 7) Recommended index for chat feed ordering (presence check)
select indexname, indexdef
from pg_indexes
where schemaname = 'public' and tablename = 'messages'
  and indexname in ('idx_messages_chat_id_created_at');








