-- Run on the local QA database with psql -v qa_user=<local synthetic student UUID>.
\set ON_ERROR_STOP on
begin;
select set_config('qa.notification_user', :'qa_user', true);
do $$
declare
  owner_id uuid := current_setting('qa.notification_user')::uuid;
  install text := gen_random_uuid()::text;
  device_token text := 'test-only-' || gen_random_uuid();
  device uuid;
  notice uuid;
  original uuid;
  control uuid;
begin
  if not exists (select 1 from public.users where id=owner_id and login like 'e2e\_%' escape '\') then
    raise exception 'A synthetic local account is required';
  end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform public.register_android_push_token_v2(install,device_token,'android','test','ru','UTC');
  select id into strict device from public.device_push_tokens where token=device_token and android_read_sync;

  -- A bulk read of old inbox-only items and a still-pending display creates no control deliveries.
  insert into public.app_notifications(recipient_id,event_type,title,body,idempotency_key)
    select owner_id,'announcement','QA bulk','','qa-bulk-' || install || '-' || i
    from generate_series(1,105) i;
  notice := public._enqueue_app_notification(owner_id,'announcement','QA pending','','{}',null,install,true);
  update public.app_notifications set read_at=now()
    where id=notice or idempotency_key like 'qa-bulk-' || install || '-%';
  if exists (select 1 from public.notification_outbox o join public.app_notifications n on n.id=o.app_notification_id
      where o.event_type='notification_read' and (n.id=notice or n.idempotency_key like 'qa-bulk-' || install || '-%')) then
    raise exception 'Unsent notifications produced control traffic';
  end if;
  select id into strict original from public.notification_outbox where app_notification_id=notice;
  if exists (select 1 from public.list_pending_device_push_tokens(original,owner_id)) then
    raise exception 'A read item can still be delivered as visible';
  end if;

  notice := public._enqueue_app_notification(owner_id,'announcement','QA delivered','','{}',null,install || '-sent',true);
  select id into strict original from public.notification_outbox where app_notification_id=notice;
  update public.notification_outbox set status='sent',attempts=1 where id=original;
  insert into public.push_delivery_attempts(outbox_id,device_token_id,success) values(original,device,true);
  perform public.mark_notification_read(notice);
  perform public.mark_notification_read(notice);
  perform public.hide_notification_for_me(notice);
  select id into strict control from public.notification_outbox where app_notification_id=notice and event_type='notification_read';
  if (select count(*) from public.list_pending_android_read_sync_tokens(control,owner_id)) <> 1
    or not exists (select 1 from public.list_pending_android_read_sync_tokens(control,owner_id) where id=device)
    or exists (select 1 from public.list_pending_android_read_sync_tokens(control,gen_random_uuid()))
    or exists (select 1 from public.list_pending_device_push_tokens(control,owner_id)) then
    raise exception 'Recipient/device routing or compatibility with earlier dispatchers failed';
  end if;
  insert into public.push_delivery_attempts(outbox_id,device_token_id,success) values(control,device,true);
  if exists (select 1 from public.list_pending_android_read_sync_tokens(control,owner_id)) then
    raise exception 'Successful read controls must not be resent';
  end if;
  perform public.register_device_push_token(install,device_token,'android','test','ru','UTC');
  if exists (select 1 from public.device_push_tokens where id=device and android_read_sync) then
    raise exception 'A legacy registration retained control capability';
  end if;
  if has_function_privilege('authenticated','public.list_pending_android_read_sync_tokens(uuid,uuid)','execute')
    or has_function_privilege('anon','public.register_android_push_token_v2(text,text,text,text,text,text)','execute') then
    raise exception 'Unexpected API grants';
  end if;
end $$;
rollback;
