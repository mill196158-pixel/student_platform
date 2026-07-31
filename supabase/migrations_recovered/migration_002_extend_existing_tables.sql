-- migration_002_extend_existing_tables.sql

alter table public.users
  add column if not exists primary_group_id uuid null references public.groups(id);

alter table public.teams
  add column if not exists group_id uuid null references public.groups(id),
  add column if not exists subject_id uuid null references public.subject_catalog(id),
  add column if not exists subject_offering_id uuid null references public.subject_offerings(id),
  add column if not exists academic_year_id uuid null references public.academic_years(id),
  add column if not exists academic_term_id uuid null references public.academic_terms(id),
  add column if not exists semester_number int null;

alter table public.chats
  add column if not exists subject_offering_id uuid null references public.subject_offerings(id);

alter table public.assignments
  add column if not exists group_id uuid null references public.groups(id),
  add column if not exists subject_id uuid null references public.subject_catalog(id),
  add column if not exists subject_offering_id uuid null references public.subject_offerings(id),
  add column if not exists academic_year_id uuid null references public.academic_years(id),
  add column if not exists academic_term_id uuid null references public.academic_terms(id),
  add column if not exists semester_number int null;

alter table public.chat_files
  add column if not exists group_id uuid null references public.groups(id),
  add column if not exists subject_id uuid null references public.subject_catalog(id),
  add column if not exists subject_offering_id uuid null references public.subject_offerings(id),
  add column if not exists academic_year_id uuid null references public.academic_years(id),
  add column if not exists academic_term_id uuid null references public.academic_terms(id),
  add column if not exists semester_number int null;

alter table public.subject_diary_entries
  add column if not exists group_id uuid null references public.groups(id),
  add column if not exists subject_id uuid null references public.subject_catalog(id),
  add column if not exists subject_offering_id uuid null references public.subject_offerings(id),
  add column if not exists academic_year_id uuid null references public.academic_years(id),
  add column if not exists academic_term_id uuid null references public.academic_terms(id),
  add column if not exists semester_number int null;

alter table public.lessons
  add column if not exists subject_id uuid null references public.subject_catalog(id),
  add column if not exists subject_offering_id uuid null references public.subject_offerings(id),
  add column if not exists teacher_id uuid null references public.teachers(id),
  add column if not exists academic_year_id uuid null references public.academic_years(id),
  add column if not exists academic_term_id uuid null references public.academic_terms(id),
  add column if not exists semester_number int null;

create index if not exists users_primary_group_id_idx
on public.users(primary_group_id);

create index if not exists teams_group_id_idx
on public.teams(group_id);

create index if not exists teams_subject_id_idx
on public.teams(subject_id);

create unique index if not exists teams_subject_offering_unique
on public.teams(subject_offering_id)
where subject_offering_id is not null;

create index if not exists teams_academic_year_id_idx
on public.teams(academic_year_id);

create index if not exists teams_academic_term_id_idx
on public.teams(academic_term_id);

create index if not exists chats_subject_offering_id_idx
on public.chats(subject_offering_id);

create index if not exists assignments_group_id_idx
on public.assignments(group_id);

create index if not exists assignments_subject_id_idx
on public.assignments(subject_id);

create index if not exists assignments_subject_offering_id_idx
on public.assignments(subject_offering_id);

create index if not exists assignments_academic_term_id_idx
on public.assignments(academic_term_id);

create index if not exists chat_files_group_id_idx
on public.chat_files(group_id);

create index if not exists chat_files_subject_id_idx
on public.chat_files(subject_id);

create index if not exists chat_files_subject_offering_id_idx
on public.chat_files(subject_offering_id);

create index if not exists chat_files_academic_term_id_idx
on public.chat_files(academic_term_id);

create index if not exists subject_diary_entries_group_id_idx
on public.subject_diary_entries(group_id);

create index if not exists subject_diary_entries_subject_id_idx
on public.subject_diary_entries(subject_id);

create index if not exists subject_diary_entries_subject_offering_id_idx
on public.subject_diary_entries(subject_offering_id);

create index if not exists subject_diary_entries_academic_term_id_idx
on public.subject_diary_entries(academic_term_id);

create index if not exists lessons_subject_id_idx
on public.lessons(subject_id);

create index if not exists lessons_subject_offering_id_idx
on public.lessons(subject_offering_id);

create index if not exists lessons_teacher_id_idx
on public.lessons(teacher_id);

create index if not exists lessons_academic_year_id_idx
on public.lessons(academic_year_id);

create index if not exists lessons_academic_term_id_idx
on public.lessons(academic_term_id);
