"""Run the ordinary lesson-to-teacher rating flows with two local students."""
import sys

from qa_local_schema_suite import ROOT, run_suite


def setup(schema, students):
    migrations = ROOT / "supabase/migrations"
    ratings = (migrations / "20260721095738_teacher_difficulty_ratings.sql").read_text("utf-8")
    about = (migrations / "20260721150000_teacher_about_text.sql").read_text("utf-8")
    # The production migration seeds its targets from the teacher names in lessons
    # and teams. Supply only this run's timetable and keep all triggers and policies.
    ratings = ratings[ratings.index("create table if not exists public.teacher_difficulty_targets"):]
    ddl = (ratings + "\n" + about).replace("private.", schema + ".").replace("public.", schema + ".")
    ddl = ddl.replace("pg_catalog, public, private", "pg_catalog, " + schema)
    ddl = ddl.replace("pg_catalog, public", "pg_catalog, " + schema)
    statements = """
        create table teams(teacher text);
        create table lessons(id uuid primary key default gen_random_uuid(), teacher text not null,
          subject text not null, date date not null, semester_number integer not null);
        insert into lessons(teacher,subject,date,semester_number)
          select 'Lecturer ' || n, 'Applied mechanics', current_date, 3
          from generate_series(1,7) as n;
        grant select on lessons to authenticated;
    """ + ddl + """
        update teacher_difficulty_targets set about_text = 'Biography of ' || display_name;
    """
    return statements, {}


if __name__ == "__main__":
    sys.exit(run_suite("teachers", setup, "integration_test/ordinary_teacher_ratings_local_test.dart",
                       "STUDENT_TEACHER_LOCAL", student_count=2))
