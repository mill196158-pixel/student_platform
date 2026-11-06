"""Run the assignment RPC security regression against disposable localhost PostgreSQL.

Never connects to Supabase. Requires Windows PostgreSQL binaries in PG_BIN or
C:\\Program Files\\PostgreSQL\\16\\bin. All rows and roles are synthetic.
"""
from pathlib import Path
import os
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('PG_BIN', r'C:\Program Files\PostgreSQL\16\bin'))
BASE = (Path(tempfile.gettempdir()) / 'student_platform_assignment_security_test').resolve()
BASE.mkdir(parents=True, exist_ok=True)
cluster = Path(tempfile.mkdtemp(prefix='cluster-', dir=BASE)).resolve()
if cluster.parent != BASE or not cluster.name.startswith('cluster-'):
    raise RuntimeError('Refusing to use a directory outside the explicit test root')
flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
started = False

def run(args, expect_ok=True, expected_error=None):
    proc = subprocess.run([str(x) for x in args], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, errors='replace', creationflags=flags)
    if (proc.returncode == 0) != expect_ok:
        raise RuntimeError(f'Unexpected exit code {proc.returncode}: {proc.stderr[-1200:]}')
    if expected_error is not None and expected_error not in proc.stderr:
        raise RuntimeError(f'Expected guard message not found: {expected_error}')
    return proc.stdout.strip()

try:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    run([BIN/'initdb.exe', '-D', cluster, '-A', 'trust', '-U', 'postgres',
         '--no-instructions', '--encoding=UTF8'])
    started_proc = subprocess.run([str(BIN/'pg_ctl.exe'), '-D', str(cluster), '-l',
        str(cluster/'server.log'), '-o', f'-h 127.0.0.1 -p {port}', '-w', 'start'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, creationflags=flags)
    if started_proc.returncode != 0:
        raise RuntimeError(f"PostgreSQL start failed; inspect {cluster / 'server.log'}")
    started = True
    run([BIN/'createdb.exe', '-h', '127.0.0.1', '-p', str(port), '-U', 'postgres',
         'assignment_security_fixture'])
    psql = [BIN/'psql.exe', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1',
            '-p', str(port), '-U', 'postgres', '-d', 'assignment_security_fixture']
    def sql(query):
        return run(psql + ['-A', '-t', '-c', query])
    def file(path, ok=True, error=None):
        return run(psql + ['-f', ROOT / path], expect_ok=ok, expected_error=error)
    fp = "select md5(replace(pg_get_functiondef('public.get_team_assignments(uuid)'::regprocedure),chr(13),''))"
    file('supabase/checks/team_assignments_security_fixture.sql')
    assert sql(fp) == 'c278bc64bdcd0c88e849580c52d346e0'
    file('supabase/migrations/20261106145137_restrict_team_assignments_to_members.sql')
    file('supabase/checks/team_assignments_security_assertions.sql')
    assert sql(fp) == 'a73b8a9df330d6fdf767439f95901039'
    file('supabase/migrations/20261106145137_restrict_team_assignments_to_members.sql', ok=False, error='definition differs from audited snapshot')
    assert sql(fp) == 'a73b8a9df330d6fdf767439f95901039'
    sql('create role fixture_extra nologin; grant execute on function public.get_team_assignments(uuid) to fixture_extra')
    file('supabase/rollback/20261106141029_restrict_team_assignments_to_members_rollback.sql', ok=False, error='owner or grants differ from expected snapshot')
    sql('revoke execute on function public.get_team_assignments(uuid) from fixture_extra')
    file('supabase/rollback/20261106141029_restrict_team_assignments_to_members_rollback.sql')
    assert sql(fp) == 'c278bc64bdcd0c88e849580c52d346e0'
    assert sql("select has_function_privilege('anon','public.get_team_assignments(uuid)','EXECUTE')") == 't'
    sql('grant authenticated to anon')
    file('supabase/migrations/20261106145137_restrict_team_assignments_to_members.sql', ok=False, error='unexpected get_team_assignments effective execution privileges')
    assert sql(fp) == 'c278bc64bdcd0c88e849580c52d346e0'
    sql('revoke authenticated from anon')
    sql('grant execute on function public.get_team_assignments(uuid) to fixture_extra')
    file('supabase/migrations/20261106145137_restrict_team_assignments_to_members.sql', ok=False, error='owner or grants differ from audited snapshot')
    assert sql(fp) == 'c278bc64bdcd0c88e849580c52d346e0'
    sql('revoke execute on function public.get_team_assignments(uuid) from fixture_extra')
    sql("alter function public.get_team_assignments(uuid) set search_path='pg_catalog'")
    file('supabase/migrations/20261106145137_restrict_team_assignments_to_members.sql', ok=False, error='definition differs from audited snapshot')
    print('PASS: member matrix, no-UID/anon, preserved signature, rollback, ACL and definition drift')
finally:
    if started:
        run([BIN/'pg_ctl.exe', '-D', cluster, '-m', 'fast', '-w', 'stop'])
    print(f'Disposable test directory retained: {cluster}')
