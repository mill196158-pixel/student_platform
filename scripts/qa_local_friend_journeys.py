"""Run friend or profile UI journeys with disposable local GoTrue students."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from uuid import UUID, uuid4

from local_e2e_api import BASE, request, sql, status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", action="store_true")
    args = parser.parse_args()
    run = secrets.token_hex(6)
    students = []
    team, chat = str(uuid4()), str(uuid4())
    try:
        for role in ("first", "peer"):
            login = f"e2e_social_{run}_{role}"
            email = login + "@student.local"
            password = secrets.token_urlsafe(24)
            code, user = request("/auth/v1/admin/users", {
                "email": email, "password": password, "email_confirm": True
            }, admin=True)
            if code not in (200, 201):
                raise RuntimeError(f"Could not create local {role} student ({code})")
            uid = str(UUID(user["id"]))
            surname = f"Friend{role}{run}"
            students.append(dict(id=uid, email=email, password=password, surname=surname))
            sql(f"""insert into public.users(id,login,name,surname,group_name)
                values ('{uid}','{login}','Student','{surname}','social-{run}')
                on conflict(id) do update set login=excluded.login, name=excluded.name,
                  surname=excluded.surname,group_name=excluded.group_name;""")
        config = {"api": BASE, "key": status["ANON_KEY"], "students": students}
        target = "test/ordinary_friend_actions_local_test.dart"
        variable = "STUDENT_FRIEND_SCENARIOS"
        if args.profile:
            owner, peer = (student["id"] for student in students)
            sql(f"""begin;
                insert into public.teams(id,name,group_name)
                  values('{team}','QA {team}','social-{run}');
                update public.chats set id='{chat}' where team_id='{team}' and type='team_main';
                insert into public.team_members(team_id,user_id) values('{team}','{owner}'),('{team}','{peer}');
                insert into public.chat_members(chat_id,user_id) values('{chat}','{owner}'),('{chat}','{peer}') on conflict do nothing;
                update public.users set status='Онлайн' where id='{owner}';
                commit;""")
            config["chat"] = chat
            target = "test/ordinary_profile_preferences_local_test.dart"
            variable = "STUDENT_PROFILE_SCENARIOS"
        env = dict(os.environ, **{variable: json.dumps(config)})
        command = ["flutter.bat" if os.name == "nt" else "flutter", "test", "--no-pub",
                   "--reporter=expanded", "--dart-define=SUPABASE_URL=" + BASE,
                   target]
        return subprocess.run(command, cwd=Path(__file__).resolve().parents[1], env=env).returncode
    finally:
        if args.profile:
            sql(f"delete from public.teams where id='{team}' and name='QA {team}';")
        for student in students:
            uid, email = student["id"], student["email"]
            code, current = request("/auth/v1/admin/users/" + uid, admin=True)
            if code != 200 or current.get("email") != email:
                raise RuntimeError("Temporary student identity changed")
            sql(f"""begin;
                delete from public.friends where user_id='{uid}' or friend_id='{uid}';
                delete from public.friend_requests where from_id='{uid}' or to_id='{uid}';
                delete from public.notification_outbox where recipient_id='{uid}';
                delete from public.app_notifications where recipient_id='{uid}';
                delete from public.notification_preferences where user_id='{uid}';
                commit;""")
            code, _ = request("/auth/v1/admin/users/" + uid, method="DELETE", admin=True)
            if code not in (200, 204):
                raise RuntimeError(f"Temporary student deletion failed ({code})")
            sql(f"delete from public.users where id='{uid}' and login='{email.split('@')[0]}';")
            if request("/auth/v1/admin/users/" + uid, admin=True)[0] != 404:
                raise RuntimeError("Temporary student survived cleanup")
        print(f"Removed {len(students)} temporary social accounts", flush=True)


if __name__ == "__main__":
    sys.exit(main())
