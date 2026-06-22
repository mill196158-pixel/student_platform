-- Read-only post-check after an approved VV 2024 students import.
-- This file intentionally contains SELECT statements only.

-- 1. Summary for staging logins in public.users and active enrollments.
with staged as (
  select
    s.*,
    nullif(trim(s.login), '') as normalized_login
  from public.stage_students_vv_2024 s
),
resolved as (
  select
    s.id as stage_id,
    s.source_row,
    s.login,
    s.full_name,
    s.group_name,
    g.id as expected_group_id,
    u.id as user_id,
    u.group_name as user_group_name,
    u.primary_group_id,
    ae.id as active_enrollment_id,
    ae.group_id as active_enrollment_group_id
  from staged s
  left join public.groups g on g.name = s.group_name
  left join public.users u on lower(u.login::text) = lower(s.normalized_login)
  left join public.student_enrollments ae
    on ae.user_id = u.id
   and ae.status = 'active'
   and ae.ended_at is null
)
select
  count(*)::bigint as staging_students_total,
  count(*) filter (where user_id is not null)::bigint as users_found_total,
  count(*) filter (where nullif(trim(coalesce(user_group_name, '')), '') is not null)::bigint as users_with_group_name_total,
  count(*) filter (where primary_group_id is not null)::bigint as users_with_primary_group_id_total,
  count(*) filter (where active_enrollment_id is not null)::bigint as users_with_active_enrollment_total,
  count(*) filter (where user_id is null)::bigint as staging_students_without_user_total,
  count(*) filter (where user_id is not null and active_enrollment_id is null)::bigint as staging_students_without_active_enrollment_total,
  count(*) filter (where active_enrollment_id is not null and active_enrollment_group_id = expected_group_id)::bigint as active_enrollment_expected_group_total,
  count(*) filter (where active_enrollment_id is not null and active_enrollment_group_id <> expected_group_id)::bigint as active_enrollment_unexpected_group_total
from resolved;

-- 2. Active enrollment counts by expected staging group.
with staged as (
  select s.*, nullif(trim(s.login), '') as normalized_login
  from public.stage_students_vv_2024 s
),
resolved as (
  select
    s.group_name as expected_group_name,
    g.id as expected_group_id,
    u.id as user_id,
    ae.id as active_enrollment_id,
    ae.group_id as active_enrollment_group_id
  from staged s
  left join public.groups g on g.name = s.group_name
  left join public.users u on lower(u.login::text) = lower(s.normalized_login)
  left join public.student_enrollments ae
    on ae.user_id = u.id
   and ae.status = 'active'
   and ae.ended_at is null
)
select
  expected_group_name,
  expected_group_id,
  count(*)::bigint as staging_students_total,
  count(*) filter (where active_enrollment_id is not null and active_enrollment_group_id = expected_group_id)::bigint as active_enrollment_in_expected_group_total,
  count(*) filter (where active_enrollment_id is not null and active_enrollment_group_id <> expected_group_id)::bigint as active_enrollment_in_other_group_total,
  count(*) filter (where user_id is not null and active_enrollment_id is null)::bigint as users_without_active_enrollment_total
from resolved
group by expected_group_name, expected_group_id
order by expected_group_name;

-- 3. Duplicate active enrollments among staging users.
with staged_users as (
  select u.id as user_id, u.login
  from public.stage_students_vv_2024 s
  join public.users u on lower(u.login::text) = lower(trim(s.login))
)
select
  su.user_id,
  su.login,
  count(ae.id)::bigint as active_enrollment_count,
  array_agg(ae.group_id order by ae.group_id) as active_group_ids
from staged_users su
join public.student_enrollments ae
  on ae.user_id = su.user_id
 and ae.status = 'active'
 and ae.ended_at is null
group by su.user_id, su.login
having count(ae.id) > 1
order by su.login;

-- 4. Staging students still missing public.users rows.
select
  s.id as stage_id,
  s.source_row,
  s.login,
  s.record_book,
  s.full_name,
  s.group_name
from public.stage_students_vv_2024 s
left join public.users u on lower(u.login::text) = lower(trim(s.login))
where u.id is null
order by s.source_row nulls last, s.id;

-- 5. Staging students with public.users rows but no active enrollment.
select
  s.id as stage_id,
  s.source_row,
  s.login,
  s.record_book,
  s.full_name,
  s.group_name,
  u.id as user_id
from public.stage_students_vv_2024 s
join public.users u on lower(u.login::text) = lower(trim(s.login))
left join public.student_enrollments ae
  on ae.user_id = u.id
 and ae.status = 'active'
 and ae.ended_at is null
where ae.id is null
order by s.source_row nulls last, s.id;

-- 6. Academic field and role mismatches after import.
select
  s.id as stage_id,
  s.source_row,
  s.login,
  s.full_name,
  s.group_name as expected_group_name,
  g.id as expected_group_id,
  u.id as user_id,
  u.group_name as actual_group_name,
  u.primary_group_id as actual_primary_group_id,
  u.role as actual_role,
  array_remove(array[
    case
      when nullif(trim(coalesce(u.group_name, '')), '') is distinct from nullif(trim(coalesce(s.group_name, '')), '')
      then 'group_name_mismatch'
    end,
    case when u.primary_group_id is distinct from g.id then 'primary_group_id_mismatch' end,
    case when lower(coalesce(u.role, '')) <> 'student' then 'role_not_student' end
  ], null) as mismatch_reasons
from public.stage_students_vv_2024 s
left join public.groups g on g.name = s.group_name
left join public.users u on lower(u.login::text) = lower(trim(s.login))
where nullif(trim(coalesce(u.group_name, '')), '') is distinct from nullif(trim(coalesce(s.group_name, '')), '')
   or u.primary_group_id is distinct from g.id
   or lower(coalesce(u.role, '')) <> 'student'
order by s.source_row nulls last, s.id;
