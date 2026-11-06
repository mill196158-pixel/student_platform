-- Reproduces production trigger behavior on synthetic rows; rolled back.
begin;
set role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-1111-4111-8111-111111111111',false);
do $$
declare target uuid;
begin
  foreach target in array array[
    'cccccccc-2222-4222-8222-222222222222'::uuid,
    'cccccccc-3333-4333-8333-333333333333'::uuid,
    'cccccccc-4444-4444-8444-444444444444'::uuid,
    'cccccccc-7777-4777-8777-777777777777'::uuid,
    'cccccccc-8888-4888-8888-888888888888'::uuid
  ] loop
    begin
      perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','blocked by trigger','file',null,null,null,target);
      raise exception 'invalid file bypassed existing trigger';
    exception when insufficient_privilege then null; end;
  end loop;
end $$;
select public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','first binding','file',null,null,null,
  'cccccccc-5555-4555-8555-555555555555');
do $$ begin
  begin
    perform public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','duplicate binding','file',null,null,null,
      'cccccccc-5555-4555-8555-555555555555');
    raise exception 'duplicate binding bypassed existing trigger';
  exception when insufficient_privilege then null; end;
end $$;
-- Existing bug: an unknown file creates a message without a file.
select public.send_chat_message('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','missing file baseline','file',null,null,null,
  'cccccccc-9999-4999-8999-999999999999');
-- Existing bug: another uploader's selected file is silently omitted.
select public.send_chat_message_with_files('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','partial baseline','file',
  array['cccccccc-6666-4666-8666-666666666666'::uuid,'cccccccc-2222-4222-8222-222222222222'::uuid]);
reset role;
do $$ begin
  if exists(select 1 from public.messages where content in ('blocked by trigger','duplicate binding')) then
    raise exception 'trigger failure did not roll back message';
  end if;
  if not exists(select 1 from public.messages m where m.content='missing file baseline'
      and not exists(select 1 from public.chat_files f where f.message_id=m.id)) then
    raise exception 'missing file baseline behavior changed';
  end if;
  if not exists(select 1 from public.messages m where m.content='partial baseline'
      and jsonb_array_length(m.attachments)=1) then
    raise exception 'partial file baseline behavior changed';
  end if;
end $$;
rollback;
