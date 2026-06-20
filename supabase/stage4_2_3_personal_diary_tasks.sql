-- Stage 4.2.3 - private personal diary tasks
-- Personal tasks are diary-only. They do not create chat messages and do not
-- participate in group assignment voting.

create table if not exists public.personal_diary_tasks (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null,
  subject_offering_id uuid null references public.subject_offerings(id) on delete set null,
  title text not null check (char_length(trim(title)) > 0),
  description text null,
  due_at timestamptz null,
  status text not null default 'todo' check (status in ('todo', 'in_progress', 'done')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz null
);

create index if not exists personal_diary_tasks_author_idx
  on public.personal_diary_tasks(author_id);

create index if not exists personal_diary_tasks_author_subject_idx
  on public.personal_diary_tasks(author_id, subject_offering_id);

create index if not exists personal_diary_tasks_author_status_due_idx
  on public.personal_diary_tasks(author_id, status, due_at);

alter table public.personal_diary_tasks enable row level security;

drop policy if exists "personal_diary_tasks_select_own" on public.personal_diary_tasks;
create policy "personal_diary_tasks_select_own"
  on public.personal_diary_tasks
  for select
  to authenticated
  using (author_id = auth.uid());

drop policy if exists "personal_diary_tasks_insert_own" on public.personal_diary_tasks;
create policy "personal_diary_tasks_insert_own"
  on public.personal_diary_tasks
  for insert
  to authenticated
  with check (author_id = auth.uid());

drop policy if exists "personal_diary_tasks_update_own" on public.personal_diary_tasks;
create policy "personal_diary_tasks_update_own"
  on public.personal_diary_tasks
  for update
  to authenticated
  using (author_id = auth.uid())
  with check (author_id = auth.uid());

drop policy if exists "personal_diary_tasks_delete_own" on public.personal_diary_tasks;
create policy "personal_diary_tasks_delete_own"
  on public.personal_diary_tasks
  for delete
  to authenticated
  using (author_id = auth.uid());
