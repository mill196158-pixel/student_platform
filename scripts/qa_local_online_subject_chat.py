"""Run the online subject-to-chat widget journey on the isolated local QA database."""
import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import UUID, uuid4

from local_e2e_schema import CONTAINER, ROOT, sql


def main():
    config = Path(sys.argv[1]).resolve(strict=True)
    run_dir = config.parent
    identity = str(UUID(json.loads(config.read_text(encoding="utf-8-sig"))["recipientId"]))
    if subprocess.check_output(
            ["docker", "inspect", "--format", "{{.Name}}", CONTAINER], text=True
    ).strip() != "/supabase_db_student_platform_e2e":
        raise RuntimeError("Local QA database is required")
    ids = {name: str(uuid4()) for name in (
        "group", "year", "term", "semester", "enrollment", "subject", "curriculum",
        "offering", "team", "chat", "message")}
    group, year, term, semester, enrollment, subject, curriculum, offering, team, chat, message = ids.values()
    title = "QA subject " + offering[:8]
    body = "QA subject discussion " + message[:8]
    manifest = run_dir / f"online-subject-{offering}.json"
    manifest.write_text(json.dumps(ids), encoding="utf-8")
    try:
        sql(f"""
          begin;
          do $$ begin
            if exists(select 1 from student_enrollments where user_id='{identity}' and status='active' and ended_at is null)
            then raise exception 'Existing active enrollment; use an unassigned local test student'; end if;
          end $$;
          insert into groups(id,name) values('{group}','QA group {group}');
          insert into academic_years(id,name,start_year,starts_on,ends_on)
            values('{year}','QA {year}',2100,current_date-30,current_date+100);
          insert into academic_terms(id,academic_year_id,term_in_year,term_sequence,name,starts_on,ends_on)
            values('{term}','{year}',1,(select coalesce(max(term_sequence),0)+1 from academic_terms),'QA {term}',current_date-30,current_date+100);
          insert into group_term_semesters(id,group_id,academic_year_id,academic_term_id,semester_number)
            values('{semester}','{group}','{year}','{term}',1);
          insert into student_enrollments(id,user_id,group_id,status) values('{enrollment}','{identity}','{group}','active');
          insert into subject_catalog(id,canonical_name,normalized_name,description)
            values('{subject}','{title}','{subject}','QA material');
          insert into curriculum_subjects(id,subject_id,raw_subject_name,display_name,semester_number,control_form)
            values('{curriculum}','{subject}','{title}','{title}',1,'Exam');
          insert into subject_offerings(id,subject_id,curriculum_subject_id,group_id,academic_year_id,academic_term_id,semester_number,display_name)
            values('{offering}','{subject}','{curriculum}','{group}','{year}','{term}',1,'{title}');
          insert into teams(id,name,group_id,subject_id,subject_offering_id,academic_year_id,academic_term_id,semester_number)
            values('{team}','{title}','{group}','{subject}','{offering}','{year}','{term}',1);
          -- The ordinary team trigger creates its main chat as part of this transaction.
          update chats set id='{chat}', subject_offering_id='{offering}' where team_id='{team}' and type='team_main';
          insert into team_members(team_id,user_id) values('{team}','{identity}');
          insert into chat_members(chat_id,user_id) values('{chat}','{identity}') on conflict do nothing;
          insert into messages(id,chat_id,author_id,content,body,msg_type,type) values('{message}','{chat}','{identity}','{body}','{body}','text','text');
          commit;
        """)
        env = dict(os.environ, STUDENT_MATERIALS_LOCAL_CONFIG=str(config),
                   STUDENT_MATERIALS_LOCAL_MANIFEST=str(manifest))
        flutter = "flutter.bat" if os.name == "nt" else "flutter"
        return subprocess.call([flutter, "test", "--no-pub",
                                "test/online_subject_chat_local_test.dart", "--reporter", "expanded"],
                               cwd=ROOT, env=env)
    finally:
        # Exact generated UUIDs only. Existing QA users and their other fixtures stay intact.
        sql(f"""
          begin;
          delete from messages where id='{message}' and chat_id='{chat}';
          delete from chat_members where chat_id='{chat}' and user_id='{identity}';
          delete from chats where id='{chat}' and team_id='{team}';
          delete from team_members where team_id='{team}' and user_id='{identity}';
          delete from teams where id='{team}' and subject_offering_id='{offering}';
          delete from subject_offerings where id='{offering}';
          delete from curriculum_subjects where id='{curriculum}';
          delete from subject_catalog where id='{subject}';
          delete from student_enrollments where id='{enrollment}' and user_id='{identity}';
          delete from group_term_semesters where id='{semester}';
          delete from academic_terms where id='{term}';
          delete from academic_years where id='{year}';
          delete from groups where id='{group}';
          commit;
        """)
        manifest.unlink()


if __name__ == "__main__":
    sys.exit(main())
