-- Run only in the per-run QA schema created by qa_local_academic_diary.py.
-- These minimal legacy tables support text entries. No file storage is involved.
create table subject_offerings (
  id uuid primary key, display_name text, subject_id uuid, group_id uuid,
  academic_year_id uuid, academic_term_id uuid, semester_number integer
);
create table teams (id uuid primary key, name text, subject_offering_id uuid);
create table assignments (
  id uuid primary key default gen_random_uuid(), subject_offering_id uuid, team_id uuid,
  title text, body text, description text, due_at timestamptz, due_text text,
  status text, published_at timestamptz, created_at timestamptz default now()
);
create table assignment_done (assignment_id uuid, user_id uuid, done boolean);
create table subject_diary_entries (
  id uuid primary key default gen_random_uuid(), team_id uuid, author_id uuid not null,
  lesson_id uuid, entry_date date not null, text text, files_count integer default 0,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  subject_offering_id uuid references subject_offerings, subject_id uuid, group_id uuid,
  academic_year_id uuid, academic_term_id uuid, semester_number integer
);
create table subject_diary_files (entry_id uuid references subject_diary_entries, file_url text);
create function get_subject_diary_files(p_entry_id uuid)
returns setof subject_diary_files language sql security invoker
set search_path from current as $$
  select f.* from subject_diary_files f join subject_diary_entries e on e.id=f.entry_id
  where f.entry_id=p_entry_id and e.author_id=auth.uid()
$$;
alter table subject_diary_entries enable row level security;
create policy own_diary on subject_diary_entries for all to authenticated
using (author_id=auth.uid()) with check (author_id=auth.uid());
grant select on subject_offerings, teams, assignments, assignment_done,
  subject_diary_entries, subject_diary_files to authenticated;
grant insert, update on subject_diary_entries to authenticated;
