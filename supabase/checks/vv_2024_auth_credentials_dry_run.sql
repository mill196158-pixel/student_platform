-- Read-only dry-run for VV 2024 Auth credentials staging.
-- This file intentionally contains SELECT statements only.

-- 1. Summary.
with stage_students as (
  select
    s.*,
    nullif(trim(s.login), '') as normalized_login,
    lower(trim(s.login)) || '@student.local' as expected_auth_email
  from public.stage_students_vv_2024 s
),
credentials as (
  select
    c.*,
    nullif(trim(c.login), '') as normalized_login,
    nullif(trim(c.auth_email), '') as normalized_auth_email,
    nullif(trim(c.auth_password), '') as normalized_auth_password
  from public.stage_student_auth_credentials_vv_2024 c
),
resolved as (
  select
    c.*,
    au.id as existing_auth_user_id,
    u.id as existing_public_user_id
  from credentials c
  left join auth.users au on lower(au.email) = lower(c.normalized_auth_email)
  left join public.users u on lower(u.login::text) = lower(c.normalized_login)
)
select
  (select count(*)::bigint from stage_students) as stage_students_total,
  (select count(*)::bigint from credentials) as credentials_rows_total,
  (select count(*)::bigint from stage_students where normalized_login is null) as stage_students_empty_login_total,
  count(*) filter (where normalized_login is null)::bigint as credentials_empty_login_total,
  count(*) filter (where normalized_auth_email is null)::bigint as empty_auth_email_total,
  count(*) filter (where normalized_auth_password is null)::bigint as empty_auth_password_total,
  count(*) filter (where normalized_auth_password = normalized_login)::bigint as auth_password_equals_login_total,
  count(*) filter (where normalized_auth_password is distinct from normalized_login)::bigint as auth_password_not_equal_login_total,
  count(*) filter (where existing_auth_user_id is not null)::bigint as already_existing_auth_users_by_email_total,
  count(*) filter (where existing_public_user_id is not null)::bigint as already_existing_public_users_by_login_total,
  count(*) filter (where created_in_auth = true)::bigint as created_in_auth_true_total,
  count(*) filter (where auth_user_id is not null)::bigint as auth_user_id_filled_total,
  count(*) filter (where error_message is not null)::bigint as rows_with_error_message_total
from resolved;

-- 2. Duplicate login values in credentials staging.
select
  login,
  count(*)::bigint as duplicate_count
from public.stage_student_auth_credentials_vv_2024
where nullif(trim(login), '') is not null
group by login
having count(*) > 1
order by login;

-- 3. Duplicate auth_email values in credentials staging.
select
  auth_email,
  count(*)::bigint as duplicate_count
from public.stage_student_auth_credentials_vv_2024
where nullif(trim(auth_email), '') is not null
group by auth_email
having count(*) > 1
order by auth_email;

-- 4. Credential rows that do not exactly match the staging student source.
select
  c.id as credential_id,
  c.login,
  c.record_book,
  c.full_name,
  c.group_name,
  c.auth_email,
  c.auth_password,
  s.id as stage_student_id,
  s.record_book as stage_record_book,
  s.full_name as stage_full_name,
  s.group_name as stage_group_name,
  lower(trim(s.login)) || '@student.local' as expected_auth_email,
  s.login as expected_auth_password
from public.stage_student_auth_credentials_vv_2024 c
full join public.stage_students_vv_2024 s
  on nullif(trim(c.login), '') = nullif(trim(s.login), '')
where c.id is null
   or s.id is null
   or c.record_book is distinct from s.record_book
   or c.full_name is distinct from s.full_name
   or c.group_name is distinct from s.group_name
   or c.auth_email is distinct from lower(trim(s.login)) || '@student.local'
   or c.auth_password is distinct from s.login
order by coalesce(s.source_row, c.id::int);

-- 5. Existing Auth users matching technical email.
select
  c.id as credential_id,
  c.login,
  c.auth_email,
  c.created_in_auth,
  c.auth_user_id,
  au.id as existing_auth_user_id,
  au.email,
  au.email_confirmed_at,
  au.created_at
from public.stage_student_auth_credentials_vv_2024 c
join auth.users au on lower(au.email) = lower(c.auth_email)
order by c.login;

-- 6. Existing public.users matching login.
select
  c.id as credential_id,
  c.login,
  c.auth_email,
  u.id as existing_public_user_id,
  u.login as public_login,
  u.group_name,
  u.primary_group_id,
  u.role
from public.stage_student_auth_credentials_vv_2024 c
join public.users u on lower(u.login::text) = lower(c.login)
order by c.login;

-- 7. Rows already marked created or containing errors.
select
  id,
  login,
  auth_email,
  auth_user_id,
  created_in_auth,
  error_message
from public.stage_student_auth_credentials_vv_2024
where created_in_auth = true
   or error_message is not null
order by login;
