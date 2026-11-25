-- Only for qa_local_timetable_backlog.py, in a fresh local schema.
create table groups(id uuid primary key, name text);
create table users(id uuid primary key, group_name text, subgroup text);
create table academic_terms(id uuid primary key, starts_on date, ends_on date, is_current boolean);
create table group_term_semesters(group_id uuid, semester_number integer, academic_term_id uuid, academic_year_id uuid, created_at timestamptz default now());
create table curriculum_subjects(id uuid primary key, display_name text, raw_subject_name text);
create table subject_catalog(id uuid primary key, canonical_name text, normalized_name text);
create table subject_aliases(subject_id uuid, alias text, normalized_alias text);
create table subject_offerings(id uuid primary key, subject_id uuid, group_id uuid, semester_number integer,
  academic_term_id uuid, academic_year_id uuid, curriculum_subject_id uuid, display_name text);
create table lessons(id uuid primary key default gen_random_uuid(), week int default 1, day text default 'ПН',
  date date, pair_num int, time_start time, time_end time, subject text, room text, teacher text,
  group_id uuid, semester_number integer, subject_id uuid, subject_offering_id uuid, academic_term_id uuid,
  academic_year_id uuid, raw_subject_name text, normalized_subject_name text, alias_match_status text, subgroup text);
alter table lessons enable row level security;
create policy enrolled on lessons for select to authenticated
  using(exists(select 1 from groups g join users u on u.group_name=g.name where g.id=lessons.group_id and u.id=auth.uid()));
grant select on users,groups,lessons to authenticated;
CREATE OR REPLACE FUNCTION "public"."f_norm_title"("t" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select trim(regexp_replace(regexp_replace(lower(coalesce(t,'')),
               '[\.\,\;\:\!\?\-–—]+', ' ', 'g'),
               '\s+', ' ', 'g'))
$$;
CREATE OR REPLACE FUNCTION "public"."get_my_lessons"("p_from" "date" DEFAULT CURRENT_DATE, "p_days" integer DEFAULT 14) RETURNS TABLE("id" "uuid", "week" integer, "day" "text", "date" "date", "pair_num" integer, "time_start" time without time zone, "time_end" time without time zone, "subject" "text", "room" "text", "teacher" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    l.id, l.week, l.day, l.date, l.pair_num,
    l.time_start, l.time_end, l.subject, l.room, l.teacher
  from public.lessons l
  join public.groups  g on g.id = l.group_id
  join public.users   u on u.group_name = g.name
  where u.id = auth.uid()
    and l.date >= p_from
    and l.date <  (p_from + make_interval(days => p_days))
  order by l.date, l.pair_num, l.time_start;
$$;
-- Schedule cases
insert into groups values (':a:','Group One'),(':b:','Group Two');
insert into users values (':student:','Group One','A'),(':peer:','Group One','B');
insert into academic_terms values(':term:','2026-12-01','2027-01-31',true);
insert into group_term_semesters values(':a:',3,':term:',gen_random_uuid()),(':b:',3,':term:',gen_random_uuid());
insert into subject_catalog values(':sub1:','Bridge mechanics','bridge mechanics'),(':sub2:','Bridge materials','bridge materials');
insert into subject_offerings(id,subject_id,group_id,semester_number,academic_term_id,display_name)
 values(':off1:',':sub1:',':a:',3,':term:','Bridge mechanics'),
       (':off2:',':sub2:',':a:',3,':term:','Bridge materials'),
       (':off3:',':sub1:',':b:',3,':term:','Bridge mechanics');
insert into lessons(date,pair_num,time_start,time_end,subject,room,teacher,group_id,semester_number,academic_term_id)
values ('2026-12-28',1,'09:00','10:30','Bridge mechanics','North 10','Lecturer One',':a:',3,':term:'),
       ('2026-12-28',2,'11:00','12:30','Bridge mechanics','South 20','Lecturer One',':a:',3,':term:'),
       ('2026-12-29',1,'09:00','10:30','Bridge materials','East 30','Lecturer Two',':a:',3,':term:'),
       ('2026-12-30',1,'09:00','10:30', U&'BRIDGE\00A0  MECHANICS','West 40','Lecturer One',':a:',3,':term:'),
       ('2027-01-04',1,'09:00','10:30','Bridge mechanics','North 99','Lecturer One',':a:',3,':term:'),
       ('2027-01-04',1,'09:00','10:30','Bridge mechanics','New Group 11','Lecturer Three',':b:',3,':term:');
alter table subject_offerings add column status text default 'active';
alter table subject_catalog add column description text;
alter table curriculum_subjects add column control_form text, add column department text, add column hours_total numeric,
  add column credits numeric,add column block_name text,add column subject_index text;
create table teams(id uuid primary key default gen_random_uuid(),name text,teacher text,icon text,group_name text,
  subject_offering_id uuid);
create table chats(id uuid primary key default gen_random_uuid(),type text,team_id uuid);
create table assignments(id uuid,team_id uuid,title text,body text,description text,due_at timestamptz,
  due_text text,status text,published_at timestamptz,subject_offering_id uuid,created_at timestamptz);
insert into teams(name,group_name,subject_offering_id) select s.display_name||' '||g.name,g.name,s.id
  from subject_offerings s join groups g on g.id=s.group_id;
insert into chats(team_id,type) select id,'team_main' from teams;
grant select on teams,chats,subject_offerings,subject_catalog,curriculum_subjects,assignments to authenticated;
revoke all on function public.resolve_subject_offering_for_schedule(uuid,text,date,integer),
  public.link_lesson_subject_from_schedule(uuid) from public,anon,authenticated;
select public.link_lesson_subject_from_schedule(l.id) from lessons l;
create table curriculum_plans(id uuid primary key,admission_year integer,nominal_semesters integer,status text);
create table group_academic_profiles(group_id uuid primary key,curriculum_plan_id uuid references curriculum_plans,
  admission_year integer,nominal_semesters integer,updated_at timestamptz default now());
insert into curriculum_plans values(':plan:',2025,8,'reviewed');
insert into group_academic_profiles values(':a:',null,2025,8,now());
alter table curriculum_subjects add column curriculum_plan_id uuid references curriculum_plans;
insert into curriculum_subjects(id,display_name,raw_subject_name,curriculum_plan_id)
  values(gen_random_uuid(),'Bridge mechanics','Bridge mechanics',':plan:');
alter table subject_offerings add foreign key(subject_id) references subject_catalog,
  add foreign key(curriculum_subject_id) references curriculum_subjects;
create function academic_ingestion_has_permission(p_code text) returns boolean language sql stable
  as $$ select auth.uid()=':staff:'::uuid and p_code in ('groups.write','subjects.write') $$;
revoke all on function academic_ingestion_has_permission(text) from public,anon,authenticated;
create table messages(id uuid primary key default gen_random_uuid(),chat_id uuid references chats,
  author_id uuid,content text,body text,created_at timestamptz default now());
create table chat_files(id uuid primary key default gen_random_uuid(),message_id uuid references messages);
grant select on messages,chat_files,group_academic_profiles to authenticated;
insert into messages(chat_id,author_id,content,body)
  select c.id,':peer:','Before academic plan','Before academic plan' from chats c
  join teams t on t.id=c.team_id where t.subject_offering_id=':off1:';
create function confirm_test_offering() returns void language sql security definer set search_path from current as $$
  update subject_offerings set curriculum_subject_id=(select id from curriculum_subjects where curriculum_plan_id=':plan:')
  where id=':off1:' and auth.uid()=':staff:'::uuid and exists(select 1 from group_academic_profiles
      where group_id=':a:' and curriculum_plan_id=':plan:') $$;
revoke all on function confirm_test_offering() from public,anon;
grant execute on function confirm_test_offering() to authenticated;
alter table users add column login text;
create table student_enrollments(id uuid default gen_random_uuid(),user_id uuid,group_id uuid,status text,ended_at timestamptz);
insert into student_enrollments(user_id,group_id,status) select id,':a:','active' from users;
create table team_members(team_id uuid references teams,user_id uuid);
insert into team_members select t.id,u.id from teams t join users u on t.group_name=u.group_name;
alter table teams add column kind text default 'subject',add column group_id uuid,add column subject_id uuid,
  add column academic_year_id uuid,add column academic_term_id uuid,add column semester_number integer;
update teams t set group_id=o.group_id,subject_id=o.subject_id,academic_term_id=o.academic_term_id,
  semester_number=o.semester_number from subject_offerings o where t.subject_offering_id=o.id;
grant select on student_enrollments,team_members,academic_terms,group_term_semesters to authenticated;
CREATE OR REPLACE FUNCTION "public"."get_my_teams"() RETURNS TABLE("id" "uuid", "name" "text", "teacher" "text", "icon" "text", "group_name" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with me as (
    select id, group_name
    from public.users
    where id = auth.uid()
    limit 1
  )
  select t.id, t.name, t.teacher, t.icon, t.group_name
  from public.teams t
  join public.team_members tm on tm.team_id = t.id
  join me on tm.user_id = me.id
  union
  select t.id, t.name, t.teacher, t.icon, t.group_name
  from public.teams t
  join me on t.group_name = me.group_name
$$;
create function advance_fixture(p_action text) returns void language plpgsql security definer set search_path from current as $$
begin
  if auth.uid() <> ':student:'::uuid then raise exception 'unexpected actor'; end if;
  case p_action
  when 'rename' then
    update teams set name='Renamed mechanics team' where subject_offering_id=':off1:';
    update subject_offerings set display_name='Updated bridge mechanics' where id=':off1:';
    update lessons set subject='Updated bridge mechanics' where subject_offering_id=':off1:';
  when 'reset_name' then
    update teams set name='Bridge mechanics Group One' where subject_offering_id=':off1:';
    update subject_offerings set display_name='Bridge mechanics' where id=':off1:';
    update lessons set subject='Bridge mechanics' where subject_offering_id=':off1:';
    update lessons set subject=U&'BRIDGE\00A0  MECHANICS' where room='West 40';
  when 'subgroup' then
    insert into lessons(date,pair_num,time_start,time_end,subject,room,teacher,group_id,subgroup,semester_number)
      values('2026-12-31',3,'13:00','14:30','Subgroup B workshop','Workshop','Instructor',':a:','B',3);
  when 'move' then update lessons set date='2026-12-27' where date='2026-12-29' and group_id=':a:';
  when 'substitute' then update lessons set teacher='Replacement teacher' where date='2026-12-28' and pair_num=2;
  when 'new_group' then update users set group_name='Group Two' where id=auth.uid();
  else raise exception 'unknown fixture action';
  end case;
end $$;
revoke all on function advance_fixture(text) from public;
grant execute on function advance_fixture(text) to authenticated;
