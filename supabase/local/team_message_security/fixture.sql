-- Synthetic-only local PostgreSQL fixture. Never connects to production.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;
revoke create on schema public from public;
create table public.users (id uuid primary key, role text not null);
insert into public.users(id,role) values
  ('aaaaaaaa-1111-4111-8111-111111111111','student'),
  ('aaaaaaaa-2222-4222-8222-222222222222','starosta'),
  ('bbbbbbbb-1111-4111-8111-111111111111','student'),
  ('aaaaaaaa-3333-4333-8333-333333333333','teacher'),
  ('bbbbbbbb-3333-4333-8333-333333333333','teacher');
create table public.teams(id uuid primary key);
insert into public.teams(id) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
create table public.academic_terms(id uuid primary key);
create table public.academic_years(id uuid primary key);
create table public.groups(id uuid primary key);
create table public.subject_catalog(id uuid primary key);
create table public.subject_offerings(id uuid primary key);
create table public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role text not null default 'member' check(role in ('owner','starosta','member')),
  created_at timestamptz not null default now(),
  primary key(team_id,user_id)
);
create table public.chats (id uuid primary key, team_id uuid not null, type text not null);
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  author_id uuid not null references public.users(id) on delete cascade,
  content text not null, attachments jsonb default '[]'::jsonb,
  is_pinned boolean not null default false, created_at timestamptz not null default now(),
  user_id uuid references public.users(id) on delete set null,
  body text not null, msg_type text not null check(msg_type in ('text','assignmentDraft','assignmentPublished','file','forward')),
  reply_to_id uuid references public.messages(id) on delete set null,
  attachment_url text, type text default 'text', assignment_id uuid, file_id uuid,
  reactions jsonb default '{}'::jsonb, edited_at timestamptz,
  constraint chk_assignment_card_has_id check(case when coalesce(type,msg_type) in
    ('assignmentDraft','assignmentPublished') then assignment_id is not null else true end)
);
create table public.chat_files (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  message_id uuid references public.messages(id) on delete cascade,
  file_name varchar(255) not null, file_key varchar(500) not null, file_url varchar(1000) not null,
  file_type varchar(100) not null default 'application/octet-stream',
  file_size bigint not null default 0 check(file_size >= 0),
  uploaded_by uuid not null references public.users(id) on delete cascade,
  uploaded_at timestamptz not null default now(), is_deleted boolean not null default false,
  group_id uuid references public.groups(id), subject_id uuid references public.subject_catalog(id),
  subject_offering_id uuid references public.subject_offerings(id),
  academic_year_id uuid references public.academic_years(id), academic_term_id uuid references public.academic_terms(id),
  semester_number integer, is_sensitive boolean not null default false
);
alter table public.messages add foreign key(file_id) references public.chat_files(id);
create schema private;
create table public.subject_diary_files(id uuid primary key);
create table private.chat_file_objects (
  file_key text primary key, chat_id uuid not null, uploaded_by uuid not null,
  file_id uuid unique references public.chat_files(id) on delete set null,
  file_name text not null, file_type text not null, file_size bigint not null check(file_size>0),
  file_url text not null, confirmed boolean not null default false,
  delete_requested_at timestamptz, deleted_at timestamptz,
  expires_at timestamptz not null default (now() + interval '1 hour'),
  created_at timestamptz not null default now(),
  diary_file_id uuid unique references public.subject_diary_files(id) on delete set null,
  constraint one_file_namespace check(file_id is null or diary_file_id is null)
);
create table public.group_collections(id uuid primary key, team_id uuid not null);
create table public.group_collection_contributions(proof_file_id uuid, user_id uuid, collection_id uuid);
insert into public.group_collections(id,team_id) values
  ('eeeeeeee-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
create table public.chat_academic_archives(chat_id uuid);
insert into public.chats(id,team_id,type) values
  ('11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','team_main'),
  ('22222222-2222-4222-8222-222222222222','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','team_main');
insert into public.team_members(team_id,user_id,role) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-1111-4111-8111-111111111111','member'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-2222-4222-8222-222222222222','starosta'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-3333-4333-8333-333333333333','member'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','bbbbbbbb-1111-4111-8111-111111111111','member');
insert into public.chat_files(id,chat_id,uploaded_by,file_name,file_key,file_url,file_type,file_size,uploaded_at) values
  ('cccccccc-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','fixture.pdf','fixture-key','fixture','application/pdf',10,now()),
  ('cccccccc-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','aaaaaaaa-2222-4222-8222-222222222222','other.pdf','other-key','other','application/pdf',10,now()),
  ('cccccccc-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','another.pdf','another-key','another','application/pdf',10,now());
insert into private.chat_file_objects(file_key,chat_id,uploaded_by,file_id,file_name,file_type,file_size,file_url,confirmed)
select file_key,chat_id,uploaded_by,id,file_name,file_type,file_size,file_url,true from public.chat_files;
