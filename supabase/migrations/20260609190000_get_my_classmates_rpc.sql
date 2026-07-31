-- Returns classmates for the current authenticated user.
--
-- Why this RPC is needed:
-- client-side RLS allows a student to read only their own student_enrollments row,
-- but the friends screen needs users with the same active enrollment context and
-- the same group admission year. The function exposes only that scoped list.

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
      se.group_id,
      se.status as enrollment_status
    from public.student_enrollments se
    where se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
    order by se.started_at desc, se.created_at desc
    limit 1
  ),
  my_group_profile as (
    select
      gap.admission_year,
      gap.active
    from public.group_academic_profiles gap
    join my_enrollment me on me.group_id = gap.group_id
    limit 1
  ),
  allowed_groups as (
    select gap.group_id
    from public.group_academic_profiles gap
    join my_group_profile mgp
      on mgp.admission_year = gap.admission_year
     and mgp.active = gap.active
  ),
  classmates as (
    select distinct se.user_id
    from public.student_enrollments se
    join allowed_groups ag on ag.group_id = se.group_id
    join my_enrollment me on me.enrollment_status = se.status
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
    gap.admission_year
  from classmates c
  join public.users u on u.id = c.user_id
  left join public.group_academic_profiles gap
    on gap.group_id = u.primary_group_id
  order by u.surname nulls last, u.name nulls last, u.login nulls last;
$$;

revoke all on function public.get_my_classmates() from public;
grant execute on function public.get_my_classmates() to authenticated;
