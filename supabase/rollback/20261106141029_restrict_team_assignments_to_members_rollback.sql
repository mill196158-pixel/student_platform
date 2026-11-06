-- SECURITY WARNING: this restores the audited IDOR and anonymous EXECUTE.
-- Never apply to any shared database without explicit, informed owner approval.
-- Draft only; fingerprint prevents overwriting a changed function.
begin;
do $guard$
begin
  if pg_catalog.to_regprocedure('public.get_team_assignments(uuid)') is null
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.get_team_assignments(uuid)'::pg_catalog.regprocedure), pg_catalog.chr(13), ''))
       <> 'a73b8a9df330d6fdf767439f95901039' then
    raise exception 'patched get_team_assignments definition differs from expected snapshot';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_proc p
    join pg_catalog.pg_roles owner_role on owner_role.oid = p.proowner
    where p.oid = 'public.get_team_assignments(uuid)'::pg_catalog.regprocedure
      and owner_role.rolname = 'postgres'
      and (select count(*) from pg_catalog.aclexplode(p.proacl) a
        where a.privilege_type = 'EXECUTE' and a.grantor = p.proowner
          and not a.is_grantable
          and a.grantee in ('postgres'::pg_catalog.regrole,
                            'authenticated'::pg_catalog.regrole, 'service_role'::pg_catalog.regrole)) = 3
      and (select count(*) from pg_catalog.aclexplode(p.proacl)) = 3
  ) then
    raise exception 'patched get_team_assignments owner or grants differ from expected snapshot';
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
set search_path to 'public'
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
  order by a.created_at asc;
$function$;
grant execute on function public.get_team_assignments(uuid) to public, anon, authenticated, service_role;
commit;
