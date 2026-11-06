-- Local draft; DO NOT APPLY REMOTELY without explicit owner authorization.
-- Mirrors existing assignments_select_if_member RLS: a direct team_members row.
-- Does not reinterpret a user-editable group name as membership.
-- The fingerprint blocks replacement if the audited live definition has drifted.
begin;
do $guard$
begin
  if pg_catalog.to_regprocedure('public.get_team_assignments(uuid)') is null
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.get_team_assignments(uuid)'::pg_catalog.regprocedure), pg_catalog.chr(13), ''))
       <> 'c278bc64bdcd0c88e849580c52d346e0' then
    raise exception 'get_team_assignments definition differs from audited snapshot';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_proc p
    join pg_catalog.pg_roles owner_role on owner_role.oid = p.proowner
    where p.oid = 'public.get_team_assignments(uuid)'::pg_catalog.regprocedure
      and owner_role.rolname = 'postgres'
      and (select count(*) from pg_catalog.aclexplode(p.proacl) a
        where a.privilege_type = 'EXECUTE' and a.grantor = p.proowner
          and not a.is_grantable
          and a.grantee in (0, 'postgres'::pg_catalog.regrole, 'anon'::pg_catalog.regrole,
                            'authenticated'::pg_catalog.regrole, 'service_role'::pg_catalog.regrole)) = 5
      and (select count(*) from pg_catalog.aclexplode(p.proacl)) = 5
  ) then
    raise exception 'get_team_assignments owner or grants differ from audited snapshot';
  end if;
end
$guard$;

create or replace function public.get_team_assignments(p_team_id uuid)
returns table(
  id uuid,
  title text,
  description text,
  link text,
  due text,
  due_at timestamptz,
  attachments jsonb,
  published boolean,
  status text,
  published_at timestamptz,
  votes integer,
  completed_by_me boolean,
  created_by uuid,
  created_at timestamptz,
  group_id uuid,
  subject_id uuid,
  subject_offering_id uuid,
  academic_year_id uuid,
  academic_term_id uuid,
  semester_number integer
)
language sql
security definer
set search_path = ''
as $function$
  select
    a.id,
    a.title,
    coalesce(a.description, a.body, '') as description,
    a.link,
    a.due_text as due,
    a.due_at,
    a.attachments,
    (a.published_at is not null or a.status = 'published') as published,
    a.status,
    a.published_at,
    (select count(*) from public.assignment_votes v where v.assignment_id = a.id and v.value = 1)::int as votes,
    exists (
      select 1 from public.assignment_done d
      where d.assignment_id = a.id and d.user_id = auth.uid()
    ) as completed_by_me,
    a.created_by,
    a.created_at,
    a.group_id,
    a.subject_id,
    a.subject_offering_id,
    a.academic_year_id,
    a.academic_term_id,
    a.semester_number
  from public.assignments a
  where a.team_id = p_team_id
    and auth.uid() is not null
    and exists (
      select 1 from public.team_members tm
      where tm.team_id = a.team_id and tm.user_id = auth.uid()
    )
  order by a.created_at asc;
$function$;

revoke execute on function public.get_team_assignments(uuid) from public, anon;
grant execute on function public.get_team_assignments(uuid) to authenticated, service_role;
do $guard$
begin
  if pg_catalog.has_function_privilege('anon', 'public.get_team_assignments(uuid)', 'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated', 'public.get_team_assignments(uuid)', 'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role', 'public.get_team_assignments(uuid)', 'EXECUTE') then
    raise exception 'unexpected get_team_assignments effective execution privileges';
  end if;
end
$guard$;
commit;
