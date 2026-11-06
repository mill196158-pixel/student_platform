-- Synthetic test identities; no external database or production rows.
do $$ begin
  if has_function_privilege('anon','public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid)','EXECUTE')
     or has_function_privilege('anon','public.send_chat_message_with_files(uuid,text,text,uuid[])','EXECUTE') then
    raise exception 'anonymous EXECUTE remained';
  end if;
  if not has_function_privilege('authenticated','public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.send_chat_message_with_files(uuid,text,text,uuid[])','EXECUTE')
     or not has_function_privilege('service_role','public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid)','EXECUTE') then
    raise exception 'required role lost EXECUTE';
  end if;
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub','bbbbbbbb-1111-4111-8111-111111111111',false);
-- TEMP exists for authenticated in production; forged shadow tables must not
-- satisfy membership or receive function writes.
create temporary table team_members(team_id uuid,user_id uuid);
insert into pg_temp.team_members values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-1111-4111-8111-111111111111');
create temporary table chats(id uuid,team_id uuid,type text);
insert into pg_temp.chats values
  ('99999999-9999-4999-8999-999999999999','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','team_main');
do $$ begin
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','blocked','text',null,null,null,null);
    raise exception 'nonmember text accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.send_chat_message_with_files('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','blocked','file',
      array['cccccccc-1111-4111-8111-111111111111'::uuid]);
    raise exception 'nonmember file accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  if exists(select 1 from public.messages) or
     exists(select 1 from public.chat_files where message_id is not null) then
    raise exception 'nonmember caused a write';
  end if;
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-1111-4111-8111-111111111111',false);
-- This is denied by the existing production file-binding trigger, not the new
-- membership candidate. INSERT must roll back with the rejected binding.
do $$ begin
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','foreign file','file',null,null,null,
      'cccccccc-2222-4222-8222-222222222222');
    raise exception 'foreign file accepted';
  exception when insufficient_privilege then null; end;
end $$;
select public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','member direct file','file',null,null,null,
  'cccccccc-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
select public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','member text','text',null,null,null,null);
select public.send_chat_message_with_files('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','member file','file',
  array['cccccccc-1111-4111-8111-111111111111'::uuid]);
do $$ begin
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','already linked','file',null,null,null,
      'cccccccc-1111-4111-8111-111111111111');
    raise exception 'already linked file accepted';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','aaaaaaaa-2222-4222-8222-222222222222',false);
select public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','starosta','text',null,null,null,null);
select set_config('request.jwt.claim.sub','aaaaaaaa-3333-4333-8333-333333333333',false);
select public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','teacher with membership','text',null,null,null,null);
select set_config('request.jwt.claim.sub','bbbbbbbb-3333-4333-8333-333333333333',false);
do $$ begin
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','teacher without membership','text',null,null,null,null);
    raise exception 'teacher without membership accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  if (select count(*) from public.messages) <> 5 then raise exception 'member send failed'; end if;
  if not exists(select 1 from public.chat_files where id='cccccccc-1111-4111-8111-111111111111' and message_id is not null)
  then raise exception 'member attachment failed'; end if;
end $$;

set role service_role;
select set_config('request.jwt.claim.sub','aaaaaaaa-1111-4111-8111-111111111111',false);
select public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','service with uid','text',null,null,null,null);
select set_config('request.jwt.claim.sub','',false);
do $$ begin
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','no uid','text',null,null,null,null);
    raise exception 'service with no uid accepted';
  exception when raise_exception then
    if sqlerrm = 'service with no uid accepted' then raise; end if;
  end;
  begin
    perform public.send_chat_message_with_files('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','no uid','text',array[]::uuid[]);
    raise exception 'service file send with no uid accepted';
  exception when raise_exception then
    if sqlerrm = 'service file send with no uid accepted' then raise; end if;
  end;
end $$;
reset role;
