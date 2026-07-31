-- LOCAL ONLY baseline approximating live schema before Stage 13 pending migrations.
-- Source: read-only remote introspection + recovered academic DDL.
-- NEVER apply to remote.

begin;

create extension if not exists pgcrypto;
create extension if not exists citext;
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to postgres, service_role;

do $$ begin
  create type public.news_post_status as enum ('draft', 'published', 'archived');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.news_audience_type as enum ('all', 'group');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.news_card_variant as enum ('gradientText', 'imageOnly', 'imageOverlay', 'imageWithText');
exception when duplicate_object then null; end $$;

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null unique
);

create table if not exists public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  login citext not null unique,
  name text default '',
  surname text default '',
  university text default '',
  group_name text default '',
  avatar_url text,
  status text default '',
  role text not null default 'student' check (role in ('student','starosta','teacher','admin')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_login_at timestamptz,
  primary_group_id uuid references public.groups(id),
  must_change_password boolean not null default false,
  last_seen_at timestamptz
);

create table if not exists public.academic_years (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  start_year int not null unique,
  starts_on date not null,
  ends_on date not null,
  is_current boolean not null default false,
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on)
);

create table if not exists public.academic_terms (
  id uuid primary key default gen_random_uuid(),
  academic_year_id uuid not null references public.academic_years(id) on delete cascade,
  term_in_year int not null check (term_in_year in (1,2)),
  term_sequence int not null unique,
  name text not null,
  preload_starts_on date,
  starts_on date not null,
  ends_on date not null,
  is_current boolean not null default false,
  created_at timestamptz not null default now(),
  unique (academic_year_id, term_in_year),
  check (ends_on >= starts_on)
);

create table if not exists public.subject_catalog (
  id uuid primary key default gen_random_uuid(),
  canonical_name text not null,
  normalized_name text not null unique,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.curriculum_subjects (
  id uuid primary key default gen_random_uuid(),
  curriculum_plan_id uuid,
  subject_id uuid not null references public.subject_catalog(id),
  raw_subject_name text not null,
  display_name text not null,
  semester_number integer,
  module_number integer,
  hours_total integer,
  credits numeric,
  created_at timestamptz not null default now(),
  subject_index text,
  block_name text,
  control_form text,
  department text,
  subject_type text,
  subject_kind text,
  is_elective boolean not null default false,
  elective_module_code text
);

create table if not exists public.subject_offerings (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references public.subject_catalog(id) on delete restrict,
  curriculum_subject_id uuid references public.curriculum_subjects(id) on delete set null,
  group_id uuid not null references public.groups(id) on delete restrict,
  academic_year_id uuid not null references public.academic_years(id) on delete restrict,
  academic_term_id uuid not null references public.academic_terms(id) on delete restrict,
  semester_number integer not null check (semester_number >= 1),
  display_name text not null,
  status text not null default 'active' check (status in ('active','archived','cancelled')),
  created_at timestamptz not null default now()
);

create table if not exists public.teachers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  normalized_name text not null,
  email text,
  department text,
  created_at timestamptz not null default now()
);
create index if not exists teachers_normalized_name_idx on public.teachers(normalized_name);

create table if not exists public.offering_teachers (
  id uuid primary key default gen_random_uuid(),
  subject_offering_id uuid not null references public.subject_offerings(id) on delete cascade,
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  role text,
  created_at timestamptz not null default now()
);

create table if not exists public.student_enrollments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete restrict,
  started_at date not null default current_date,
  ended_at date,
  status text not null default 'active' check (status in ('active','transferred','completed','left','archived')),
  transfer_reason text,
  transferred_from_enrollment_id uuid references public.student_enrollments(id) on delete set null,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ended_at is null or ended_at >= started_at)
);
create unique index if not exists student_enrollments_one_active_per_user
  on public.student_enrollments(user_id) where status='active' and ended_at is null;

create or replace function public.f_norm_subject(p text)
returns text language sql immutable as $$
  select lower(regexp_replace(coalesce(p,''), '\s+', ' ', 'g'));
$$;

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text default '',
  teacher text default '',
  icon text default '',
  group_name text default '',
  owner_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  group_id uuid references public.groups(id),
  subject_id uuid references public.subject_catalog(id),
  subject_offering_id uuid references public.subject_offerings(id),
  academic_year_id uuid references public.academic_years(id),
  academic_term_id uuid references public.academic_terms(id),
  semester_number integer
);
create unique index if not exists teams_subject_offering_unique
  on public.teams(subject_offering_id) where subject_offering_id is not null;
create unique index if not exists uniq_teams_group_norm_subject
  on public.teams(group_name, public.f_norm_subject(name));

create table if not exists public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','starosta','member')),
  created_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

create table if not exists public.chats (
  id uuid primary key default gen_random_uuid(),
  team_id uuid references public.teams(id) on delete cascade,
  type text not null check (type in ('team_main','dm','other')),
  invite_code citext unique,
  created_at timestamptz not null default now(),
  subject_offering_id uuid references public.subject_offerings(id)
);
create unique index if not exists uniq_chats_team_main
  on public.chats(team_id, type) where type = 'team_main';

create table if not exists public.chat_members (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role_in_chat text not null default 'member' check (role_in_chat in ('owner','moderator','member')),
  created_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  author_id uuid not null references public.users(id) on delete cascade,
  content text not null default '',
  attachments jsonb default '[]'::jsonb,
  is_pinned boolean not null default false,
  created_at timestamptz not null default now(),
  user_id uuid references public.users(id) on delete set null,
  body text not null default '',
  msg_type text not null default 'text',
  reply_to_id uuid references public.messages(id) on delete set null,
  attachment_url text,
  type text default 'text',
  assignment_id uuid,
  file_id uuid,
  reactions jsonb default '{}'::jsonb,
  edited_at timestamptz
);

create table if not exists public.chat_files (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  message_id uuid references public.messages(id) on delete cascade,
  file_name varchar(255) not null,
  file_key varchar(500) not null,
  file_url varchar(1000) not null,
  file_type varchar(100) not null default 'application/octet-stream',
  file_size bigint not null default 0 check (file_size >= 0),
  uploaded_by uuid not null references public.users(id) on delete cascade,
  uploaded_at timestamptz not null default now(),
  is_deleted boolean not null default false,
  group_id uuid references public.groups(id),
  subject_id uuid references public.subject_catalog(id),
  subject_offering_id uuid references public.subject_offerings(id),
  academic_year_id uuid references public.academic_years(id),
  academic_term_id uuid references public.academic_terms(id),
  semester_number integer
);

alter table public.messages
  drop constraint if exists messages_file_id_fkey;
alter table public.messages
  add constraint messages_file_id_fkey foreign key (file_id) references public.chat_files(id);

create table if not exists public.chat_academic_archives (
  chat_id uuid primary key references public.chats(id) on delete cascade,
  academic_term_id uuid not null references public.academic_terms(id),
  subject_offering_id uuid references public.subject_offerings(id),
  archived_at timestamptz not null default now(),
  available_until timestamptz not null,
  expired_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_reads (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  last_read_at timestamptz not null default '1970-01-01'::timestamptz,
  last_read_message_id uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  primary key (chat_id, user_id)
);

create table if not exists public.chat_user_settings (
  user_id uuid not null references public.users(id) on delete cascade,
  chat_id uuid not null references public.chats(id) on delete cascade,
  is_pinned boolean not null default false,
  is_muted boolean not null default false,
  is_archived boolean not null default false,
  hidden_at timestamptz,
  cleared_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, chat_id)
);

create table if not exists public.teacher_difficulty_targets (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  normalized_name text not null,
  created_at timestamptz not null default now(),
  about_text text
);

create table if not exists public.teacher_difficulty_votes (
  teacher_id uuid not null references public.teacher_difficulty_targets(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  score smallint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (teacher_id, user_id)
);

create table if not exists public.teacher_difficulty_summaries (
  teacher_id uuid primary key references public.teacher_difficulty_targets(id) on delete cascade,
  vote_count integer not null default 0,
  score_total integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.subject_student_profiles (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references public.subject_catalog(id) on delete cascade,
  student_title text,
  short_description text,
  what_to_expect text,
  how_to_pass text,
  useful_materials_note text,
  common_pitfalls text,
  tags text[] not null default '{}',
  moderation_status text not null default 'draft',
  created_by uuid references public.users(id),
  updated_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.subject_difficulty_votes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  subject_id uuid not null references public.subject_catalog(id),
  subject_offering_id uuid not null references public.subject_offerings(id),
  difficulty_rating integer not null,
  workload_rating integer,
  usefulness_rating integer,
  exam_stress_rating integer,
  comment text,
  is_anonymous boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Minimal team/chat membership sync used by ensure_group_space.
create or replace function public.ensure_team_main_chat()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.chats c where c.team_id = new.id and c.type = 'team_main'
  ) then
    insert into public.chats(team_id, type) values (new.id, 'team_main');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_teams_ensure_main_chat on public.teams;
create trigger trg_teams_ensure_main_chat
after insert on public.teams
for each row execute function public.ensure_team_main_chat();

create or replace function public.sync_team_member_to_chat()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_chat uuid;
begin
  select id into v_chat from public.chats where team_id = new.team_id and type = 'team_main' limit 1;
  if v_chat is not null then
    insert into public.chat_members(chat_id, user_id, role_in_chat)
    values (v_chat, new.user_id, 'member')
    on conflict do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_team_members_sync_chat on public.team_members;
create trigger trg_team_members_sync_chat
after insert on public.team_members
for each row execute function public.sync_team_member_to_chat();

-- Pre-Stage-13 archive helper (returns integer). Stage 13.2 replaces body.
create or replace function public.archive_academic_chats_for_term(p_academic_term_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term public.academic_terms%rowtype;
  v_now timestamptz := pg_catalog.now();
  v_available_until timestamptz;
  v_count integer := 0;
begin
  if p_academic_term_id is null then
    return 0;
  end if;
  select * into v_term from public.academic_terms at where at.id = p_academic_term_id;
  if not found or v_term.is_current or v_term.starts_on > (v_now at time zone 'utc')::date then
    return 0;
  end if;
  v_available_until := ((v_term.ends_on + interval '12 months')::timestamp at time zone 'utc');
  with candidates as (
    select c.id as chat_id, coalesce(t.subject_offering_id, c.subject_offering_id) as subject_offering_id
    from public.chats c
    join public.teams t on t.id = c.team_id
    left join public.subject_offerings so on so.id = coalesce(t.subject_offering_id, c.subject_offering_id)
    where c.type = 'team_main'
      and coalesce(t.academic_term_id, so.academic_term_id) = p_academic_term_id
  ), upserted as (
    insert into public.chat_academic_archives(chat_id, academic_term_id, subject_offering_id, archived_at, available_until)
    select chat_id, p_academic_term_id, subject_offering_id, v_now, v_available_until from candidates
    on conflict (chat_id) do update set
      academic_term_id = excluded.academic_term_id,
      subject_offering_id = coalesce(public.chat_academic_archives.subject_offering_id, excluded.subject_offering_id),
      available_until = excluded.available_until,
      expired_at = null
    returning 1
  )
  select count(*)::integer into v_count from upserted;
  return coalesce(v_count, 0);
end;
$$;
revoke all on function public.archive_academic_chats_for_term(uuid) from public, anon, authenticated;
grant execute on function public.archive_academic_chats_for_term(uuid) to service_role;

-- Placeholder replaced by Stage 13.2 drop+create with extended columns.
create or replace function public.get_my_chat_summaries()
returns table(chat_id uuid)
language sql
security definer
set search_path = ''
as $$
  select null::uuid where false;
$$;

commit;
