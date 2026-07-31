-- migration_001_core_academic_subjects.sql

create extension if not exists pgcrypto;

create table if not exists public.academic_years (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  start_year int not null,
  starts_on date not null,
  ends_on date not null,
  is_current boolean not null default false,
  created_at timestamptz not null default now(),
  constraint academic_years_name_unique unique (name),
  constraint academic_years_start_year_unique unique (start_year),
  constraint academic_years_dates_check check (ends_on >= starts_on)
);

create table if not exists public.academic_terms (
  id uuid primary key default gen_random_uuid(),
  academic_year_id uuid not null references public.academic_years(id) on delete cascade,
  term_in_year int not null,
  term_sequence int not null unique,
  name text not null,
  preload_starts_on date null,
  starts_on date not null,
  ends_on date not null,
  is_current boolean not null default false,
  created_at timestamptz not null default now(),
  constraint academic_terms_term_in_year_check check (term_in_year in (1, 2)),
  constraint academic_terms_term_sequence_check check (term_sequence > 0),
  constraint academic_terms_dates_check check (ends_on >= starts_on),
  constraint academic_terms_preload_check check (preload_starts_on is null or preload_starts_on <= starts_on),
  constraint academic_terms_unique unique (academic_year_id, term_in_year)
);

create index if not exists academic_terms_academic_year_id_idx
on public.academic_terms(academic_year_id);

create table if not exists public.group_academic_profiles (
  group_id uuid primary key references public.groups(id) on delete cascade,
  admission_year int not null,
  nominal_semesters int not null default 4,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_academic_profiles_admission_year_check check (admission_year between 2000 and 2100),
  constraint group_academic_profiles_nominal_semesters_check check (nominal_semesters > 0)
);

create table if not exists public.group_term_semesters (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  academic_year_id uuid not null references public.academic_years(id) on delete cascade,
  academic_term_id uuid not null references public.academic_terms(id) on delete cascade,
  semester_number int not null,
  source text not null default 'manual',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_term_semesters_unique unique (group_id, academic_term_id),
  constraint group_term_semesters_semester_check check (semester_number > 0),
  constraint group_term_semesters_source_check check (source in ('manual', 'auto', 'import', 'admin'))
);

create index if not exists group_term_semesters_group_id_idx
on public.group_term_semesters(group_id);

create index if not exists group_term_semesters_academic_term_id_idx
on public.group_term_semesters(academic_term_id);

create index if not exists group_term_semesters_semester_number_idx
on public.group_term_semesters(semester_number);

create table if not exists public.group_name_history (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  name text not null,
  valid_from date not null,
  valid_to date null,
  source text not null default 'manual',
  created_at timestamptz not null default now(),
  constraint group_name_history_dates_check check (valid_to is null or valid_to >= valid_from),
  constraint group_name_history_source_check check (source in ('manual', 'auto', 'import', 'admin')),
  constraint group_name_history_unique unique (group_id, name, valid_from)
);

create index if not exists group_name_history_group_id_idx
on public.group_name_history(group_id);

create index if not exists group_name_history_name_idx
on public.group_name_history(name);

create index if not exists group_name_history_period_idx
on public.group_name_history(valid_from, valid_to);

create table if not exists public.group_naming_profiles (
  group_id uuid primary key references public.groups(id) on delete cascade,
  base_code text not null,
  program_code text null,
  current_course_number int not null,
  auto_rename boolean not null default false,
  pattern text not null default '{base}-{course}',
  updated_at timestamptz not null default now(),
  constraint group_naming_profiles_course_check
    check (current_course_number > 0)
);

comment on table public.group_naming_profiles is
  'Optional naming profile for academic groups. Used only when auto_rename is explicitly enabled. Do not infer blindly from groups.name.';

comment on column public.group_naming_profiles.base_code is
  'Stable group name prefix used for rename pattern, e.g. 1-СДПГСуст, 1-СДПГС, 1-СДТГВ.';

comment on column public.group_naming_profiles.program_code is
  'Optional program/profile code for analytics, e.g. СДПГСуст, СДПГС, СДТГВ. Not used as FK.';

create table if not exists public.student_enrollments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete restrict,
  started_at date not null default current_date,
  ended_at date null,
  status text not null default 'active',
  transfer_reason text null,
  transferred_from_enrollment_id uuid null references public.student_enrollments(id) on delete set null,
  created_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint student_enrollments_status_check
    check (status in ('active', 'transferred', 'completed', 'left', 'archived')),
  constraint student_enrollments_dates_check
    check (ended_at is null or ended_at >= started_at)
);

comment on column public.student_enrollments.user_id is
  'FK to public.users.id. Permanent student number is stored in public.users.login.';

create unique index if not exists student_enrollments_one_active_per_user
on public.student_enrollments(user_id)
where status = 'active' and ended_at is null;

create index if not exists student_enrollments_user_id_idx
on public.student_enrollments(user_id);

create index if not exists student_enrollments_group_id_idx
on public.student_enrollments(group_id);

create index if not exists student_enrollments_status_idx
on public.student_enrollments(status);

create index if not exists student_enrollments_period_idx
on public.student_enrollments(started_at, ended_at);

create table if not exists public.subject_catalog (
  id uuid primary key default gen_random_uuid(),
  canonical_name text not null,
  normalized_name text not null,
  description text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subject_catalog_normalized_name_unique unique (normalized_name)
);

create table if not exists public.subject_aliases (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references public.subject_catalog(id) on delete cascade,
  alias text not null,
  normalized_alias text not null,
  source text null,
  created_at timestamptz not null default now(),
  constraint subject_aliases_normalized_alias_unique unique (normalized_alias)
);

create table if not exists public.subject_alias_review_queue (
  id uuid primary key default gen_random_uuid(),
  raw_subject_name text not null,
  normalized_alias text not null,
  source text null,
  curriculum_plan_id uuid null,
  group_id uuid null references public.groups(id) on delete set null,
  academic_year_id uuid null references public.academic_years(id) on delete set null,
  status text not null default 'pending',
  resolved_subject_id uuid null references public.subject_catalog(id) on delete set null,
  resolved_by uuid null references public.users(id) on delete set null,
  resolved_at timestamptz null,
  created_at timestamptz not null default now(),
  constraint subject_alias_review_status_check
    check (status in ('pending', 'resolved', 'rejected'))
);

create unique index if not exists subject_alias_review_pending_unique
on public.subject_alias_review_queue(normalized_alias)
where status = 'pending';

create table if not exists public.curriculum_subjects (
  id uuid primary key default gen_random_uuid(),
  curriculum_plan_id uuid null,
  subject_id uuid not null references public.subject_catalog(id) on delete restrict,
  raw_subject_name text not null,
  display_name text not null,
  semester_number int null,
  module_number int null,
  hours_total int null,
  credits numeric null,
  created_at timestamptz not null default now()
);

create unique index if not exists curriculum_subjects_plan_subject_unique
on public.curriculum_subjects(curriculum_plan_id, subject_id, semester_number, module_number)
where curriculum_plan_id is not null;

create index if not exists curriculum_subjects_subject_id_idx
on public.curriculum_subjects(subject_id);

create table if not exists public.subject_offerings (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references public.subject_catalog(id) on delete restrict,
  curriculum_subject_id uuid null references public.curriculum_subjects(id) on delete set null,
  group_id uuid not null references public.groups(id) on delete restrict,
  academic_year_id uuid not null references public.academic_years(id) on delete restrict,
  academic_term_id uuid not null references public.academic_terms(id) on delete restrict,
  semester_number int not null,
  display_name text not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  constraint subject_offerings_status_check
    check (status in ('active', 'archived', 'cancelled')),
  constraint subject_offerings_semester_check
    check (semester_number >= 1)
);

create unique index if not exists subject_offerings_curriculum_subject_unique
on public.subject_offerings(group_id, curriculum_subject_id, academic_year_id, academic_term_id)
where curriculum_subject_id is not null;

create unique index if not exists subject_offerings_subject_term_unique
on public.subject_offerings(group_id, subject_id, academic_year_id, academic_term_id)
where curriculum_subject_id is null;

create index if not exists subject_offerings_group_id_idx
on public.subject_offerings(group_id);

create index if not exists subject_offerings_subject_id_idx
on public.subject_offerings(subject_id);

create index if not exists subject_offerings_academic_term_id_idx
on public.subject_offerings(academic_term_id);

create table if not exists public.teachers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  normalized_name text not null,
  email text null,
  department text null,
  created_at timestamptz not null default now()
);

create index if not exists teachers_normalized_name_idx
on public.teachers(normalized_name);

create table if not exists public.offering_teachers (
  id uuid primary key default gen_random_uuid(),
  subject_offering_id uuid not null references public.subject_offerings(id) on delete cascade,
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  role text null,
  created_at timestamptz not null default now(),
  constraint offering_teachers_unique unique (subject_offering_id, teacher_id, role)
);

create table if not exists public.subject_ratings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  subject_id uuid not null references public.subject_catalog(id) on delete cascade,
  curriculum_subject_id uuid null references public.curriculum_subjects(id) on delete cascade,
  subject_offering_id uuid null references public.subject_offerings(id) on delete cascade,
  scope text not null,
  rating int not null,
  difficulty int null,
  usefulness int null,
  like_value int null,
  comment text null,
  created_at timestamptz not null default now(),
  constraint subject_ratings_scope_check
    check (scope in ('global', 'module', 'offering')),
  constraint subject_ratings_rating_check
    check (rating between 1 and 5),
  constraint subject_ratings_difficulty_check
    check (difficulty is null or difficulty between 1 and 5),
  constraint subject_ratings_usefulness_check
    check (usefulness is null or usefulness between 1 and 5),
  constraint subject_ratings_like_value_check
    check (like_value is null or like_value between -1 and 1),
  constraint subject_ratings_scope_target_check check (
    (scope = 'global' and curriculum_subject_id is null and subject_offering_id is null)
    or
    (scope = 'module' and curriculum_subject_id is not null and subject_offering_id is null)
    or
    (scope = 'offering' and subject_offering_id is not null)
  )
);

create unique index if not exists subject_ratings_global_unique
on public.subject_ratings(user_id, subject_id, scope)
where scope = 'global';

create unique index if not exists subject_ratings_module_unique
on public.subject_ratings(user_id, curriculum_subject_id, scope)
where scope = 'module';

create unique index if not exists subject_ratings_offering_unique
on public.subject_ratings(user_id, subject_offering_id, scope)
where scope = 'offering';

create table if not exists public.teacher_ratings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  rating int not null,
  clarity int null,
  fairness int null,
  engagement int null,
  comment text null,
  created_at timestamptz not null default now(),
  constraint teacher_ratings_unique unique (user_id, teacher_id),
  constraint teacher_ratings_rating_check check (rating between 1 and 5)
);

create table if not exists public.teacher_subject_ratings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  subject_id uuid not null references public.subject_catalog(id) on delete cascade,
  subject_offering_id uuid null references public.subject_offerings(id) on delete cascade,
  scope text not null,
  rating int not null,
  clarity int null,
  fairness int null,
  engagement int null,
  comment text null,
  created_at timestamptz not null default now(),
  constraint teacher_subject_ratings_scope_check
    check (scope in ('global_subject', 'offering')),
  constraint teacher_subject_ratings_rating_check
    check (rating between 1 and 5),
  constraint teacher_subject_ratings_scope_target_check check (
    (scope = 'global_subject' and subject_offering_id is null)
    or
    (scope = 'offering' and subject_offering_id is not null)
  )
);

create unique index if not exists teacher_subject_ratings_global_subject_unique
on public.teacher_subject_ratings(user_id, teacher_id, subject_id)
where scope = 'global_subject';

create unique index if not exists teacher_subject_ratings_offering_unique
on public.teacher_subject_ratings(user_id, teacher_id, subject_offering_id)
where scope = 'offering';
