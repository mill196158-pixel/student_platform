-- Rollback for Stage 4.2.1 assignment model hardening.
-- Restores the pre-hardening assignment RPC behavior captured during Stage 4.2 audit.

drop function if exists public.get_team_assignments(uuid);

create or replace function public.get_team_assignments(p_team_id uuid)
returns table(
  id uuid,
  title text,
  description text,
  link text,
  due text,
  attachments jsonb,
  published boolean,
  votes integer,
  completed_by_me boolean,
  created_by uuid,
  created_at timestamptz
)
language sql
security definer
set search_path to 'public'
as $function$
  select
    a.id,
    a.title,
    a.description,
    a.link,
    a.due_text as due,
    a.attachments,
    (a.published_at is not null) as published,
    (select count(*) from public.assignment_votes v where v.assignment_id = a.id)::int as votes,
    exists (
      select 1 from public.assignment_done d
      where d.assignment_id = a.id and d.user_id = auth.uid()
    ) as completed_by_me,
    a.created_by,
    a.created_at
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
begin
  insert into public.assignments(team_id, title, description, link, due_text, attachments, created_by)
  values (p_team_id, p_title, p_description, nullif(p_link,''), nullif(p_due,''), coalesce(p_attachments,'[]'::jsonb), auth.uid())
  returning id into v_id;

  select id into v_chat
  from public.chats
  where team_id = p_team_id and type = 'team_main'
  limit 1;

  insert into public.messages(
    chat_id, author_id,
    content, body,
    type, msg_type,
    assignment_id, created_at
  )
  values (
    v_chat, auth.uid(),
    'Черновик задания: '||p_title, 'Черновик задания: '||p_title,
    'assignmentDraft', 'assignmentDraft',
    v_id, now()
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
  select team_id into v_team from public.assignments where id = p_assignment_id;

  select exists(
    select 1 from public.team_members tm
    where tm.team_id = v_team and tm.user_id = auth.uid() and tm.role in ('starosta','teacher','admin','owner')
  ) into v_allowed;

  if not v_allowed then
    raise exception 'forbidden';
  end if;

  update public.assignments set published_at = now() where id = p_assignment_id;

  update public.messages
     set type = 'assignmentPublished',
         msg_type = 'assignmentPublished'
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
  v_votes int;
begin
  insert into public.assignment_votes(assignment_id, user_id)
  values (p_assignment_id, v_user)
  on conflict do nothing;

  select count(*) into v_votes
  from public.assignment_votes
  where assignment_id = p_assignment_id;

  if v_votes >= 2 then
    update public.assignments
    set published_at = now()
    where id = p_assignment_id
    and published_at is null;
  end if;

  return json_build_object(
    'votes', v_votes,
    'published', (select published_at is not null from public.assignments where id = p_assignment_id)
  );
end;
$function$;

grant execute on function public.get_team_assignments(uuid) to anon, authenticated, service_role;
grant execute on function public.propose_assignment(uuid, text, text, text, text, jsonb) to anon, authenticated, service_role;
grant execute on function public.publish_assignment(uuid) to anon, authenticated, service_role;
grant execute on function public.vote_assignment(uuid) to anon, authenticated, service_role;
