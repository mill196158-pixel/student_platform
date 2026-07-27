-- Stage 13.9 — Group action (topic/collection) push + in-app notifications.
-- Local migration only. Append after stage13_9_chat_topics_collections.
-- Enqueue via public._enqueue_app_notification; membership/archive at enqueue;
-- mute + prefs at should_deliver_push_for_outbox.

begin;

-- ---------------------------------------------------------------------------
-- 0) Minimal Stage 11 scaffolding when applying on a stripped local DB.
--     Full remote already has these tables/functions from Stage 11.
-- ---------------------------------------------------------------------------
create table if not exists public.notification_preferences (
  user_id uuid primary key references public.users(id) on delete cascade,
  dm_messages boolean not null default true,
  friend_requests boolean not null default true,
  friend_accepts boolean not null default true,
  study_assignments boolean not null default true,
  schedule_changes boolean not null default true,
  study_announcements boolean not null default true,
  group_replies boolean not null default true,
  group_mentions boolean not null default true,
  group_all_messages boolean not null default false,
  group_actions boolean not null default true,
  show_message_preview boolean not null default true,
  push_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.app_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.users(id) on delete cascade,
  event_type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  source_id text,
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  deleted_at timestamptz
);

create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  app_notification_id uuid references public.app_notifications(id) on delete set null,
  recipient_id uuid not null references public.users(id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  processing_started_at timestamptz,
  last_error text
);

do $$
begin
  if to_regprocedure(
    'public._enqueue_app_notification(uuid,text,text,text,jsonb,text,text,boolean)'
  ) is null then
    execute $fn$
      create function public._enqueue_app_notification(
        p_recipient_id uuid,
        p_event_type text,
        p_title text,
        p_body text,
        p_data jsonb default '{}'::jsonb,
        p_source_id text default null,
        p_idempotency_key text default null,
        p_enqueue_push boolean default true
      ) returns uuid
      language plpgsql
      security definer
      set search_path = ''
      as $body$
      declare
        v_id uuid;
        v_key text := coalesce(
          p_idempotency_key,
          p_event_type || ':' || coalesce(p_source_id, '') || ':' || p_recipient_id::text
        );
      begin
        insert into public.app_notifications(
          recipient_id, event_type, title, body, data, source_id, idempotency_key
        ) values (
          p_recipient_id, p_event_type, p_title, p_body, coalesce(p_data, '{}'::jsonb),
          p_source_id, v_key
        )
        on conflict (idempotency_key) do update
          set title = excluded.title
        returning id into v_id;

        if coalesce(p_enqueue_push, true) then
          insert into public.notification_outbox(
            app_notification_id, recipient_id, event_type, payload, idempotency_key
          ) values (
            v_id,
            p_recipient_id,
            p_event_type,
            jsonb_build_object(
              'title', p_title,
              'body', p_body,
              'data', coalesce(p_data, '{}'::jsonb)
            ),
            v_key || ':push'
          )
          on conflict (idempotency_key) do nothing;
        end if;
        return v_id;
      end;
      $body$;
    $fn$;
    revoke all on function public._enqueue_app_notification(uuid, text, text, text, jsonb, text, text, boolean)
      from public, anon, authenticated;
    grant execute on function public._enqueue_app_notification(uuid, text, text, text, jsonb, text, text, boolean)
      to service_role;
  end if;
end $$;

-- Soft stubs used by delivery gate when Stage 11 helpers are absent.
do $outer$
begin
  if to_regprocedure('public._chat_is_muted_for(uuid,uuid)') is null then
    execute $fn$
      create function public._chat_is_muted_for(p_user_id uuid, p_chat_id uuid)
      returns boolean language sql stable security definer set search_path = '' as $b$
        select false;
      $b$;
    $fn$;
  end if;
  if to_regprocedure('public._chat_is_academically_archived(uuid)') is null then
    execute $fn$
      create function public._chat_is_academically_archived(p_chat_id uuid)
      returns boolean language sql stable security definer set search_path = '' as $b$
        select exists (
          select 1 from public.chat_academic_archives a where a.chat_id = p_chat_id
        );
      $b$;
    $fn$;
  end if;
  if to_regprocedure('public._users_blocked_either(uuid,uuid)') is null then
    execute $fn$
      create function public._users_blocked_either(p_a uuid, p_b uuid)
      returns boolean language sql stable security definer set search_path = '' as $b$
        select false;
      $b$;
    $fn$;
  end if;
end
$outer$;

-- ---------------------------------------------------------------------------
-- 1) Preference category: group_actions (default true)
-- ---------------------------------------------------------------------------
alter table public.notification_preferences
  add column if not exists group_actions boolean not null default true;

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
  v_row.group_actions := true;
  v_row.show_message_preview := true;
  v_row.push_enabled := true;
  v_row.updated_at := now();
  return v_row;
end;
$function$;

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
    'group_actions', v_prefs.group_actions,
    'show_message_preview', v_prefs.show_message_preview,
    'push_enabled', v_prefs.push_enabled,
    'updated_at', v_prefs.updated_at
  );
end;
$function$;

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
    group_actions,
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
    coalesce((v_patch->>'group_actions')::boolean, v_prefs.group_actions),
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
    group_actions = excluded.group_actions,
    show_message_preview = excluded.show_message_preview,
    push_enabled = excluded.push_enabled,
    updated_at = now();

  return public.get_my_notification_preferences();
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2) Team member enumeration + safe enqueue helpers
-- ---------------------------------------------------------------------------
create or replace function private.active_team_member_user_ids(p_team_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct tm.user_id
  from public.teams t
  join public.team_members tm on tm.team_id = t.id
  join public.student_enrollments se
    on se.user_id = tm.user_id
   and se.group_id = t.group_id
   and se.status = 'active'
   and se.ended_at is null
  where t.id = p_team_id
    and t.kind = 'group_space'
    and not exists (
      select 1
      from public.chats c
      join public.chat_academic_archives a on a.chat_id = c.id
      where c.team_id = t.id and c.type = 'team_main'
    )
  union
  select tm.user_id
  from public.teams t
  join public.team_members tm on tm.team_id = t.id
  join public.student_enrollments se
    on se.user_id = tm.user_id
   and se.group_id = t.group_id
   and se.status = 'active'
   and se.ended_at is null
  where t.id = p_team_id
    and coalesce(t.kind, 'subject') = 'subject'
    and t.group_id is not null
    and private.is_active_subject_team_for_group(t.id, t.group_id)
    and not exists (
      select 1
      from public.chats c
      join public.chat_academic_archives a on a.chat_id = c.id
      where c.team_id = t.id and c.type = 'team_main'
    );
$$;

revoke all on function private.active_team_member_user_ids(uuid)
  from public, anon, authenticated;

create or replace function private._utc_day_bucket()
returns text
language sql
stable
set search_path = ''
as $$
  select to_char((now() at time zone 'UTC')::date, 'YYYY-MM-DD');
$$;

revoke all on function private._utc_day_bucket() from public, anon, authenticated;

create or replace function private._safe_group_action_push_data(
  p_event_type text,
  p_chat_id uuid,
  p_team_id uuid,
  p_selection_id uuid default null,
  p_collection_id uuid default null,
  p_card_message_id uuid default null
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'version', 1,
    'type', p_event_type,
    'chat_id', p_chat_id,
    'team_id', p_team_id,
    'selection_id', p_selection_id,
    'collection_id', p_collection_id,
    'card_message_id', p_card_message_id
  ));
$$;

revoke all on function private._safe_group_action_push_data(
  text, uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated;

create or replace function private._enqueue_group_action_team_broadcast(
  p_team_id uuid,
  p_chat_id uuid,
  p_actor_id uuid,
  p_event_type text,
  p_title text,
  p_body text,
  p_selection_id uuid,
  p_collection_id uuid,
  p_card_message_id uuid,
  p_source_id text,
  p_idempotency_prefix text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recipient uuid;
  v_data jsonb;
begin
  if p_chat_id is not null and public._chat_is_academically_archived(p_chat_id) then
    return;
  end if;

  v_data := private._safe_group_action_push_data(
    p_event_type,
    p_chat_id,
    p_team_id,
    p_selection_id,
    p_collection_id,
    p_card_message_id
  );

  for v_recipient in
    select uid from private.active_team_member_user_ids(p_team_id) as uid
    where p_actor_id is null or uid is distinct from p_actor_id
  loop
    perform public._enqueue_app_notification(
      v_recipient,
      p_event_type,
      p_title,
      p_body,
      v_data,
      p_source_id,
      p_idempotency_prefix || ':' || v_recipient::text,
      true
    );
  end loop;
end;
$$;

revoke all on function private._enqueue_group_action_team_broadcast(
  uuid, uuid, uuid, text, text, text, uuid, uuid, uuid, text, text
) from public, anon, authenticated;

create or replace function private._enqueue_group_action_single(
  p_recipient_id uuid,
  p_actor_id uuid,
  p_event_type text,
  p_title text,
  p_body text,
  p_chat_id uuid,
  p_team_id uuid,
  p_selection_id uuid,
  p_collection_id uuid,
  p_card_message_id uuid,
  p_source_id text,
  p_idempotency_key text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_data jsonb;
begin
  if p_recipient_id is null then
    return;
  end if;
  if p_actor_id is not null and p_recipient_id = p_actor_id then
    return;
  end if;
  if p_chat_id is not null and public._chat_is_academically_archived(p_chat_id) then
    return;
  end if;
  if p_team_id is not null
     and not exists (
       select 1
       from private.active_team_member_user_ids(p_team_id) uid
       where uid = p_recipient_id
     ) then
    return;
  end if;

  v_data := private._safe_group_action_push_data(
    p_event_type,
    p_chat_id,
    p_team_id,
    p_selection_id,
    p_collection_id,
    p_card_message_id
  );

  perform public._enqueue_app_notification(
    p_recipient_id,
    p_event_type,
    p_title,
    p_body,
    v_data,
    p_source_id,
    p_idempotency_key,
    true
  );
end;
$$;

revoke all on function private._enqueue_group_action_single(
  uuid, uuid, text, text, text, uuid, uuid, uuid, uuid, uuid, text, text
) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3) Delivery gate for new event types
-- ---------------------------------------------------------------------------
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
  v_team_id uuid;
  v_peer_id uuid;
  v_author_id uuid;
  v_allow boolean := true;
  v_reason text := null;
  v_title text;
  v_body text;
  v_is_group_action boolean := false;
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
  v_team_id := nullif(v_data->>'team_id', '')::uuid;
  v_peer_id := nullif(v_data->>'peer_id', '')::uuid;
  v_author_id := nullif(v_data->>'author_id', '')::uuid;
  v_title := v_outbox.payload->>'title';
  v_body := v_outbox.payload->>'body';
  v_is_group_action := v_outbox.event_type in (
    'topic_selection_created',
    'topic_deadline_soon',
    'topic_reassigned',
    'topic_pick_changed',
    'collection_created',
    'collection_deadline_soon',
    'collection_contribution_private'
  );

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

  -- Re-check membership at delivery time (user may have left after enqueue).
  if v_is_group_action then
    if v_team_id is null and v_chat_id is not null then
      select c.team_id into v_team_id
      from public.chats c
      where c.id = v_chat_id;
    end if;
    if v_team_id is null
       or not exists (
         select 1
         from private.active_team_member_user_ids(v_team_id) uid
         where uid = v_outbox.recipient_id
       ) then
      return jsonb_build_object('allow', false, 'reason', 'not_member');
    end if;
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
    when 'topic_selection_created',
         'topic_deadline_soon',
         'topic_reassigned',
         'topic_pick_changed',
         'collection_created',
         'collection_deadline_soon',
         'collection_contribution_private' then
      v_allow := coalesce(v_prefs.group_actions, true);
    else v_allow := true;
  end case;

  if not v_allow then
    v_reason := 'preference_disabled';
  end if;

  if not coalesce(v_prefs.show_message_preview, true) then
    if v_outbox.event_type = 'dm_message' then
      v_body := 'Новое сообщение';
    elsif v_outbox.event_type in ('team_message', 'team_reply') then
      v_body := 'Новое сообщение в учебном чате';
    elsif v_outbox.event_type in (
      'topic_selection_created',
      'collection_created',
      'topic_deadline_soon',
      'collection_deadline_soon',
      'topic_reassigned',
      'topic_pick_changed',
      'collection_contribution_private'
    ) then
      v_body := 'Новое действие в группе';
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

-- ---------------------------------------------------------------------------
-- 4) RPC hooks: publish / create / reassign / release / confirm
-- ---------------------------------------------------------------------------
create or replace function public.publish_topic_selection_for_chat(
  p_chat_id uuid,
  p_title text,
  p_description text default '',
  p_deadline_at timestamptz default null,
  p_completion_deadline_at timestamptz default null,
  p_allow_change boolean default true,
  p_show_results_to_all boolean default true,
  p_source_file_id uuid default null,
  p_options jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team public.teams%rowtype;
  v_chat public.chats%rowtype;
  v_selection_id uuid;
  v_message_id uuid;
  v_option jsonb;
  v_sort integer := 0;
  v_option_count integer := 0;
  v_title text := btrim(coalesce(p_title, ''));
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if v_title = '' then
    raise exception 'title_required' using errcode = '22023';
  end if;

  select * into v_chat from public.chats where id = p_chat_id for update;
  if not found or v_chat.type <> 'team_main' or v_chat.team_id is null then
    raise exception 'invalid_chat' using errcode = '22023';
  end if;

  select * into v_team from public.teams where id = v_chat.team_id for update;
  if not found or coalesce(v_team.kind, 'subject') = 'dm' then
    raise exception 'invalid_team' using errcode = '22023';
  end if;
  if not private.can_manage_team_topics(v_team.id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.chat_academic_archives a where a.chat_id = p_chat_id
  ) then
    raise exception 'chat_archived' using errcode = '42501';
  end if;

  if jsonb_typeof(coalesce(p_options, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(p_options) < 1
     or jsonb_array_length(p_options) > 200 then
    raise exception 'invalid_options' using errcode = '22023';
  end if;

  if p_source_file_id is not null and not exists (
    select 1
    from public.chat_files f
    where f.id = p_source_file_id
      and f.chat_id = p_chat_id
      and coalesce(f.is_sensitive, false) = false
  ) then
    raise exception 'invalid_source_file' using errcode = '22023';
  end if;

  insert into public.group_topic_selections(
    group_id, team_id, created_by, title, description, deadline_at,
    completion_deadline_at, allow_change, show_results_to_all, source_file_id, status
  ) values (
    v_team.group_id, v_team.id, auth.uid(), v_title, coalesce(p_description, ''),
    p_deadline_at, p_completion_deadline_at, coalesce(p_allow_change, true),
    coalesce(p_show_results_to_all, true), p_source_file_id, 'open'
  ) returning id into v_selection_id;

  for v_option in
    select value from jsonb_array_elements(p_options)
  loop
    v_sort := v_sort + 1;
    if btrim(coalesce(v_option->>'title', '')) = '' then
      continue;
    end if;
    insert into public.group_topic_options(selection_id, title, capacity, sort_order)
    values (
      v_selection_id,
      btrim(v_option->>'title'),
      greatest(1, coalesce((v_option->>'capacity')::integer, 1)),
      coalesce((v_option->>'sort_order')::integer, v_sort)
    );
    v_option_count := v_option_count + 1;
  end loop;

  if v_option_count < 1 then
    raise exception 'options_required' using errcode = '22023';
  end if;

  insert into public.messages(chat_id, author_id, body, content, msg_type)
  values (
    p_chat_id,
    auth.uid(),
    'Выбор темы: ' || v_title,
    jsonb_build_object(
      'card', 'topic_selection',
      'selection_id', v_selection_id
    ),
    'system'
  ) returning id into v_message_id;

  update public.group_topic_selections
  set card_message_id = v_message_id, updated_at = now()
  where id = v_selection_id;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    v_selection_id,
    auth.uid(),
    'published',
    jsonb_build_object('option_count', v_option_count, 'message_id', v_message_id)
  );

  perform private._enqueue_group_action_team_broadcast(
    v_team.id,
    p_chat_id,
    auth.uid(),
    'topic_selection_created',
    'Выбор темы',
    'Опубликован выбор темы: ' || v_title,
    v_selection_id,
    null,
    v_message_id,
    v_selection_id::text,
    'topic_selection_created:' || v_selection_id::text
  );

  return jsonb_build_object(
    'selection_id', v_selection_id,
    'message_id', v_message_id,
    'option_count', v_option_count
  );
end;
$$;

create or replace function public.create_group_collection(
  p_title text,
  p_description text default '',
  p_purpose text default '',
  p_deadline_at timestamptz default null,
  p_amount_optional numeric default null,
  p_instructions text default '',
  p_payment_details text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid := private.current_active_group_id();
  v_team uuid;
  v_chat uuid;
  v_id uuid;
  v_message_id uuid;
  v_title text := btrim(coalesce(p_title, ''));
begin
  v_team := private.group_space_team_id(v_group);
  if not private.can_manage_team_collections(v_team) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_chat := private.team_main_chat_id(v_team);

  insert into public.group_collections(
    group_id, team_id, created_by, title, description, purpose, deadline_at,
    amount_optional, instructions, status
  ) values (
    v_group, v_team, auth.uid(), v_title, coalesce(p_description, ''),
    coalesce(p_purpose, ''), p_deadline_at, p_amount_optional,
    left(coalesce(p_instructions, ''), 4000),
    'open'
  ) returning id into v_id;

  if btrim(coalesce(p_payment_details, '')) <> '' then
    insert into public.group_collection_secrets(collection_id, payment_details)
    values (v_id, left(btrim(p_payment_details), 2000));
  end if;

  if v_chat is not null then
    insert into public.messages(chat_id, author_id, body, content, msg_type)
    values (
      v_chat,
      auth.uid(),
      'Сбор: ' || v_title,
      jsonb_build_object('card', 'collection', 'collection_id', v_id),
      'system'
    ) returning id into v_message_id;

    update public.group_collections
    set card_message_id = v_message_id, updated_at = now()
    where id = v_id;
  end if;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    v_id,
    auth.uid(),
    'created',
    jsonb_build_object('has_payment_details', btrim(coalesce(p_payment_details, '')) <> '')
  );

  perform private._enqueue_group_action_team_broadcast(
    v_team,
    v_chat,
    auth.uid(),
    'collection_created',
    'Новый сбор',
    'Создан сбор: ' || v_title,
    null,
    v_id,
    v_message_id,
    v_id::text,
    'collection_created:' || v_id::text
  );

  return v_id;
end;
$$;

create or replace function public.reassign_topic_pick(
  p_selection_id uuid,
  p_user_id uuid,
  p_option_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
  v_capacity integer;
  v_count integer;
  v_prev uuid;
  v_chat uuid;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_topics(v_selection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_selection.status <> 'open'
     or (v_selection.deadline_at is not null and v_selection.deadline_at <= now()) then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;
  if not private.is_active_team_member(v_selection.team_id)
     or not exists (
       select 1 from public.team_members tm
       where tm.team_id = v_selection.team_id and tm.user_id = p_user_id
     ) then
    if not (
      exists (
        select 1 from public.teams t
        where t.id = v_selection.team_id and t.kind = 'group_space'
      )
      and exists (
        select 1 from public.student_enrollments se
        where se.user_id = p_user_id
          and se.group_id = v_selection.group_id
          and se.status = 'active'
          and se.ended_at is null
      )
    ) then
      raise exception 'target_not_member' using errcode = '42501';
    end if;
  end if;

  select capacity into v_capacity
  from public.group_topic_options
  where id = p_option_id and selection_id = p_selection_id
  for update;
  if v_capacity is null then
    raise exception 'invalid_option' using errcode = '22023';
  end if;

  select option_id into v_prev
  from public.group_topic_picks
  where selection_id = p_selection_id and user_id = p_user_id
  for update;

  select count(*) into v_count
  from public.group_topic_picks
  where selection_id = p_selection_id
    and option_id = p_option_id
    and user_id is distinct from p_user_id;
  if v_count >= v_capacity then
    raise exception 'option_full' using errcode = 'P0001';
  end if;

  delete from public.group_topic_picks
  where selection_id = p_selection_id and user_id = p_user_id;

  insert into public.group_topic_picks(selection_id, option_id, user_id)
  values (p_selection_id, p_option_id, p_user_id);

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id,
    auth.uid(),
    'reassigned',
    jsonb_build_object(
      'user_id', p_user_id,
      'previous_option_id', v_prev,
      'option_id', p_option_id
    )
  );

  v_chat := private.team_main_chat_id(v_selection.team_id);

  perform private._enqueue_group_action_single(
    p_user_id,
    auth.uid(),
    'topic_reassigned',
    'Тема назначена',
    'Вам назначена тема в «' || v_selection.title || '»',
    v_chat,
    v_selection.team_id,
    p_selection_id,
    null,
    v_selection.card_message_id,
    p_selection_id::text,
    'topic_reassigned:' || p_selection_id::text || ':' || p_user_id::text || ':' || p_option_id::text
  );
end;
$$;

create or replace function public.release_topic_pick(
  p_selection_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
  v_chat uuid;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_topics(v_selection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.group_topic_picks
  where selection_id = p_selection_id and user_id = p_user_id;
  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id,
    auth.uid(),
    'released',
    jsonb_build_object('user_id', p_user_id)
  );

  v_chat := private.team_main_chat_id(v_selection.team_id);

  perform private._enqueue_group_action_single(
    p_user_id,
    auth.uid(),
    'topic_pick_changed',
    'Тема снята',
    'Ваш выбор темы снят в «' || v_selection.title || '»',
    v_chat,
    v_selection.team_id,
    p_selection_id,
    null,
    v_selection.card_message_id,
    p_selection_id::text,
    'topic_pick_changed:' || p_selection_id::text || ':' || p_user_id::text || ':release'
  );
end;
$$;

create or replace function public.confirm_collection_contribution(
  p_collection_id uuid,
  p_user_id uuid,
  p_payment_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_updated integer;
  v_chat uuid;
begin
  select * into v_collection
  from public.group_collections
  where id = p_collection_id
  for update;
  if not found then
    raise exception 'collection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_collections(v_collection.team_id)
     or p_payment_status not in ('confirmed', 'rejected') then
    raise exception 'forbidden_or_invalid_status' using errcode = '42501';
  end if;

  update public.group_collection_contributions
  set payment_status = p_payment_status, updated_at = now()
  where collection_id = p_collection_id and user_id = p_user_id;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'contribution_not_found' using errcode = 'P0002';
  end if;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id,
    auth.uid(),
    'payment_reviewed',
    jsonb_build_object('user_id', p_user_id, 'status', p_payment_status)
  );

  if p_payment_status = 'confirmed' then
    v_chat := private.team_main_chat_id(v_collection.team_id);
    perform private._enqueue_group_action_single(
      p_user_id,
      auth.uid(),
      'collection_contribution_private',
      'Взнос подтверждён',
      'Организатор подтвердил ваш взнос в «' || v_collection.title || '»',
      v_chat,
      v_collection.team_id,
      null,
      p_collection_id,
      v_collection.card_message_id,
      p_collection_id::text,
      'collection_contribution_private:' || p_collection_id::text || ':' || p_user_id::text || ':confirmed'
    );
  end if;
end;
$$;

grant execute on function public.confirm_collection_contribution(uuid, uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) Deadline worker (24h UTC bucket dedupe, advisory lock)
-- ---------------------------------------------------------------------------
create or replace function public.run_group_action_deadline_notifications()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bucket text := private._utc_day_bucket();
  v_topic record;
  v_collection record;
  v_recipient uuid;
  v_chat uuid;
  v_enqueued integer := 0;
begin
  if not pg_try_advisory_lock(hashtext('stage13_9_group_action_deadline_worker')) then
    return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'locked');
  end if;

  begin
    for v_topic in
      select s.id, s.team_id, s.title, s.deadline_at, s.card_message_id
      from public.group_topic_selections s
      where s.status = 'open'
        and s.deadline_at is not null
        and s.deadline_at > now()
        and s.deadline_at <= now() + interval '24 hours'
    loop
      v_chat := private.team_main_chat_id(v_topic.team_id);
      if v_chat is not null and public._chat_is_academically_archived(v_chat) then
        continue;
      end if;

      for v_recipient in
        select uid from private.active_team_member_user_ids(v_topic.team_id) as uid
      loop
        perform public._enqueue_app_notification(
          v_recipient,
          'topic_deadline_soon',
          'Срок выбора темы',
          'До дедлайна «' || v_topic.title || '» меньше суток',
          private._safe_group_action_push_data(
            'topic_deadline_soon',
            v_chat,
            v_topic.team_id,
            v_topic.id,
            null,
            v_topic.card_message_id
          ),
          v_topic.id::text,
          'topic_deadline_soon:' || v_topic.id::text || ':' || v_recipient::text || ':' || v_bucket,
          true
        );
        v_enqueued := v_enqueued + 1;
      end loop;
    end loop;

    for v_collection in
      select c.id, c.team_id, c.title, c.deadline_at, c.card_message_id
      from public.group_collections c
      where c.status = 'open'
        and c.deadline_at is not null
        and c.deadline_at > now()
        and c.deadline_at <= now() + interval '24 hours'
    loop
      v_chat := private.team_main_chat_id(v_collection.team_id);
      if v_chat is not null and public._chat_is_academically_archived(v_chat) then
        continue;
      end if;

      for v_recipient in
        select uid from private.active_team_member_user_ids(v_collection.team_id) as uid
      loop
        perform public._enqueue_app_notification(
          v_recipient,
          'collection_deadline_soon',
          'Срок сбора',
          'До дедлайна «' || v_collection.title || '» меньше суток',
          private._safe_group_action_push_data(
            'collection_deadline_soon',
            v_chat,
            v_collection.team_id,
            null,
            v_collection.id,
            v_collection.card_message_id
          ),
          v_collection.id::text,
          'collection_deadline_soon:' || v_collection.id::text || ':' || v_recipient::text || ':' || v_bucket,
          true
        );
        v_enqueued := v_enqueued + 1;
      end loop;
    end loop;
  exception
    when others then
      perform pg_advisory_unlock(hashtext('stage13_9_group_action_deadline_worker'));
      raise;
  end;

  perform pg_advisory_unlock(hashtext('stage13_9_group_action_deadline_worker'));

  return jsonb_build_object(
    'ok', true,
    'bucket', v_bucket,
    'attempted', v_enqueued
  );
end;
$$;

revoke all on function public.run_group_action_deadline_notifications()
  from public, anon, authenticated;
grant execute on function public.run_group_action_deadline_notifications()
  to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid)
    from cron.job
    where jobname = 'group-action-deadline-notifications';

    perform cron.schedule(
      'group-action-deadline-notifications',
      '15 * * * *',
      $cron$select public.run_group_action_deadline_notifications();$cron$
    );
  end if;
exception
  when others then
    raise notice 'Skipping group-action-deadline-notifications cron: %', sqlerrm;
end $$;

commit;
