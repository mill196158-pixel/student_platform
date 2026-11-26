"""Run after local_e2e_schema.py --chat-journeys with three local QA configs."""
from contextlib import contextmanager, nullcontext
import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import UUID, uuid4

from local_e2e_schema import CONTAINER, ROOT, sql
from qa_local_dm_messages import value


@contextmanager
def compose_publication(chat):
    """Keep the Realtime event stream limited to the new synthetic chat."""
    signature = """select pg_get_expr(r.prqual,r.prrelid)
      from pg_publication_rel r join pg_publication p on p.oid=r.prpubid
      where p.pubname='supabase_realtime' and r.prrelid='public.messages'::regclass;"""
    check = """select count(*) from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename='messages';"""
    identity = """select relreplident from pg_class
      where oid='public.messages'::regclass;"""
    if value(check) != "0" or value(identity) != "d":
        # Established test stands already have an owner-managed stream.
        yield
        return
    sql(f"""
      begin;
      alter table public.messages replica identity full;
      alter publication supabase_realtime add table public.messages
        where (chat_id='{chat}'::uuid);
      commit;
    """)
    added = value(signature)
    assert chat in added and value(identity) == "f"
    try:
        yield
    finally:
        if value(signature) != added or value(identity) != "f":
            raise RuntimeError("Local Realtime fixture changed; preserving current definition")
        sql("""
          begin;
          alter publication supabase_realtime drop table public.messages;
          alter table public.messages replica identity default;
          commit;
        """)
        assert value(check) == "0" and value(identity) == "d"
        print("PASS restored original local Realtime publication and replica identity", flush=True)

def main():
    compose = sys.argv[1:2] == ["--compose"]
    organize = sys.argv[1:2] == ["--organize"]
    args = sys.argv[2:] if compose or organize else sys.argv[1:]
    if compose:
        if len(args) != 3:
            raise ValueError("Supply sender, recipient and the local TLS certificate")
        ca = Path(args[-1]).resolve(strict=True)
        pem = ca.read_bytes()
        if b"-----BEGIN CERTIFICATE-----" not in pem or b"PRIVATE KEY" in pem:
            raise ValueError("Public local TLS certificate required")
        args = args[:-1]
    configs = [Path(path).resolve(strict=True) for path in args]
    required = 2 if compose else 3
    if len(configs) != required:
        raise ValueError(f"Supply {required} local student config files")
    users = []
    for path in configs:
        config = json.loads(path.read_text(encoding="utf-8-sig"))
        if config["port"] != 55321:
            raise ValueError("Local QA service on port 55321 required")
        users.append(str(UUID(config["recipientId"])))
    if len(set(users)) != required or subprocess.check_output(
        ["docker", "inspect", "--format", "{{.Name}}", CONTAINER], text=True
    ).strip() != "/supabase_db_student_platform_e2e":
        raise ValueError("Distinct local QA students required")
    owner = users[0]
    groups = [dict(team=str(uuid4()), chat=str(uuid4())) for _ in users[1:]]
    ids = ",".join("'" + group["chat"] + "'" for group in groups)
    fixture = configs[0].parent / ("switch-chat-" + groups[0]["team"] + ".json")
    fixture.write_text(json.dumps(groups), encoding="utf-8")
    seeded = False
    try:
        pairs = []
        for group, sender in zip(groups, users[1:]):
            team, chat = group["team"], group["chat"]
            pairs.append(f"""
              insert into public.teams(id,name,group_name)
                values('{team}','QA {team}','QA {team}');
              update public.chats set id='{chat}' where team_id='{team}' and type='team_main';
              insert into public.team_members(team_id,user_id)
                values('{team}','{owner}'),('{team}','{sender}');
              insert into public.chat_members(chat_id,user_id)
                values('{chat}','{owner}'),('{chat}','{sender}') on conflict do nothing;
            """)
        # This fresh QA account has no prior preferences. A conflict aborts the transaction.
        identities = ",".join(f"'{user}'" for user in users)
        sql(f"""begin;
            do $$ begin
              if (select count(*) from public.users where id in ({identities}) and left(login,4)='e2e_') <> {required}
                then raise exception 'Disposable QA students required'; end if;
            end $$;
            insert into public.notification_preferences(user_id,group_all_messages) values('{owner}',true);
            """ + "".join(pairs) + "commit;")
        seeded = True
        env = dict(os.environ, STUDENT_CHAT_SWITCH_CONFIGS=json.dumps([str(p) for p in configs]),
                   STUDENT_CHAT_SWITCH_MANIFEST=str(fixture))
        if compose:
            env["STUDENT_TEAM_LOCAL_CA"] = str(ca)
            target = ["-d", "windows", "--dart-define=SUPABASE_URL=https://127.0.0.1:55443",
                      "integration_test/ordinary_team_messages_local_test.dart"]
        elif organize:
            target = ["test/ordinary_chat_list_actions_local_test.dart"]
        else:
            target = ["test/online_chat_switch_local_test.dart"]
        with (compose_publication(groups[0]["chat"]) if compose else nullcontext()):
            return subprocess.call(["flutter.bat" if os.name == "nt" else "flutter", "test", "--no-pub",
                                    "--reporter=expanded", *target],
                                   cwd=ROOT, env=env)
    finally:
        if seeded:
            # Notifications and their outbox rows are independent of chat FK cascades.
            team_ids = ",".join(f"'{group['team']}'" for group in groups)
            sql(f"""begin;
              delete from public.notification_outbox where app_notification_id in
                (select id from public.app_notifications where (data->>'chat_id') in ({ids}));
              delete from public.app_notifications where (data->>'chat_id') in ({ids});
              delete from public.teams where id in ({team_ids});
              delete from public.notification_preferences where user_id='{owner}';
              commit;""")
        fixture.unlink()


if __name__ == "__main__":
    sys.exit(main())
