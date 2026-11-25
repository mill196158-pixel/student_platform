"""Run real subject, team history, file-origin and restart journeys using local Supabase.

Usage: python scripts/qa_local_online_subject_chat.py --fresh --file-origin
Use --push-same, --switch, --ui-paging, --paging, --restart, --ack-crash,
--clean-device, --drafts or --events for the other journeys. Accepts an existing local QA config
instead of --fresh. Prepare the public chat fixture before starting; --events
also needs the scoped Realtime publication from qa_local_dm_messages.dm_schema.
"""
from contextlib import contextmanager, nullcontext
import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import UUID, uuid4

from local_e2e_schema import CONTAINER, ROOT, sql


@contextmanager
def include_realtime_author(author):
    from qa_local_dm_messages import value
    predicate = """select pg_get_expr(prqual,prrelid) from pg_publication_rel
        where prpubid=(select oid from pg_publication where pubname='supabase_realtime')
          and prrelid='public.messages'::regclass and prattrs is null;"""
    original = value(predicate)
    if not original or 'author_id' not in original:
        raise RuntimeError("Expected the scoped local DM fixture publication")
    def change(expr):
        sql("begin; alter publication supabase_realtime drop table public.messages;"
            "alter publication supabase_realtime add table public.messages where (" + expr + "); commit;")
    change(f"({original}) or author_id='{author}'::uuid")
    ours = value(predicate)
    try:
        yield
    finally:
        if value(predicate) != ours:
            raise RuntimeError("Publication changed; preserving current membership")
        change(original)
        assert value(predicate) == original
        print("PASS original local Realtime publication restored", flush=True)


def run_fresh(args):
    from contextlib import ExitStack
    from secrets import token_urlsafe
    from tempfile import TemporaryDirectory
    from local_e2e_api import request, status
    from qa_local_schema_suite import delete_student
    run_root = ROOT / "build" / "qa_local_subject"
    run_root.mkdir(parents=True, exist_ok=True)
    with ExitStack() as stack:
        work = Path(stack.enter_context(TemporaryDirectory(dir=run_root)))
        accounts = []
        for tag in ("student", "peer"):
            login = f"e2e_subject_{tag}_{uuid4().hex[:10]}"
            email = login + "@student.local"
            password = token_urlsafe(24)
            code, user = request("/auth/v1/admin/users", dict(
                email=email, password=password, email_confirm=True), admin=True)
            if code not in (200, 201):
                raise RuntimeError(f"Local fixture student creation failed ({code})")
            uid = str(UUID(user["id"]))
            stack.callback(delete_student, uid, email)
            stack.callback(sql, f"""delete from public.notification_outbox where recipient_id='{uid}';
                delete from public.app_notifications where recipient_id='{uid}';
                delete from public.notification_preferences where user_id='{uid}';""")
            sql(f"""insert into public.users(id,login,name,surname)
                values('{uid}','{login}','QA','{tag}')
                on conflict(id) do update set login=excluded.login;""")
            accounts.append((uid, login, email, password))
        uid, login, email, password = accounts[0]
        peer, _, peer_email, peer_password = accounts[1]
        config = work / "student.json"
        config.write_text(json.dumps(dict(
            recipientId=uid, login=login, email=email, password=password,
            peerId=peer, peerEmail=peer_email, peerPassword=peer_password,
            anonKey=status["ANON_KEY"], port=55321)), encoding="utf-8")
        return subprocess.call([sys.executable, __file__, str(config), *args], cwd=ROOT)


def main():
    if sys.argv[1:2] == ["--fresh"]:
        return run_fresh(sys.argv[2:])
    config = Path(sys.argv[1]).resolve(strict=True)
    run_dir = config.parent
    settings = json.loads(config.read_text(encoding="utf-8-sig"))
    identity = str(UUID(settings["recipientId"]))
    peer = str(UUID(settings.get("peerId", identity)))
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
    events = "--events" in sys.argv[2:]
    restart = "--clean-device" in sys.argv[2:] or "--restart" in sys.argv[2:] or "--ack" in sys.argv[2:] or "--ack-crash" in sys.argv[2:] or "--drafts" in sys.argv[2:] or events
    paging = "--paging" in sys.argv[2:]
    file_origin = any(flag in sys.argv[2:] for flag in ("--file-origin", "--switch", "--ui-paging")) or restart or paging
    if file_origin:
        ids.update({key: str(uuid4()) for key in ("file", "loose", "older", "unavailable")})
        ids.update({key: str(uuid4()) for key in ("otherOffering", "otherTeam", "otherChat", "otherMessage", "otherFile")})
    if "--push-same" in sys.argv[2:]: ids["pushSame"] = True
    if "--drafts" in sys.argv[2:]: ids["drafts"] = True
    if events:
        if peer == identity:
            raise ValueError("Real-time editing needs two distinct synthetic students")
        ids.update(events=True, eventEdit=str(uuid4()), eventDelete=str(uuid4()))
    if "--ack" in sys.argv[2:] or "--ack-crash" in sys.argv[2:]:
        ids["ack"] = True
        ids["crash"] = "--ack-crash" in sys.argv[2:]
    if "--switch" in sys.argv[2:]:
        ids["switch"] = True
    if "--ui-paging" in sys.argv[2:]:
        ids["uiPaging"] = True
    if restart:
        ids.update({key: str(uuid4()) for key in ("emptyTeam", "emptyChat", "coldTeam", "coldChat")})
    manifest.write_text(json.dumps(ids), encoding="utf-8")
    try:
        sql(f"""
          begin;
          select pg_advisory_xact_lock(63021865);
          do $$ begin
            if exists(select 1 from student_enrollments where user_id='{identity}' and status='active' and ended_at is null)
            then raise exception 'Existing active enrollment; use an unassigned local test student'; end if;
          end $$;
          insert into groups(id,name) values('{group}','QA group {group}');
          insert into academic_years(id,name,start_year,starts_on,ends_on)
            values('{year}','QA {year}',(select greatest(2100,coalesce(max(start_year),2099)+1) from academic_years),current_date-30,current_date+100);
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
        if file_origin:
            times = "now()-interval '1 day'" if paging else "now()-interval '1 day'+i*interval '1 second'"
            sql(f"""
              begin;
              update group_term_semesters set semester_number=2 where id='{semester}';
              update subject_offerings set semester_number=2 where id='{offering}';
              update teams set semester_number=2 where id='{team}';
              insert into subject_offerings(id,subject_id,curriculum_subject_id,group_id,academic_year_id,academic_term_id,semester_number,display_name)
                values('{ids['otherOffering']}','{subject}',null,'{group}','{year}','{term}',1,'{title}');
              insert into teams(id,name,group_id,subject_id,subject_offering_id,academic_year_id,academic_term_id,semester_number)
                values('{ids['otherTeam']}','Archive team {ids['otherTeam']}','{group}','{subject}','{ids['otherOffering']}','{year}','{term}',1);
              update chats set id='{ids['otherChat']}',subject_offering_id='{ids['otherOffering']}' where team_id='{ids['otherTeam']}' and type='team_main';
              insert into team_members(team_id,user_id) values('{ids['otherTeam']}','{identity}'),('{team}','{peer}') on conflict do nothing;
              insert into chat_members(chat_id,user_id) values('{ids['otherChat']}','{identity}'),('{chat}','{peer}') on conflict do nothing;
              insert into messages(id,chat_id,author_id,content,body)
                values('{ids['otherMessage']}','{ids['otherChat']}','{identity}','Sibling source {chat}','Sibling source {chat}');
              insert into chat_files(id,chat_id,message_id,file_name,file_key,file_url,uploaded_by)
                values('{ids['otherFile']}','{ids['otherChat']}','{ids['otherMessage']}','Plan.dwg','{ids['otherFile']}','https://example.invalid/{ids['otherFile']}','{identity}');
              insert into messages(id,chat_id,author_id,content,body,created_at) values
                ('{ids['older']}','{chat}','{peer}','Older source: {chat}','Older source: {chat}',now()-interval '2 days'),
                ('{ids['unavailable']}','{chat}','{identity}','Removed source {chat}','Removed source {chat}',now()-interval '3 days');
              insert into messages(chat_id,author_id,content,body,created_at)
                select '{chat}','{identity}','Sequence '||i,'Sequence '||i,
                       {times} from generate_series(1,120) as i;
              insert into chat_files(id,chat_id,message_id,file_name,file_key,file_url,uploaded_by) values
                ('{ids['file']}','{chat}','{ids['older']}','Plan.dwg','{ids['file']}','https://example.invalid/{ids['file']}','{identity}'),
                ('{ids['loose']}','{chat}',null,'Unattached.dwg','{ids['loose']}','https://example.invalid/{ids['loose']}','{identity}'),
                (gen_random_uuid(),'{chat}','{ids['unavailable']}','Removed.dwg','{ids['unavailable']}','https://example.invalid/{ids['unavailable']}','{identity}');
              commit;
            """)
        env = dict(os.environ, STUDENT_MATERIALS_LOCAL_CONFIG=str(config),
                   STUDENT_MATERIALS_LOCAL_MANIFEST=str(manifest))
        flutter = "flutter.bat" if os.name == "nt" else "flutter"
        if paging:
            return subprocess.call([flutter, "test", "--no-pub", "--reporter=expanded",
                "test/ordinary_team_paging_local_test.dart"], cwd=ROOT, env=env)
        if restart:
            for role in ("empty", "cold"):
                team2, chat2 = ids[role+"Team"], ids[role+"Chat"]
                sql(f"""begin; insert into teams(id,name,group_id)
                        values('{team2}','QA {team2}','{group}');
                    update chats set id='{chat2}' where team_id='{team2}' and type='team_main';
                    insert into team_members(team_id,user_id) values('{team2}','{identity}');
                    insert into chat_members(chat_id,user_id) values('{chat2}','{identity}') on conflict do nothing;
                    commit;""")
            sql(f"""insert into messages(chat_id,author_id,content,body) values
                ('{ids['coldChat']}','{identity}','Cold history marker','Cold history marker');""")
            if events:
                sql(f"""insert into messages(id,chat_id,author_id,content,body) values
                    ('{ids['eventEdit']}','{chat}','{peer}','Peer original marker','Peer original marker'),
                    ('{ids['eventDelete']}','{chat}','{peer}','Peer to remove marker','Peer to remove marker');""")
            from tempfile import TemporaryDirectory
            with (include_realtime_author(peer) if events else nullcontext()), TemporaryDirectory(prefix="history-", dir=run_dir) as directory:
                env["STUDENT_RESTART_STORAGE"] = directory
                for phase in (("clean-device",) if "--clean-device" in sys.argv else ("online", "offline")):
                    env["STUDENT_RESTART_PHASE"] = phase
                    result = subprocess.call([flutter, "test", "--no-pub", "--reporter=expanded",
                        "--dart-define=SUPABASE_URL=http://127.0.0.1:55321",
                        "test/ordinary_chat_restart_local_test.dart"], cwd=ROOT, env=env)
                    if phase == "online" and ids.get("crash"):
                        from qa_local_dm_messages import value
                        marker = Path(directory) / "confirmed-before-exit"
                        if not marker.is_file() or result == 0:
                            raise RuntimeError("Expected an abrupt Flutter process exit after visible confirmation")
                        uid = str(UUID(marker.read_text()))
                        assert value(f"select count(*) from messages where id='{uid}' and chat_id='{chat}' and author_id='{identity}';") == "1"
                        print("PASS expected process interruption and independently verified committed message", flush=True)
                    elif result:
                        return result
                return 0
        if "--file-origin" in sys.argv:
            from threading import Event, Thread
            from qa_local_dm_messages import value
            stop = Event()
            request_file = manifest.with_suffix(".revoke")
            ack = manifest.with_suffix(".revoked")
            def remove_test_membership():
                while not stop.wait(.04):
                    if request_file.exists():
                        sql(f"""begin;
                          delete from team_members where team_id='{team}' and user_id='{identity}';
                          delete from chat_members where chat_id='{chat}' and user_id='{identity}';
                          update teams set group_name='QA-reassigned-{team}' where id='{team}';
                          commit;""")
                        assert value(f"select count(*) from team_members where team_id='{team}' and user_id='{identity}'") == "0"
                        assert value(f"""select count(*) from teams t join users u on u.id='{identity}'
                            where t.id='{team}' and t.group_name=u.group_name;""") == "0"
                        ack.touch()
                        return
            thread = Thread(target=remove_test_membership, daemon=True)
            thread.start()
            try:
                return subprocess.call([flutter, "test", "--no-pub", "--reporter=expanded",
                    "test/online_subject_chat_local_test.dart"], cwd=ROOT, env=env)
            finally:
                stop.set()
                thread.join(timeout=15)
                for marker in (request_file, ack): marker.unlink(missing_ok=True)
        return subprocess.call([flutter, "test", "--no-pub",
                                "test/online_subject_chat_local_test.dart", "--reporter", "expanded"],
                               cwd=ROOT, env=env)
    finally:
        # Exact generated UUIDs only. Existing QA users and their other fixtures stay intact.
        if restart:
            sql(f"delete from teams where id in ('{ids['emptyTeam']}','{ids['coldTeam']}') and group_id='{group}';")
        if file_origin:
            sql(f"""begin; delete from notification_outbox where app_notification_id in
              (select id from app_notifications where data->>'chat_id' in ('{chat}','{ids['otherChat']}'));
              delete from app_notifications where data->>'chat_id' in ('{chat}','{ids['otherChat']}');
              delete from teams where id='{ids['otherTeam']}' and subject_offering_id='{ids['otherOffering']}';
              delete from subject_offerings where id='{ids['otherOffering']}'; commit;""")
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
