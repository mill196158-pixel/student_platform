-- Exact archived-message trigger behavior with synthetic archive data.
begin;
insert into public.chat_academic_archives(chat_id)
values('11111111-1111-4111-8111-111111111111');
set role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-1111-4111-8111-111111111111',false);
do $$ begin
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','archived text','text',null,null,null,null);
    raise exception 'archived text accepted';
  exception when raise_exception then
    if sqlerrm <> 'academic_chat_archived' then raise; end if;
  end;
  begin
    perform public.send_chat_message_with_files('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','archived files','file',
      array['cccccccc-5555-4555-8555-555555555555'::uuid]);
    raise exception 'archived file accepted';
  exception when raise_exception then
    if sqlerrm <> 'academic_chat_archived' then raise; end if;
  end;
end $$;
reset role;
do $$ begin
  if exists(select 1 from public.messages where content in ('archived text','archived files')) then
    raise exception 'archived send wrote message';
  end if;
end $$;
rollback;
