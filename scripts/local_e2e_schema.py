"""LOCAL ONLY schema reconstruction. Never connects to a remote database.

The historical baseline is approximate; missing RPCs remain missing on purpose.
This is a test harness, not a production migration or proof of schema parity.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = 'supabase_db_student_platform_e2e'

def sql(value):
    result = subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'psql', '-U', 'postgres',
         '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q'],
        input=value, text=True, encoding='utf-8', capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr[-2400:])
    return result.stdout

def install_chat_journeys():
    """Prepare the existing minimal local database for real chat/inbox journeys."""
    migrations = ROOT / 'supabase/migrations'
    summary = (migrations / '20260717155000_get_my_chat_summaries_rpc.sql').read_text('utf-8')
    push = (migrations / '20260718101311_stage11_push_notifications.sql').read_text('utf-8')
    # The minimal database has no assignments or lessons; use the message trigger
    # and its dependencies directly from Stage 11.
    chat_push, marker, remaining = push.partition('-- 11. Event triggers: friends')
    _, realtime_marker, remaining = remaining.partition('-- 14. Realtime for in-app center')
    realtime, cron_marker, _ = remaining.partition('-- 15. Optional cleanup cron')
    if not all((marker, realtime_marker, cron_marker)):
        raise RuntimeError('Message notification migration boundary is missing')
    # Existing notification installations can be more recent. Never replace them.
    has_push = 'present' in sql("""
      select 'present' where to_regclass('public.app_notifications') is not null;
    """)
    baseline = (ROOT / 'supabase/local/chat_journey_rpcs.sql').read_text('utf-8')
    sql("""
      begin;
      do $$ begin
        if to_regprocedure('public.mark_chat_read(uuid,uuid)') is not null
          or to_regprocedure('public.get_unread_in_chat(uuid)') is not null
          or to_regprocedure('public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid)') is not null
          or (select btrim(prosrc, E' \\n\\r\\t') from pg_proc where oid='public.get_my_chat_summaries()'::regprocedure)
             is distinct from 'select null::uuid where false;'
        then raise exception 'Chat RPCs already installed or divergent; expected minimal local schema';
        end if;
      end $$;
      drop function public.get_my_chat_summaries();
    """ + summary + baseline + ('' if has_push else chat_push + realtime) + """
      notify pgrst, 'reload schema';
      commit;
    """)
    print('Installed local chat journey RPCs and message notifications')

def main():
    # Exact container identity, no DSN/env/remote fallback supported.
    name = subprocess.check_output(
        ['docker', 'inspect', '--format', '{{.Name}}', CONTAINER], text=True).strip()
    if name != '/' + CONTAINER:
        raise SystemExit('Wrong local container')
    if sys.argv[1:] == ['--chat-journeys']:
        install_chat_journeys()
        return
    if sys.argv[1:]:
        raise SystemExit('Usage: local_e2e_schema.py [--chat-journeys]')
    exists = sql("select to_regclass('public.users');").strip()
    if 'users' in exists:
        raise SystemExit('Local users table already exists; refusing implicit reset')
    sql((ROOT / 'supabase/local/pre_stage13_baseline.sql').read_text('utf-8'))
    sql((ROOT / 'supabase/migrations_recovered/migration_001_core_academic_subjects.sql').read_text('utf-8'))
    # Reconstructed table shapes required by the checked-in real RPC migrations.
    # These definitions are NOT asserted to match production policies.
    sql('''
      create table public.friends (
        id uuid primary key default gen_random_uuid(),
        user_id uuid not null references public.users(id),
        friend_id uuid not null references public.users(id),
        created_at timestamptz not null default now());
      create table public.friend_requests (
        id uuid primary key default gen_random_uuid(),
        from_id uuid not null references public.users(id),
        to_id uuid not null references public.users(id),
        created_at timestamptz not null default now());
      alter table public.users add column city text default '';
      create table public.message_reactions (
        message_id uuid references public.messages(id),
        user_id uuid references public.users(id), emoji text,
        primary key(message_id,user_id,emoji));
    ''')
    migrations = [
      '20260715170000_friendship_atomic_rpc.sql',
      '20260717153000_get_my_friends_and_incoming_requests_rpc.sql',
      '20260717154000_chat_user_settings.sql',
      '20260717180000_edit_own_message.sql',
      '20260717191546_user_blocks_dm_protection.sql',
      '20260719090000_get_chat_messages_page.sql',
      '20260719094600_fix_get_chat_messages_page_text_types.sql',
      '20260720180000_get_user_friends_preview.sql',
      '20260720220000_user_presence_last_seen.sql',
    ]
    failures = []
    for filename in migrations:
        try:
            sql((ROOT / 'supabase/migrations' / filename).read_text('utf-8'))
            print('APPLIED', filename)
        except RuntimeError as error:
            failures.append(filename)
            print('FAILED', filename, str(error))
    print('Incomplete migration count:', len(failures))
    if failures:
        sys.exit(1)

if __name__ == '__main__':
    main()
