-- The schema is private to one run and the account is a disposable local GoTrue user.
create table users (id uuid primary key, login text, group_name text, must_change_password boolean);
insert into users values (':student:', ':login:', 'QA BRIDGE GROUP', false);
create function get_my_profile() returns setof users language sql stable set search_path from current as
$$ select * from users where id=auth.uid() $$;
create table groups(id uuid primary key, name text);
insert into groups values (':group:', 'QA BRIDGE GROUP');
create table student_enrollments (id uuid primary key default gen_random_uuid(), user_id uuid, group_id uuid references groups, status text, ended_at timestamptz);
insert into student_enrollments(user_id,group_id,status) values (':student:',':group:','active');
create table academic_terms(id uuid primary key, starts_on date, ends_on date, is_current boolean);
insert into academic_terms values (':term:',current_date-90,current_date+90,true);
create table group_term_semesters(group_id uuid references groups, academic_year_id uuid, academic_term_id uuid references academic_terms, semester_number integer);
insert into group_term_semesters values (':group:',':year:',':term:',3);

create table curriculum_subjects(id uuid primary key, assessment_types text[], control_form text,
    display_name text,raw_subject_name text,department text,hours_total integer,credits numeric,block_name text,subject_index text);
insert into curriculum_subjects(id,assessment_types) values
  (':curriculum_project:',array['exam','course_project']),(':curriculum_control:',array['course_work']),
  (':curriculum_empty:',array['exam']);
update curriculum_subjects set control_form=:schema:.academic_control_form_from_assessments(assessment_types);
create table subject_catalog(id uuid primary key default gen_random_uuid(), canonical_name text, control_form text);
insert into subject_catalog(canonical_name,control_form) values ('Сопромат','Экзамен'),
  ('Курсовой проект и практика','КП'),('Гидравлика','Экзамен');
create table subject_offerings(id uuid primary key,subject_id uuid,curriculum_subject_id uuid references curriculum_subjects,
    group_id uuid references groups,semester_number integer,status text,display_name text);
insert into subject_offerings values (':off_project:',null,':curriculum_project:',':group:',3,'active','Сопромат'),
  (':off_control:',null,':curriculum_control:',':group:',3,'active','Курсовой проект и практика'),
  (':off_empty:',null,':curriculum_empty:',':group:',3,'active','Гидравлика');
update subject_offerings o set subject_id=c.id from subject_catalog c where c.canonical_name=o.display_name;
create function get_subject_card(p_subject_offering_id uuid) returns jsonb
language sql stable set search_path from current as $$
  select jsonb_build_object('subject_id',c.id,'subject_offering_id',o.id,'canonical_name',c.canonical_name,'control_form',c.control_form)
  from subject_offerings o join subject_catalog c on c.id=o.subject_id join student_enrollments e on e.group_id=o.group_id
  where o.id=p_subject_offering_id and e.user_id=auth.uid() and e.status='active' and e.ended_at is null $$;
create table teams(id uuid primary key,subject_offering_id uuid references subject_offerings,name text,teacher text,icon text,
    group_name text,kind text default 'subject');
alter table teams add column group_id uuid, add column subject_id uuid,
    add column academic_year_id uuid, add column academic_term_id uuid, add column semester_number integer;
insert into teams(id,subject_offering_id,name,group_name) values
  (':team_project:',':off_project:','Сопромат', 'QA BRIDGE GROUP'),
  (':team_control:',':off_control:','Курсовой проект и практика','QA BRIDGE GROUP'),
  (':team_empty:',':off_empty:','Гидравлика','QA BRIDGE GROUP');
create table team_members(team_id uuid references teams,user_id uuid, primary key(team_id,user_id));
insert into team_members select id,':student:' from teams;
alter table team_members enable row level security;
create policy own_team_memberships on team_members for select to authenticated using (user_id=auth.uid());
create table chats(id uuid primary key, team_id uuid references teams,type text);
insert into chats values (':chat_project:',':team_project:','team_main'),(':chat_control:',':team_control:','team_main'),
  (':chat_empty:',':team_empty:','team_main');
create table fixture_archived_chat (chat_id uuid primary key references chats);
-- This projection follows the same offering -> curriculum join and control_form
-- used in the deployed rpc_get_my_subjects_v2. No routing label is supplied.
create function rpc_get_my_subjects_v2() returns table(subject_offering_id uuid, group_id uuid, semester_number integer,
    subject_title text,control_form text,team_id uuid,chat_id uuid,can_open_chat boolean)
language sql stable set search_path from current as $$
  select o.id,o.group_id,o.semester_number,o.display_name,s.control_form,t.id,c.id,true
  from subject_offerings o join curriculum_subjects s on s.id=o.curriculum_subject_id
  join teams t on t.subject_offering_id=o.id join chats c on c.team_id=t.id and c.type='team_main'
  join student_enrollments e on e.group_id=o.group_id and e.status='active' and e.ended_at is null
  where e.user_id=auth.uid() $$;
create table messages(id uuid primary key default gen_random_uuid(),chat_id uuid references chats, author_id uuid,
    body text,content text,created_at timestamptz default now(), msg_type text default 'text');
insert into messages(chat_id,author_id,body,content) values (':chat_project:',':student:','Расчёт моста: проект 036','Расчёт моста: проект 036'),
    (':chat_control:',':student:','Обычный чат 036','Обычный чат 036');
create function get_chat_messages_page(p_chat_id uuid,p_limit integer default 100,p_before_at timestamptz default null,
    p_before_id uuid default null) returns table(id uuid,chat_id uuid,author_id uuid,text text,type text,
    created_at timestamptz,has_more boolean,attachments jsonb) language sql stable set search_path from current as $$
   select m.id,m.chat_id,m.author_id,m.body,m.msg_type,m.created_at,false,'[]'::jsonb
   from messages m join rpc_get_my_subjects_v2() v on v.chat_id=m.chat_id
   where m.chat_id=p_chat_id and (p_before_at is null or m.created_at<p_before_at) order by m.created_at desc limit p_limit $$;
create table chat_files(id uuid primary key, chat_id uuid references chats, file_name text,file_key text, file_url text,
    file_type text default 'application/pdf', file_size integer default 1450, is_deleted boolean default false,
    uploaded_by uuid, uploaded_at timestamptz default now(), message_id uuid references messages);
insert into chat_files(id,chat_id,file_name,file_key,file_url,uploaded_by) values
  (':file_project:',':chat_project:','Расчётная записка.pdf',':file_project:',':base:/project.pdf',':student:'),
  (':file_control:',':chat_control:','Расчётная записка.pdf',':file_control:',':base:/control.pdf',':student:');
create function get_my_chat_summaries() returns table(chat_id uuid, chat_type text, team_id uuid,
    team_name text, title text, settings_exists boolean, unread_count int)
language sql stable set search_path from current as $$
  select v.chat_id,'team_main',v.team_id,v.subject_title,v.subject_title,true,0
  from rpc_get_my_subjects_v2() v
  where not exists(select 1 from fixture_archived_chat a where a.chat_id=v.chat_id) $$;
create function fixture_deny_project_writes() returns void
language sql security definer set search_path from current as $$
  delete from team_members where team_id=':team_project:' and user_id=auth.uid() $$;
create function fixture_archive_empty_chat() returns void
language sql security definer set search_path from current as $$
  insert into fixture_archived_chat(chat_id) select ':chat_empty:' where auth.uid()=':student:'
  on conflict do nothing $$;
create function fixture_seed_long_history() returns void
language sql security definer set search_path from current as $$
  insert into messages(chat_id,author_id,body,content,created_at)
  select ':chat_project:',auth.uid(),'История чата ' || n,'История чата ' || n,
    now() - (40 - n) * interval '3 minutes'
  from generate_series(1,40) n where auth.uid()=':student:' $$;
create function get_chat_composer_capabilities(p_chat_id uuid) returns jsonb
language sql stable set search_path from current as $$
  select jsonb_build_object('chat_type','team','team_kind','subject',
    'is_active_member',false,'can_propose_assignment',false,
    'reasons',jsonb_build_object('propose_assignment','not_member'))
  from rpc_get_my_subjects_v2() v
  where v.chat_id=p_chat_id $$;
create function send_chat_message(p_team_id uuid,p_text text,p_type text,
    p_reply_to uuid,p_attachment_url text,p_assignment_id uuid,p_file_id uuid)
returns uuid language plpgsql security definer set search_path from current as $$
declare target uuid; sent uuid;
begin
  select c.id into target from chats c join team_members tm on tm.team_id=c.team_id
  where c.team_id=p_team_id and c.type='team_main' and tm.user_id=auth.uid()
    and not exists(select 1 from fixture_archived_chat a where a.chat_id=c.id);
  if target is null then raise exception 'forbidden'; end if;
  insert into messages(chat_id,author_id,body,content,msg_type)
  values(target,auth.uid(),p_text,p_text,p_type) returning id into sent;
  return sent;
end $$;
grant select on all tables in schema :schema: to authenticated;
revoke execute on all functions in schema :schema: from public,anon;
grant execute on all functions in schema :schema: to authenticated;
