-- Ephemeral local-only baseline for Stage 13.10 assignment behavioral checks.
-- DO NOT add to production migrations. Safe to re-run (IF NOT EXISTS).
-- Mirrors live public.assignments / assignment_votes shape (project gwdanmwluhrcfxbnplwd).

create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  author_id uuid null references public.users(id) on delete set null,
  title text not null,
  body text null default '',
  due_at timestamptz null,
  status text not null default 'draft'
    check (status in ('draft', 'voting', 'published', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz null,
  due_text text null,
  attachments jsonb not null default '[]'::jsonb,
  created_by uuid null references auth.users(id) on delete set null,
  description text null,
  link text null,
  group_id uuid null references public.groups(id),
  subject_id uuid null,
  subject_offering_id uuid null,
  academic_year_id uuid null,
  academic_term_id uuid null,
  semester_number integer null
);

create table if not exists public.assignment_votes (
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  value smallint not null check (value in (-1, 1)),
  created_at timestamptz not null default now(),
  primary key (assignment_id, user_id)
);

-- Optional FK from messages.assignment_id when missing (local baseline has column, no FK).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'messages_assignment_id_fkey'
  ) then
    begin
      alter table public.messages
        add constraint messages_assignment_id_fkey
        foreign key (assignment_id) references public.assignments(id)
        on delete set null;
    exception when others then
      -- Ignore if types/permissions prevent FK in this sandbox.
      null;
    end;
  end if;
end $$;

alter table public.assignments enable row level security;
alter table public.assignment_votes enable row level security;

-- Minimal member SELECT policies (RPC is SECURITY DEFINER for writes).
drop policy if exists assignments_member_select on public.assignments;
create policy assignments_member_select on public.assignments
for select to authenticated
using (
  exists (
    select 1 from public.team_members tm
    where tm.team_id = assignments.team_id and tm.user_id = auth.uid()
  )
  or private.is_active_team_member(assignments.team_id)
);

drop policy if exists assignment_votes_member_select on public.assignment_votes;
create policy assignment_votes_member_select on public.assignment_votes
for select to authenticated
using (
  exists (
    select 1 from public.assignments a
    join public.team_members tm on tm.team_id = a.team_id
    where a.id = assignment_votes.assignment_id and tm.user_id = auth.uid()
  )
);

grant select on public.assignments to authenticated, service_role;
grant select on public.assignment_votes to authenticated, service_role;
