"""Local rollback-only algorithm model. Live import/RLS is tested separately."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = next((ROOT / 'supabase/migrations').glob('*_schedule_subjects_without_curriculum.sql'))
SETUP = r"""
begin;
create schema no_plan_test;
create table no_plan_test.groups(id uuid primary key,name text);
create table no_plan_test.academic_years(id uuid primary key,start_year int);
create table no_plan_test.academic_terms(id uuid primary key,academic_year_id uuid,starts_on date,ends_on date,term_in_year int,is_current bool);
create table no_plan_test.group_academic_identities(group_id uuid,admission_year int);
create table no_plan_test.group_academic_profiles(group_id uuid,admission_year int,active bool,curriculum_plan_id uuid);
create table no_plan_test.curriculum_plans(id uuid,status text,reviewed_at timestamptz,admission_year int,nominal_semesters int);
create table no_plan_test.group_term_semesters(group_id uuid,academic_term_id uuid,academic_year_id uuid,semester_number int,unique(group_id,academic_term_id));
create table no_plan_test.subject_catalog(id uuid primary key default gen_random_uuid(),canonical_name text,normalized_name text unique,status text default 'draft');
create table no_plan_test.subject_aliases(subject_id uuid,alias text,normalized_alias text unique);
create table no_plan_test.subject_offerings(id uuid primary key default gen_random_uuid(),subject_id uuid,group_id uuid,academic_year_id uuid,academic_term_id uuid,semester_number int,display_name text,curriculum_subject_id uuid,status text default 'active');
create unique index no_plan_offering_unique on no_plan_test.subject_offerings(group_id,subject_id,academic_year_id,academic_term_id) where curriculum_subject_id is null;
create table no_plan_test.teams(id uuid primary key default gen_random_uuid(),name text,group_name text,group_id uuid,subject_id uuid,subject_offering_id uuid,academic_year_id uuid,academic_term_id uuid,semester_number int,kind text,icon text);
create unique index no_plan_team_unique on no_plan_test.teams(subject_offering_id) where subject_offering_id is not null;
create table no_plan_test.chats(id uuid primary key default gen_random_uuid(),team_id uuid);
create table no_plan_test.chat_academic_archives(chat_id uuid);
create table no_plan_test.lessons(id uuid primary key default gen_random_uuid(),group_id uuid,date date,subject text,raw_subject_name text,subject_id uuid,subject_offering_id uuid,academic_year_id uuid,academic_term_id uuid,semester_number int,normalized_subject_name text,alias_match_status text default 'pending');
create function no_plan_test.f_norm_schedule_subject(t text) returns text language sql immutable as $$ select trim(regexp_replace(lower(t), '\s*\((л\.|пр\.)\)\s*$', '', 'g')) $$;
create function no_plan_test.f_subject_base(t text) returns text language sql immutable as $$ select trim(regexp_replace(t, '\s*\((л\.|пр\.)\)\s*$', '', 'g')) $$;
create function no_plan_test.stage13_8_ensure_subject_chat_and_members(t uuid) returns bool language plpgsql as $$begin if not exists(select 1 from no_plan_test.chats where team_id=t) then insert into no_plan_test.chats(team_id) values(t); end if; return true;end$$;
create function no_plan_test.rasp_schedule_require_run() returns void language plpgsql as $$begin if coalesce(auth.role(),'')<>'service_role' then raise exception 'forbidden' using errcode='42501';end if;end$$;
"""
CHECKS = r"""
do $$
declare g uuid:=gen_random_uuid(); y uuid:=gen_random_uuid(); t uuid:=gen_random_uuid();
 s uuid; s2 uuid; result jsonb; n int;
begin
 insert into no_plan_test.groups values(g,'fixture');
 insert into no_plan_test.academic_years values(y,2026);
 insert into no_plan_test.academic_terms values(t,y,'2026-09-01','2027-01-31',1,true);
 insert into no_plan_test.group_academic_profiles values(g,2026,true,null);
 insert into no_plan_test.lessons(group_id,date,subject) values(g,'2026-10-01','Квантовая механика (л.)'),(g,'2026-10-02','Квантовая механика (пр.)');
 begin perform no_plan_test.sync_schedule_subjects(g,'2026-10-01','2026-10-31',null); raise exception 'null dry run accepted'; exception when invalid_parameter_value then null;end;
 result:=no_plan_test.sync_schedule_subjects(g,'2026-10-01','2026-10-31',true);
 assert (select count(*)=0 from no_plan_test.subject_catalog),'dry run writes';
 result:=no_plan_test.sync_schedule_subjects(g,'2026-10-01','2026-10-31',false);
 assert (result->>'linked')::int=2, result::text;
 assert (result->>'created_subjects')::int=1, result::text;
 assert (select count(*)=1 from no_plan_test.subject_offerings),'duplicate offering';
 assert (select count(*)=1 from no_plan_test.teams),'duplicate team';
 result:=no_plan_test.sync_schedule_subjects(g,'2026-10-01','2026-10-31',false);
 assert (result->>'created_subjects')::int=0 and (result->>'created_teams')::int=0,'replay created duplicates';
 select id into s from no_plan_test.subject_catalog;
 insert into no_plan_test.subject_aliases values(s,'Квантмех','квантмех');
 insert into no_plan_test.lessons(group_id,date,subject) values(g,'2026-10-03','Квантмех'),(g,'2026-10-04','Квантовая механка');
 result:=no_plan_test.sync_schedule_subjects(g,'2026-10-01','2026-10-31',false);
 assert (result->>'linked')::int=3 and (result->>'pending')::int=1,result::text;
 assert (select count(*)=1 from no_plan_test.subject_catalog),'typo created duplicate';
 insert into no_plan_test.subject_catalog(canonical_name,normalized_name) values('Квантмех','квантмех') returning id into s2;
 update no_plan_test.lessons set subject_offering_id=null,subject_id=null where subject='Квантмех';
 result:=no_plan_test.sync_schedule_subjects(g,'2026-10-01','2026-10-31',false);
 assert (result->>'pending')::int=2,result::text;
 insert into no_plan_test.lessons(group_id,date,subject) values(g,'2030-10-01','Другое');
 result:=no_plan_test.sync_schedule_subjects(g,'2030-10-01','2030-10-31',false);
 assert result->'issues'->0->>'reason'='no_term',result::text;
 assert not has_function_privilege('authenticated','no_plan_test.sync_schedule_subjects(uuid,date,date,boolean,text)','EXECUTE'),'private helper exposed';
 begin perform no_plan_test.admin_sync_schedule_subjects(g,'2026-10-01','2026-10-31',false); raise exception 'unauthorized wrapper accepted'; exception when insufficient_privilege then null;end;
 raise notice 'PASS local model: no-plan create, lecture/practice, alias, typo, ambiguity, replay, dry-run, no-term, wrapper denial';
end $$;
rollback;
"""

if __name__ == '__main__':
    sql = MIGRATION.read_text(encoding='utf-8').split('-- Integrate once per imported group')[0]
    sql = sql.replace('public.', 'no_plan_test.').replace('private.', 'no_plan_test.')
    result = subprocess.run(['docker','exec','-i','supabase_db_student_platform_e2e','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'], input=(SETUP+sql+CHECKS).encode(),capture_output=True)
    print(result.stdout.decode()); print(result.stderr.decode())
    raise SystemExit(result.returncode)
