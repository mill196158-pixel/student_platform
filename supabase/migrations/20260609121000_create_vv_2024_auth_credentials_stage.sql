create table if not exists public.stage_student_auth_credentials_vv_2024 (
  id bigserial primary key,
  imported_at timestamptz not null default now(),
  import_batch text null,
  record_book text null,
  login text null,
  full_name text null,
  group_name text null,
  auth_email text null,
  auth_password text null,
  need_password_change boolean not null default true,
  auth_user_id uuid null,
  created_in_auth boolean not null default false,
  error_message text null,
  validation_status text not null default 'pending',
  validation_errors jsonb not null default '[]'::jsonb,
  constraint stage_student_auth_credentials_vv_2024_validation_errors_array_check
    check (jsonb_typeof(validation_errors) = 'array')
);

alter table public.stage_student_auth_credentials_vv_2024 enable row level security;

create unique index if not exists stage_student_auth_credentials_vv_2024_login_uidx
  on public.stage_student_auth_credentials_vv_2024 (login)
  where login is not null;

create unique index if not exists stage_student_auth_credentials_vv_2024_auth_email_uidx
  on public.stage_student_auth_credentials_vv_2024 (auth_email)
  where auth_email is not null;

create index if not exists stage_student_auth_credentials_vv_2024_created_idx
  on public.stage_student_auth_credentials_vv_2024 (created_in_auth);

insert into public.stage_student_auth_credentials_vv_2024 (
  import_batch,
  record_book,
  login,
  full_name,
  group_name,
  auth_email,
  auth_password,
  need_password_change,
  validation_status,
  validation_errors
)
select
  s.import_batch,
  nullif(trim(s.record_book), ''),
  nullif(trim(s.login), ''),
  s.full_name,
  s.group_name,
  lower(trim(s.login)) || '@student.local',
  nullif(trim(s.login), ''),
  true,
  'pending',
  '[]'::jsonb
from public.stage_students_vv_2024 s
where nullif(trim(s.login), '') is not null
on conflict (login) where login is not null
do update set
  import_batch = excluded.import_batch,
  record_book = excluded.record_book,
  full_name = excluded.full_name,
  group_name = excluded.group_name,
  auth_email = excluded.auth_email,
  auth_password = excluded.auth_password,
  need_password_change = true,
  validation_status = 'pending',
  validation_errors = '[]'::jsonb,
  error_message = null
where public.stage_student_auth_credentials_vv_2024.created_in_auth = false;
