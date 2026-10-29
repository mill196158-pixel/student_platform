set local lock_timeout='3s';
do $$
declare f record; role_name text;
begin
for f in select p.oid,p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('upsert_local_user','register_local_user','send_test_message','send_chat_message_for_login','get_my_teams_by_login','debug_team_snapshot') loop
execute format('revoke execute on function %s from public, anon, authenticated',f.signature);
foreach role_name in array array['anon','authenticated'] loop
if has_function_privilege(role_name,f.oid,'EXECUTE') then raise exception 'Residual execute on % for %',f.signature,role_name; end if;
end loop;
end loop;
end $$;
