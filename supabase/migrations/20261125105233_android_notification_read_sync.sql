begin;

alter table public.device_push_tokens
  add column android_read_sync boolean not null default false;

-- A legacy registration, including a downgrade or a token transfer, must
-- revoke the previous client's capability even if its version string is equal.
create schema notification_sync_private;
create function notification_sync_private.reset_android_read_sync_registration()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.android_read_sync := false;
  return new;
end;
$$;
revoke all on function notification_sync_private.reset_android_read_sync_registration() from public, anon, authenticated;
create trigger reset_android_read_sync_registration
before update of user_id, installation_id, platform, app_version on public.device_push_tokens
for each row execute function notification_sync_private.reset_android_read_sync_registration();

create function notification_sync_private.register_android_push_token_v2(
  p_installation_id text, p_token text, p_platform text,
  p_app_version text, p_locale text, p_timezone text
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_platform is distinct from 'android' or auth.uid() is null then
    raise exception 'Android account required';
  end if;
  perform public.register_device_push_token(
    p_installation_id, p_token, p_platform, p_app_version, p_locale, p_timezone
  );
  update public.device_push_tokens
  set android_read_sync = true
  where user_id = auth.uid() and installation_id = trim(p_installation_id)
    and token = trim(p_token) and platform = 'android';
end;
$$;
revoke all on function notification_sync_private.register_android_push_token_v2(text,text,text,text,text,text)
  from public, anon, authenticated;
grant usage on schema notification_sync_private to authenticated;
grant execute on function notification_sync_private.register_android_push_token_v2(text,text,text,text,text,text)
  to authenticated;
create function public.register_android_push_token_v2(
  p_installation_id text, p_token text, p_platform text,
  p_app_version text, p_locale text, p_timezone text
) returns void language sql security invoker set search_path = '' as $$
  select notification_sync_private.register_android_push_token_v2($1,$2,$3,$4,$5,$6);
$$;
revoke all on function public.register_android_push_token_v2(text,text,text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.register_android_push_token_v2(text,text,text,text,text,text)
  to authenticated;

create index notification_outbox_visible_notification_idx
  on public.notification_outbox(app_notification_id,recipient_id)
  where app_notification_id is not null and event_type <> 'notification_read';

create function notification_sync_private.enqueue_android_notification_read()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.device_push_tokens d where d.user_id = new.recipient_id
      and d.android_read_sync and d.enabled and d.invalidated_at is null) then
    return new;
  end if;
  -- Serialize against the dispatcher's SKIP LOCKED claim. An unsent row will
  -- subsequently be filtered by read_at. An in-flight send needs a control.
  perform 1 from public.notification_outbox o
    where o.app_notification_id = new.id and o.recipient_id = new.recipient_id
      and o.event_type <> 'notification_read' for share;
  if exists (select 1 from public.notification_outbox o
      where o.app_notification_id = new.id and o.recipient_id = new.recipient_id
      and o.event_type <> 'notification_read' and o.attempts > 0
      and (o.status <> 'skipped' or exists (select 1 from public.push_delivery_attempts a
        where a.outbox_id = o.id and a.success))) then
    insert into public.notification_outbox
      (app_notification_id, recipient_id, event_type, idempotency_key)
    values (new.id, new.recipient_id, 'notification_read', 'android-read:' || new.id)
    on conflict (idempotency_key) do nothing;
  end if;
  return new;
end;
$$;
revoke all on function notification_sync_private.enqueue_android_notification_read() from public, anon, authenticated;
create trigger enqueue_android_notification_read
after update of read_at, deleted_at on public.app_notifications
for each row when (old.read_at is null and old.deleted_at is null
  and (new.read_at is not null or new.deleted_at is not null))
execute function notification_sync_private.enqueue_android_notification_read();

-- The prior dispatcher uses this RPC for visible alerts. It must never show
-- the control as a notification, including when application versions overlap.
create or replace function public.list_pending_device_push_tokens(p_outbox_id uuid, p_user_id uuid)
returns table(id uuid, token text, platform text, installation_id text)
language sql security definer set search_path = '' as $$
  select d.id,d.token,d.platform,d.installation_id
  from public.device_push_tokens d
  join public.notification_outbox o on o.id = p_outbox_id and o.recipient_id = d.user_id
  left join public.app_notifications n on n.id = o.app_notification_id
  where d.user_id = p_user_id and d.enabled and d.invalidated_at is null
    and o.event_type <> 'notification_read'
    and (o.app_notification_id is null or
      (n.recipient_id = d.user_id and n.read_at is null and n.deleted_at is null))
    and not exists (select 1 from public.push_delivery_attempts a
      where a.outbox_id = o.id and a.device_token_id = d.id and a.success);
$$;

create function public.list_pending_android_read_sync_tokens(p_outbox_id uuid, p_user_id uuid)
returns table(id uuid, token text, platform text, installation_id text)
language sql security invoker set search_path = '' as $$
  select d.id,d.token,d.platform,d.installation_id
  from public.notification_outbox o
  join public.app_notifications n on n.id = o.app_notification_id and n.recipient_id = o.recipient_id
  join public.device_push_tokens d on d.user_id = n.recipient_id
  where o.id = p_outbox_id and o.recipient_id = p_user_id and o.event_type = 'notification_read'
    and (n.read_at is not null or n.deleted_at is not null)
    and d.platform = 'android' and d.android_read_sync and d.enabled and d.invalidated_at is null
    and exists (select 1 from public.notification_outbox original
      where original.app_notification_id = n.id and original.recipient_id = n.recipient_id
        and original.event_type <> 'notification_read' and original.attempts > 0
        and (original.status in ('processing','pending','failed')
          or exists (select 1 from public.push_delivery_attempts first_attempt
            where first_attempt.outbox_id = original.id and first_attempt.device_token_id = d.id
              and first_attempt.success)))
    and not exists (select 1 from public.push_delivery_attempts a
      where a.outbox_id = o.id and a.device_token_id = d.id and a.success);
$$;
revoke all on function public.list_pending_android_read_sync_tokens(uuid,uuid) from public, anon, authenticated;
grant execute on function public.list_pending_android_read_sync_tokens(uuid,uuid) to service_role;

commit;
