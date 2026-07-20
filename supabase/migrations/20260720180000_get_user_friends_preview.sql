-- Profile "Друзья" list for another user (bypasses member-only RLS on friends).
create or replace function public.get_user_friends_preview(
  p_user_id uuid,
  p_limit integer default 50
)
returns table (
  id uuid,
  name text,
  surname text,
  avatar_url text,
  university text,
  group_name text
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  if p_user_id is null then
    return;
  end if;

  return query
  with edges as (
    select case
      when f.user_id = p_user_id then f.friend_id
      else f.user_id
    end as friend_user_id
    from public.friends f
    where f.user_id = p_user_id
       or f.friend_id = p_user_id
  )
  select
    u.id,
    u.name,
    u.surname,
    u.avatar_url,
    u.university,
    u.group_name
  from edges e
  join public.users u on u.id = e.friend_user_id
  order by u.surname nulls last, u.name nulls last
  limit v_limit;
end;
$function$;

revoke all on function public.get_user_friends_preview(uuid, integer) from public;
revoke all on function public.get_user_friends_preview(uuid, integer) from anon;
grant execute on function public.get_user_friends_preview(uuid, integer) to authenticated;
