-- Both original RPCs with the production binding trigger. Synthetic rows only.
begin;
set role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-1111-4111-8111-111111111111',false);
select public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','baseline direct','file',null,null,null,
  'cccccccc-1111-4111-8111-111111111111');
select public.send_chat_message_with_files('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','baseline files','file',
  array['cccccccc-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid]);
do $$ begin
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','foreign baseline','file',null,null,null,
      'cccccccc-2222-4222-8222-222222222222');
    raise exception 'foreign file bypassed trigger';
  exception when insufficient_privilege then null; end;
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','already linked baseline','file',null,null,null,
      'cccccccc-1111-4111-8111-111111111111');
    raise exception 'already-linked file bypassed trigger';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  if (select count(*) from public.messages where content in ('baseline direct','baseline files'))<>2
     or exists(select 1 from public.messages where content in ('foreign baseline','already linked baseline')) then
    raise exception 'baseline trigger compatibility differs';
  end if;
end $$;
rollback;
