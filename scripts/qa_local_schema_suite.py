"""Run a local Flutter suite against its own PostgREST schema and synthetic accounts."""
from contextlib import ExitStack
from http.client import RemoteDisconnected
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.parse import urlsplit
from urllib.request import build_opener, ProxyHandler
from uuid import UUID, uuid4

from local_e2e_api import request, sql, status

ROOT = Path(__file__).resolve().parents[1]
REST = "supabase_rest_student_platform_e2e"


def delete_student(uid, email):
    code, account = request("/auth/v1/admin/users/" + uid, admin=True)
    assert code == 200 and account["email"] == email
    code, _ = request("/auth/v1/admin/users/" + uid, method="DELETE", admin=True)
    assert code in (200, 204)
    assert request("/auth/v1/admin/users/" + uid, admin=True)[0] == 404
    assert "(0 rows)" in sql(f"select 1 from public.users where id='{uid}';")


def drop_schema(schema):
    sql(f"drop schema {schema} cascade;")
    assert "(0 rows)" in sql(f"select 1 from pg_namespace where nspname='{schema}';")


def run_with_required_markers(command, *, required_markers, **kwargs):
    # Flutter in a shared checkout can run another generated integration entrypoint
    # and exit successfully with every test skipped. Verify the requested journey.
    missing = {marker.encode("utf-8") for marker in required_markers}
    with subprocess.Popen(command, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, **kwargs) as process:
        for line in process.stdout:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            missing = {marker for marker in missing if marker not in line}
        result = process.wait()
    if missing:
        names = ", ".join(marker.decode("utf-8") for marker in sorted(missing))
        print(f"Missing E2E pass markers: {names}", flush=True)
        result = result or 1
    return subprocess.CompletedProcess(command, result)


def run_suite(name, setup, target, env_key, student_count=1, phases=(None,),
              run_client=None, required_markers=()):
    tag = uuid4().hex[:12]
    schema = "e2e_" + name + "_" + tag
    gateway = "e2e-" + name + "-rest-" + tag
    origin = json.loads(subprocess.check_output(["docker", "inspect", REST]))[0]
    network = "supabase_network_student_platform_e2e"
    assert network in origin["NetworkSettings"]["Networks"]
    config = dict(item.split("=", 1) for item in origin["Config"]["Env"])
    assert urlsplit(config["PGRST_DB_URI"]).hostname == "supabase_db_student_platform_e2e"
    with ExitStack() as stack:
        accounts = []
        for index in range(student_count):
            email = schema + (str(index) if index else "") + "@student.local"
            password = secrets.token_urlsafe(24)
            code, user = request("/auth/v1/admin/users", {
                "email": email, "password": password, "email_confirm": True}, admin=True)
            assert code in (200, 201) and user["email"] == email, "Local QA signup failed"
            uid = str(UUID(user["id"]))
            stack.callback(delete_student, uid, email)
            accounts.append(dict(student=uid, email=email, password=password))
        statements, values = setup(schema, [a["student"] for a in accounts])
        sql(f"begin; create schema {schema}; set local search_path to {schema}, public; "
            f"grant usage on schema {schema} to authenticated;" + statements + " commit;")
        stack.callback(drop_schema, schema)
        rest_env = dict(os.environ, PGRST_DB_SCHEMAS=schema, PGRST_DB_CONFIG="false",
                        **{k: config[k] for k in ("PGRST_DB_URI", "PGRST_JWT_SECRET", "PGRST_DB_ANON_ROLE")})
        options = [opt for key in ("PGRST_DB_URI", "PGRST_JWT_SECRET", "PGRST_DB_ANON_ROLE",
                                   "PGRST_DB_SCHEMAS", "PGRST_DB_CONFIG") for opt in ("-e", key)]
        subprocess.run(["docker", "run", "--detach", "--rm", "--name", gateway,
                        "--network", network, "--publish", "127.0.0.1::3000", *options,
                        origin["Config"]["Image"]], check=True, env=rest_env, stdout=subprocess.DEVNULL)
        stack.callback(subprocess.run, ["docker", "stop", "-t", "1", gateway],
                       check=True, stdout=subprocess.DEVNULL)
        address = subprocess.check_output(["docker", "port", gateway, "3000/tcp"], text=True).strip()
        assert address.startswith("127.0.0.1:")
        port = int(address.split(":")[1])
        opener = build_opener(ProxyHandler({}))
        for attempt in range(30):
            try:
                with opener.open("http://" + address + "/", timeout=2):
                    break
            except (URLError, RemoteDisconnected) as error:
                if getattr(error, "code", None) in (401, 403):
                    break
                if attempt == 29:
                    raise
                time.sleep(.3)
        env = dict(os.environ, **{env_key: json.dumps(dict(
            schema=schema, restPort=port, anon=status["ANON_KEY"],
            accounts=accounts, **accounts[0], **values))})
        command = ["flutter.bat" if os.name == "nt" else "flutter", "test",
                   "--no-pub", "-d", "windows", "--reporter=expanded",
                   "--dart-define=SUPABASE_URL=http://127.0.0.1:55321", target]
        for phase in phases:
            phase_env = env if phase is None else dict(env, STUDENT_QA_PHASE=phase)
            if required_markers:
                client = run_client or run_with_required_markers
                result = client(command, cwd=ROOT, env=phase_env, required_markers=required_markers)
            else:
                result = (run_client or subprocess.run)(command, cwd=ROOT, env=phase_env)
            if result.returncode:
                break
    print(f"PASS cleanup of isolated {name} schema, REST container and test accounts", flush=True)
    return result.returncode
