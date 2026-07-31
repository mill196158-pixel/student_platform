-- Stage 9: server-side user blocks + DM insert protection.
-- Does not alter friendships / friend_requests.
-- Does not add user_blocks to supabase_realtime.

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------

create table if not exists public.user_blocks (
  blocker_id uuid not null references public.users (id) on delete cascade,
  blocked_id uuid not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint user_blocks_no_self check (blocker_id <> blocked_id)
);

create index if not exists user_blocks_blocked_id_idx
  on public.user_blocks (blocked_id);

comment on table public.user_blocks is
  'User block edges. Writes only via SECURITY DEFINER RPCs.';

-- ---------------------------------------------------------------------------
-- 2. RLS / grants (no direct client writes)
-- ---------------------------------------------------------------------------

alter table public.user_blocks enable row level security;
alter table public.user_blocks force row level security;

revoke all on table public.user_blocks from public;
revoke all on table public.user_blocks from anon;
revoke all on table public.user_blocks from authenticated;

grant select on table public.user_blocks to authenticated;

drop policy if exists user_blocks_select_own on public.user_blocks;
create policy user_blocks_select_own
  on public.user_blocks
  for select
  to authenticated
  using (blocker_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 3. RPCs
-- ---------------------------------------------------------------------------

create or replace function public.block_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user';
  end if;

  if p_user_id = v_me then
    raise exception using
      errcode = 'P0001',
      message = 'cannot_block_self';
  end if;

  if not exists (
    select 1
    from public.users u
    where u.id = p_user_id
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'user_not_found';
  end if;

  insert into public.user_blocks (blocker_id, blocked_id)
  values (v_me, p_user_id)
  on conflict (blocker_id, blocked_id) do nothing;
end;
$function$;

revoke all on function public.block_user(uuid) from public;
revoke all on function public.block_user(uuid) from anon;
grant execute on function public.block_user(uuid) to authenticated;

create or replace function public.unblock_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user';
  end if;

  delete from public.user_blocks ub
  where ub.blocker_id = v_me
    and ub.blocked_id = p_user_id;
end;
$function$;

revoke all on function public.unblock_user(uuid) from public;
revoke all on function public.unblock_user(uuid) from anon;
grant execute on function public.unblock_user(uuid) to authenticated;

create or replace function public.get_block_relationship(p_user_id uuid)
returns table (
  i_blocked boolean,
  dm_available boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := (select auth.uid());
  v_i_blocked boolean := false;
  v_blocked_me boolean := false;
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user';
  end if;

  if p_user_id = v_me then
    return query select false, true;
    return;
  end if;

  select exists (
    select 1
    from public.user_blocks ub
    where ub.blocker_id = v_me
      and ub.blocked_id = p_user_id
  ) into v_i_blocked;

  select exists (
    select 1
    from public.user_blocks ub
    where ub.blocker_id = p_user_id
      and ub.blocked_id = v_me
  ) into v_blocked_me;

  return query
  select
    v_i_blocked,
    not (v_i_blocked or v_blocked_me);
end;
$function$;

revoke all on function public.get_block_relationship(uuid) from public;
revoke all on function public.get_block_relationship(uuid) from anon;
grant execute on function public.get_block_relationship(uuid) to authenticated;

create or replace function public.get_my_blocked_user_ids()
returns uuid[]
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := (select auth.uid());
  v_ids uuid[];
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  select coalesce(array_agg(ub.blocked_id order by ub.created_at desc), '{}'::uuid[])
  into v_ids
  from public.user_blocks ub
  where ub.blocker_id = v_me;

  return v_ids;
end;
$function$;

revoke all on function public.get_my_blocked_user_ids() from public;
revoke all on function public.get_my_blocked_user_ids() from anon;
grant execute on function public.get_my_blocked_user_ids() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. BEFORE INSERT trigger: block new DM messages when either side blocked
-- ---------------------------------------------------------------------------

create or replace function public.fn_messages_block_dm_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
  v_chat_type text;
  v_peer uuid;
begin
  -- Preserve service-role / non-user server operations.
  if v_me is null then
    return new;
  end if;

  if new.author_id is distinct from v_me then
    raise exception using
      errcode = 'P0001',
      message = 'not_author';
  end if;

  if new.chat_id is null then
    return new;
  end if;

  select c.type
  into v_chat_type
  from public.chats c
  where c.id = new.chat_id;

  if v_chat_type is distinct from 'dm' then
    return new;
  end if;

  select cm.user_id
  into v_peer
  from public.chat_members cm
  where cm.chat_id = new.chat_id
    and cm.user_id <> v_me
  limit 1;

  if v_peer is null then
    return new;
  end if;

  if exists (
    select 1
    from public.user_blocks ub
    where (ub.blocker_id = v_me and ub.blocked_id = v_peer)
       or (ub.blocker_id = v_peer and ub.blocked_id = v_me)
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'dm_blocked';
  end if;

  return new;
end;
$function$;

revoke all on function public.fn_messages_block_dm_insert() from public;
revoke all on function public.fn_messages_block_dm_insert() from anon;
revoke all on function public.fn_messages_block_dm_insert() from authenticated;

drop trigger if exists trg_messages_block_dm_insert on public.messages;
create trigger trg_messages_block_dm_insert
before insert on public.messages
for each row
execute function public.fn_messages_block_dm_insert();

-- ---------------------------------------------------------------------------
-- 5. ensure_dm_chat: allow opening existing DM; forbid creating when blocked
-- Previous live definition had no race guard — lock users before create path.
-- ---------------------------------------------------------------------------

create or replace function public.ensure_dm_chat(p_partner uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  me uuid := (select auth.uid());
  v_a uuid;
  v_b uuid;
  v_chat uuid;
begin
  if me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_partner is null or p_partner = me then
    raise exception using
      errcode = 'P0001',
      message = 'bad_partner';
  end if;

  v_a := least(me, p_partner);
  v_b := greatest(me, p_partner);

  select dp.chat_id
  into v_chat
  from public.dm_pairs dp
  where dp.a = v_a
    and dp.b = v_b;

  -- Existing DM may be opened for history even when blocked.
  if v_chat is not null then
    return v_chat;
  end if;

  -- Serialize concurrent first-time DM creation for the same pair.
  perform 1
  from public.users u
  where u.id = v_a
  for update;

  perform 1
  from public.users u
  where u.id = v_b
  for update;

  select dp.chat_id
  into v_chat
  from public.dm_pairs dp
  where dp.a = v_a
    and dp.b = v_b;

  if v_chat is not null then
    return v_chat;
  end if;

  if exists (
    select 1
    from public.user_blocks ub
    where (ub.blocker_id = me and ub.blocked_id = p_partner)
       or (ub.blocker_id = p_partner and ub.blocked_id = me)
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'dm_blocked';
  end if;

  insert into public.chats (id, team_id, type, created_at)
  values (gen_random_uuid(), null, 'dm', now())
  returning id into v_chat;

  insert into public.chat_members (chat_id, user_id, role_in_chat)
  values
    (v_chat, me, 'member'),
    (v_chat, p_partner, 'member');

  insert into public.dm_pairs (chat_id, a, b)
  values (v_chat, v_a, v_b);

  return v_chat;
end;
$function$;

revoke all on function public.ensure_dm_chat(uuid) from public;
revoke all on function public.ensure_dm_chat(uuid) from anon;
grant execute on function public.ensure_dm_chat(uuid) to authenticated;
