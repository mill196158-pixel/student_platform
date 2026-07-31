-- Real online presence via last_seen heartbeat.
-- Display rule (client): offline if last_seen_at older than ~3 minutes,
-- otherwise show the user's chosen status text.

alter table public.users
  add column if not exists last_seen_at timestamptz;

create index if not exists users_last_seen_at_idx
  on public.users (last_seen_at desc nulls last);

-- Cheap heartbeat: only updates own row.
create or replace function public.touch_my_presence()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_now timestamptz := now();
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  update public.users
  set last_seen_at = v_now
  where id = v_me;

  return v_now;
end;
$$;

revoke all on function public.touch_my_presence() from public, anon;
grant execute on function public.touch_my_presence() to authenticated;

-- Expose last_seen_at on profile / friends / classmates.
-- Must drop first: return row type changes.

drop function if exists public.get_user_profile(uuid);
drop function if exists public.get_my_friends_bulk();
drop function if exists public.get_my_classmates();

create or replace function public.get_user_profile(p_id uuid)
returns table (
  id uuid,
  name text,
  surname text,
  university text,
  group_name text,
  avatar_url text,
  status text,
  last_seen_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    u.id,
    u.name,
    u.surname,
    u.university,
    u.group_name,
    u.avatar_url,
    u.status,
    u.last_seen_at
  from public.users u
  where u.id = p_id
  limit 1;
$$;

create or replace function public.get_my_friends_bulk()
returns table (
  id uuid,
  name text,
  surname text,
  avatar_url text,
  status text,
  university text,
  city text,
  group_name text,
  created_at timestamptz,
  last_seen_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  return query
  select
    u.id,
    u.name,
    u.surname,
    u.avatar_url,
    u.status,
    u.university,
    ''::text as city,
    u.group_name,
    f.created_at,
    u.last_seen_at
  from public.friends f
  join public.users u
    on u.id = case
      when f.user_id = v_me then f.friend_id
      else f.user_id
    end
  where f.user_id = v_me
     or f.friend_id = v_me
  order by u.surname nulls last, u.name nulls last;
end;
$$;

create or replace function public.get_my_classmates()
returns table (
  id uuid,
  name text,
  surname text,
  avatar_url text,
  status text,
  university text,
  city text,
  group_name text,
  primary_group_id uuid,
  admission_year integer,
  last_seen_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with my_enrollment as (
    select se.group_id
    from public.student_enrollments se
    where se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
    order by se.started_at desc, se.created_at desc
    limit 1
  ),
  my_group_profile as (
    select gap.group_id, gap.admission_year
    from public.group_academic_profiles gap
    join my_enrollment me on me.group_id = gap.group_id
    where gap.active = true
    limit 1
  ),
  classmates as (
    select distinct se.user_id, se.group_id
    from public.student_enrollments se
    join my_group_profile mgp on mgp.group_id = se.group_id
    where se.status = 'active'
      and se.ended_at is null
      and se.user_id <> auth.uid()
  )
  select
    u.id,
    u.name,
    u.surname,
    u.avatar_url,
    u.status,
    u.university,
    ''::text as city,
    u.group_name,
    u.primary_group_id,
    mgp.admission_year,
    u.last_seen_at
  from classmates c
  join my_group_profile mgp on mgp.group_id = c.group_id
  join public.users u on u.id = c.user_id
  order by u.surname nulls last, u.name nulls last, u.login nulls last;
$$;

revoke all on function public.get_user_profile(uuid) from public, anon;
grant execute on function public.get_user_profile(uuid) to authenticated;

revoke all on function public.get_my_friends_bulk() from public, anon;
grant execute on function public.get_my_friends_bulk() to authenticated;

revoke all on function public.get_my_classmates() from public, anon;
grant execute on function public.get_my_classmates() to authenticated;

drop function if exists public.search_users_global(text, integer);

create function public.search_users_global(p_q text, p_limit integer default 50)
returns table (
  id uuid,
  name text,
  surname text,
  university text,
  group_name text,
  avatar_url text,
  status text,
  last_seen_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    u.id,
    u.name,
    u.surname,
    u.university,
    u.group_name,
    u.avatar_url,
    u.status,
    u.last_seen_at
  from public.users u
  where
    (
      (u.name    ilike '%' || replace(coalesce(p_q,''), '%', '') || '%')
      or
      (u.surname ilike '%' || replace(coalesce(p_q,''), '%', '') || '%')
      or
      (trim(coalesce(u.name,'') || ' ' || coalesce(u.surname,'')) ilike '%' || replace(coalesce(p_q,''), '%', '') || '%')
    )
    and u.id <> auth.uid()
  order by u.surname, u.name
  limit greatest(1, least(p_limit, 100));
$$;

grant execute on function public.search_users_global(text, integer) to authenticated;
