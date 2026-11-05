\set ON_ERROR_STOP on
-- Run with psql against a fresh, disposable local database of this name.
do $$ begin
  if current_database() <> 'guest_reconcile_check' then
    raise exception 'Use the disposable guest_reconcile_check database';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
end $$;

create schema private;
create table private.guest_public_groups (group_id uuid primary key);
create table public.academic_terms (id integer primary key, starts_on date, ends_on date);
create table public.curriculum_subjects (
  id integer primary key, subject_index text, block_name text, display_name text, raw_subject_name text
);
create table public.subject_catalog (
  id integer primary key, canonical_name text, control_form text, description text,
  department text, requirements text, learning_outcomes text, status text,
  guest_visible boolean not null default true, archived_at timestamptz
);
create table public.subject_offerings (
  id integer primary key, subject_id integer, group_id uuid, academic_term_id integer,
  curriculum_subject_id integer, status text
);
create table public.lessons (
  group_id uuid, date date, subject_id integer, academic_term_id integer,
  subject_offering_id integer, alias_match_status text
);

insert into private.guest_public_groups values
 ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002');
insert into public.academic_terms values (1,current_date-12,current_date+12), (2,current_date-40,current_date-13);
insert into public.curriculum_subjects values
 (1,'Б2.О.01',null,'НИР',null), (2,null,null,'Учебная практика',null),
 (3,'Б1.О.01',null,'теория и практика перевода',null), (4,null,null,'практикум',null);
insert into public.subject_catalog (id,canonical_name,status) values
 (1,'Algebra','published'), (2,'Practice index','published'), (3,'Practice title','published'),
 (4,'Theory','published'), (5,'Workshop','published'), (6,'Old term','published'),
 (7,'Schedule only','published'), (8,'Other group','published'), (9,'Draft','draft'),
 (10,'Conflicting offering','published'), (11,'Wrong explicit term','published'),
 (12,'Hidden subject','published'), (13,'Archived subject','published');
update public.subject_catalog set guest_visible = false where id = 12;
update public.subject_catalog set archived_at = now() where id = 13;
insert into public.subject_offerings
select id, id, '00000000-0000-0000-0000-000000000001', case when id=6 then 2 else 1 end,
  case when id between 2 and 5 then id-1 end, 'active'
from generate_series(1,6) id;
insert into public.subject_offerings values (8,8,'00000000-0000-0000-0000-000000000002',1,null,'active');
insert into public.lessons values
 ('00000000-0000-0000-0000-000000000001',current_date,1,1,1,'matched'),
 ('00000000-0000-0000-0000-000000000001',current_date,7,null,null,'matched'),
 ('00000000-0000-0000-0000-000000000001',current_date,9,1,null,'matched'),
 ('00000000-0000-0000-0000-000000000001',current_date,12,1,null,'matched'),
 ('00000000-0000-0000-0000-000000000001',current_date,13,1,null,'matched'),
 ('00000000-0000-0000-0000-000000000001',current_date,10,1,8,'matched'),
 ('00000000-0000-0000-0000-000000000001',current_date,11,2,null,'matched'),
 ('00000000-0000-0000-0000-000000000001',current_date-14,6,2,6,'matched'),
 ('00000000-0000-0000-0000-000000000001',current_date,4,1,null,'pending'),
 ('00000000-0000-0000-0000-000000000002',current_date,null,1,null,'pending');

\ir ../migrations/20261104154646_guest_group_subjects.sql
\ir ../migrations/20261105000711_guest_group_visibility_guard.sql

set role anon;
do $$ declare scoped jsonb;
begin
  scoped := public.get_guest_group_subjects('00000000-0000-0000-0000-000000000001');
  if jsonb_path_query_array(scoped, '$[*].id') <> '[1,2,3,7]'::jsonb then
    raise exception 'Wrong reconciled subjects: %', scoped;
  end if;
  if jsonb_path_query_array(public.get_guest_group_subjects('00000000-0000-0000-0000-000000000002'), '$[*].id') <> '[8]'::jsonb then
    raise exception 'Pending-only schedule should keep the current plan';
  end if;
  if public.get_guest_group_subjects('00000000-0000-0000-0000-000000000003') <> '[]'::jsonb then
    raise exception 'Group outside the public list';
  end if;
  if jsonb_path_query_array(public.get_guest_group_subjects('00000000-0000-0000-0000-000000000001','practice',1), '$[*].id') <> '[3]'::jsonb then
    raise exception 'Search or pagination changed';
  end if;
end $$;
reset role;

delete from public.lessons where group_id = '00000000-0000-0000-0000-000000000002';
set role anon;
do $$ begin
  if jsonb_array_length(public.get_guest_group_subjects('00000000-0000-0000-0000-000000000002')) <> 1 then
    raise exception 'Absent schedule should keep the current plan';
  end if;
end $$;
reset role;

-- A hidden or archived scheduled subject must still suppress unrelated plan fallback.
insert into public.lessons values
 ('00000000-0000-0000-0000-000000000002',current_date,12,1,null,'matched');
set role anon;
do $$ begin
  if public.get_guest_group_subjects('00000000-0000-0000-0000-000000000002') <> '[]'::jsonb then
    raise exception 'Hidden scheduled subject should suppress unrelated plan subjects';
  end if;
end $$;
reset role;
delete from public.lessons where group_id = '00000000-0000-0000-0000-000000000002';
insert into public.lessons values
 ('00000000-0000-0000-0000-000000000002',current_date,13,1,null,'matched');
set role anon;
do $$ begin
  if public.get_guest_group_subjects('00000000-0000-0000-0000-000000000002') <> '[]'::jsonb then
    raise exception 'Archived scheduled subject should suppress unrelated plan subjects';
  end if;
end $$;
reset role;
delete from public.lessons where group_id = '00000000-0000-0000-0000-000000000002';

insert into public.lessons values
 ('00000000-0000-0000-0000-000000000002',current_date,9,1,null,'matched');
set role anon;
do $$ begin
  if public.get_guest_group_subjects('00000000-0000-0000-0000-000000000002') <> '[]'::jsonb then
    raise exception 'An unpublished scheduled subject should not expose unrelated plan subjects';
  end if;
end $$;
reset role;

insert into public.academic_terms values (3,current_date-1,current_date+1);
set role anon;
do $$ begin
  if public.get_guest_group_subjects('00000000-0000-0000-0000-000000000001') <> '[]'::jsonb then
    raise exception 'Overlapping terms should not mix disciplines';
  end if;
end $$;
reset role;
