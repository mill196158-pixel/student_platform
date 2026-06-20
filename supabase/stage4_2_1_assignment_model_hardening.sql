-- Stage 4.2.1 - assignment model hardening
-- Scope: RPC-only hardening for assignment academic linkage, chat bubble contract,
-- trusted publishing, and voting threshold. No RLS/table changes.

drop function if exists public.get_team_assignments(uuid);

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

create or replace function public.propose_assignment(
  p_team_id uuid,
  p_title text,
  p_description text,
  p_link text default null::text,
  p_due text default null::text,
  p_attachments jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id uuid;
  v_chat uuid;
  v_user uuid := auth.uid();
  v_team public.teams%rowtype;
  v_is_trusted boolean := false;
  v_msg_type text := 'assignmentDraft';
begin
  if v_user is null then
    raise exception 'not_authenticated';
  end if;

  select *
  into v_team
  from public.teams
  where id = p_team_id;

  if not found then
    raise exception 'team_not_found';
  end if;

  select exists(
    select 1
    from public.team_members tm
    where tm.team_id = p_team_id
      and tm.user_id = v_user
      and tm.role in ('starosta', 'teacher', 'admin', 'owner')
  )
  into v_is_trusted;

  if v_is_trusted then
    v_msg_type := 'assignmentPublished';
  end if;

  insert into public.assignments(
    team_id,
    author_id,
    created_by,
    title,
    body,
    description,
    link,
    due_text,
    attachments,
    status,
    published_at,
    group_id,
    subject_id,
    subject_offering_id,
    academic_year_id,
    academic_term_id,
    semester_number
  )
  values (
    p_team_id,
    v_user,
    v_user,
    p_title,
    coalesce(p_description, ''),
    p_description,
    nullif(p_link, ''),
    nullif(p_due, ''),
    coalesce(p_attachments, '[]'::jsonb),
    case when v_is_trusted then 'published' else 'draft' end,
    case when v_is_trusted then now() else null end,
    v_team.group_id,
    v_team.subject_id,
    v_team.subject_offering_id,
    v_team.academic_year_id,
    v_team.academic_term_id,
    v_team.semester_number
  )
  returning id into v_id;

  select id into v_chat
  from public.chats
  where team_id = p_team_id and type = 'team_main'
  limit 1;

  insert into public.messages(
    chat_id,
    author_id,
    content,
    body,
    type,
    msg_type,
    assignment_id,
    created_at
  )
  values (
    v_chat,
    v_user,
    case when v_is_trusted then 'Новое задание: ' || p_title else 'Черновик задания: ' || p_title end,
    case when v_is_trusted then 'Новое задание: ' || p_title else 'Черновик задания: ' || p_title end,
    v_msg_type,
    v_msg_type,
    v_id,
    now()
  )
  on conflict (assignment_id) do nothing;

  return v_id;
end;
$function$;

create or replace function public.publish_assignment(p_assignment_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_team uuid;
  v_allowed boolean;
begin
  select team_id into v_team
  from public.assignments
  where id = p_assignment_id;

  select exists(
    select 1 from public.team_members tm
    where tm.team_id = v_team
      and tm.user_id = auth.uid()
      and tm.role in ('starosta','teacher','admin','owner')
  ) into v_allowed;

  if not v_allowed then
    raise exception 'forbidden';
  end if;

  update public.assignments
  set
    status = 'published',
    published_at = coalesce(published_at, now())
  where id = p_assignment_id;

  update public.messages
     set type = 'assignmentPublished',
         msg_type = 'assignmentPublished',
         content = regexp_replace(coalesce(content, ''), '^Черновик задания:', 'Новое задание:'),
         body = regexp_replace(coalesce(body, ''), '^Черновик задания:', 'Новое задание:')
   where assignment_id = p_assignment_id
     and coalesce(type, msg_type) = 'assignmentDraft';
end;
$function$;

create or replace function public.vote_assignment(p_assignment_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user uuid := auth.uid();
  v_team uuid;
  v_votes int;
  v_published boolean;
begin
  if v_user is null then
    raise exception 'not_authenticated';
  end if;

  select team_id into v_team
  from public.assignments
  where id = p_assignment_id;

  if v_team is null then
    raise exception 'assignment_not_found';
  end if;

  if not exists (
    select 1
    from public.team_members tm
    where tm.team_id = v_team
      and tm.user_id = v_user
  ) then
    raise exception 'forbidden';
  end if;

  insert into public.assignment_votes(assignment_id, user_id, value)
  values (p_assignment_id, v_user, 1)
  on conflict (assignment_id, user_id)
  do update set value = 1;

  select count(*) into v_votes
  from public.assignment_votes
  where assignment_id = p_assignment_id
    and value = 1;

  if v_votes >= 2 then
    update public.assignments
    set
      status = 'published',
      published_at = coalesce(published_at, now())
    where id = p_assignment_id
      and published_at is null;

    update public.messages
       set type = 'assignmentPublished',
           msg_type = 'assignmentPublished',
           content = regexp_replace(coalesce(content, ''), '^Черновик задания:', 'Новое задание:'),
           body = regexp_replace(coalesce(body, ''), '^Черновик задания:', 'Новое задание:')
     where assignment_id = p_assignment_id
       and coalesce(type, msg_type) = 'assignmentDraft';
  end if;

  select (published_at is not null or status = 'published')
  into v_published
  from public.assignments
  where id = p_assignment_id;

  return json_build_object(
    'votes', v_votes,
    'published', coalesce(v_published, false)
  );
end;
$function$;

grant execute on function public.get_team_assignments(uuid) to anon, authenticated, service_role;
grant execute on function public.propose_assignment(uuid, text, text, text, text, jsonb) to anon, authenticated, service_role;
grant execute on function public.publish_assignment(uuid) to anon, authenticated, service_role;
grant execute on function public.vote_assignment(uuid) to anon, authenticated, service_role;
