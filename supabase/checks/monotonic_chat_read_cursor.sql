-- Local regression with two disposable students. Invoke psql with
-- -v qa_user=<recipient UUID> -v qa_peer=<sender UUID>. All writes roll back.
\set ON_ERROR_STOP on
begin;
select set_config('qa.cursor_test_user', :'qa_user', true),
       set_config('qa.cursor_test_peer', :'qa_peer', true);
do $check$
declare
  student uuid := current_setting('qa.cursor_test_user')::uuid;
  peer uuid := current_setting('qa.cursor_test_peer')::uuid;
  chat uuid := gen_random_uuid();
  first_message uuid := gen_random_uuid();
  tie_a uuid := gen_random_uuid();
  tie_b uuid := gen_random_uuid();
  newest uuid := greatest(tie_a, tie_b);
  base_time timestamptz := now() - interval '1 minute';
  row_state public.chat_reads;
  other_chat uuid := gen_random_uuid();
  other_message uuid := gen_random_uuid();
  group_team uuid := gen_random_uuid();
  qa_group text := 'e2e_' || gen_random_uuid();
  year_id uuid := gen_random_uuid();
  term_id uuid := gen_random_uuid();
begin
  if student = peer or
     (select count(*) from public.users where id in (student, peer) and starts_with(login, 'e2e_')) <> 2 then
    raise exception 'Provide two disposable local students';
  end if;
  insert into public.chats(id, type) values (chat, 'dm');
  insert into public.chat_members(chat_id, user_id) values (chat, student), (chat, peer);
  insert into public.messages(id, chat_id, author_id, body, msg_type, created_at)
  values (first_message, chat, peer, 'older cursor fixture', 'system', base_time),
         (tie_a, chat, peer, 'tied cursor A', 'system', base_time + interval '1 second'),
         (tie_b, chat, peer, 'tied cursor B', 'system', base_time + interval '1 second');
  perform set_config('request.jwt.claim.sub', student::text, true);

  perform public.mark_chat_read(chat, newest);
  perform public.mark_chat_read(chat, first_message);
  perform public.mark_chat_read(chat, least(tie_a, tie_b));
  perform public.mark_chat_read(chat, newest);
  select * into strict row_state from public.chat_reads where chat_id = chat and user_id = student;
  if row_state.last_read_at <> base_time + interval '1 second'
     or row_state.last_read_message_id is distinct from newest then
    raise exception 'Delayed, duplicate or tied receipt moved the cursor backwards';
  end if;

  perform public.mark_chat_read(chat, null);
  perform public.mark_chat_read(chat, first_message);
  select * into strict row_state from public.chat_reads where chat_id = chat and user_id = student;
  if row_state.last_read_at <> now() or row_state.last_read_message_id is distinct from newest then
    raise exception 'A delayed receipt crossed the mark-through-now barrier';
  end if;

  insert into public.teams(id,name,group_name) values(group_team,'QA cursor group',qa_group);
  insert into public.chats(id,type,team_id) values(other_chat,'team_main',group_team)
  on conflict do nothing;
  select id into strict other_chat from public.chats where type='team_main' and team_id=group_team;
  perform set_config('request.jwt.claim.sub', peer::text, true);
  insert into public.messages(id,chat_id,author_id,msg_type,body)
  values(other_message,other_chat,peer,'system','other conversation');
  perform set_config('request.jwt.claim.sub', student::text, true);
  begin
    perform public.mark_chat_read(other_chat,other_message);
    raise exception 'Nonmember marked this conversation';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.mark_chat_read(chat,other_message);
    raise exception 'Message from a different chat advanced this conversation';
  exception when no_data_found then null;
  end;
  begin
    perform public.mark_chat_read(chat,gen_random_uuid());
    raise exception 'Missing message advanced this conversation';
  exception when no_data_found then null;
  end;
  if (select to_jsonb(cr) from public.chat_reads cr where chat_id=chat and user_id=student) <> to_jsonb(row_state)
      or exists(select 1 from public.chat_reads where chat_id=other_chat and user_id=student) then
    raise exception 'Rejected request changed a receipt';
  end if;

  update public.users set group_name=qa_group where id=student;
  insert into public.academic_years(id,name,start_year,starts_on,ends_on)
  values(year_id,'cursor '||year_id,2300,'2300-01-01','2300-12-31');
  insert into public.academic_terms(id,academic_year_id,term_in_year,term_sequence,name,starts_on,ends_on)
  values(term_id,year_id,1,(select coalesce(max(term_sequence),0)+1 from public.academic_terms),
         'cursor term','2300-01-01','2300-06-30');
  insert into public.chat_academic_archives(chat_id,academic_term_id,available_until)
  values(other_chat,term_id,now()+interval '1 day');
  perform public.mark_chat_read(other_chat,other_message);
  select * into strict row_state from public.chat_reads where chat_id=other_chat and user_id=student;
  update public.chat_academic_archives set expired_at=now() where chat_id=other_chat;
  begin
    perform public.mark_chat_read(other_chat,null);
    raise exception 'Expired archive accepted a new read';
  exception when insufficient_privilege then null;
  end;
  if (select to_jsonb(cr) from public.chat_reads cr where chat_id=other_chat and user_id=student) <> to_jsonb(row_state) then
    raise exception 'Expired archive changed an existing receipt';
  end if;
end
$check$;
rollback;
