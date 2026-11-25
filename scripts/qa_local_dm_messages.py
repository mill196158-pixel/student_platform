"""Test the ordinary DM composer on two unused local E2E accounts.

First prepare the minimal local database with local_e2e_schema.py --chat-journeys.
Run: python scripts/qa_local_dm_messages.py FIRST.json SECOND.json
Use --prepared when the DM functions, pair table and Realtime are already installed.
"""
import argparse
from contextlib import contextmanager, nullcontext
import json
import os
from pathlib import Path
import subprocess
from uuid import UUID, uuid4

from local_e2e_schema import ROOT, sql


def value(query):
    return sql("\\pset format unaligned\n\\pset tuples_only on\n" + query).strip()


def qa_accounts(paths):
    users = []
    for path in paths:
        account = json.loads(path.read_text(encoding="utf-8-sig"))
        if account["port"] != 55321 or not account["login"].startswith("e2e_"):
            raise ValueError("A synthetic local student on port 55321 is required")
        users.append(str(UUID(account["recipientId"])))
    if len(set(users)) != 2:
        raise ValueError("Two distinct students are required")
    ids = ",".join(f"'{user}'" for user in users)
    if value(f"select count(*) from public.users where id in ({ids}) and starts_with(login,'e2e_');") != "2":
        raise ValueError("Use two disposable local profiles")
    return users


@contextmanager
def dm_schema(users):
    # This is the minimal historical database. Refuse to replace existing RPCs,
    # publication settings or table definitions. --prepared skips all DDL.
    migrations = ROOT / "supabase/migrations"
    files = (migrations / "20261029214551_private_chat_file_access.sql").read_text("utf-8")
    objects, boundary, _ = files.partition("-- Audited legacy rows")
    send_start = files.index("CREATE OR REPLACE FUNCTION public.send_message_in_chat_with_files(")
    if not boundary:
        raise RuntimeError("Canonical DM migration boundary missing")
    send = files[send_start:]
    receipts = (migrations / "20261029203453_idempotent_dm_send.sql").read_text("utf-8")
    pair = "public.dm_pairs"
    tables = ["private.chat_file_objects", "private.dm_send_receipts", "public.group_collection_contributions"]
    procs = ["public.send_dm_message_once(uuid,text,text,uuid,uuid[])",
             "public.send_message_in_chat_with_files(uuid,text,uuid,uuid[])"]
    owned = [f"to_regclass('{table}')::oid" for table in [pair, *tables]] + [
        f"to_regprocedure('{proc}')::oid" for proc in procs]
    signature = "select concat_ws(':'," + ",".join(owned) + ");"
    ids = ",".join(f"'{uid}'::uuid" for uid in users)
    sql(f"""
      begin;
      do $$begin
        if num_nonnulls({','.join(owned)}) <> 0
          or to_regprocedure('public.get_unread_in_chat(uuid)') is null
          or to_regprocedure('public.ensure_dm_chat(uuid)') is null
          or exists(select 1 from pg_publication_tables where pubname='supabase_realtime'
                    and schemaname='public' and tablename='messages')
          or exists(select 1 from information_schema.columns where table_schema='public'
                    and table_name='chat_files' and column_name='is_sensitive')
          or (select relreplident from pg_class where oid='public.messages'::regclass)<>'d'
        then raise exception 'Expected minimal local chat schema; use --prepared for an existing DM setup'; end if;
      end$$;
      create table public.dm_pairs(
        a uuid references public.users(id) on delete cascade, b uuid references public.users(id) on delete cascade,
        chat_id uuid unique not null references public.chats(id) on delete cascade, primary key(a,b));
      alter table public.dm_pairs enable row level security;
      revoke all on public.dm_pairs from public, anon, authenticated;
      alter table public.chat_files add column is_sensitive boolean not null default false;
      -- Local baseline shape used by text-only sends (no collection or file rows).
      create table public.group_collection_contributions(proof_file_id uuid,user_id uuid,collection_id uuid);
      alter table public.group_collection_contributions enable row level security;
      revoke all on public.group_collection_contributions from public,anon,authenticated;
      alter table public.messages replica identity full;
      alter publication supabase_realtime add table public.messages where (author_id in ({ids}));
    """ + objects + send + receipts + "notify pgrst,'reload schema'; commit;")
    expected = value(signature)
    try:
        yield
    finally:
        if value(signature) != expected:
            raise RuntimeError("Local DM dependency changed; preserving database objects")
        sql("""
          begin; do $$begin
          if exists(select 1 from public.dm_pairs) or exists(select 1 from private.dm_send_receipts)
            or exists(select 1 from private.chat_file_objects) or exists(select 1 from public.group_collection_contributions)
            or exists(select 1 from public.chat_files where is_sensitive)
          then raise exception 'Local DM fixture contains additional data'; end if; end$$;
          alter publication supabase_realtime drop table public.messages;
          alter table public.messages replica identity default;
          drop function public.send_dm_message_once(uuid,text,text,uuid,uuid[]);
          drop function public.send_message_in_chat_with_files(uuid,text,uuid,uuid[]);
          drop table private.dm_send_receipts, private.chat_file_objects, public.group_collection_contributions, public.dm_pairs;
          alter table public.chat_files drop column is_sensitive;
          notify pgrst,'reload schema'; commit;
        """)


def run(paths, users):
    a, b = users
    pair = f"a=least('{a}'::uuid,'{b}'::uuid) and b=greatest('{a}'::uuid,'{b}'::uuid)"
    if value(f"select chat_id from public.dm_pairs where {pair};"):
        raise ValueError("Use two disposable students with no existing direct conversation")
    marker = uuid4().hex
    env = dict(os.environ, STUDENT_ORDINARY_DM_CONFIGS=json.dumps([str(p) for p in paths]),
               STUDENT_DM_MARKER=marker)
    try:
        return subprocess.call(["flutter.bat" if os.name == "nt" else "flutter", "test", "--no-pub",
                                "--reporter=expanded", "--dart-define=SUPABASE_URL=http://127.0.0.1:55321",
                                "test/ordinary_dm_messages_local_test.dart"], cwd=ROOT, env=env)
    finally:
        chat = value(f"select chat_id from public.dm_pairs where {pair};")
        if chat:
            chat = str(UUID(chat))
            sql(f"""
              begin; do $$begin
                if exists(select 1 from public.chat_members where chat_id='{chat}' and user_id not in ('{a}','{b}'))
                  or exists(select 1 from public.messages where chat_id='{chat}' and
                    (author_id not in ('{a}','{b}') or right(coalesce(body,''),33)<>' {marker}'))
                then raise exception 'Preserving foreign data in local test chat'; end if;
              end$$;
              delete from public.notification_outbox where recipient_id in ('{a}','{b}') and
                app_notification_id in(select id from public.app_notifications where data->>'chat_id'='{chat}');
              delete from public.app_notifications where recipient_id in ('{a}','{b}') and data->>'chat_id'='{chat}';
              delete from public.chats where id='{chat}' and exists(select 1 from public.dm_pairs where {pair} and chat_id='{chat}');
              commit;
            """)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("accounts", type=Path, nargs=2)
    parser.add_argument("--prepared", action="store_true")
    args = parser.parse_args()
    paths = [p.resolve(strict=True) for p in args.accounts]
    users = qa_accounts(paths)
    with nullcontext() if args.prepared else dm_schema(users):
        raise SystemExit(run(paths, users))
