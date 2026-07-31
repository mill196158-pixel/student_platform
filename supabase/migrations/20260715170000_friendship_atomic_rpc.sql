-- Stage 2.1 - atomic friendship RPCs.
--
-- This migration keeps the existing read/realtime path intact while moving
-- writes for friends and friend_requests behind SECURITY DEFINER RPCs.
--
-- Do not apply this migration before Flutter writes are moved to these RPCs:
-- direct client inserts/deletes on friends and friend_requests are revoked below.

begin;

lock table public.friends, public.friend_requests
in share row exclusive mode;

-- Supabase installs pgcrypto in the extensions schema. Use extensions.digest()
-- below and do not try to create a second pgcrypto copy in public.

-- ---------------------------------------------------------------------------
-- 1. Data cleanup
-- ---------------------------------------------------------------------------

delete from public.friend_requests
where from_id = to_id;

delete from public.friends
where user_id = friend_id;

with ranked as (
  select
    f.id,
    row_number() over (
      partition by least(f.user_id, f.friend_id), greatest(f.user_id, f.friend_id)
      order by f.created_at asc, f.id asc
    ) as rn
  from public.friends f
)
delete from public.friends f
using ranked r
where f.id = r.id
  and r.rn > 1;

update public.friends
set
  user_id = least(user_id, friend_id),
  friend_id = greatest(user_id, friend_id)
where user_id > friend_id;

with ranked as (
  select
    r.id,
    row_number() over (
      partition by r.from_id, r.to_id
      order by r.created_at asc, r.id asc
    ) as rn
  from public.friend_requests r
)
delete from public.friend_requests r
using ranked d
where r.id = d.id
  and d.rn > 1;

with mutual_requests as (
  select distinct
    least(a.from_id, a.to_id) as user_id,
    greatest(a.from_id, a.to_id) as friend_id,
    least(a.created_at, b.created_at) as created_at
  from public.friend_requests a
  join public.friend_requests b
    on b.from_id = a.to_id
   and b.to_id = a.from_id
  where a.from_id <> a.to_id
)
insert into public.friends(user_id, friend_id, created_at)
select mr.user_id, mr.friend_id, min(mr.created_at)
from mutual_requests mr
group by mr.user_id, mr.friend_id
on conflict do nothing;

delete from public.friend_requests r
where exists (
  select 1
  from public.friends f
  where f.user_id = least(r.from_id, r.to_id)
    and f.friend_id = greatest(r.from_id, r.to_id)
);

-- ---------------------------------------------------------------------------
-- 2. Constraints and indexes
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'friends'
      and c.conname = 'friends_not_self'
  ) then
    alter table public.friends
      add constraint friends_not_self check (user_id <> friend_id);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'friend_requests'
      and c.conname = 'fr_not_self'
  ) then
    alter table public.friend_requests
      add constraint fr_not_self check (from_id <> to_id);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'friends'
      and c.conname = 'friends_unique_pair'
  ) then
    alter table public.friends
      add constraint friends_unique_pair unique (user_id, friend_id);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'friend_requests'
      and c.conname = 'fr_uniq'
  ) then
    alter table public.friend_requests
      add constraint fr_uniq unique (from_id, to_id);
  end if;
end $$;

create unique index if not exists friends_unique_canonical_pair_idx
on public.friends (
  least(user_id, friend_id),
  greatest(user_id, friend_id)
);

create unique index if not exists friend_requests_unique_canonical_pair_idx
on public.friend_requests (
  least(from_id, to_id),
  greatest(from_id, to_id)
);

create index if not exists idx_friends_user_id
on public.friends(user_id);

create index if not exists idx_friends_friend_id
on public.friends(friend_id);

create index if not exists idx_fr_to_id
on public.friend_requests(to_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 3. Trigger hardening
-- ---------------------------------------------------------------------------

create or replace function public.fn_friends_canonicalize()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_tmp uuid;
begin
  if new.user_id = new.friend_id then
    raise exception using
      errcode = 'P0001',
      message = 'friendship_self_not_allowed';
  end if;

  if new.user_id > new.friend_id then
    v_tmp := new.user_id;
    new.user_id := new.friend_id;
    new.friend_id := v_tmp;
  end if;

  return new;
end;
$function$;

create or replace function public.fn_friends_after_insert()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  delete from public.friend_requests r
  where (r.from_id = new.user_id and r.to_id = new.friend_id)
     or (r.from_id = new.friend_id and r.to_id = new.user_id);

  return new;
end;
$function$;

do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgname = 'trg_friends_canonicalize'
      and tgrelid = 'public.friends'::regclass
      and not tgisinternal
  ) then
    create trigger trg_friends_canonicalize
    before insert on public.friends
    for each row
    execute function public.fn_friends_canonicalize();
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgname = 'trg_friends_after_insert'
      and tgrelid = 'public.friends'::regclass
      and not tgisinternal
  ) then
    create trigger trg_friends_after_insert
    after insert on public.friends
    for each row
    execute function public.fn_friends_after_insert();
  end if;
end $$;

-- PostgreSQL advisory locks only expose a 64-bit key space. A collision-free
-- encoding of two 128-bit UUIDs is impossible in that API. This helper uses a
-- deterministic SHA-256 digest truncated to two signed int32 advisory keys, and
-- then also locks both public.users rows in canonical order. Correctness comes
-- from the row locks; the advisory lock provides a stable pair-scoped lock key
-- without relying on process-dependent hash functions.
create or replace function public._friend_pair_lock(p_user_a uuid, p_user_b uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_low uuid := least(p_user_a, p_user_b);
  v_high uuid := greatest(p_user_a, p_user_b);
  v_digest bytea;
  v_key1 bigint;
  v_key2 bigint;
  v_locked_count integer := 0;
  v_locked_id uuid;
begin
  if p_user_a is null or p_user_b is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user_id';
  end if;

  v_digest := extensions.digest(v_low::text || ':' || v_high::text, 'sha256');

  v_key1 :=
      (pg_catalog.get_byte(v_digest, 0)::bigint << 24)
    | (pg_catalog.get_byte(v_digest, 1)::bigint << 16)
    | (pg_catalog.get_byte(v_digest, 2)::bigint << 8)
    |  pg_catalog.get_byte(v_digest, 3)::bigint;

  v_key2 :=
      (pg_catalog.get_byte(v_digest, 4)::bigint << 24)
    | (pg_catalog.get_byte(v_digest, 5)::bigint << 16)
    | (pg_catalog.get_byte(v_digest, 6)::bigint << 8)
    |  pg_catalog.get_byte(v_digest, 7)::bigint;

  if v_key1 >= 2147483648 then
    v_key1 := v_key1 - 4294967296;
  end if;

  if v_key2 >= 2147483648 then
    v_key2 := v_key2 - 4294967296;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(v_key1::integer, v_key2::integer);

  for v_locked_id in
    select u.id
    from public.users u
    where u.id in (v_low, v_high)
    order by u.id
    for update
  loop
    v_locked_count := v_locked_count + 1;
  end loop;

  if v_locked_count <> 2 then
    raise exception using
      errcode = 'P0001',
      message = 'user_not_found';
  end if;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Atomic friendship RPCs
-- ---------------------------------------------------------------------------

create or replace function public.send_friend_request(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := auth.uid();
  v_user_id uuid;
  v_friend_id uuid;
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user_id';
  end if;

  if v_me = p_user_id then
    raise exception using
      errcode = 'P0001',
      message = 'friendship_self_not_allowed';
  end if;

  v_user_id := least(v_me, p_user_id);
  v_friend_id := greatest(v_me, p_user_id);

  perform public._friend_pair_lock(v_me, p_user_id);

  if exists (
    select 1
    from public.friends f
    where f.user_id = v_user_id
      and f.friend_id = v_friend_id
  ) then
    return;
  end if;

  if exists (
    select 1
    from public.friend_requests r
    where r.from_id = p_user_id
      and r.to_id = v_me
  ) then
    insert into public.friends(user_id, friend_id)
    values (v_user_id, v_friend_id)
    on conflict do nothing;

    delete from public.friend_requests r
    where (r.from_id = v_me and r.to_id = p_user_id)
       or (r.from_id = p_user_id and r.to_id = v_me);

    return;
  end if;

  insert into public.friend_requests(from_id, to_id)
  values (v_me, p_user_id)
  on conflict do nothing;
end;
$function$;

create or replace function public.accept_friend_request(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := auth.uid();
  v_user_id uuid;
  v_friend_id uuid;
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user_id';
  end if;

  if v_me = p_user_id then
    raise exception using
      errcode = 'P0001',
      message = 'friendship_self_not_allowed';
  end if;

  v_user_id := least(v_me, p_user_id);
  v_friend_id := greatest(v_me, p_user_id);

  perform public._friend_pair_lock(v_me, p_user_id);

  if exists (
    select 1
    from public.friends f
    where f.user_id = v_user_id
      and f.friend_id = v_friend_id
  ) then
    delete from public.friend_requests r
    where (r.from_id = v_me and r.to_id = p_user_id)
       or (r.from_id = p_user_id and r.to_id = v_me);

    return;
  end if;

  if not exists (
    select 1
    from public.friend_requests r
    where r.from_id = p_user_id
      and r.to_id = v_me
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'friend_request_not_found';
  end if;

  insert into public.friends(user_id, friend_id)
  values (v_user_id, v_friend_id)
  on conflict do nothing;

  delete from public.friend_requests r
  where (r.from_id = v_me and r.to_id = p_user_id)
     or (r.from_id = p_user_id and r.to_id = v_me);
end;
$function$;

create or replace function public.decline_friend_request(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user_id';
  end if;

  if v_me = p_user_id then
    raise exception using
      errcode = 'P0001',
      message = 'friendship_self_not_allowed';
  end if;

  perform public._friend_pair_lock(v_me, p_user_id);

  delete from public.friend_requests r
  where r.from_id = p_user_id
    and r.to_id = v_me;
end;
$function$;

create or replace function public.cancel_friend_request(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user_id';
  end if;

  if v_me = p_user_id then
    raise exception using
      errcode = 'P0001',
      message = 'friendship_self_not_allowed';
  end if;

  perform public._friend_pair_lock(v_me, p_user_id);

  delete from public.friend_requests r
  where r.from_id = v_me
    and r.to_id = p_user_id;
end;
$function$;

create or replace function public.remove_friend(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := auth.uid();
  v_user_id uuid;
  v_friend_id uuid;
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'invalid_user_id';
  end if;

  if v_me = p_user_id then
    raise exception using
      errcode = 'P0001',
      message = 'friendship_self_not_allowed';
  end if;

  v_user_id := least(v_me, p_user_id);
  v_friend_id := greatest(v_me, p_user_id);

  perform public._friend_pair_lock(v_me, p_user_id);

  delete from public.friends f
  where f.user_id = v_user_id
    and f.friend_id = v_friend_id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Grants and write policies
-- ---------------------------------------------------------------------------

revoke all privileges on table public.friends from PUBLIC, anon, authenticated;
revoke all privileges on table public.friend_requests from PUBLIC, anon, authenticated;

grant select on table public.friends to authenticated;
grant select on table public.friend_requests to authenticated;

drop policy if exists friends_insert_by_member on public.friends;
drop policy if exists friends_delete_by_member on public.friends;
drop policy if exists fr_insert_self_to_other on public.friend_requests;
drop policy if exists fr_delete_by_pair on public.friend_requests;

revoke all on function public._friend_pair_lock(uuid, uuid) from PUBLIC, anon, authenticated;
revoke all on function public.fn_friends_canonicalize() from PUBLIC, anon, authenticated;
revoke all on function public.fn_friends_after_insert() from PUBLIC, anon, authenticated;

revoke execute on function public.send_friend_request(uuid) from PUBLIC, anon;
revoke execute on function public.accept_friend_request(uuid) from PUBLIC, anon;
revoke execute on function public.decline_friend_request(uuid) from PUBLIC, anon;
revoke execute on function public.cancel_friend_request(uuid) from PUBLIC, anon;
revoke execute on function public.remove_friend(uuid) from PUBLIC, anon;

grant execute on function public.send_friend_request(uuid) to authenticated;
grant execute on function public.accept_friend_request(uuid) to authenticated;
grant execute on function public.decline_friend_request(uuid) to authenticated;
grant execute on function public.cancel_friend_request(uuid) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;

commit;
