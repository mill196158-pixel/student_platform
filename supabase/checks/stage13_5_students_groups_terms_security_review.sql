-- Stage 13.5 security review (local after migration).
select c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('admin_term_ops_batches', 'admin_term_ops_rows');

select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_schema = 'public'
  and routine_name like 'admin_%'
  and (
    routine_name like '%student%'
    or routine_name like '%group%'
    or routine_name like '%term%'
  )
order by routine_name, grantee;

select indexname from pg_indexes
where schemaname = 'public'
  and indexname = 'admin_term_ops_batches_actor_payload_uidx';
