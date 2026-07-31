-- Tighten get_my_classmates(): classmates must be from the current user's exact
-- active group, not from all groups with the same admission year.

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
  admission_year int
)
language sql
security definer
set search_path = public
stable
as $$
  with my_enrollment as (
    select
      se.group_id
    from public.student_enrollments se
    where se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
    order by se.started_at desc, se.created_at desc
    limit 1
  ),
  my_group_profile as (
    select
      gap.group_id,
      gap.admission_year
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
    mgp.admission_year
  from classmates c
  join my_group_profile mgp on mgp.group_id = c.group_id
  join public.users u on u.id = c.user_id
  order by u.surname nulls last, u.name nulls last, u.login nulls last;
$$;

revoke all on function public.get_my_classmates() from public;
grant execute on function public.get_my_classmates() to authenticated;
