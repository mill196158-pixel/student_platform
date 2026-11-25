-- Completion receipts can consist only of the two keys. A stored false
-- flag on older schemas explicitly means the assignment is still open.
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
        and (pg_catalog.to_jsonb(d) -> 'done') is distinct from 'false'::jsonb
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
