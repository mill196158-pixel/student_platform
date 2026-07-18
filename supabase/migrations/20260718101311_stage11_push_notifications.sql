-- Stage 11: push tokens, preferences, in-app notifications, outbox.
-- No HTTP / secrets / service_role keys in this migration.
-- Database Webhook → Edge Function is a manual post-deploy step.

-- ---------------------------------------------------------------------------
-- 1. device_push_tokens (no client SELECT / direct writes)
-- ---------------------------------------------------------------------------

create table if not exists public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  installation_id text not null,
  token text not null,
  platform text not null check (platform in ('android', 'ios')),
  app_version text,
  locale text,
  timezone text,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  invalidated_at timestamptz,
  constraint device_push_tokens_token_unique unique (token),
  constraint device_push_tokens_user_installation_unique unique (user_id, installation_id)
);

create index if not exists device_push_tokens_user_enabled_idx
  on public.device_push_tokens (user_id)
  where enabled = true and invalidated_at is null;

comment on table public.device_push_tokens is
  'FCM device tokens. Writes only via SECURITY DEFINER RPCs. Not selectable by clients.';

alter table public.device_push_tokens enable row level security;
alter table public.device_push_tokens force row level security;

revoke all on table public.device_push_tokens from public;
revoke all on table public.device_push_tokens from anon;
revoke all on table public.device_push_tokens from authenticated;

-- ---------------------------------------------------------------------------
-- 2. notification_preferences (one row per user)
-- ---------------------------------------------------------------------------

create table if not exists public.notification_preferences (
  user_id uuid primary key references public.users (id) on delete cascade,
  dm_messages boolean not null default true,
  friend_requests boolean not null default true,
  friend_accepts boolean not null default true,
  study_assignments boolean not null default true,
  schedule_changes boolean not null default true,
  study_announcements boolean not null default true,
  group_replies boolean not null default true,
  group_mentions boolean not null default true,
  group_all_messages boolean not null default false,
  show_message_preview boolean not null default true,
  push_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

comment on table public.notification_preferences is
  'Per-user notification preferences. Missing row means defaults (all true except group_all_messages).';

alter table public.notification_preferences enable row level security;
alter table public.notification_preferences force row level security;

revoke all on table public.notification_preferences from public;
revoke all on table public.notification_preferences from anon;
revoke all on table public.notification_preferences from authenticated;

grant select, insert, update on table public.notification_preferences to authenticated;

drop policy if exists notification_preferences_select_own on public.notification_preferences;
create policy notification_preferences_select_own
  on public.notification_preferences
  for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists notification_preferences_insert_own on public.notification_preferences;
create policy notification_preferences_insert_own
  on public.notification_preferences
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists notification_preferences_update_own on public.notification_preferences;
create policy notification_preferences_update_own
  on public.notification_preferences
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 3. app_notifications (in-app center)
-- ---------------------------------------------------------------------------

create table if not exists public.app_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.users (id) on delete cascade,
  event_type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  source_id text,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  deleted_at timestamptz,
  constraint app_notifications_idempotency_key_unique unique (idempotency_key)
);

create index if not exists app_notifications_recipient_created_idx
  on public.app_notifications (recipient_id, created_at desc)
  where deleted_at is null;

create index if not exists app_notifications_recipient_unread_idx
  on public.app_notifications (recipient_id)
  where deleted_at is null and read_at is null;

comment on table public.app_notifications is
  'In-app notification center rows. Created only by trusted triggers/helpers.';

alter table public.app_notifications enable row level security;
alter table public.app_notifications force row level security;

revoke all on table public.app_notifications from public;
revoke all on table public.app_notifications from anon;
revoke all on table public.app_notifications from authenticated;

grant select on table public.app_notifications to authenticated;

drop policy if exists app_notifications_select_own on public.app_notifications;
create policy app_notifications_select_own
  on public.app_notifications
  for select
  to authenticated
  using (
    recipient_id = (select auth.uid())
    and deleted_at is null
  );

-- ---------------------------------------------------------------------------
-- 4. notification_outbox + push_delivery_attempts (server-only)
-- ---------------------------------------------------------------------------

create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  app_notification_id uuid references public.app_notifications (id) on delete set null,
  recipient_id uuid not null references public.users (id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text not null,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  processing_started_at timestamptz,
  last_error text,
  constraint notification_outbox_idempotency_key_unique unique (idempotency_key)
);

create index if not exists notification_outbox_pending_idx
  on public.notification_outbox (available_at, created_at)
  where status = 'pending';

create index if not exists notification_outbox_processing_started_idx
  on public.notification_outbox (processing_started_at)
  where status = 'processing';

comment on table public.notification_outbox is
  'Push delivery outbox. No client access. Processed by Edge Function.';

alter table public.notification_outbox enable row level security;
alter table public.notification_outbox force row level security;

revoke all on table public.notification_outbox from public;
revoke all on table public.notification_outbox from anon;
revoke all on table public.notification_outbox from authenticated;

create table if not exists public.push_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  outbox_id uuid not null references public.notification_outbox (id) on delete cascade,
  device_token_id uuid references public.device_push_tokens (id) on delete set null,
  provider text not null default 'fcm_http_v1',
  success boolean not null default false,
  http_status integer,
  error_code text,
  error_message text,
  created_at timestamptz not null default now()
);

create index if not exists push_delivery_attempts_outbox_idx
  on public.push_delivery_attempts (outbox_id, created_at desc);

comment on table public.push_delivery_attempts is
  'Per-device FCM delivery log. Server-only.';

alter table public.push_delivery_attempts enable row level security;
alter table public.push_delivery_attempts force row level security;

revoke all on table public.push_delivery_attempts from public;
revoke all on table public.push_delivery_attempts from anon;
revoke all on table public.push_delivery_attempts from authenticated;

-- ---------------------------------------------------------------------------
-- 5. Helpers
-- ---------------------------------------------------------------------------

create or replace function public._notification_prefs_or_defaults(p_user_id uuid)
returns public.notification_preferences
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_row public.notification_preferences;
begin
  select * into v_row
  from public.notification_preferences np
  where np.user_id = p_user_id;

  if found then
    return v_row;
  end if;

  v_row.user_id := p_user_id;
  v_row.dm_messages := true;
  v_row.friend_requests := true;
  v_row.friend_accepts := true;
  v_row.study_assignments := true;
  v_row.schedule_changes := true;
  v_row.study_announcements := true;
  v_row.group_replies := true;
  v_row.group_mentions := true;
  v_row.group_all_messages := false;
  v_row.show_message_preview := true;
  v_row.push_enabled := true;
  v_row.updated_at := now();
  return v_row;
end;
$function$;

revoke all on function public._notification_prefs_or_defaults(uuid) from public;
revoke all on function public._notification_prefs_or_defaults(uuid) from anon;
revoke all on function public._notification_prefs_or_defaults(uuid) from authenticated;

create or replace function public._users_blocked_either(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.user_blocks ub
    where (ub.blocker_id = p_a and ub.blocked_id = p_b)
       or (ub.blocker_id = p_b and ub.blocked_id = p_a)
  );
$function$;

revoke all on function public._users_blocked_either(uuid, uuid) from public;
revoke all on function public._users_blocked_either(uuid, uuid) from anon;
revoke all on function public._users_blocked_either(uuid, uuid) from authenticated;

create or replace function public._chat_is_muted_for(p_user_id uuid, p_chat_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    (
      select cus.is_muted
      from public.chat_user_settings cus
      where cus.user_id = p_user_id
        and cus.chat_id = p_chat_id
    ),
    false
  );
$function$;

revoke all on function public._chat_is_muted_for(uuid, uuid) from public;
revoke all on function public._chat_is_muted_for(uuid, uuid) from anon;
revoke all on function public._chat_is_muted_for(uuid, uuid) from authenticated;

create or replace function public._chat_is_academically_archived(p_chat_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.chat_academic_archives caa
    where caa.chat_id = p_chat_id
  );
$function$;

revoke all on function public._chat_is_academically_archived(uuid) from public;
revoke all on function public._chat_is_academically_archived(uuid) from anon;
revoke all on function public._chat_is_academically_archived(uuid) from authenticated;

create or replace function public._display_name(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $function$
  select nullif(
    trim(concat_ws(' ', nullif(u.name, ''), nullif(u.surname, ''))),
    ''
  )
  from public.users u
  where u.id = p_user_id;
$function$;

revoke all on function public._display_name(uuid) from public;
revoke all on function public._display_name(uuid) from anon;
revoke all on function public._display_name(uuid) from authenticated;

-- Same access model as get_my_chat_summaries: team_members ∪ same group_name.
create or replace function public._team_accessible_user_ids(p_team_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $function$
  select tm.user_id
  from public.team_members tm
  where tm.team_id = p_team_id
  union
  select u.id
  from public.teams t
  join public.users u
    on u.group_name is not null
   and t.group_name is not null
   and u.group_name = t.group_name
  where t.id = p_team_id;
$function$;

revoke all on function public._team_accessible_user_ids(uuid) from public;
revoke all on function public._team_accessible_user_ids(uuid) from anon;
revoke all on function public._team_accessible_user_ids(uuid) from authenticated;

create or replace function public._enqueue_app_notification(
  p_recipient_id uuid,
  p_event_type text,
  p_title text,
  p_body text,
  p_data jsonb,
  p_source_id text,
  p_idempotency_key text,
  p_queue_push boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_notification_id uuid;
  v_prefs public.notification_preferences;
  v_should_push boolean;
begin
  if p_recipient_id is null or p_idempotency_key is null then
    return null;
  end if;

  insert into public.app_notifications (
    recipient_id,
    event_type,
    title,
    body,
    data,
    source_id,
    idempotency_key
  ) values (
    p_recipient_id,
    p_event_type,
    p_title,
    p_body,
    coalesce(p_data, '{}'::jsonb),
    p_source_id,
    p_idempotency_key
  )
  on conflict (idempotency_key) do nothing
  returning id into v_notification_id;

  if v_notification_id is null then
    select an.id into v_notification_id
    from public.app_notifications an
    where an.idempotency_key = p_idempotency_key;
    return v_notification_id;
  end if;

  v_prefs := public._notification_prefs_or_defaults(p_recipient_id);
  v_should_push := coalesce(p_queue_push, true) and coalesce(v_prefs.push_enabled, true);

  insert into public.notification_outbox (
    app_notification_id,
    recipient_id,
    event_type,
    payload,
    idempotency_key,
    status
  ) values (
    v_notification_id,
    p_recipient_id,
    p_event_type,
    jsonb_build_object(
      'version', 1,
      'type', p_event_type,
      'notification_id', v_notification_id,
      'title', p_title,
      'body', p_body,
      'data', coalesce(p_data, '{}'::jsonb)
    ),
    p_idempotency_key || ':push',
    case when v_should_push then 'pending' else 'skipped' end
  )
  on conflict (idempotency_key) do nothing;

  return v_notification_id;
end;
$function$;

revoke all on function public._enqueue_app_notification(uuid, text, text, text, jsonb, text, text, boolean) from public;
revoke all on function public._enqueue_app_notification(uuid, text, text, text, jsonb, text, text, boolean) from anon;
revoke all on function public._enqueue_app_notification(uuid, text, text, text, jsonb, text, text, boolean) from authenticated;

-- ---------------------------------------------------------------------------
-- 6. Token RPCs
-- ---------------------------------------------------------------------------

create or replace function public.register_device_push_token(
  p_installation_id text,
  p_token text,
  p_platform text,
  p_app_version text default null,
  p_locale text default null,
  p_timezone text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
  v_installation_id text;
  v_token text;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  if p_installation_id is null or length(trim(p_installation_id)) = 0 then
    raise exception using errcode = 'P0001', message = 'invalid_installation_id';
  end if;

  if p_token is null or length(trim(p_token)) = 0 then
    raise exception using errcode = 'P0001', message = 'invalid_token';
  end if;

  if p_platform not in ('android', 'ios') then
    raise exception using errcode = 'P0001', message = 'invalid_platform';
  end if;

  v_installation_id := trim(p_installation_id);
  v_token := trim(p_token);

  -- Free (user_id, installation_id) if this install previously held another token.
  delete from public.device_push_tokens dpt
  where dpt.user_id = v_me
    and dpt.installation_id = v_installation_id
    and dpt.token is distinct from v_token;

  -- Atomic transfer/upsert by unique token.
  insert into public.device_push_tokens (
    user_id,
    installation_id,
    token,
    platform,
    app_version,
    locale,
    timezone,
    enabled,
    last_seen_at,
    invalidated_at,
    updated_at
  ) values (
    v_me,
    v_installation_id,
    v_token,
    p_platform,
    nullif(trim(coalesce(p_app_version, '')), ''),
    nullif(trim(coalesce(p_locale, '')), ''),
    nullif(trim(coalesce(p_timezone, '')), ''),
    true,
    now(),
    null,
    now()
  )
  on conflict (token) do update
  set
    user_id = excluded.user_id,
    installation_id = excluded.installation_id,
    platform = excluded.platform,
    app_version = excluded.app_version,
    locale = excluded.locale,
    timezone = excluded.timezone,
    enabled = true,
    invalidated_at = null,
    last_seen_at = now(),
    updated_at = now();
end;
$function$;

revoke all on function public.register_device_push_token(text, text, text, text, text, text) from public;
revoke all on function public.register_device_push_token(text, text, text, text, text, text) from anon;
grant execute on function public.register_device_push_token(text, text, text, text, text, text) to authenticated;

create or replace function public.disable_device_push_token(p_installation_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  if p_installation_id is null or length(trim(p_installation_id)) = 0 then
    raise exception using errcode = 'P0001', message = 'invalid_installation_id';
  end if;

  update public.device_push_tokens dpt
  set
    enabled = false,
    invalidated_at = coalesce(dpt.invalidated_at, now()),
    updated_at = now()
  where dpt.user_id = v_me
    and dpt.installation_id = trim(p_installation_id)
    and dpt.enabled = true;
end;
$function$;

revoke all on function public.disable_device_push_token(text) from public;
revoke all on function public.disable_device_push_token(text) from anon;
grant execute on function public.disable_device_push_token(text) to authenticated;

create or replace function public.disable_all_my_push_tokens()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  update public.device_push_tokens dpt
  set
    enabled = false,
    invalidated_at = coalesce(dpt.invalidated_at, now()),
    updated_at = now()
  where dpt.user_id = v_me
    and dpt.enabled = true;
end;
$function$;

revoke all on function public.disable_all_my_push_tokens() from public;
revoke all on function public.disable_all_my_push_tokens() from anon;
grant execute on function public.disable_all_my_push_tokens() to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Preferences RPCs
-- ---------------------------------------------------------------------------

create or replace function public.get_my_notification_preferences()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
  v_prefs public.notification_preferences;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  v_prefs := public._notification_prefs_or_defaults(v_me);

  return jsonb_build_object(
    'dm_messages', v_prefs.dm_messages,
    'friend_requests', v_prefs.friend_requests,
    'friend_accepts', v_prefs.friend_accepts,
    'study_assignments', v_prefs.study_assignments,
    'schedule_changes', v_prefs.schedule_changes,
    'study_announcements', v_prefs.study_announcements,
    'group_replies', v_prefs.group_replies,
    'group_mentions', v_prefs.group_mentions,
    'group_all_messages', v_prefs.group_all_messages,
    'show_message_preview', v_prefs.show_message_preview,
    'push_enabled', v_prefs.push_enabled,
    'updated_at', v_prefs.updated_at
  );
end;
$function$;

revoke all on function public.get_my_notification_preferences() from public;
revoke all on function public.get_my_notification_preferences() from anon;
grant execute on function public.get_my_notification_preferences() to authenticated;

create or replace function public.update_my_notification_preferences(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
  v_prefs public.notification_preferences;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  v_prefs := public._notification_prefs_or_defaults(v_me);

  insert into public.notification_preferences as np (
    user_id,
    dm_messages,
    friend_requests,
    friend_accepts,
    study_assignments,
    schedule_changes,
    study_announcements,
    group_replies,
    group_mentions,
    group_all_messages,
    show_message_preview,
    push_enabled,
    updated_at
  ) values (
    v_me,
    coalesce((v_patch->>'dm_messages')::boolean, v_prefs.dm_messages),
    coalesce((v_patch->>'friend_requests')::boolean, v_prefs.friend_requests),
    coalesce((v_patch->>'friend_accepts')::boolean, v_prefs.friend_accepts),
    coalesce((v_patch->>'study_assignments')::boolean, v_prefs.study_assignments),
    coalesce((v_patch->>'schedule_changes')::boolean, v_prefs.schedule_changes),
    coalesce((v_patch->>'study_announcements')::boolean, v_prefs.study_announcements),
    coalesce((v_patch->>'group_replies')::boolean, v_prefs.group_replies),
    coalesce((v_patch->>'group_mentions')::boolean, v_prefs.group_mentions),
    coalesce((v_patch->>'group_all_messages')::boolean, v_prefs.group_all_messages),
    coalesce((v_patch->>'show_message_preview')::boolean, v_prefs.show_message_preview),
    coalesce((v_patch->>'push_enabled')::boolean, v_prefs.push_enabled),
    now()
  )
  on conflict (user_id) do update
  set
    dm_messages = excluded.dm_messages,
    friend_requests = excluded.friend_requests,
    friend_accepts = excluded.friend_accepts,
    study_assignments = excluded.study_assignments,
    schedule_changes = excluded.schedule_changes,
    study_announcements = excluded.study_announcements,
    group_replies = excluded.group_replies,
    group_mentions = excluded.group_mentions,
    group_all_messages = excluded.group_all_messages,
    show_message_preview = excluded.show_message_preview,
    push_enabled = excluded.push_enabled,
    updated_at = now();

  return public.get_my_notification_preferences();
end;
$function$;

revoke all on function public.update_my_notification_preferences(jsonb) from public;
revoke all on function public.update_my_notification_preferences(jsonb) from anon;
grant execute on function public.update_my_notification_preferences(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. In-app notification RPCs
-- ---------------------------------------------------------------------------

create or replace function public.get_my_app_notifications(p_limit integer default 50)
returns setof public.app_notifications
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  return query
  select an.*
  from public.app_notifications an
  where an.recipient_id = v_me
    and an.deleted_at is null
  order by an.created_at desc
  limit v_limit;
end;
$function$;

revoke all on function public.get_my_app_notifications(integer) from public;
revoke all on function public.get_my_app_notifications(integer) from anon;
grant execute on function public.get_my_app_notifications(integer) to authenticated;

create or replace function public.get_my_unread_notification_count()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
  v_count integer;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  select count(*)::integer into v_count
  from public.app_notifications an
  where an.recipient_id = v_me
    and an.deleted_at is null
    and an.read_at is null;

  return coalesce(v_count, 0);
end;
$function$;

revoke all on function public.get_my_unread_notification_count() from public;
revoke all on function public.get_my_unread_notification_count() from anon;
grant execute on function public.get_my_unread_notification_count() to authenticated;

create or replace function public.mark_notification_read(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  update public.app_notifications an
  set read_at = coalesce(an.read_at, now())
  where an.id = p_notification_id
    and an.recipient_id = v_me
    and an.deleted_at is null;
end;
$function$;

revoke all on function public.mark_notification_read(uuid) from public;
revoke all on function public.mark_notification_read(uuid) from anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;

create or replace function public.mark_all_notifications_read()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  update public.app_notifications an
  set read_at = coalesce(an.read_at, now())
  where an.recipient_id = v_me
    and an.deleted_at is null
    and an.read_at is null;
end;
$function$;

revoke all on function public.mark_all_notifications_read() from public;
revoke all on function public.mark_all_notifications_read() from anon;
grant execute on function public.mark_all_notifications_read() to authenticated;

create or replace function public.hide_notification_for_me(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  update public.app_notifications an
  set
    deleted_at = coalesce(an.deleted_at, now()),
    read_at = coalesce(an.read_at, now())
  where an.id = p_notification_id
    and an.recipient_id = v_me
    and an.deleted_at is null;
end;
$function$;

revoke all on function public.hide_notification_for_me(uuid) from public;
revoke all on function public.hide_notification_for_me(uuid) from anon;
grant execute on function public.hide_notification_for_me(uuid) to authenticated;

create or replace function public.cleanup_old_app_notifications(p_days integer default 90)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_deleted integer;
begin
  delete from public.app_notifications an
  where an.created_at < now() - make_interval(days => greatest(coalesce(p_days, 90), 30));

  get diagnostics v_deleted = row_count;
  return coalesce(v_deleted, 0);
end;
$function$;

revoke all on function public.cleanup_old_app_notifications(integer) from public;
revoke all on function public.cleanup_old_app_notifications(integer) from anon;
revoke all on function public.cleanup_old_app_notifications(integer) from authenticated;
grant execute on function public.cleanup_old_app_notifications(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 9. Outbox claim helpers (Edge Function / service_role)
-- ---------------------------------------------------------------------------
-- Retry note (INSERT webhook alone is NOT enough):
-- Database Webhook on notification_outbox INSERT fires only for new rows.
-- When complete_notification_outbox sets status back to 'pending' (retry),
-- that is an UPDATE — the INSERT webhook will not run again.
-- Do NOT add a recursive UPDATE webhook.
-- Preferred drain for retries / stuck processing:
--   pg_cron (e.g. every 1 min) POST Edge Function with PUSH_DISPATCH_SECRET
--   (secret configured in Dashboard/cron headers, never hardcoded in SQL).
-- claim_pending_notification_outbox also reclaims processing older than 5 minutes.

create or replace function public.claim_pending_notification_outbox(p_limit integer default 25)
returns setof public.notification_outbox
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
begin
  -- Exhausted stuck processing cannot be reclaimed (attempts already >= 8).
  update public.notification_outbox o
  set
    status = 'failed',
    processing_started_at = null,
    processed_at = now(),
    last_error = 'max_attempts_exceeded'
  where o.status = 'processing'
    and o.attempts >= 8
    and o.processing_started_at is not null
    and o.processing_started_at <= now() - interval '5 minutes';

  return query
  with picked as (
    select o.id
    from public.notification_outbox o
    where o.attempts < 8
      and (
        (o.status = 'pending' and o.available_at <= now())
        or (
          o.status = 'processing'
          and o.processing_started_at is not null
          and o.processing_started_at <= now() - interval '5 minutes'
        )
      )
    order by o.available_at, o.created_at
    limit v_limit
    for update skip locked
  )
  update public.notification_outbox o
  set
    status = 'processing',
    processing_started_at = now(),
    attempts = o.attempts + 1,
    last_error = null
  from picked
  where o.id = picked.id
  returning o.*;
end;
$function$;

revoke all on function public.claim_pending_notification_outbox(integer) from public;
revoke all on function public.claim_pending_notification_outbox(integer) from anon;
revoke all on function public.claim_pending_notification_outbox(integer) from authenticated;
grant execute on function public.claim_pending_notification_outbox(integer) to service_role;

create or replace function public.complete_notification_outbox(
  p_outbox_id uuid,
  p_status text,
  p_error text default null,
  p_retry_seconds integer default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_status not in ('sent', 'failed', 'skipped', 'pending') then
    raise exception using errcode = 'P0001', message = 'invalid_status';
  end if;

  update public.notification_outbox o
  set
    status = p_status,
    processing_started_at = null,
    processed_at = case
      when p_status in ('sent', 'failed', 'skipped') then now()
      else null
    end,
    last_error = p_error,
    available_at = case
      when p_status = 'pending' then now() + make_interval(secs => greatest(coalesce(p_retry_seconds, 30), 5))
      else o.available_at
    end
  where o.id = p_outbox_id;
end;
$function$;

revoke all on function public.complete_notification_outbox(uuid, text, text, integer) from public;
revoke all on function public.complete_notification_outbox(uuid, text, text, integer) from anon;
revoke all on function public.complete_notification_outbox(uuid, text, text, integer) from authenticated;
grant execute on function public.complete_notification_outbox(uuid, text, text, integer) to service_role;

create or replace function public.list_active_device_push_tokens(p_user_id uuid)
returns table (
  id uuid,
  token text,
  platform text,
  installation_id text
)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  return query
  select dpt.id, dpt.token, dpt.platform, dpt.installation_id
  from public.device_push_tokens dpt
  where dpt.user_id = p_user_id
    and dpt.enabled = true
    and dpt.invalidated_at is null;
end;
$function$;

revoke all on function public.list_active_device_push_tokens(uuid) from public;
revoke all on function public.list_active_device_push_tokens(uuid) from anon;
revoke all on function public.list_active_device_push_tokens(uuid) from authenticated;
grant execute on function public.list_active_device_push_tokens(uuid) to service_role;

create or replace function public.list_pending_device_push_tokens(
  p_outbox_id uuid,
  p_user_id uuid
)
returns table (
  id uuid,
  token text,
  platform text,
  installation_id text
)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  return query
  select dpt.id, dpt.token, dpt.platform, dpt.installation_id
  from public.device_push_tokens dpt
  where dpt.user_id = p_user_id
    and dpt.enabled = true
    and dpt.invalidated_at is null
    and not exists (
      select 1
      from public.push_delivery_attempts pda
      where pda.outbox_id = p_outbox_id
        and pda.device_token_id = dpt.id
        and pda.success = true
    );
end;
$function$;

revoke all on function public.list_pending_device_push_tokens(uuid, uuid) from public;
revoke all on function public.list_pending_device_push_tokens(uuid, uuid) from anon;
revoke all on function public.list_pending_device_push_tokens(uuid, uuid) from authenticated;
grant execute on function public.list_pending_device_push_tokens(uuid, uuid) to service_role;

create or replace function public.has_successful_push_delivery(p_outbox_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
begin
  return exists (
    select 1
    from public.push_delivery_attempts pda
    where pda.outbox_id = p_outbox_id
      and pda.success = true
  );
end;
$function$;

revoke all on function public.has_successful_push_delivery(uuid) from public;
revoke all on function public.has_successful_push_delivery(uuid) from anon;
revoke all on function public.has_successful_push_delivery(uuid) from authenticated;
grant execute on function public.has_successful_push_delivery(uuid) to service_role;

create or replace function public.invalidate_device_push_token_by_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update public.device_push_tokens dpt
  set
    enabled = false,
    invalidated_at = coalesce(dpt.invalidated_at, now()),
    updated_at = now()
  where dpt.token = p_token
    and dpt.enabled = true;
end;
$function$;

revoke all on function public.invalidate_device_push_token_by_token(text) from public;
revoke all on function public.invalidate_device_push_token_by_token(text) from anon;
revoke all on function public.invalidate_device_push_token_by_token(text) from authenticated;
grant execute on function public.invalidate_device_push_token_by_token(text) to service_role;

create or replace function public.record_push_delivery_attempt(
  p_outbox_id uuid,
  p_device_token_id uuid,
  p_success boolean,
  p_http_status integer default null,
  p_error_code text default null,
  p_error_message text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  insert into public.push_delivery_attempts (
    outbox_id,
    device_token_id,
    success,
    http_status,
    error_code,
    error_message
  ) values (
    p_outbox_id,
    p_device_token_id,
    coalesce(p_success, false),
    p_http_status,
    p_error_code,
    left(p_error_message, 500)
  );
end;
$function$;

revoke all on function public.record_push_delivery_attempt(uuid, uuid, boolean, integer, text, text) from public;
revoke all on function public.record_push_delivery_attempt(uuid, uuid, boolean, integer, text, text) from anon;
revoke all on function public.record_push_delivery_attempt(uuid, uuid, boolean, integer, text, text) from authenticated;
grant execute on function public.record_push_delivery_attempt(uuid, uuid, boolean, integer, text, text) to service_role;

create or replace function public.should_deliver_push_for_outbox(p_outbox_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_outbox public.notification_outbox;
  v_prefs public.notification_preferences;
  v_data jsonb;
  v_chat_id uuid;
  v_peer_id uuid;
  v_author_id uuid;
  v_allow boolean := true;
  v_reason text := null;
  v_title text;
  v_body text;
begin
  select * into v_outbox
  from public.notification_outbox o
  where o.id = p_outbox_id;

  if not found then
    return jsonb_build_object('allow', false, 'reason', 'missing_outbox');
  end if;

  v_prefs := public._notification_prefs_or_defaults(v_outbox.recipient_id);
  v_data := coalesce(v_outbox.payload->'data', '{}'::jsonb);
  v_chat_id := nullif(v_data->>'chat_id', '')::uuid;
  v_peer_id := nullif(v_data->>'peer_id', '')::uuid;
  v_author_id := nullif(v_data->>'author_id', '')::uuid;
  v_title := v_outbox.payload->>'title';
  v_body := v_outbox.payload->>'body';

  if not coalesce(v_prefs.push_enabled, true) then
    return jsonb_build_object('allow', false, 'reason', 'push_disabled');
  end if;

  if v_chat_id is not null and public._chat_is_muted_for(v_outbox.recipient_id, v_chat_id) then
    return jsonb_build_object('allow', false, 'reason', 'chat_muted');
  end if;

  if v_chat_id is not null and public._chat_is_academically_archived(v_chat_id) then
    return jsonb_build_object('allow', false, 'reason', 'chat_archived');
  end if;

  if v_author_id is not null
     and public._users_blocked_either(v_outbox.recipient_id, v_author_id) then
    return jsonb_build_object('allow', false, 'reason', 'blocked');
  end if;

  if v_peer_id is not null
     and public._users_blocked_either(v_outbox.recipient_id, v_peer_id) then
    return jsonb_build_object('allow', false, 'reason', 'blocked');
  end if;

  case v_outbox.event_type
    when 'dm_message' then v_allow := v_prefs.dm_messages;
    when 'team_message' then v_allow := v_prefs.group_all_messages;
    when 'team_reply' then v_allow := v_prefs.group_replies or v_prefs.group_all_messages;
    when 'friend_request' then v_allow := v_prefs.friend_requests;
    when 'friend_accepted' then v_allow := v_prefs.friend_accepts;
    when 'assignment' then v_allow := v_prefs.study_assignments;
    when 'schedule_change' then v_allow := v_prefs.schedule_changes;
    when 'announcement' then v_allow := v_prefs.study_announcements;
    else v_allow := true;
  end case;

  if not v_allow then
    v_reason := 'preference_disabled';
  end if;

  -- Always apply CURRENT preview preference (not the body frozen at enqueue).
  if not coalesce(v_prefs.show_message_preview, true) then
    if v_outbox.event_type = 'dm_message' then
      v_body := 'Новое сообщение';
    elsif v_outbox.event_type in ('team_message', 'team_reply') then
      v_body := 'Новое сообщение в учебном чате';
    end if;
  end if;

  return jsonb_build_object(
    'allow', v_allow,
    'reason', v_reason,
    'show_message_preview', v_prefs.show_message_preview,
    'title', v_title,
    'body', v_body,
    'data', v_data,
    'event_type', v_outbox.event_type,
    'recipient_id', v_outbox.recipient_id,
    'notification_id', v_outbox.app_notification_id
  );
end;
$function$;

revoke all on function public.should_deliver_push_for_outbox(uuid) from public;
revoke all on function public.should_deliver_push_for_outbox(uuid) from anon;
revoke all on function public.should_deliver_push_for_outbox(uuid) from authenticated;
grant execute on function public.should_deliver_push_for_outbox(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 10. Event triggers: messages
-- ---------------------------------------------------------------------------

create or replace function public.trg_fn_enqueue_message_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_chat public.chats;
  v_prefs public.notification_preferences;
  v_recipient uuid;
  v_author_name text;
  v_title text;
  v_body text;
  v_preview text;
  v_msg_type text;
  v_is_file boolean;
  v_is_image boolean;
  v_reply_author uuid;
  v_event_type text;
  v_data jsonb;
  v_allow_in_app boolean;
begin
  -- Skip reactions / edits / technical bubbles.
  if tg_op <> 'INSERT' then
    return new;
  end if;

  v_msg_type := coalesce(nullif(new.msg_type, ''), nullif(new.type, ''), 'text');
  if v_msg_type in ('assignmentDraft', 'system', 'reaction') then
    return new;
  end if;

  select * into v_chat
  from public.chats c
  where c.id = new.chat_id;

  if not found then
    return new;
  end if;

  if public._chat_is_academically_archived(new.chat_id) then
    return new;
  end if;

  v_author_name := coalesce(public._display_name(new.author_id), 'Пользователь');
  v_preview := nullif(trim(coalesce(new.body, new.content, '')), '');
  v_is_file := v_msg_type in ('file', 'image', 'photo')
    or coalesce(jsonb_array_length(coalesce(new.attachments, '[]'::jsonb)), 0) > 0
    or new.file_id is not null
    or nullif(trim(coalesce(new.attachment_url, '')), '') is not null;
  v_is_image := v_msg_type in ('image', 'photo')
    or coalesce(new.attachment_url, '') ~* '\.(jpg|jpeg|png|gif|webp)(\?|$)';

  if new.reply_to_id is not null then
    select m.author_id into v_reply_author
    from public.messages m
    where m.id = new.reply_to_id;
  end if;

  if v_chat.type = 'dm' then
    select case
      when dp.a = new.author_id then dp.b
      else dp.a
    end into v_recipient
    from public.dm_pairs dp
    where dp.chat_id = new.chat_id;

    if v_recipient is null or v_recipient = new.author_id then
      return new;
    end if;

    if public._users_blocked_either(new.author_id, v_recipient) then
      return new;
    end if;

    if public._chat_is_muted_for(v_recipient, new.chat_id) then
      return new;
    end if;

    v_prefs := public._notification_prefs_or_defaults(v_recipient);
    if not v_prefs.dm_messages then
      return new;
    end if;

    v_title := v_author_name;
    if not v_prefs.show_message_preview then
      v_body := 'Новое сообщение';
    elsif v_is_image then
      v_body := 'Отправил(а) фото';
    elsif v_is_file then
      v_body := 'Отправил(а) файл';
    else
      v_body := coalesce(left(v_preview, 180), 'Новое сообщение');
    end if;

    v_data := jsonb_build_object(
      'version', 1,
      'type', 'dm_message',
      'chat_id', new.chat_id,
      'peer_id', new.author_id,
      'author_id', new.author_id,
      'message_id', new.id
    );

    perform public._enqueue_app_notification(
      v_recipient,
      'dm_message',
      v_title,
      v_body,
      v_data,
      new.id::text,
      'dm_message:' || new.id::text,
      true
    );
    return new;
  end if;

  if v_chat.type = 'team_main' then
    if v_chat.team_id is null then
      return new;
    end if;

    for v_recipient in
      select recip_id
      from public._team_accessible_user_ids(v_chat.team_id) as recip_id
      where recip_id <> new.author_id
    loop
      if public._chat_is_muted_for(v_recipient, new.chat_id) then
        continue;
      end if;

      v_prefs := public._notification_prefs_or_defaults(v_recipient);
      v_allow_in_app := false;
      v_event_type := null;

      if v_reply_author is not null
         and v_reply_author = v_recipient
         and (v_prefs.group_replies or v_prefs.group_all_messages) then
        v_allow_in_app := true;
        v_event_type := 'team_reply';
      elsif v_prefs.group_all_messages then
        v_allow_in_app := true;
        v_event_type := 'team_message';
      end if;

      -- No fake @mentions: real mention model does not exist.

      if not v_allow_in_app or v_event_type is null then
        continue;
      end if;

      v_title := coalesce(v_chat.type, 'Группа');
      -- Prefer team subject-ish title from chat id fallback.
      v_title := 'Учебный чат';
      if not v_prefs.show_message_preview then
        v_body := v_author_name || ': новое сообщение';
      elsif v_is_image then
        v_body := v_author_name || ': отправил(а) фото';
      elsif v_is_file then
        v_body := v_author_name || ': отправил(а) файл';
      else
        v_body := v_author_name || ': ' || coalesce(left(v_preview, 160), 'новое сообщение');
      end if;

      if v_event_type = 'team_reply' then
        v_title := 'Ответ в учебном чате';
      end if;

      v_data := jsonb_build_object(
        'version', 1,
        'type', v_event_type,
        'chat_id', new.chat_id,
        'team_id', v_chat.team_id,
        'author_id', new.author_id,
        'message_id', new.id
      );

      perform public._enqueue_app_notification(
        v_recipient,
        v_event_type,
        v_title,
        v_body,
        v_data,
        new.id::text,
        v_event_type || ':' || new.id::text || ':' || v_recipient::text,
        true
      );
    end loop;
  end if;

  return new;
end;
$function$;

revoke all on function public.trg_fn_enqueue_message_notifications() from public;
revoke all on function public.trg_fn_enqueue_message_notifications() from anon;
revoke all on function public.trg_fn_enqueue_message_notifications() from authenticated;

drop trigger if exists trg_enqueue_message_notifications on public.messages;
create trigger trg_enqueue_message_notifications
  after insert on public.messages
  for each row
  execute function public.trg_fn_enqueue_message_notifications();

-- ---------------------------------------------------------------------------
-- 11. Event triggers: friends
-- ---------------------------------------------------------------------------

create or replace function public.trg_fn_enqueue_friend_request_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_prefs public.notification_preferences;
  v_name text;
begin
  if new.to_id is null or new.from_id is null then
    return new;
  end if;

  v_prefs := public._notification_prefs_or_defaults(new.to_id);
  if not v_prefs.friend_requests then
    return new;
  end if;

  v_name := coalesce(public._display_name(new.from_id), 'Пользователь');

  perform public._enqueue_app_notification(
    new.to_id,
    'friend_request',
    'Заявка в друзья',
    v_name || ' хочет добавить вас в друзья',
    jsonb_build_object(
      'version', 1,
      'type', 'friend_request',
      'friend_user_id', new.from_id
    ),
    new.id::text,
    'friend_request:' || new.id::text,
    true
  );

  return new;
end;
$function$;

revoke all on function public.trg_fn_enqueue_friend_request_notifications() from public;
revoke all on function public.trg_fn_enqueue_friend_request_notifications() from anon;
revoke all on function public.trg_fn_enqueue_friend_request_notifications() from authenticated;

drop trigger if exists trg_enqueue_friend_request_notifications on public.friend_requests;
create trigger trg_enqueue_friend_request_notifications
  after insert on public.friend_requests
  for each row
  execute function public.trg_fn_enqueue_friend_request_notifications();

create or replace function public.trg_fn_enqueue_friend_accept_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_other uuid;
  v_prefs public.notification_preferences;
  v_name text;
begin
  -- Notify the user who did NOT just accept (the original requester / other side).
  if v_actor is null then
    return new;
  end if;

  if v_actor = new.user_id then
    v_other := new.friend_id;
  elsif v_actor = new.friend_id then
    v_other := new.user_id;
  else
    -- Fallback: notify both sides except actor is unknown; skip to avoid spam.
    return new;
  end if;

  v_prefs := public._notification_prefs_or_defaults(v_other);
  if not v_prefs.friend_accepts then
    return new;
  end if;

  v_name := coalesce(public._display_name(v_actor), 'Пользователь');

  perform public._enqueue_app_notification(
    v_other,
    'friend_accepted',
    'Новый друг',
    v_name || ' принял(а) заявку в друзья',
    jsonb_build_object(
      'version', 1,
      'type', 'friend_accepted',
      'friend_user_id', v_actor
    ),
    new.id::text,
    'friend_accepted:' || new.id::text || ':' || v_other::text,
    true
  );

  return new;
end;
$function$;

revoke all on function public.trg_fn_enqueue_friend_accept_notifications() from public;
revoke all on function public.trg_fn_enqueue_friend_accept_notifications() from anon;
revoke all on function public.trg_fn_enqueue_friend_accept_notifications() from authenticated;

drop trigger if exists trg_enqueue_friend_accept_notifications on public.friends;
create trigger trg_enqueue_friend_accept_notifications
  after insert on public.friends
  for each row
  execute function public.trg_fn_enqueue_friend_accept_notifications();

-- ---------------------------------------------------------------------------
-- 12. Event triggers: assignments
-- ---------------------------------------------------------------------------

create or replace function public.trg_fn_enqueue_assignment_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_recipient uuid;
  v_prefs public.notification_preferences;
  v_title text;
  v_body text;
  v_event_key text;
  v_chat_id uuid;
  v_is_publish boolean := false;
  v_is_due_change boolean := false;
begin
  if tg_op = 'INSERT' then
    v_is_publish := coalesce(new.status, '') = 'published' and new.published_at is not null;
  elsif tg_op = 'UPDATE' then
    v_is_publish :=
      coalesce(old.status, '') is distinct from coalesce(new.status, '')
      and coalesce(new.status, '') = 'published';
    v_is_due_change :=
      coalesce(new.status, '') = 'published'
      and (
        coalesce(old.due_text, '') is distinct from coalesce(new.due_text, '')
        or old.due_at is distinct from new.due_at
      );
  end if;

  if not v_is_publish and not v_is_due_change then
    return new;
  end if;

  -- Drafts never notify.
  if coalesce(new.status, '') <> 'published' then
    return new;
  end if;

  if new.team_id is null then
    return new;
  end if;

  select c.id into v_chat_id
  from public.chats c
  where c.team_id = new.team_id
    and c.type = 'team_main'
  limit 1;

  if v_chat_id is not null and public._chat_is_academically_archived(v_chat_id) then
    return new;
  end if;

  if v_is_publish then
    v_title := 'Новое задание';
    v_body := coalesce(nullif(trim(new.title), ''), 'Опубликовано задание');
    v_event_key := 'assignment_published:' || new.id::text;
  else
    v_title := 'Срок задания изменён';
    v_body := coalesce(nullif(trim(new.title), ''), 'Задание')
      || case
           when nullif(trim(coalesce(new.due_text, '')), '') is not null
             then ': до ' || trim(new.due_text)
           else ''
         end;
    v_event_key := 'assignment_due:' || new.id::text || ':' || md5(
      coalesce(new.due_text, '') || '|' || coalesce(new.due_at::text, '')
    );
  end if;

  for v_recipient in
    select recip_id
    from public._team_accessible_user_ids(new.team_id) as recip_id
    where (v_actor is null or recip_id <> v_actor)
      and recip_id <> coalesce(
        new.author_id,
        new.created_by,
        '00000000-0000-0000-0000-000000000000'::uuid
      )
  loop
    v_prefs := public._notification_prefs_or_defaults(v_recipient);
    if not v_prefs.study_assignments then
      continue;
    end if;

    perform public._enqueue_app_notification(
      v_recipient,
      'assignment',
      v_title,
      v_body,
      jsonb_build_object(
        'version', 1,
        'type', 'assignment',
        'assignment_id', new.id,
        'team_id', new.team_id,
        'chat_id', v_chat_id
      ),
      new.id::text,
      v_event_key || ':' || v_recipient::text,
      true
    );
  end loop;

  return new;
end;
$function$;

revoke all on function public.trg_fn_enqueue_assignment_notifications() from public;
revoke all on function public.trg_fn_enqueue_assignment_notifications() from anon;
revoke all on function public.trg_fn_enqueue_assignment_notifications() from authenticated;

drop trigger if exists trg_enqueue_assignment_notifications on public.assignments;
create trigger trg_enqueue_assignment_notifications
  after insert or update on public.assignments
  for each row
  execute function public.trg_fn_enqueue_assignment_notifications();

-- ---------------------------------------------------------------------------
-- 13. Event triggers: schedule (meaningful lesson changes only)
-- ---------------------------------------------------------------------------

create or replace function public.trg_fn_enqueue_schedule_change_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_recipient uuid;
  v_prefs public.notification_preferences;
  v_changed boolean := false;
  v_title text;
  v_body text;
  v_key text;
  v_group_name text;
begin
  if tg_op = 'INSERT' then
    v_changed := true;
    v_title := 'Новое занятие в расписании';
    v_body := coalesce(nullif(trim(new.subject), ''), 'Занятие')
      || case when new.date is not null then ' · ' || new.date::text else '' end;
    v_key := 'schedule_insert:' || new.id::text;
  elsif tg_op = 'UPDATE' then
    v_changed :=
      old.date is distinct from new.date
      or old.day is distinct from new.day
      or old.pair_num is distinct from new.pair_num
      or old.time_start is distinct from new.time_start
      or old.time_end is distinct from new.time_end
      or coalesce(old.subject, '') is distinct from coalesce(new.subject, '')
      or coalesce(old.room, '') is distinct from coalesce(new.room, '')
      or coalesce(old.teacher, '') is distinct from coalesce(new.teacher, '')
      or old.group_id is distinct from new.group_id;
    -- Ignore pure academic-link / alias remaps without schedule impact.
    if not v_changed then
      return new;
    end if;
    v_title := 'Изменение в расписании';
    v_body := coalesce(nullif(trim(new.subject), ''), 'Занятие')
      || case when new.date is not null then ' · ' || new.date::text else '' end;
    v_key := 'schedule_update:' || new.id::text || ':' || md5(
      coalesce(new.date::text, '') || '|' ||
      coalesce(new.pair_num::text, '') || '|' ||
      coalesce(new.time_start::text, '') || '|' ||
      coalesce(new.time_end::text, '') || '|' ||
      coalesce(new.subject, '') || '|' ||
      coalesce(new.room, '') || '|' ||
      coalesce(new.teacher, '')
    );
  else
    return new;
  end if;

  if new.group_id is null then
    return new;
  end if;

  select g.name into v_group_name
  from public.groups g
  where g.id = new.group_id;

  for v_recipient in
    select u.id
    from public.users u
    where u.group_name is not null
      and v_group_name is not null
      and u.group_name = v_group_name
      and (v_actor is null or u.id <> v_actor)
  loop
    v_prefs := public._notification_prefs_or_defaults(v_recipient);
    if not v_prefs.schedule_changes then
      continue;
    end if;

    perform public._enqueue_app_notification(
      v_recipient,
      'schedule_change',
      v_title,
      v_body,
      jsonb_build_object(
        'version', 1,
        'type', 'schedule_change',
        'lesson_id', new.id
      ),
      new.id::text,
      v_key || ':' || v_recipient::text,
      true
    );
  end loop;

  return new;
end;
$function$;

revoke all on function public.trg_fn_enqueue_schedule_change_notifications() from public;
revoke all on function public.trg_fn_enqueue_schedule_change_notifications() from anon;
revoke all on function public.trg_fn_enqueue_schedule_change_notifications() from authenticated;

drop trigger if exists trg_enqueue_schedule_change_notifications on public.lessons;
create trigger trg_enqueue_schedule_change_notifications
  after insert or update on public.lessons
  for each row
  execute function public.trg_fn_enqueue_schedule_change_notifications();

-- ---------------------------------------------------------------------------
-- 14. Realtime for in-app center
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) then
    begin
      alter publication supabase_realtime add table public.app_notifications;
    exception
      when duplicate_object then null;
    end;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 15. Optional cleanup cron (if pg_cron available)
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid)
    from cron.job
    where jobname = 'app-notifications-cleanup';

    perform cron.schedule(
      'app-notifications-cleanup',
      '20 4 * * *',
      $cron$select public.cleanup_old_app_notifications(90);$cron$
    );
  end if;
exception
  when others then
    raise notice 'Skipping app-notifications-cleanup cron: %', sqlerrm;
end $$;

-- Manual Database Webhook + minute Cron: see
--   supabase/manual/stage11_webhook_setup.sql.example
--   supabase/manual/stage11_dispatch_cron_setup.sql.example
-- INSERT webhook = fast first delivery; Cron = retries + stuck processing.
-- Never embed PUSH_DISPATCH_SECRET in this migration.
