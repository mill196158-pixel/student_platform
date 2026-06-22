-- Read-only dry-run for importing VV 2024 students from staging.
-- This file intentionally contains SELECT statements only.

-- 1. Summary counts after the Auth credentials stage.
with staged as (
  select
    s.*,
    nullif(trim(s.login), '') as normalized_login
  from public.stage_students_vv_2024 s
),
resolved as (
  select
    s.*,
    g.id as future_group_id,
    u.id as existing_user_id,
    u.name as existing_name,
    u.surname as existing_surname,
    u.group_name as existing_group_name,
    u.primary_group_id as existing_primary_group_id,
    u.role as existing_role,
    c.auth_email,
    c.auth_user_id as staged_auth_user_id,
    c.created_in_auth,
    c.need_password_change,
    au.id as existing_auth_user_id,
    ae.id as active_enrollment_id,
    ae.group_id as active_enrollment_group_id
  from staged s
  left join public.groups g on g.name = s.group_name
  left join public.users u on lower(u.login::text) = lower(s.normalized_login)
  left join public.stage_student_auth_credentials_vv_2024 c on lower(c.login) = lower(s.normalized_login)
  left join auth.users au on au.id = c.auth_user_id
  left join public.student_enrollments ae
    on ae.user_id = u.id
   and ae.status = 'active'
   and ae.ended_at is null
),
classified as (
  select
    *,
    existing_user_id is null as is_new_for_public_users,
    existing_user_id is not null as already_in_public_users,
    existing_user_id is null
      and created_in_auth = true
      and staged_auth_user_id is not null
      and existing_auth_user_id is not null
      and future_group_id is not null as can_insert_public_user_without_auth_creation,
    existing_user_id is null
      and (created_in_auth is distinct from true or staged_auth_user_id is null or existing_auth_user_id is null) as blocked_missing_auth_user,
    future_group_id is null as blocked_missing_group,
    existing_user_id is not null
      and nullif(trim(coalesce(existing_group_name, '')), '') is null
      and nullif(trim(coalesce(group_name, '')), '') is not null as expected_group_name_fill,
    existing_user_id is not null
      and existing_primary_group_id is null
      and future_group_id is not null as expected_primary_group_id_fill,
    existing_user_id is not null
      and nullif(trim(coalesce(existing_group_name, '')), '') is not null
      and nullif(trim(coalesce(group_name, '')), '') is not null
      and trim(existing_group_name) is distinct from trim(group_name) as real_group_name_conflict,
    existing_user_id is not null
      and existing_primary_group_id is not null
      and future_group_id is not null
      and existing_primary_group_id <> future_group_id as real_primary_group_id_conflict,
    existing_user_id is not null
      and lower(coalesce(role, '')) = 'member'
      and lower(coalesce(existing_role, '')) = 'student' as compatible_role_mismatch,
    existing_user_id is not null
      and lower(coalesce(existing_role, '')) not in ('', 'student')
      and lower(coalesce(existing_role, '')) is distinct from lower(coalesce(role, '')) as real_role_conflict,
    existing_user_id is not null
      and future_group_id is not null
      and active_enrollment_id is null as needs_active_enrollment,
    existing_user_id is not null
      and future_group_id is not null
      and active_enrollment_id is not null
      and active_enrollment_group_id = future_group_id as has_active_enrollment_same_group,
    existing_user_id is not null
      and future_group_id is not null
      and active_enrollment_id is not null
      and active_enrollment_group_id <> future_group_id as has_active_enrollment_other_group,
    existing_user_id is not null
      and (
        nullif(trim(coalesce(existing_name, '')), '') is not null
        and nullif(trim(coalesce(name, '')), '') is not null
        and trim(existing_name) is distinct from trim(name)
      ) as real_name_conflict,
    existing_user_id is not null
      and (
        nullif(trim(coalesce(existing_surname, '')), '') is not null
        and nullif(trim(coalesce(surname, '')), '') is not null
        and trim(existing_surname) is distinct from trim(surname)
      ) as real_surname_conflict
  from resolved
),
summary as (
  select
    count(*)::bigint as staging_students_total,
    count(*) filter (where is_new_for_public_users)::bigint as new_for_public_users_total,
    count(*) filter (where already_in_public_users)::bigint as already_in_public_users_total,
    count(*) filter (where can_insert_public_user_without_auth_creation)::bigint as can_insert_public_users_without_auth_creation,
    count(*) filter (where blocked_missing_auth_user)::bigint as blocked_missing_auth_user_total,
    count(*) filter (where blocked_missing_group)::bigint as blocked_missing_group_total,
    count(*) filter (where expected_group_name_fill)::bigint as expected_group_name_fills,
    count(*) filter (where expected_primary_group_id_fill)::bigint as expected_primary_group_id_fills,
    count(*) filter (where compatible_role_mismatch)::bigint as compatible_role_mismatches,
    count(*) filter (where real_group_name_conflict)::bigint as real_group_name_conflicts,
    count(*) filter (where real_primary_group_id_conflict)::bigint as real_primary_group_id_conflicts,
    count(*) filter (where real_role_conflict)::bigint as real_role_conflicts,
    count(*) filter (where real_name_conflict)::bigint as real_name_conflicts,
    count(*) filter (where real_surname_conflict)::bigint as real_surname_conflicts,
    count(*) filter (where needs_active_enrollment)::bigint as enrollments_to_create,
    count(*) filter (where has_active_enrollment_same_group)::bigint as already_has_active_enrollment_same_group_total,
    count(*) filter (where has_active_enrollment_other_group)::bigint as active_enrollment_other_group_conflicts_total,
    count(*) filter (
      where blocked_missing_auth_user
         or blocked_missing_group
         or real_group_name_conflict
         or real_primary_group_id_conflict
         or real_role_conflict
         or has_active_enrollment_other_group
    )::bigint as blocked_rows_total
  from classified
)
select *
from summary;

-- 2. Per-student dry-run detail with expected fills and real conflicts.
with staged as (
  select s.*, nullif(trim(s.login), '') as normalized_login
  from public.stage_students_vv_2024 s
),
resolved as (
  select
    s.id as stage_id,
    s.source_row,
    s.record_book,
    s.login,
    s.surname,
    s.name,
    s.full_name,
    s.group_name,
    s.role,
    g.id as future_group_id,
    u.id as existing_user_id,
    u.name as existing_name,
    u.surname as existing_surname,
    u.group_name as existing_group_name,
    u.primary_group_id as existing_primary_group_id,
    u.role as existing_role,
    c.auth_email,
    c.auth_user_id as staged_auth_user_id,
    c.created_in_auth,
    au.id as existing_auth_user_id,
    ae.id as active_enrollment_id,
    ae.group_id as active_enrollment_group_id
  from staged s
  left join public.groups g on g.name = s.group_name
  left join public.users u on lower(u.login::text) = lower(s.normalized_login)
  left join public.stage_student_auth_credentials_vv_2024 c on lower(c.login) = lower(s.normalized_login)
  left join auth.users au on au.id = c.auth_user_id
  left join public.student_enrollments ae
    on ae.user_id = u.id
   and ae.status = 'active'
   and ae.ended_at is null
)
select
  stage_id,
  source_row,
  record_book,
  login,
  full_name,
  group_name as staging_group_name,
  role as staging_role,
  future_group_id,
  existing_user_id,
  existing_group_name,
  existing_primary_group_id,
  existing_role,
  auth_email,
  staged_auth_user_id,
  existing_auth_user_id,
  created_in_auth,
  nullif(trim(coalesce(existing_group_name, '')), '') is null
    and nullif(trim(coalesce(group_name, '')), '') is not null as expected_group_name_fill,
  existing_primary_group_id is null and future_group_id is not null as expected_primary_group_id_fill,
  lower(coalesce(role, '')) = 'member' and lower(coalesce(existing_role, '')) = 'student' as compatible_role_mismatch,
  nullif(trim(coalesce(existing_group_name, '')), '') is not null
    and nullif(trim(coalesce(group_name, '')), '') is not null
    and trim(existing_group_name) is distinct from trim(group_name) as real_group_name_conflict,
  existing_primary_group_id is not null
    and future_group_id is not null
    and existing_primary_group_id <> future_group_id as real_primary_group_id_conflict,
  lower(coalesce(existing_role, '')) not in ('', 'student')
    and lower(coalesce(existing_role, '')) is distinct from lower(coalesce(role, '')) as real_role_conflict,
  active_enrollment_id,
  active_enrollment_group_id,
  case
    when future_group_id is null then 'blocked_missing_group'
    when existing_user_id is null and (created_in_auth is distinct from true or staged_auth_user_id is null or existing_auth_user_id is null) then 'blocked_missing_auth_user'
    when active_enrollment_id is not null and active_enrollment_group_id <> future_group_id then 'blocked_active_enrollment_other_group'
    when existing_user_id is null then 'can_insert_public_user_from_created_auth_user'
    when active_enrollment_id is null then 'existing_user_ready_for_academic_fill_and_enrollment'
    else 'already_has_active_enrollment_same_group'
  end as import_status
from resolved
order by source_row nulls last, stage_id;

-- 3. Rows that cannot be safely imported without manual decision.
with staged as (
  select s.*, nullif(trim(s.login), '') as normalized_login
  from public.stage_students_vv_2024 s
),
resolved as (
  select
    s.id as stage_id,
    s.source_row,
    s.login,
    s.record_book,
    s.full_name,
    s.group_name,
    s.role,
    g.id as future_group_id,
    u.id as existing_user_id,
    u.group_name as existing_group_name,
    u.primary_group_id as existing_primary_group_id,
    u.role as existing_role,
    c.auth_email,
    c.auth_user_id as staged_auth_user_id,
    c.created_in_auth,
    au.id as existing_auth_user_id,
    ae.id as active_enrollment_id,
    ae.group_id as active_enrollment_group_id
  from staged s
  left join public.groups g on g.name = s.group_name
  left join public.users u on lower(u.login::text) = lower(s.normalized_login)
  left join public.stage_student_auth_credentials_vv_2024 c on lower(c.login) = lower(s.normalized_login)
  left join auth.users au on au.id = c.auth_user_id
  left join public.student_enrollments ae
    on ae.user_id = u.id
   and ae.status = 'active'
   and ae.ended_at is null
)
select
  *,
  array_remove(array[
    case when future_group_id is null then 'missing_group' end,
    case when existing_user_id is null and (created_in_auth is distinct from true or staged_auth_user_id is null or existing_auth_user_id is null) then 'missing_created_auth_user_for_public_user_insert' end,
    case when active_enrollment_id is not null and active_enrollment_group_id <> future_group_id then 'active_enrollment_in_other_group' end,
    case when nullif(trim(coalesce(existing_group_name, '')), '') is not null and trim(existing_group_name) is distinct from trim(group_name) then 'real_group_name_conflict' end,
    case when existing_primary_group_id is not null and future_group_id is not null and existing_primary_group_id <> future_group_id then 'real_primary_group_id_conflict' end,
    case when lower(coalesce(existing_role, '')) not in ('', 'student') and lower(coalesce(existing_role, '')) is distinct from lower(coalesce(role, '')) then 'real_role_conflict' end
  ], null) as manual_decision_reasons
from resolved
where future_group_id is null
   or (existing_user_id is null and (created_in_auth is distinct from true or staged_auth_user_id is null or existing_auth_user_id is null))
   or (active_enrollment_id is not null and active_enrollment_group_id <> future_group_id)
   or (nullif(trim(coalesce(existing_group_name, '')), '') is not null and trim(existing_group_name) is distinct from trim(group_name))
   or (existing_primary_group_id is not null and future_group_id is not null and existing_primary_group_id <> future_group_id)
   or (lower(coalesce(existing_role, '')) not in ('', 'student') and lower(coalesce(existing_role, '')) is distinct from lower(coalesce(role, '')))
order by source_row nulls last, stage_id;
