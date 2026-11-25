"""Compare the team assignments RPC on the three supported local receipt schemas."""
import argparse
from uuid import uuid4

from local_e2e_api import sql
from qa_local_schema_suite import ROOT


def check(shape, baseline):
    schema = "e2e_teamflag_" + uuid4().hex[:12]
    owner, peer, team, task, later = (str(uuid4()) for _ in range(5))
    fixture = (ROOT / "supabase/checks/team_assignments_security_fixture.sql").read_text("utf-8")
    tables = fixture[fixture.index("create table public.team_members"):fixture.index("insert into public.assignments")]
    script = ("20261106145137_restrict_team_assignments_to_members.sql" if baseline
              else "20261125183102_respect_team_assignment_receipt_flags.sql")
    source = (ROOT / "supabase/migrations" / script).read_text("utf-8")
    start = source.index("create or replace function public.get_team_assignments(")
    rpc = source[start:source.index("do $guard$", start)] if baseline else source[start:]
    extra = ""
    if shape != "keys":
        extra = "alter table assignment_done add column done boolean;"
        if shape == "legacy":
            extra += "alter table assignment_done alter column done set default false, add column done_at timestamptz;"
        extra += f"update assignment_done set done=false where assignment_id='{task}' and user_id='{owner}';"
        extra += f"update assignment_done set done=true where user_id='{peer}';"
    expect_done = 'true' if shape == "keys" else 'false'
    query = f"""
      begin; create schema {schema}; set local search_path to {schema},public;
      {tables.replace('public.', schema + '.')}
      {rpc.replace('public.', schema + '.')}
      grant usage on schema {schema} to authenticated;
      do $$ begin
        if has_function_privilege('anon', '{schema}.get_team_assignments(uuid)', 'execute')
          or not has_function_privilege('authenticated', '{schema}.get_team_assignments(uuid)', 'execute')
          or not has_function_privilege('service_role', '{schema}.get_team_assignments(uuid)', 'execute')
        then raise exception 'Unexpected role grants'; end if;
      end $$;
      insert into team_members(team_id,user_id) values ('{team}','{owner}'),('{team}','{peer}');
      insert into assignments(id,team_id,title,status,created_at) values
         ('{task}','{team}','Initial drawings','published','2026-01-01T12:00Z'),
         ('{later}','{team}','Revised drawings','published','2026-01-02T12:00Z');
      insert into assignment_done(assignment_id,user_id) values
         ('{task}','{owner}'),('{task}','{peer}'),('{later}','{owner}');
      {extra}
      set local role authenticated;
      select set_config('request.jwt.claim.sub','{owner}',true);
      do $$ declare actual boolean[]; begin
         select array_agg(completed_by_me order by ordinality) into actual
           from get_team_assignments('{team}') with ordinality;
         if actual is distinct from array[{expect_done},true] then
           raise exception 'Owner team completion on {shape} was %, expected [{expect_done},true]', actual;
         end if;
         if (select array_agg(title order by ordinality) from get_team_assignments('{team}') with ordinality)
              is distinct from array['Initial drawings','Revised drawings'] then
            raise exception 'Missing or reordered assignments';
         end if;
      end $$;
      select set_config('request.jwt.claim.sub','{peer}',true);
      do $$ begin
        if (select array_agg(completed_by_me order by created_at) from get_team_assignments('{team}'))
             is distinct from array[true,false] then raise exception 'Peer flags differ'; end if;
      end $$;
      rollback;"""
    sql(query)
    print(f"PASS {shape}: ordered own and peer assignment flags, transaction rolled back", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", action="store_true")
    baseline = parser.parse_args().baseline
    for receipt_shape in ("keys", "nullable", "legacy"):
        check(receipt_shape, baseline)
