"""Run the native diary UI against a private disposable schema and local GoTrue."""
from datetime import date, timedelta
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import build_opener, ProxyHandler
from uuid import UUID, uuid4

from local_e2e_api import request, sql, status

ROOT = Path(__file__).resolve().parents[1]
REST = "supabase_rest_student_platform_e2e"


def run():
    tag = uuid4().hex[:12]
    schema = "e2e_diary_" + tag
    gateway = "e2e-diary-rest-" + tag
    origin = json.loads(subprocess.check_output(["docker", "inspect", REST]))[0]
    network = "supabase_network_student_platform_e2e"
    assert network in origin["NetworkSettings"]["Networks"]
    config = dict(item.split("=", 1) for item in origin["Config"]["Env"])
    password = secrets.token_urlsafe(24)
    email = schema + "@student.local"
    code, user = request("/auth/v1/admin/users", {
        "email": email, "password": password, "email_confirm": True}, admin=True)
    assert code in (200, 201) and user["email"] == email, "Local QA signup failed"
    uid = str(UUID(user["id"]))
    offering, team, lesson = [str(uuid4()) for _ in range(3)]
    today = date.today()
    tomorrow = today + timedelta(days=1)
    previous = today - timedelta(days=1)
    created = False
    started = False
    try:
        tables = (ROOT / "scripts/qa_academic_diary_fixture.sql").read_text("utf-8")
        tasks = (ROOT / "supabase/stage4_2_3_personal_diary_tasks.sql").read_text("utf-8")
        sql(f"""begin; create schema {schema}; set local search_path to {schema}, public;
          grant usage on schema {schema} to authenticated;
        """ + tables + tasks.replace("public.", schema + ".") + f"""
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
          commit;""")
        created = True
        rest_env = dict(os.environ, PGRST_DB_SCHEMAS=schema, PGRST_DB_CONFIG="false",
                        **{k: config[k] for k in ("PGRST_DB_URI", "PGRST_JWT_SECRET", "PGRST_DB_ANON_ROLE")})
        options = [opt for key in ("PGRST_DB_URI", "PGRST_JWT_SECRET", "PGRST_DB_ANON_ROLE",
                                   "PGRST_DB_SCHEMAS", "PGRST_DB_CONFIG") for opt in ("-e", key)]
        subprocess.run(["docker", "run", "--detach", "--rm", "--name", gateway,
                        "--network", network, "--publish", "127.0.0.1::3000", *options,
                        origin["Config"]["Image"]], check=True, env=rest_env, stdout=subprocess.DEVNULL)
        started = True
        address = subprocess.check_output(["docker", "port", gateway, "3000/tcp"], text=True).strip()
        assert address.startswith("127.0.0.1:")
        port = int(address.split(":")[1])
        opener = build_opener(ProxyHandler({}))
        for attempt in range(30):
            try:
                with opener.open("http://" + address + "/", timeout=2):
                    break
            except URLError as error:
                if getattr(error, "code", None) in (401, 403):
                    break
                if attempt == 29:
                    raise
                time.sleep(.3)
        env = dict(os.environ, STUDENT_DIARY_LOCAL=json.dumps({
            "schema": schema, "restPort": port, "email": email, "password": password,
            "anon": status["ANON_KEY"], "student": uid, "offering": offering,
            "lesson": lesson, "lessonDay": tomorrow.isoformat(), "today": today.isoformat(),
            "archiveDay": previous.isoformat()}))
        return subprocess.run(["flutter.bat" if os.name == "nt" else "flutter", "test",
            "--no-pub", "-d", "windows", "--reporter=expanded",
            "--dart-define=SUPABASE_URL=http://127.0.0.1:55321",
            "integration_test/ordinary_academic_diary_local_test.dart"], cwd=ROOT, env=env).returncode
    finally:
        try:
            if started:
                subprocess.run(["docker", "stop", "-t", "1", gateway],
                               check=True, stdout=subprocess.DEVNULL)
        finally:
            try:
                if created:
                    sql(f"drop schema {schema} cascade;")
            finally:
                code, checked = request("/auth/v1/admin/users/" + uid, admin=True)
                assert code == 200 and checked["email"] == email
                code, _ = request("/auth/v1/admin/users/" + uid, method="DELETE", admin=True)
                assert code in (200, 204)
                assert request("/auth/v1/admin/users/" + uid, admin=True)[0] == 404
                residue = sql(f"""select 1 from pg_namespace where nspname='{schema}'
                    union all select 1 from public.users where id='{uid}';""")
                assert "(0 rows)" in residue, "Temporary schema or student profile remained"
                print("PASS cleanup of isolated diary schema, REST container and test account", flush=True)


if __name__ == "__main__":
    sys.exit(run())
