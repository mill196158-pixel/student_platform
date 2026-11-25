"""Run the ordinary lesson-to-teacher rating flows with three local students."""
import sys
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory

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
        insert into lessons(teacher,subject,date,semester_number) values
          ('Орлов П.А.', 'Геометрия', current_date, 3),
          ('Орлов П.В.', 'Гидравлика', current_date, 3),
          ('Семёнова-Орлова Л.И.', 'Механика', current_date, 3),
          ('Семёнова-Орлова Л.И.', 'Термодинамика', current_date, 3),
          ('Сидоров И.И.', 'Черчение', current_date, 3),
          ('Дмитриев Р.П.', 'Материаловедение', current_date, 3),
          ('Лебедева И.Н.', 'Информатика', current_date, 3),
          ('Зотов С.А.', 'Гидрология', current_date, 3),
          ('Зотов С.А.', 'Гидрогеология', current_date, 3),
          ('Оченьдлинная-Двойнаяфамилия Александрина Константиновна', 'Топография', current_date, 3);
        grant select on lessons to authenticated;
    """ + ddl + """
        update teacher_difficulty_targets set about_text = 'Biography of ' || display_name;
    """
    admin = (migrations / "20260727184156_stage13_3_teachers_admin.sql").read_text("utf-8")
    def routine(name):
        start = admin.index("create or replace function " + name + "(")
        return admin[start:admin.index("$$;",admin.index("as $$",start)) + 3].replace("public.",schema + ".").replace("private.",schema + ".")
    statements += """
        alter table lessons add column group_id uuid default gen_random_uuid();
        create table teachers(id uuid primary key default gen_random_uuid(),full_name text,department text,status text,
          position text,academic_degree text,about_text text,photo_path text,contacts_public jsonb);
        alter table teacher_difficulty_targets add column canonical_teacher_id uuid references teachers;
        insert into teachers(full_name,department,about_text,status) select display_name,
          case display_name when 'Орлов П.А.' then 'Кафедра геометрии' when 'Орлов П.В.' then 'Кафедра гидравлики'
            when 'Зотов С.А.' then 'Первая кафедра' end,about_text,'published' from teacher_difficulty_targets;
        update teacher_difficulty_targets t set canonical_teacher_id=p.id from teachers p where p.full_name=t.display_name;
        alter table teachers enable row level security;
        create policy published_teachers on teachers for select to authenticated using(status='published');
        grant select on teachers to authenticated;
        create function stage13_3_related_subjects(uuid) returns jsonb language sql as $$ select '[]'::jsonb $$;
        create function change_test_department() returns void language sql security definer set search_path from current
          as $$ update teachers set department='Обновлённая кафедра' where full_name='Зотов С.А.' $$;
        revoke all on function change_test_department() from public;
        grant execute on function change_test_department() to authenticated;
    """
    statements += routine("public.get_published_teacher")
    for student, score in zip(students, (5, 4, 2)):
        statements += f"""
          insert into teacher_difficulty_votes(teacher_id,user_id,score)
            select id,'{student}',{score} from teacher_difficulty_targets
            where display_name='Оченьдлинная-Двойнаяфамилия Александрина Константиновна';
        """
    if "--legacy" in sys.argv:
        return statements + "alter table teacher_difficulty_targets drop column canonical_teacher_id;", {"legacy": True}
    if "--sessions" in sys.argv:
        statements += """
          create table test_rating_sessions(phase text primary key, confirmed boolean not null default false,
            session_id uuid not null unique default ((auth.jwt()->>'session_id')::uuid));
          alter table test_rating_sessions enable row level security;
          create policy peer_state on test_rating_sessions for select to authenticated using(true);
          create policy open_own on test_rating_sessions for insert to authenticated
            with check (session_id=(auth.jwt()->>'session_id')::uuid);
          create policy confirm_own on test_rating_sessions for update to authenticated
            using (session_id=(auth.jwt()->>'session_id')::uuid);
          grant select,insert(phase),update(confirmed) on test_rating_sessions to authenticated;
        """
    return statements, {}

def run_two_sessions(command, *, cwd, env):
    # Two independent Flutter engines keep both rating pickers on screen at once.
    # The ordinary single-client suite continues to use the native Windows app.
    (ROOT / "build").mkdir(exist_ok=True)
    with TemporaryDirectory(dir=ROOT / "build", prefix="rating_sessions_") as folder:
        def launch(phase):
            host = Path(folder) / (phase + "_test.dart")
            host.write_text("import '../../" + command[-1] + "' as suite;\nvoid main() => suite.main();\n", encoding="utf-8")
            device = command.index("-d")
            host_command = [*command[:device], *command[device+2:-1], str(host.relative_to(ROOT))]
            return subprocess.run(host_command, cwd=cwd, env=dict(env, STUDENT_QA_PHASE=phase))
        with ThreadPoolExecutor(2) as pool:
            results = list(pool.map(launch, ("first", "second")))
        return next((result for result in results if result.returncode), results[0])


if __name__ == "__main__":
    sys.exit(run_suite("teachers", setup, "integration_test/ordinary_teacher_ratings_local_test.dart",
                       "STUDENT_TEACHER_LOCAL", student_count=3,
                       run_client=run_two_sessions if "--sessions" in sys.argv else None))
