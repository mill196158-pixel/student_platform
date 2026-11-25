"""Exercise the notification center using two disposable students on local Supabase."""
import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import UUID, uuid4

from local_e2e_schema import ROOT, sql


def main(primary, other):
    configs = [json.loads(path.read_text(encoding="utf-8-sig")) for path in (primary, other)]
    owner, peer = (str(UUID(config["recipientId"])) for config in configs)
    if owner == peer or any(config["port"] != 55321 for config in configs):
        raise ValueError("Expected two distinct local QA accounts")
    marker = "qa-center-" + uuid4().hex + "-"
    try:
        sql(f"""
          begin;
          do $$begin
            if (select count(*) from public.users where id in ('{owner}','{peer}')
                and left(login,4)='e2e_') <> 2
                or exists(select 1 from public.app_notifications where recipient_id in ('{owner}','{peer}'))
            then raise exception 'Two empty local QA accounts are required'; end if;
          end$$;
          insert into public.app_notifications(recipient_id,event_type,title,body,idempotency_key,created_at,read_at)
          select '{owner}', 'announcement', 'QA inbox ' || i, '', '{marker}' || i,
                 now() - interval '2 days' + i * interval '1 minute',
                 case when i>0 then now() end from generate_series(0,51) i;
          insert into public.app_notifications(recipient_id,event_type,title,body,idempotency_key)
          values ('{peer}','announcement','QA other student','','{marker}other');
          commit;
        """)
        env = dict(os.environ, STUDENT_CENTER_QA_PRIMARY=str(primary), STUDENT_CENTER_QA_OTHER=str(other))
        return subprocess.call(["flutter.bat" if os.name == "nt" else "flutter", "test", "--no-pub",
                                "--reporter=expanded", "test/notification_center_local_journey_test.dart"],
                               cwd=ROOT, env=env)
    finally:
        sql(f"delete from public.app_notifications where recipient_id in ('{owner}','{peer}') "
            f"and starts_with(idempotency_key,'{marker}');")


if __name__ == "__main__":
    sys.exit(main(*(Path(path).resolve(strict=True) for path in sys.argv[1:])))
