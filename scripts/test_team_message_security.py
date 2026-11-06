"""Synthetic-only PostgreSQL regression for the local Team message guard.

Starts a disposable localhost PostgreSQL cluster; never contacts production.
Retains the test directory for inspection instead of deleting user files.
"""
from pathlib import Path
import os
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('PG_BIN', r'C:\Program Files\PostgreSQL\16\bin'))
BASE = (Path(tempfile.gettempdir()) / 'student_platform_team_message_security').resolve()
BASE.mkdir(parents=True, exist_ok=True)
cluster = Path(tempfile.mkdtemp(prefix='cluster-', dir=BASE)).resolve()
if cluster.parent != BASE or not cluster.name.startswith('cluster-'):
    raise RuntimeError('Invalid local test directory')
flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
started = False

def run(args, *, ok=True, contains=None):
    p = subprocess.run([str(a) for a in args], text=True, encoding='utf-8',
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       errors='replace', creationflags=flags)
    if (p.returncode == 0) != ok:
        raise RuntimeError(f'Unexpected exit {p.returncode}: {p.stderr[-1800:]}')
    if contains and contains not in p.stderr:
        raise RuntimeError(f'Expected {contains!r}: {p.stderr[-1800:]}')
    return p.stdout.strip()

try:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    run([BIN/'initdb.exe','-D',cluster,'-A','trust','-U','postgres',
         '--no-instructions','--encoding=UTF8'])
    launch = subprocess.run([str(BIN/'pg_ctl.exe'),'-D',str(cluster),'-l',str(cluster/'server.log'),
         '-o',f'-h 127.0.0.1 -p {port}','-w','start'],
         stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=flags)
    if launch.returncode:
        raise RuntimeError(f'Local PostgreSQL start failed: {cluster / "server.log"}')
    started = True
    run([BIN/'createdb.exe','-h','127.0.0.1','-p',port,'-U','postgres','team_message_fixture'])
    psql = [BIN/'psql.exe','-X','-q','-v','ON_ERROR_STOP=1','-h','127.0.0.1',
            '-p',port,'-U','postgres','-d','team_message_fixture']
    def sql(value):
        return run(psql+['-A','-t','-c',value])
    def file(name, *, ok=True, contains=None):
        paths = {
          'candidate_membership.sql': ROOT/'supabase/migrations/20261106220749_restrict_team_message_sends_to_members.sql',
          'rollback_membership.sql': ROOT/'supabase/rollback/20261106220749_restrict_team_message_sends_to_members_rollback.sql',
        }
        path = paths.get(name, ROOT/'supabase/local/team_message_security'/name)
        return run(psql+['-f',path],
                   ok=ok, contains=contains)
    signatures = [
        'public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid)',
        'public.send_chat_message_with_files(uuid,text,text,uuid[])',
    ]
    def fingerprints():
        return [sql("select md5(replace(pg_get_functiondef('"+s+"'::regprocedure),chr(13),''))")
                for s in signatures]
    file('fixture.sql')
    file('baseline_triggers.sql')
    file('baseline_other_file_triggers.sql')
    file('baseline_functions.sql')
    file('file_fixture_delta.sql')
    for signature in signatures:
        sql(f'grant execute on function {signature} to anon, authenticated, service_role')
    file('baseline_member_trigger_assertions.sql')
    file('baseline_trigger_assertions.sql')
    file('archive_assertions.sql')
    baseline = fingerprints()
    assert baseline == ['f51be1f52d3ad8ba4b3b539a878f93bf',
                        '00c0ad8bc07aa3f12792c2af951bbb8e'], baseline
    file('candidate_membership.sql')
    file('baseline_member_trigger_assertions.sql')
    file('baseline_trigger_assertions.sql')
    file('archive_assertions.sql')
    file('assertions.sql')
    candidate = fingerprints()
    assert candidate == ['00ec8efaccb63d6d1fff84704b46d2d0',
                         '338bd0e898b8f70b6438dd3787bd7b9c'], candidate

    # A concurrent membership DELETE cannot pass the row lock while a send
    # transaction is still active. Advisory lock signals after the RPC.
    team = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    user = 'aaaaaaaa-1111-4111-8111-111111111111'
    for ordinal, call in enumerate([
        f"select public.send_chat_message('{team}','locked','text',null,null,null,null)",
        f"select public.send_chat_message_with_files('{team}','locked','text',array[]::uuid[])",
    ]):
        lock_id = 938410 + ordinal
        statement = ("begin; set role authenticated; "
            f"select set_config('request.jwt.claim.sub','{user}',false); "
            f"{call}; select pg_advisory_lock({lock_id}); select pg_sleep(3); commit;")
        holder = subprocess.Popen([str(a) for a in psql+['-c',statement]],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, creationflags=flags)
        try:
            deadline = time.monotonic()+8
            while time.monotonic() < deadline:
                if sql(f'select not pg_try_advisory_lock({lock_id})') == 't':
                    break
                if holder.poll() is not None:
                    raise RuntimeError('Lock-holder failed before reaching marker')
                time.sleep(.05)
            else:
                raise RuntimeError('Timed out waiting for lock-holder')
            run(psql+['-v','VERBOSITY=verbose','-c',f"set lock_timeout='200ms'; delete from public.team_members "
                f"where team_id='{team}' and user_id='{user}'"], ok=False, contains='55P03')
            run(psql+['-v','VERBOSITY=verbose','-c',f"set lock_timeout='200ms'; update public.team_members "
                f"set user_id='dddddddd-1111-4111-8111-111111111111' where team_id='{team}' and user_id='{user}'"],
                ok=False, contains='55P03')
            _, error = holder.communicate(timeout=8)
            if holder.returncode:
                raise RuntimeError(error.decode('utf-8', errors='replace')[-1200:])
            sql(f"delete from public.team_members where team_id='{team}' and user_id='{user}'")
            run(psql+['-v','VERBOSITY=verbose','-c',
                f"set role authenticated; select set_config('request.jwt.claim.sub','{user}',false); {call}"],
                ok=False, contains='42501')
            sql(f"insert into public.team_members(team_id,user_id) values('{team}','{user}')")
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.communicate(timeout=8)

    file('candidate_membership.sql', ok=False,
         contains='team send definition differs from audited snapshot')
    assert fingerprints() == candidate
    sql('create role fixture_extra nologin')
    sql(f'grant execute on function {signatures[0]} to fixture_extra')
    file('rollback_membership.sql', ok=False,
         contains='protected team send owner or grants differ')
    sql(f'revoke execute on function {signatures[0]} from fixture_extra')
    file('rollback_membership.sql')
    assert fingerprints() == baseline
    sql("update public.chat_files set message_id=null where id in ('cccccccc-1111-4111-8111-111111111111','cccccccc-aaaa-4aaa-8aaa-aaaaaaaaaaaa')")
    sql('delete from public.messages')
    file('baseline_member_trigger_assertions.sql')
    file('baseline_trigger_assertions.sql')
    file('archive_assertions.sql')
    assert sql(f"select has_function_privilege('anon','{signatures[0]}','EXECUTE')") == 't'
    sql('alter table public.chat_files disable trigger guard_chat_file_message_binding')
    file('candidate_membership.sql', ok=False, contains='required live file guards differ')
    assert fingerprints() == baseline
    sql('alter table public.chat_files enable trigger guard_chat_file_message_binding')
    sql('grant execute on function private.guard_chat_file_reference() to fixture_extra')
    file('candidate_membership.sql', ok=False, contains='required live file guards differ')
    sql('revoke execute on function private.guard_chat_file_reference() from fixture_extra')
    sql('grant authenticated to anon')
    file('candidate_membership.sql', ok=False,
         contains='unexpected role or schema privileges')
    sql('revoke authenticated from anon')
    sql('grant service_role to anon')
    file('candidate_membership.sql', ok=False,
         contains='unexpected effective team send privileges')
    assert fingerprints() == baseline
    sql('revoke service_role from anon')
    sql(f'grant execute on function {signatures[0]} to fixture_extra')
    file('candidate_membership.sql', ok=False,
         contains='team send owner or grants differ from audited snapshot')
    sql(f'revoke execute on function {signatures[0]} from fixture_extra')
    sql(f"alter function {signatures[0]} set search_path='pg_catalog'")
    file('candidate_membership.sql', ok=False,
         contains='team send definition differs from audited snapshot')
    print('PASS: membership/ACL matrices, concurrent revoke, drift and guarded rollback')
finally:
    if started:
        run([BIN/'pg_ctl.exe','-D',cluster,'-m','fast','-w','stop'])
    print(f'Disposable local test directory retained: {cluster}')
