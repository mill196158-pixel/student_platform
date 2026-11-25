"""Exercise the ordinary login UI and restart it with the same local storage."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack
from uuid import UUID, uuid4

ROOT = Path(__file__).resolve().parents[1]


def main(first, second, ca):
    configs = [json.loads(path.read_text(encoding="utf-8-sig")) for path in (first, second)]
    if not all(c["port"] == 55321 and c["email"] == c["login"] + "@student.local"
               and c["login"].startswith("e2e_") for c in configs):
        raise ValueError("Expected two local QA students")
    if configs[0]["recipientId"] == configs[1]["recipientId"] or configs[0]["anonKey"] != configs[1]["anonKey"]:
        raise ValueError("Expected distinct accounts on the same local backend")
    if b"-----BEGIN CERTIFICATE-----" not in ca.read_bytes() or b"PRIVATE KEY" in ca.read_bytes():
        raise ValueError("Supply a public QA certificate")
    # The disposable directory inherits the private account-config directory's ACL.
    with tempfile.TemporaryDirectory(prefix="auth-ui-", dir=first.parent) as folder:
        state = Path(folder)
        defines = state / "defines.json"
        defines.write_text(json.dumps({"SUPABASE_URL": "https://127.0.0.1:55443",
                                       "SUPABASE_ANON_KEY": configs[0]["anonKey"]}), encoding="utf-8")
        env = dict(os.environ, STUDENT_AUTH_LOCAL_FIRST=str(first), STUDENT_AUTH_LOCAL_SECOND=str(second),
                   STUDENT_AUTH_LOCAL_CA=str(ca), STUDENT_AUTH_LOCAL_STATE=str(state))
        for phase in ("login", "restore"):
            env["STUDENT_AUTH_LOCAL_PHASE"] = phase
            result = subprocess.run(["flutter.bat" if os.name == "nt" else "flutter", "test", "--no-pub",
                                     "--reporter=expanded", "--dart-define-from-file=" + str(defines),
                                     "test/ordinary_account_journey_local_test.dart"], cwd=ROOT, env=env)
            if result.returncode:
                return result.returncode
        return 0


def disposable():
    from local_e2e_api import request, sql, status
    from qa_local_schema_suite import delete_student
    import secrets

    with ExitStack() as stack:
        folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="student-login-")))
        if os.name == "nt":
            import getpass
            subprocess.run(["icacls", str(folder), "/inheritance:r", "/grant:r",
                            getpass.getuser()+":(OI)(CI)F"], check=True, stdout=subprocess.DEVNULL)
        paths, ids = [], []
        marker = 'Theme journey ' + uuid4().hex[:10]
        for i in range(2):
            login = "e2e_login_" + uuid4().hex[:12]
            email, password = login + "@student.local", secrets.token_urlsafe(24)
            code, user = request("/auth/v1/admin/users", {"email":email,"password":password,
                "email_confirm":True},admin=True)
            if code not in (200,201):
                raise RuntimeError("Local sign-up did not create a test identity")
            uid = str(UUID(user["id"]))
            stack.callback(delete_student,uid,email)
            ids.append(uid)
            sql(f"insert into public.users(id,login,name,surname) values ('{uid}','{login}','Student','Login') "
                f"on conflict(id) do update set login=excluded.login,name=excluded.name,surname=excluded.surname;")
            path = folder / f"account-{i}.json"
            path.write_text(json.dumps(dict(login=login,email=email,password=password,recipientId=uid,themeMessage=marker,
                                           port=55321,anonKey=status["ANON_KEY"])),encoding="utf-8")
            paths.append(path)
        chat = str(uuid4())
        sql(f"""begin; insert into public.chats(id,type) values('{chat}','dm');
            insert into public.chat_members(chat_id,user_id) values('{chat}','{ids[0]}'),('{chat}','{ids[1]}');
            insert into public.messages(chat_id,author_id,body,content,msg_type)
            values('{chat}','{ids[0]}','{marker}','{marker}','text'); commit;""")
        stack.callback(sql, f"""begin;
            delete from public.notification_outbox where recipient_id in ('{ids[0]}','{ids[1]}');
            delete from public.app_notifications where recipient_id in ('{ids[0]}','{ids[1]}');
            delete from public.chats where id='{chat}' and type='dm'; commit;""")
        with subprocess.Popen([sys.executable, "-u", str(ROOT / "scripts/qa_local_android_gateway.py"),
                               str(folder)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True) as proxy:
            try:
                ready = any("Local Android gateway ready" in line for line in proxy.stdout)
                if not ready:
                    raise RuntimeError("Local login gateway failed to start")
                start = time.monotonic()
                result = main(*paths, folder / "ordinary_test_ca.pem")
                print(f"Login and fresh-process restore exited {result} after {time.monotonic()-start:.1f}s")
                return result
            finally:
                (folder / "stop-gateway").touch()
                proxy.wait(timeout=45)


if __name__ == "__main__":
    sys.exit(main(*(Path(arg).resolve(strict=True) for arg in sys.argv[1:]))
             if sys.argv[1:] else disposable())
