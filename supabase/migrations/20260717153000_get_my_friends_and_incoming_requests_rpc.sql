-- Bulk friends / incoming requests RPCs to avoid N+1 get_user_profile calls.
-- Exposes only the listed public profile fields for the authenticated caller.

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
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
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
    f.created_at
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
$function$;

create or replace function public.get_my_incoming_friend_requests()
returns table (
  id uuid,
  name text,
  surname text,
  avatar_url text,
  status text,
  university text,
  city text,
  group_name text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
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
    r.created_at
  from public.friend_requests r
  join public.users u on u.id = r.from_id
  where r.to_id = v_me
  order by r.created_at desc;
end;
$function$;

revoke execute on function public.get_my_friends_bulk() from PUBLIC, anon;
revoke execute on function public.get_my_incoming_friend_requests() from PUBLIC, anon;

grant execute on function public.get_my_friends_bulk() to authenticated;
grant execute on function public.get_my_incoming_friend_requests() to authenticated;
