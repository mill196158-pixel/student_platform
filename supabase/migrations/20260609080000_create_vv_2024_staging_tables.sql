-- Create staging tables for VV 2024 student and curriculum CSV imports.
-- This migration creates only isolated staging tables. It does not write to
-- production tables and does not create Supabase Auth users.

create extension if not exists pgcrypto;

create table if not exists public.stage_students_vv_2024 (
  id bigserial primary key,
  imported_at timestamptz not null default now(),
  import_batch_id uuid not null default gen_random_uuid(),
  validation_status text not null default 'pending',
  validation_errors jsonb not null default '[]'::jsonb,

  import_batch text null,
  source_row int null,
  record_book text null,
  login text null,
  surname text null,
  name text null,
  patronymic text null,
  full_name text null,
  group_name text null,
  admission_year int null,
  source_admission_year int null,
  current_course int null,
  current_semester_number int null,
  current_academic_year text null,
  current_term_name text null,
  role text null,
  is_active boolean null,
  auth_email text null,
  initial_password text null,
  faculty text null,
  direction text null,
  program_profile text null,
  qualification text null,
  education_level text null,
  study_form text null,
  import_note text null,

  constraint stage_students_vv_2024_validation_errors_array_check
    check (jsonb_typeof(validation_errors) = 'array')
);

create index if not exists stage_students_vv_2024_import_batch_idx
on public.stage_students_vv_2024(import_batch);

create index if not exists stage_students_vv_2024_group_name_idx
on public.stage_students_vv_2024(group_name);

create index if not exists stage_students_vv_2024_record_book_idx
on public.stage_students_vv_2024(record_book);

create index if not exists stage_students_vv_2024_login_idx
on public.stage_students_vv_2024(login);

create index if not exists stage_students_vv_2024_validation_status_idx
on public.stage_students_vv_2024(validation_status);

alter table public.stage_students_vv_2024 enable row level security;

create table if not exists public.stage_curriculum_vv_2024 (
  id bigserial primary key,
  imported_at timestamptz not null default now(),
  import_batch_id uuid not null default gen_random_uuid(),
  validation_status text not null default 'pending',
  validation_errors jsonb not null default '[]'::jsonb,

  import_batch text null,
  source_row int null,
  group_name text null,
  admission_year int null,
  current_semester_number int null,
  curriculum_year int null,
  academic_year text null,
  course int null,
  semester_number int null,
  semester_calendar_year int null,
  term_name text null,
  academic_term_code text null,
  subject_index text null,
  raw_subject_name text null,
  display_name text null,
  block_name text null,
  control_form text null,
  credits_total numeric null,
  hours_total int null,
  subject_type text null,
  subject_kind text null,
  department text null,
  is_elective boolean null,
  elective_module_code text null,
  is_elective_module_header boolean null,
  is_elective_option boolean null,
  include_in_subject_catalog boolean null,
  include_in_group_offerings_default boolean null,
  import_order int null,
  dedupe_key text null,
  import_note text null,

  constraint stage_curriculum_vv_2024_validation_errors_array_check
    check (jsonb_typeof(validation_errors) = 'array')
);

create index if not exists stage_curriculum_vv_2024_import_batch_idx
on public.stage_curriculum_vv_2024(import_batch);

create index if not exists stage_curriculum_vv_2024_group_semester_idx
on public.stage_curriculum_vv_2024(group_name, semester_number);

create index if not exists stage_curriculum_vv_2024_subject_idx
on public.stage_curriculum_vv_2024(raw_subject_name, display_name);

create index if not exists stage_curriculum_vv_2024_elective_idx
on public.stage_curriculum_vv_2024(is_elective, elective_module_code);

create index if not exists stage_curriculum_vv_2024_dedupe_key_idx
on public.stage_curriculum_vv_2024(dedupe_key);

create index if not exists stage_curriculum_vv_2024_validation_status_idx
on public.stage_curriculum_vv_2024(validation_status);

alter table public.stage_curriculum_vv_2024 enable row level security;
