-- Synthetic PostgreSQL fixture only. Run solely on a disposable local cluster.
do $$ begin
  if current_database() <> 'assignment_security_fixture' or inet_server_addr() <> '127.0.0.1'::inet then
    raise exception 'This fixture may only run on the named local disposable database';
  end if;
end $$;
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
create table public.team_members(team_id uuid not null, user_id uuid not null, role text);
create table public.assignments(
  id uuid, team_id uuid, title text, description text, body text, link text,
  due_text text, due_at timestamptz, attachments jsonb, status text,
  published_at timestamptz, created_by uuid, created_at timestamptz,
  group_id uuid, subject_id uuid, subject_offering_id uuid,
  academic_year_id uuid, academic_term_id uuid, semester_number integer
);
create table public.assignment_votes(assignment_id uuid, value integer);
create table public.assignment_done(assignment_id uuid, user_id uuid);
insert into public.assignments(id, team_id, title, status, created_at) values
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','10000000-0000-0000-0000-000000000001','fixture one','published','2026-01-01Z'),
('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','20000000-0000-0000-0000-000000000002','fixture two','published','2026-01-02Z');
insert into public.assignment_votes values
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',1),('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',-1);
insert into public.assignment_done values
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','00000000-0000-0000-0000-000000000001');
insert into public.team_members values
('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','member'),
('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','teacher'),
('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000003','admin'),
('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000004','member'),
('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000005','member');
create or replace function public.get_team_assignments(p_team_id uuid)
returns table(
  id uuid,
  title text,
  description text,
  link text,
  due text,
  due_at timestamptz,
  attachments jsonb,
  published boolean,
  status text,
  published_at timestamptz,
  votes integer,
  completed_by_me boolean,
  created_by uuid,
  created_at timestamptz,
  group_id uuid,
  subject_id uuid,
  subject_offering_id uuid,
  academic_year_id uuid,
  academic_term_id uuid,
  semester_number integer
)
language sql
security definer
set search_path to 'public'
as $function$
  select
    a.id,
    a.title,
    coalesce(a.description, a.body, '') as description,
    a.link,
    a.due_text as due,
    a.due_at,
    a.attachments,
    (a.published_at is not null or a.status = 'published') as published,
    a.status,
    a.published_at,
    (select count(*) from public.assignment_votes v where v.assignment_id = a.id and v.value = 1)::int as votes,
    exists (
      select 1 from public.assignment_done d
      where d.assignment_id = a.id and d.user_id = auth.uid()
    ) as completed_by_me,
    a.created_by,
    a.created_at,
    a.group_id,
    a.subject_id,
    a.subject_offering_id,
    a.academic_year_id,
    a.academic_term_id,
    a.semester_number
  from public.assignments a
  where a.team_id = p_team_id
  order by a.created_at asc;
$function$;
grant execute on function public.get_team_assignments(uuid) to anon, authenticated, service_role;

-- Extra cases document existing RLS semantics, not stronger active-membership rules.
create table public.teams(id uuid primary key, kind text, archived boolean);
insert into public.teams values
('10000000-0000-0000-0000-000000000001','subject',false),
('20000000-0000-0000-0000-000000000002','group_space',false),
('30000000-0000-0000-0000-000000000003','subject',true);
insert into public.assignments(id, team_id, title, status, created_at) values
('cccccccc-cccc-cccc-cccc-cccccccccccc','30000000-0000-0000-0000-000000000003','fixture archive','published','2026-01-03Z');
insert into public.team_members values
('30000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000006','teacher');

-- Mirror live direct-team-membership SELECT policies on synthetic tables.
grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;
grant select on public.assignments, public.team_members to authenticated;
alter table public.team_members enable row level security;
create policy tm_select_own on public.team_members for select
  using (user_id = auth.uid());
alter table public.assignments enable row level security;
create policy assignments_select_if_member on public.assignments for select
  using (exists (select 1 from public.team_members tm
    where tm.team_id = assignments.team_id and tm.user_id = auth.uid()));
