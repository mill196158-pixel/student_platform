-- Stage 13.4 subjects security review (local after migration).
select c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'subject_catalog','subject_student_profiles','subject_versions',
    'subject_import_batches','subject_import_rows'
  );

select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_schema = 'public'
  and (
    routine_name like 'admin_%subject%'
    or routine_name = 'get_published_subject'
  )
order by routine_name, grantee;

select indexname from pg_indexes
where schemaname = 'public'
  and indexname in (
    'subject_import_batches_actor_payload_uidx',
    'subject_catalog_normalized_name_uidx'
  );

-- Residual if >0: unique index intentionally skipped until admin merge.
select normalized_name, count(*) as dup_count
from public.subject_catalog
group by normalized_name
having count(*) > 1;

-- Legacy permissive catalog policy must be gone.
select pol.polname
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'subject_catalog'
  and pol.polname = 'subject_catalog_read_authenticated';

