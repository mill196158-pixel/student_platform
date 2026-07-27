-- Stage 13.3 teachers security review (run locally after the migration).
select c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('teachers','teacher_versions','teacher_import_batches','teacher_import_rows');

select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_schema = 'public'
  and routine_name in (
    'admin_list_teachers','admin_upsert_teacher','admin_set_teacher_status',
    'admin_list_teacher_versions','admin_restore_teacher_version',
    'admin_list_teacher_import_batches','admin_list_teacher_import_rows',
    'admin_teacher_import_dry_run','admin_teacher_import_apply','get_published_teacher'
  )
order by routine_name, grantee;

select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('teachers','teacher_versions','teacher_import_batches','teacher_import_rows')
order by table_name, grantee, privilege_type;

-- Unique apply replay key must exist.
select indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and indexname = 'teacher_import_batches_actor_payload_uidx';
