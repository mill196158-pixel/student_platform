-- Stage 4.2.1B - assignment persistence fix
-- Scope: make assignment bubbles fully server-backed by returning assignment_id
-- from chat fetch RPC and returning both assignment/message ids from propose_assignment.
-- No table/RLS changes.

drop function if exists public.get_chat_messages_for_team(uuid, integer, timestamptz);

create or replace function public.get_chat_messages_for_team(
  p_team_id uuid,
  p_limit integer default 400,
  p_since timestamptz default '1970-01-01 00:00:00+00'::timestamptz
)
returns table(
  id uuid,
  chat_id uuid,
  author_id uuid,
  author_login text,
  author_name text,
  author_avatar_url text,
  text text,
  type text,
  msg_type text,
  at timestamptz,
  created_at timestamptz,
  reply_to_id uuid,
  assignment_id uuid,
  file_id uuid,
  attachments jsonb,
  reactions jsonb,
  user_reactions text[],
  is_pinned boolean
)
language sql
security definer
set search_path to 'public'
as $function$
with main_chat as (
  select id
  from public.chats
  where team_id = p_team_id and type = 'team_main'
  limit 1
)
select
  m.id,
  m.chat_id,
  m.author_id,
  u.login as author_login,
  trim(coalesce(u.name,'') || ' ' || coalesce(u.surname,'')) as author_name,
  u.avatar_url as author_avatar_url,
  coalesce(m.content, m.body, '') as text,
  coalesce(m.msg_type, m.type, 'text') as type,
  coalesce(m.msg_type, m.type, 'text') as msg_type,
  m.created_at as at,
  m.created_at,
  m.reply_to_id,
  m.assignment_id,
  m.file_id,
  coalesce(m.attachments, '[]'::jsonb) as attachments,
  (
    select coalesce(jsonb_object_agg(emoji, cnt), '{}'::jsonb)
    from (
      select emoji, count(*) as cnt
      from public.message_reactions mr
      where mr.message_id = m.id
      group by emoji
    ) t
  ) as reactions,
  (
    select array_agg(emoji)
    from public.message_reactions mr
    where mr.message_id = m.id and mr.user_id = auth.uid()
  ) as user_reactions,
  m.is_pinned
from public.messages m
join main_chat c on c.id = m.chat_id
left join public.users u on u.id = m.author_id
where m.created_at >= p_since
order by m.created_at asc
limit coalesce(p_limit, 400);
$function$;

drop function if exists public.propose_assignment(uuid, text, text, text, text, jsonb);

create or replace function public.propose_assignment(
  p_team_id uuid,
  p_title text,
  p_description text,
  p_link text default null::text,
  p_due text default null::text,
  p_attachments jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_assignment_id uuid;
  v_message_id uuid;
  v_chat uuid;
  v_user uuid := auth.uid();
  v_team public.teams%rowtype;
  v_is_trusted boolean := false;
  v_msg_type text := 'assignmentDraft';
  v_status text := 'draft';
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

  select id
  into v_chat
  from public.chats
  where team_id = p_team_id and type = 'team_main'
  limit 1;

  if v_chat is null then
    raise exception 'team_main_chat_not_found';
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
    v_status := 'published';
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
    v_status,
    case when v_is_trusted then now() else null end,
    v_team.group_id,
    v_team.subject_id,
    v_team.subject_offering_id,
    v_team.academic_year_id,
    v_team.academic_term_id,
    v_team.semester_number
  )
  returning id into v_assignment_id;

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
    v_assignment_id,
    now()
  )
  returning id into v_message_id;

  return jsonb_build_object(
    'assignment_id', v_assignment_id,
    'message_id', v_message_id,
    'msg_type', v_msg_type,
    'status', v_status,
    'published', v_is_trusted
  );
end;
$function$;

grant execute on function public.get_chat_messages_for_team(uuid, integer, timestamptz) to anon, authenticated, service_role;
grant execute on function public.propose_assignment(uuid, text, text, text, text, jsonb) to anon, authenticated, service_role;
