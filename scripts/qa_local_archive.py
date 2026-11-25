"""Exercise chat archives via Flutter, loopback GoTrue and a per-run PostgREST."""
from contextlib import ExitStack, contextmanager
from datetime import date, timedelta
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import build_opener, ProxyHandler
from uuid import UUID, uuid4

from local_e2e_api import request, sql, status

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase/migrations"
REST = "supabase_rest_student_platform_e2e"


@contextmanager
def account(email):
    password = secrets.token_urlsafe(24)
    code, body = request("/auth/v1/admin/users", {
        "email": email, "password": password, "email_confirm": True}, admin=True)
    assert code in (200, 201) and body["email"] == email, "Local signup failed"
    uid = str(UUID(body["id"]))
    try:
        yield dict(id=uid, email=email, password=password)
    finally:
        code, body = request("/auth/v1/admin/users/" + uid, admin=True)
        assert code == 200 and body["email"] == email
        assert request("/auth/v1/admin/users/" + uid, admin=True, method="DELETE")[0] in (200, 204)
        assert request("/auth/v1/admin/users/" + uid, admin=True)[0] == 404


@contextmanager
def gateway(schema):
    container = schema.replace("_", "-")
    origin = json.loads(subprocess.check_output(["docker", "inspect", REST]))[0]
    network = "supabase_network_student_platform_e2e"
    assert network in origin["NetworkSettings"]["Networks"]
    config = dict(item.split("=", 1) for item in origin["Config"]["Env"])
    local = {k: config[k] for k in ("PGRST_DB_URI", "PGRST_JWT_SECRET", "PGRST_DB_ANON_ROLE")}
    local.update(PGRST_DB_SCHEMAS=schema, PGRST_DB_CONFIG="false")
    subprocess.run(["docker", "run", "--detach", "--rm", "--name", container,
                    "--network", network, "--publish", "127.0.0.1::3000",
                    *[opt for key in local for opt in ("-e", key)], origin["Config"]["Image"]],
                   env=dict(os.environ, **local), stdout=subprocess.DEVNULL, check=True)
    try:
        address = subprocess.check_output(["docker", "port", container, "3000/tcp"], text=True).strip()
        assert address.startswith("127.0.0.1:")
        opener = build_opener(ProxyHandler({}))
        for attempt in range(50):
            try:
                with opener.open("http://" + address + "/", timeout=2):
                    break
            except HTTPError as error:
                if error.code in (401, 403):
                    break
                raise
            except URLError:
                if attempt == 49:
                    raise
                time.sleep(.2)
        yield int(address.split(":")[1])
    finally:
        subprocess.run(["docker", "stop", "-t", "1", container], check=True, stdout=subprocess.DEVNULL)


def section(script, start, end):
    source = (MIGRATIONS / script).read_text("utf-8")
    begin = source.index(start)
    return source[begin:source.index(end, begin) + len(end)]


def install(schema, students, dm, available):
    archive = "20260717200000_academic_and_personal_chat_archive.sql"
    archive_rpcs = section(archive, "create or replace function public.set_personal_chat_archived(",
                           "grant execute on function public.get_my_archived_chat_summaries() to authenticated;")
    group_summary = section("20260727184049_stage13_2_group_space.sql",
                            "drop function public.get_my_chat_summaries();",
                            "grant execute on function public.get_my_chat_summaries() to authenticated;")
    send = section("20261029214551_private_chat_file_access.sql",
                   "CREATE OR REPLACE FUNCTION public.send_message_in_chat_with_files(",
                   "grant execute on function public.send_message_in_chat_with_files(uuid,text,uuid,uuid[]) to authenticated;")
    history = section("20260728165633_stage13_12_group_action_cards_unified_details.sql",
                      "create function public.get_chat_messages_page(",
                      "grant execute on function public.get_chat_messages_page(uuid, integer, timestamptz, uuid)\n  to authenticated;")
    current = (MIGRATIONS / "20261125183100_restore_chat_list_archive_visibility.sql").read_text("utf-8")
    apply = "\n".join((archive_rpcs, group_summary, history, send, current))
    tables = ("users teams chats chat_members team_members chat_user_settings messages chat_reads "
              "groups academic_terms group_term_semesters chat_academic_archives chat_files message_reactions").split()
    shapes = "\n".join(f"create table {t} (like public.{t} including all);" for t in tables)
    uid, peer = [u["id"] for u in students]
    team, course_chat, term = [str(uuid4()) for _ in range(3)]
    sql(f"""begin; create schema {schema}; set local search_path to {schema},public;
          grant usage on schema {schema} to authenticated;
          {shapes}
          alter table teams add column if not exists kind text not null default 'subject';
          alter table chat_files add column if not exists is_sensitive boolean not null default false;
          create table chat_file_objects(file_id uuid, confirmed boolean, delete_requested_at timestamptz,
             deleted_at timestamptz,file_key text,chat_id uuid,uploaded_by uuid);
          create table group_collection_contributions(proof_file_id uuid);
          {apply.replace('public.', schema + '.').replace('private.', schema + '.')}
          insert into users(id, login, name, surname) values
            ('{uid}','student_a','Anna','Archive'), ('{peer}','student_b','Boris','Archive');
          insert into teams(id,name) values ('{team}','Archive Mechanics');
          insert into team_members(team_id,user_id) values ('{team}','{uid}');
          insert into chats(id,team_id,type) values ('{dm}',null,'dm'), ('{course_chat}','{team}','team_main');
          insert into chat_members(chat_id,user_id) values ('{dm}','{uid}'),('{dm}','{peer}');
          insert into chat_user_settings(user_id,chat_id) values ('{uid}','{dm}'),('{peer}','{dm}');
          insert into academic_terms(id,academic_year_id,name,term_in_year,term_sequence,starts_on,ends_on)
            values ('{term}',gen_random_uuid(),'Осенний семестр',1,1,current_date-150,current_date-30);
          insert into chat_academic_archives(chat_id,academic_term_id,available_until)
            values ('{course_chat}','{term}','{available} 12:00:00+00');
          commit;""")


def verify_clear_boundary(schema, dm, students):
    # Equal timestamps are reachable within the same PostgreSQL transaction.
    # Exercise both sides of the strict watermark and roll back the extra rows.
    owner, peer = (account["id"] for account in students)
    sql(f"""begin; set local search_path to {schema}, public;
      select set_config('request.jwt.claim.sub','{owner}',true);
      select set_config('request.jwt.claims','{{"sub":"{owner}","role":"authenticated"}}',true);
      do $$
      declare cutoff timestamptz; n integer; gr uuid := gen_random_uuid();
        private_chat uuid := gen_random_uuid(); subject uuid := gen_random_uuid();
        subject_chat uuid := gen_random_uuid();
      begin
        insert into teams(id,name,kind,group_name) values
          (gr,'E2E group','group_space','A'),(subject,'E2E subject','subject','B');
        update users set group_name='A' where id='{owner}';
        update users set group_name='B' where id='{peer}';
        insert into chats(id,type,team_id) values
          (private_chat,'team_main',gr),(subject_chat,'team_main',subject);
        if exists(select 1 from get_my_chat_summaries()
                  where chat_id in(private_chat,subject_chat)) then
          raise exception 'Group name alone exposed a private group space or another subject';
        end if;
        insert into team_members(team_id,user_id) values (gr,'{owner}');
        if not exists(select 1 from get_my_chat_summaries()
                      where chat_id=private_chat and team_kind='group_space') then
          raise exception 'Member lost group-space chat or kind';
        end if;
        perform hide_personal_chat_for_me('{dm}');
        select hidden_at into strict cutoff from chat_user_settings
          where user_id='{owner}' and chat_id='{dm}';
        insert into messages(chat_id,author_id,body,created_at)
          values ('{dm}','{peer}','at the boundary',cutoff);
        if exists(select 1 from get_my_chat_summaries() where chat_id='{dm}') then
          raise exception 'A message equal to the hide timestamp resurfaced the conversation';
        end if;
        insert into messages(chat_id,author_id,body,created_at)
          values ('{dm}','{peer}','after the boundary',cutoff+interval '1 microsecond');
        select unread_count into strict n from get_my_chat_summaries()
          where chat_id='{dm}' and body='after the boundary';
        if n<>1 then raise exception 'Cleared messages reached the unread counter'; end if;
      end $$; rollback;""")
    print("PASS archive database guards: group-space membership, equal timestamp, next microsecond", flush=True)


def run():
    schema = "e2e_archive_" + uuid4().hex[:12]
    dm = str(uuid4())
    available = (date.today() + timedelta(days=30)).isoformat()
    with ExitStack() as stack:
        students = [stack.enter_context(account(schema + suffix + "@student.local")) for suffix in ("a", "b")]
        install(schema, students, dm, available)
        stack.callback(sql, f"drop schema {schema} cascade;")
        port = stack.enter_context(gateway(schema))
        cfg = dict(schema=schema, accounts=students, chat=dm, available=available, restPort=port, anon=status["ANON_KEY"])
        result = subprocess.run(["flutter.bat" if os.name == "nt" else "flutter", "test", "--no-pub",
            "--reporter=expanded", "--dart-define=SUPABASE_URL=http://127.0.0.1:55321",
            "test/ordinary_chat_archive_local_test.dart"], cwd=ROOT,
            env=dict(os.environ, STUDENT_ARCHIVE_LOCAL=json.dumps(cfg)))
        if result.returncode == 0:
            verify_clear_boundary(schema, dm, students)
    residue = sql(f"select 1 from pg_namespace where nspname='{schema}';")
    assert "(0 rows)" in residue
    print("PASS archive cleanup: both local accounts, isolated schema and gateway", flush=True)
    return result.returncode


if __name__ == "__main__":
    sys.exit(run())
