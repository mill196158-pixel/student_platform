"""Run the native diary UI against a private disposable schema and local GoTrue."""
from datetime import date, timedelta
import argparse
import sys
from uuid import uuid4

from qa_local_schema_suite import ROOT, run_suite
from local_e2e_api import sql

RECEIPTS = ROOT / "supabase/migrations/20261125183101_persist_assignment_completion_receipts.sql"


def scoped(source, schema):
    return source.replace("public.", schema + ".").replace("private.", schema + ".")


def setup(schema, students):
    uid = students[0]
    offering, team, lesson = [str(uuid4()) for _ in range(3)]
    today = date.today()
    tomorrow = today + timedelta(days=1)
    previous = today - timedelta(days=1)
    tables = (ROOT / "scripts/qa_academic_diary_fixture.sql").read_text("utf-8")
    tasks = (ROOT / "supabase/stage4_2_3_personal_diary_tasks.sql").read_text("utf-8")
    statements = (tables + tasks.replace("public.", schema + ".") + f"""
      grant select, insert, update on personal_diary_tasks to authenticated;
      insert into subject_offerings (id,display_name) values ('{offering}','E2E Mechanics');
      insert into teams values ('{team}','E2E Mechanics','{offering}');
      insert into assignments(subject_offering_id,team_id,title,description,due_at,status,published_at)
        values ('{offering}','{team}','Frame calculation','Draw the support reactions',
                '{tomorrow} 12:00:00+00','published',now()),
               ('{offering}','{team}','Unpublished exercise','Draft',now(),'draft',null);
      insert into subject_diary_entries(team_id,author_id,subject_offering_id,entry_date,text)
        values ('{team}','{uid}','{offering}','{previous}','Archive bridge sketch');
      insert into subject_diary_entries(team_id,author_id,subject_offering_id,entry_date,lesson_id,text)
        values ('{team}','{uid}','{offering}','{today}',gen_random_uuid(),'Another lesson today');
      """)
    return statements, dict(offering=offering, lesson=lesson, lessonDay=tomorrow.isoformat(),
                            today=today.isoformat(), archiveDay=previous.isoformat())


def planner_setup(schema, students, *, revised=True):
    statements, values = setup(schema, students)
    first, second = students
    offering = values["offering"]
    other, group = str(uuid4()), str(uuid4())
    statements += f"""
      alter table assignment_done add primary key (assignment_id,user_id);
      alter table teams add column kind text default 'subject', add column group_id uuid,
          add column academic_term_id uuid, add column teacher text, add column icon text,
          add column group_name text, add column subject_id uuid, add column academic_year_id uuid,
          add column semester_number integer;
      alter table subject_offerings add column status text default 'active';
      alter table subject_diary_files add column id uuid default gen_random_uuid();
      create table users(id uuid primary key, login text);
      insert into users values ('{first}','planner_one'), ('{second}','planner_two');
      create table groups(id uuid primary key, name text);
      insert into groups values ('{group}','Planner group');
      create table team_members(team_id uuid, user_id uuid);
      create table student_enrollments(user_id uuid, group_id uuid, status text, ended_at timestamptz);
      create table academic_terms(id uuid primary key, is_current boolean, starts_on date, ends_on date);
      create table group_term_semesters(group_id uuid, semester_number integer, academic_year_id uuid,
          academic_term_id uuid references academic_terms);
      insert into academic_terms values(gen_random_uuid(),true,current_date-20,current_date+40);
      insert into group_term_semesters select '{group}',3,gen_random_uuid(),id from academic_terms;
      create table messages(id uuid,assignment_id uuid);
      create table chats(id uuid, team_id uuid, type text);
      create table chat_academic_archives(chat_id uuid);
      update teams set group_id='{group}';
      insert into team_members select t.id, s.user_id from teams t cross join
        (values ('{first}'::uuid), ('{second}'::uuid)) s(user_id);
      insert into student_enrollments values ('{first}','{group}','active',null),
        ('{second}','{group}','active',null);
      alter table student_enrollments add column id uuid default gen_random_uuid();
      grant select on groups, group_term_semesters, academic_terms, users, student_enrollments,
          messages to authenticated;
      insert into subject_offerings(id,display_name) values ('{other}','E2E Mechanics');
      update subject_offerings set group_id='{group}', semester_number=3;
      insert into assignments(team_id,subject_offering_id,title,due_at,status,published_at)
        select id,'{offering}','Legacy practice','{values["lessonDay"]} 12:00:00+00',
            'published',now() from teams;
      insert into assignment_done(assignment_id,user_id,done)
        select id,'{first}',false from assignments where title='Legacy practice';
      insert into subject_diary_entries(author_id,subject_offering_id,entry_date,text)
        values ('{first}','{other}','{values["today"]}','Same title, other offering'),
               ('{second}','{offering}','{values["today"]}','Peer laboratory notebook');
      insert into personal_diary_tasks(author_id,subject_offering_id,title,description,status,completed_at)
        values ('{first}','{offering}','Laboratory checklist','Support reactions: original calculations','done',now()),
               ('{second}','{offering}','Laboratory checklist','Peer sample measurements','todo',null);
    """
    # Install the repository RPC and the membership predicates it actually calls.
    # Both schema names become this run's private, disposable schema.
    migrations = ROOT / "supabase/migrations"
    for name, filename in (
        ("private.is_group_space_member", "20260727184049_stage13_2_group_space.sql"),
        ("private.is_active_subject_team_for_group", "20260727184049_stage13_2_group_space.sql"),
        ("private.is_active_team_member", "20260727235000_stage13_9_chat_topics_collections.sql"),
        ("public.set_assignment_done", "20261030003733_assignment_mutation_authorization.sql"),
    ):
        source = (migrations / filename).read_text("utf-8")
        start = source.index("create or replace function " + name + "(")
        end = source.index("$$;", source.index("as $$", start)) + 3
        statements += "\n" + scoped(source[start:end], schema)
    statements += """
        revoke all on function is_group_space_member(uuid),
            is_active_subject_team_for_group(uuid,uuid), is_active_team_member(uuid)
            from public,anon,authenticated;
        revoke all on function set_assignment_done(uuid,boolean) from public,anon;
        grant execute on function set_assignment_done(uuid,boolean) to authenticated;
    """
    if revised:
        statements += scoped(RECEIPTS.read_text("utf-8"), schema)
    return statements, dict(values, otherOffering=other, planner=True)


def check_receipt_contract():
    schema = "e2e_diary_sql_" + uuid4().hex[:12]
    students = [str(uuid4()), str(uuid4())]
    baseline, _ = planner_setup(schema, students, revised=False)
    assertions = (ROOT / "scripts/qa_assignment_receipt_contract.sql").read_text("utf-8")
    sql(f"""begin; create schema {schema}; set local search_path to {schema},public;
        grant usage on schema {schema} to authenticated; {baseline}
        create temporary table original_proc as
          select oid,proowner,proacl,prosecdef,proconfig from pg_proc
          where oid='set_assignment_done(uuid,boolean)'::regprocedure;
        {scoped(RECEIPTS.read_text("utf-8"), schema)}
        select set_config('qa.student', '{students[0]}', true),
               set_config('qa.peer', '{students[1]}', true);
        {assertions} rollback;""")
    assert "(0 rows)" in sql(f"select nspname from pg_namespace where nspname='{schema}';")
    print("PASS current key-only table, nullable flag table and legacy flag/timestamp table; "
          "peer independence, repeat completion, undo and unchanged routine privileges; rolled back.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--planner", action="store_true", help="Run the two-student diary journeys")
    mode.add_argument("--backlog", action="store_true", help="Check the numbered diary backlog on two local accounts")
    mode.add_argument("--deadline", action="store_true", help="Run the own-task month change on fresh accounts")
    mode.add_argument("--receipt-contract", action="store_true", help="Rehearse three receipt table versions")
    args = parser.parse_args()
    if args.receipt_contract:
        check_receipt_contract()
        sys.exit(0)
    if args.backlog or args.deadline:
        def backlog_setup(schema, students):
            ddl, values = planner_setup(schema, students[:2])
            ddl += f"""
                alter table assignments add column link text, add column attachments jsonb,
                  add column created_by uuid, add column group_id uuid, add column subject_id uuid,
                  add column academic_year_id uuid, add column academic_term_id uuid, add column semester_number integer;
                create table assignment_votes(assignment_id uuid,value integer);
                create table lessons(id uuid primary key,date date,subject text, group_id uuid,
                  subject_id uuid,subject_offering_id uuid,semester_number integer,pair_num integer,time_start time);
                grant select on lessons to authenticated;
                create function get_my_lessons(p_from date,p_days integer) returns table (id uuid)
                    language sql stable as $$ select null::uuid where false $$;
                alter table assignments enable row level security;
                create policy visible_fixture_assignments on assignments for select to authenticated using (true);
                create policy edit_own_fixture_assignment on assignments for update to authenticated
                    using (created_by=auth.uid()) with check (created_by=auth.uid());
                update assignments set created_by='{students[2]}' where title='Frame calculation';
                grant update(due_at) on assignments to authenticated;
                insert into assignments(subject_offering_id,team_id,title,description,status,published_at,due_at)
                  select subject_offering_id,id,'Deadline notification example','Last-day assignment instructions',
                    'published',now(), date_trunc('month',current_date)+interval '2 months'-interval '12 hours'
                    from teams;
            """
            source = (ROOT / "supabase/migrations/20261125183102_respect_team_assignment_receipt_flags.sql").read_text("utf-8")
            ddl += scoped(source, schema)
            return ddl, dict(values, backlog=True, secondLesson=str(uuid4()))
        sys.exit(run_suite("diary", backlog_setup, "integration_test/ordinary_academic_diary_local_test.dart",
                           "STUDENT_DIARY_LOCAL", student_count=3,
                           phases=("deadline",) if args.deadline else ("create","restart","deadline")))
    planner = args.planner
    sys.exit(run_suite("diary", planner_setup if planner else setup,
                       "integration_test/ordinary_academic_diary_local_test.dart",
                       "STUDENT_DIARY_LOCAL", student_count=2 if planner else 1))
