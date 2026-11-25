"""Run the native diary UI against a private disposable schema and local GoTrue."""
from datetime import date, timedelta
import sys
from uuid import uuid4

from qa_local_schema_suite import ROOT, run_suite


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


if __name__ == "__main__":
    sys.exit(run_suite("diary", setup, "integration_test/ordinary_academic_diary_local_test.dart",
                       "STUDENT_DIARY_LOCAL"))
