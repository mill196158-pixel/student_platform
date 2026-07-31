-- Stage 13.10 — group actions UX matrix, composer capabilities, one deadline,
-- collection payment status machine. Local only; do not remote-apply without owner.

-- ---------------------------------------------------------------------------
-- 1) Topics are subject-team only (managers). Collections remain group_space.
-- ---------------------------------------------------------------------------
create or replace function private.can_manage_team_topics(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_team_member(p_team_id)
    and exists (
      select 1
      from public.teams t
      where t.id = p_team_id
        and coalesce(t.kind, 'subject') = 'subject'
        and exists (
          select 1
          from public.team_members tm
          where tm.team_id = t.id
            and tm.user_id = auth.uid()
            and lower(coalesce(tm.role, '')) in ('starosta', 'owner')
        )
    );
$$;

revoke all on function private.can_manage_team_topics(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Collection payment statuses: 5 product states + legacy aliases.
-- ---------------------------------------------------------------------------
alter table public.group_collection_contributions
  drop constraint if exists group_collection_contributions_payment_status_check;

alter table public.group_collection_contributions
  add constraint group_collection_contributions_payment_status_check
  check (
    payment_status in (
      'unmarked',
      'pending_review', -- legacy alias of reported
      'reported',
      'confirmed',
      'rejected', -- legacy; prefer not_received / needs_clarification
      'not_received',
      'needs_clarification'
    )
  );

-- Normalize legacy rejected → needs_clarification only when organizer notes
-- are absent; keep rejected readable via UI mapping. No destructive remap of
-- pending_review (UI maps to «Участник сообщил»).

-- ---------------------------------------------------------------------------
-- 3) Composer capabilities SoT
-- ---------------------------------------------------------------------------
create or replace function public.get_chat_composer_capabilities(p_chat_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_chat public.chats%rowtype;
  v_team public.teams%rowtype;
  v_kind text;
  v_is_dm boolean := false;
  v_is_member boolean := false;
  v_is_active_subject boolean := false;
  v_can_propose boolean := false;
  v_can_manage_assignments boolean := false;
  v_can_topic boolean := false;
  v_can_collection boolean := false;
  v_show_propose boolean := false;
  v_show_topic boolean := false;
  v_show_collection boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_chat from public.chats where id = p_chat_id;
  if not found then
    raise exception 'chat_not_found' using errcode = 'P0002';
  end if;

  -- DM: never reveal team metadata; no group actions / assignments.
  if v_chat.type = 'dm' or v_chat.team_id is null then
    return jsonb_build_object(
      'chat_type', 'dm',
      'team_kind', 'dm',
      'is_active_member', false,
      'is_active_subject_team', false,
      'show_propose_assignment', false,
      'show_topic_selection', false,
      'show_collection', false,
      'can_propose_assignment', false,
      'can_manage_assignments', false,
      'can_create_topic_selection', false,
      'can_create_collection', false,
      'reasons', jsonb_build_object(
        'propose_assignment', 'dm_not_allowed',
        'topic_selection', 'dm_not_allowed',
        'collection', 'dm_not_allowed'
      )
    );
  end if;

  select * into v_team from public.teams where id = v_chat.team_id;
  if not found then
    raise exception 'team_not_found' using errcode = 'P0002';
  end if;

  v_kind := coalesce(v_team.kind, 'subject');
  if v_kind = 'dm' then
    v_is_dm := true;
  end if;

  v_is_member := private.is_active_team_member(v_team.id);

  if v_kind = 'subject' then
    v_is_active_subject := v_is_member
      and v_team.group_id is not null
      and private.is_active_subject_team_for_group(v_team.id, v_team.group_id)
      and not exists (
        select 1
        from public.chat_academic_archives a
        where a.chat_id = v_chat.id
      );
  end if;

  v_can_manage_assignments := v_is_member and exists (
    select 1
    from public.team_members tm
    where tm.team_id = v_team.id
      and tm.user_id = v_uid
      and lower(coalesce(tm.role, '')) in ('starosta', 'owner', 'teacher', 'admin')
  );

  -- Ordinary members may propose drafts; organizers/trusted auto-publish server-side.
  v_can_propose := v_is_member
    and v_chat.type = 'team_main'
    and not v_is_dm
    and (
      v_kind = 'group_space'
      or v_is_active_subject
    );

  v_can_topic := private.can_manage_team_topics(v_team.id);
  v_can_collection := private.can_manage_team_collections(v_team.id);

  -- Structural visibility (always show in menu for this chat kind; auth gates enable).
  v_show_propose := not v_is_dm and v_chat.type = 'team_main'
    and (v_kind = 'group_space' or v_kind = 'subject');
  v_show_topic := v_kind = 'subject';
  v_show_collection := v_kind = 'group_space';

  return jsonb_build_object(
    'chat_type', case when v_chat.type = 'team_main' then 'team' else v_chat.type end,
    'team_kind', v_kind,
    'is_active_member', v_is_member,
    'is_active_subject_team', v_is_active_subject,
    'show_propose_assignment', v_show_propose,
    'show_topic_selection', v_show_topic,
    'show_collection', v_show_collection,
    'can_propose_assignment', v_can_propose,
    'can_manage_assignments', v_can_manage_assignments,
    'can_create_topic_selection', v_can_topic,
    'can_create_collection', v_can_collection,
    'reasons', jsonb_build_object(
      'propose_assignment', case
        when v_is_dm then 'dm_not_allowed'
        when not v_is_member then 'not_member'
        when v_kind = 'subject' and not v_is_active_subject then 'subject_inactive'
        when not v_can_propose then 'forbidden'
        else null
      end,
      'topic_selection', case
        when v_is_dm then 'dm_not_allowed'
        when v_kind = 'group_space' then 'group_space_not_allowed'
        when v_kind <> 'subject' then 'invalid_chat'
        when not v_is_active_subject then 'subject_inactive'
        when not v_can_topic then 'not_organizer'
        else null
      end,
      'collection', case
        when v_is_dm then 'dm_not_allowed'
        when v_kind <> 'group_space' then 'subject_not_allowed'
        when not v_is_member then 'not_member'
        when not v_can_collection then 'not_organizer'
        else null
      end
    )
  );
end;
$$;

revoke all on function public.get_chat_composer_capabilities(uuid)
  from public, anon;
grant execute on function public.get_chat_composer_capabilities(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) publish_topic_selection_for_chat — subject-only + one canonical deadline
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
  v_deadline timestamptz;
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
  if not found then
    raise exception 'invalid_team' using errcode = '22023';
  end if;
  if coalesce(v_team.kind, 'subject') <> 'subject' then
    raise exception 'topic_selection_subject_only' using errcode = '42501';
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

  -- Canonical deadline: prefer deadline_at; accept legacy completion as fallback.
  -- New rows never write completion_deadline_at (leave NULL).
  v_deadline := coalesce(p_deadline_at, p_completion_deadline_at);

  insert into public.group_topic_selections(
    group_id, team_id, created_by, title, description, deadline_at,
    completion_deadline_at, allow_change, show_results_to_all, source_file_id, status
  ) values (
    v_team.group_id, v_team.id, auth.uid(), v_title, coalesce(p_description, ''),
    v_deadline, null, coalesce(p_allow_change, true),
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
    'text'
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

  return jsonb_build_object(
    'selection_id', v_selection_id,
    'message_id', v_message_id,
    'option_count', v_option_count
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) Close legacy group-space topic create / option write paths
-- ---------------------------------------------------------------------------
create or replace function public.create_topic_selection(
  p_title text,
  p_description text default '',
  p_deadline_at timestamptz default null,
  p_allow_change boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Stage 13.10: topic selection is subject-team only; legacy group-space
  -- shell create is retired (existing rows remain readable).
  raise exception 'topic_selection_subject_only' using errcode = '42501';
end;
$$;

create or replace function public.add_topic_option(
  p_selection_id uuid,
  p_title text,
  p_capacity integer,
  p_sort_order integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
  v_id uuid;
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
  insert into public.group_topic_options(selection_id, title, capacity, sort_order)
  values (
    p_selection_id,
    btrim(coalesce(p_title, '')),
    greatest(1, coalesce(p_capacity, 1)),
    coalesce(p_sort_order, 0)
  )
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6) Collection contribution FSM
-- ---------------------------------------------------------------------------
create or replace function public.upsert_my_collection_contribution(
  p_collection_id uuid,
  p_participation_status text default 'unmarked',
  p_payment_status text default 'unmarked',
  p_amount numeric default null,
  p_comment text default '',
  p_proof_file_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_existing public.group_collection_contributions%rowtype;
  v_id uuid;
  v_status text := coalesce(p_payment_status, 'unmarked');
begin
  select * into v_collection
  from public.group_collections
  where id = p_collection_id
  for update;
  if not found or v_collection.status <> 'open'
     or not private.is_active_team_member(v_collection.team_id) then
    raise exception 'collection_unavailable' using errcode = '42501';
  end if;

  -- Accept legacy pending_review as reported.
  if v_status = 'pending_review' then
    v_status := 'reported';
  end if;
  if v_status not in ('unmarked', 'reported') then
    raise exception 'invalid_payment_status' using errcode = '22023';
  end if;

  select * into v_existing
  from public.group_collection_contributions
  where collection_id = p_collection_id and user_id = auth.uid()
  for update;

  -- Participant cannot escalate to organizer statuses or undo confirmed alone.
  if found and v_existing.payment_status in (
    'confirmed', 'not_received', 'needs_clarification', 'rejected'
  ) and v_status = 'unmarked' then
    -- Allow return to unmarked only from reported; organizer states need organizer RPC.
    raise exception 'organizer_status_locked' using errcode = '42501';
  end if;
  if found and v_existing.payment_status = 'confirmed' then
    raise exception 'already_confirmed' using errcode = '42501';
  end if;

  if p_proof_file_id is not null and not exists (
    select 1
    from public.chat_files cf
    join public.chats ch on ch.id = cf.chat_id
    where cf.id = p_proof_file_id
      and cf.uploaded_by = auth.uid()
      and ch.team_id = v_collection.team_id
      and ch.type = 'team_main'
  ) then
    raise exception 'invalid_proof_file' using errcode = '22023';
  end if;
  if p_proof_file_id is not null then
    update public.chat_files set is_sensitive = true where id = p_proof_file_id;
  end if;

  insert into public.group_collection_contributions(
    collection_id, user_id, participation_status, payment_status, amount, comment, proof_file_id
  ) values (
    p_collection_id, auth.uid(), p_participation_status, v_status, p_amount,
    coalesce(p_comment, ''), p_proof_file_id
  )
  on conflict (collection_id, user_id) do update
  set participation_status = excluded.participation_status,
      payment_status = excluded.payment_status,
      amount = excluded.amount,
      comment = excluded.comment,
      proof_file_id = coalesce(excluded.proof_file_id, public.group_collection_contributions.proof_file_id),
      updated_at = now()
  returning id into v_id;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id,
    auth.uid(),
    'contribution_upserted',
    jsonb_build_object(
      'participation_status', p_participation_status,
      'payment_status', v_status,
      'has_proof', p_proof_file_id is not null
      -- never log requisites / proof URLs / file ids in push; event payload ok for audit
    )
  );
  return v_id;
end;
$$;

-- Replace 3-arg with 4-arg (default null) so existing callers keep working.
drop function if exists public.confirm_collection_contribution(uuid, uuid, text);

create or replace function public.confirm_collection_contribution(
  p_collection_id uuid,
  p_user_id uuid,
  p_payment_status text,
  p_organizer_comment text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_chat uuid;
  v_status text := coalesce(p_payment_status, '');
  v_prev text;
  v_found boolean := false;
begin
  select * into v_collection
  from public.group_collections
  where id = p_collection_id
  for update;
  if not found then
    raise exception 'collection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_collections(v_collection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Legacy rejected → needs_clarification unless explicitly not_received.
  if v_status = 'rejected' then
    v_status := 'needs_clarification';
  end if;
  if v_status not in (
    'confirmed', 'not_received', 'needs_clarification', 'reported', 'unmarked'
  ) then
    raise exception 'forbidden_or_invalid_status' using errcode = '42501';
  end if;

  select payment_status into v_prev
  from public.group_collection_contributions
  where collection_id = p_collection_id and user_id = p_user_id
  for update;
  v_found := found;

  if not v_found then
    -- Manual mark: organizer may insert a row for a member.
    insert into public.group_collection_contributions(
      collection_id, user_id, participation_status, payment_status, comment
    ) values (
      p_collection_id,
      p_user_id,
      'joining',
      v_status,
      coalesce(p_organizer_comment, '')
    );
  else
    update public.group_collection_contributions
    set payment_status = v_status,
        comment = case
          when p_organizer_comment is null then comment
          else p_organizer_comment
        end,
        updated_at = now()
    where collection_id = p_collection_id and user_id = p_user_id;
  end if;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id,
    auth.uid(),
    'payment_reviewed',
    jsonb_build_object(
      'user_id', p_user_id,
      'status', v_status,
      'prev_status', v_prev,
      'has_comment', p_organizer_comment is not null and btrim(p_organizer_comment) <> ''
    )
  );

  if v_status = 'confirmed' then
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

revoke all on function public.confirm_collection_contribution(uuid, uuid, text, text)
  from public, anon;
grant execute on function public.confirm_collection_contribution(uuid, uuid, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7) Deadline read compat: coalesce(deadline_at, completion_deadline_at)
--    Preserve Stage 13.9 JSON shape (incl. payload).
-- ---------------------------------------------------------------------------
create or replace function public.list_my_group_action_deadlines(
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with bounds as (
    select
      coalesce(p_from, now() - interval '30 days') as d_from,
      coalesce(p_to, now() + interval '180 days') as d_to
  ),
  topic_items as (
    select
      'topic_deadline'::text as event_type,
      s.id as entity_id,
      s.title,
      coalesce(s.deadline_at, s.completion_deadline_at) as occurs_at,
      private.team_main_chat_id(s.team_id) as chat_id,
      s.team_id,
      s.group_id,
      t.name as team_name,
      s.status as action_status,
      (
        select o.title
        from public.group_topic_picks p
        join public.group_topic_options o on o.id = p.option_id
        where p.selection_id = s.id and p.user_id = auth.uid()
        limit 1
      ) as my_pick_text,
      jsonb_build_object('selection_id', s.id, 'card_message_id', s.card_message_id) as payload
    from public.group_topic_selections s
    join public.teams t on t.id = s.team_id
    cross join bounds b
    where s.status = 'open'
      and coalesce(t.kind, 'subject') = 'subject'
      and coalesce(s.deadline_at, s.completion_deadline_at) is not null
      and coalesce(s.deadline_at, s.completion_deadline_at) between b.d_from and b.d_to
      and private.is_active_team_member(s.team_id)
  ),
  collection_items as (
    select
      'collection_deadline'::text as event_type,
      c.id as entity_id,
      c.title,
      c.deadline_at as occurs_at,
      private.team_main_chat_id(c.team_id) as chat_id,
      c.team_id,
      c.group_id,
      t.name as team_name,
      c.status as action_status,
      case
        when cc.payment_status in ('confirmed') then 'Перевод получен'
        when cc.payment_status in ('reported', 'pending_review') then 'Отметил перевод'
        when cc.payment_status in ('not_received') then 'Не поступило'
        when cc.payment_status in ('needs_clarification', 'rejected') then 'Нужно уточнение'
        when cc.participation_status = 'joining' then 'Участвую'
        when cc.participation_status = 'declined' then 'Не участвую'
        else null
      end as my_pick_text,
      jsonb_build_object('collection_id', c.id, 'card_message_id', c.card_message_id) as payload
    from public.group_collections c
    join public.teams t on t.id = c.team_id
    left join public.group_collection_contributions cc
      on cc.collection_id = c.id and cc.user_id = auth.uid()
    cross join bounds b
    where c.status = 'open'
      and c.deadline_at is not null
      and c.deadline_at between b.d_from and b.d_to
      and private.is_active_team_member(c.team_id)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'event_type', x.event_type,
        'entity_id', x.entity_id,
        'title', x.title,
        'occurs_at', x.occurs_at,
        'chat_id', x.chat_id,
        'team_id', x.team_id,
        'group_id', x.group_id,
        'team_name', x.team_name,
        'status', x.action_status,
        'my_pick_text', x.my_pick_text,
        'payload', x.payload
      )
      order by x.occurs_at nulls last
    ),
    '[]'::jsonb
  )
  from (
    select * from topic_items
    union all
    select * from collection_items
  ) x;
$$;

revoke all on function public.list_my_group_action_deadlines(timestamptz, timestamptz)
  from public, anon;
grant execute on function public.list_my_group_action_deadlines(timestamptz, timestamptz)
  to authenticated, service_role;

revoke all on function
  public.publish_topic_selection_for_chat(uuid, text, text, timestamptz, timestamptz, boolean, boolean, uuid, jsonb),
  public.create_topic_selection(text, text, timestamptz, boolean),
  public.add_topic_option(uuid, text, integer, integer),
  public.upsert_my_collection_contribution(uuid, text, text, numeric, text, uuid)
from public, anon;

grant execute on function
  public.publish_topic_selection_for_chat(uuid, text, text, timestamptz, timestamptz, boolean, boolean, uuid, jsonb),
  public.create_topic_selection(text, text, timestamptz, boolean),
  public.add_topic_option(uuid, text, integer, integer),
  public.upsert_my_collection_contribution(uuid, text, text, numeric, text, uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8) Codex P1: harden assignment write RPCs (membership + chat kind)
-- ---------------------------------------------------------------------------
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
set search_path = ''
as $$
declare
  v_assignment_id uuid;
  v_message_id uuid;
  v_chat uuid;
  v_user uuid := auth.uid();
  v_team public.teams%rowtype;
  v_is_trusted boolean := false;
  v_msg_type text := 'assignmentDraft';
  v_status text := 'draft';
  v_kind text;
begin
  if v_user is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'title_required' using errcode = '22023';
  end if;

  select * into v_team from public.teams where id = p_team_id;
  if not found then
    raise exception 'team_not_found' using errcode = 'P0002';
  end if;
  v_kind := coalesce(v_team.kind, 'subject');
  if v_kind = 'dm' then
    raise exception 'dm_not_allowed' using errcode = '42501';
  end if;
  if not private.is_active_team_member(p_team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_kind = 'subject'
     and not (
       v_team.group_id is not null
       and private.is_active_subject_team_for_group(v_team.id, v_team.group_id)
     ) then
    raise exception 'subject_inactive' using errcode = '42501';
  end if;

  select id into v_chat
  from public.chats
  where team_id = p_team_id and type = 'team_main'
  limit 1;
  if v_chat is null then
    raise exception 'team_main_chat_not_found' using errcode = 'P0002';
  end if;
  if exists (
    select 1 from public.chat_academic_archives a where a.chat_id = v_chat
  ) then
    raise exception 'chat_archived' using errcode = '42501';
  end if;

  select exists(
    select 1
    from public.team_members tm
    where tm.team_id = p_team_id
      and tm.user_id = v_user
      and lower(coalesce(tm.role, '')) in ('starosta', 'teacher', 'admin', 'owner')
  ) into v_is_trusted;

  if v_is_trusted then
    v_msg_type := 'assignmentPublished';
    v_status := 'published';
  end if;

  insert into public.assignments(
    team_id, author_id, created_by, title, body, description, link, due_text,
    attachments, status, published_at, group_id, subject_id, subject_offering_id,
    academic_year_id, academic_term_id, semester_number
  ) values (
    p_team_id, v_user, v_user, btrim(p_title), coalesce(p_description, ''),
    p_description, nullif(p_link, ''), nullif(p_due, ''),
    coalesce(p_attachments, '[]'::jsonb), v_status,
    case when v_is_trusted then now() else null end,
    v_team.group_id, v_team.subject_id, v_team.subject_offering_id,
    v_team.academic_year_id, v_team.academic_term_id, v_team.semester_number
  ) returning id into v_assignment_id;

  insert into public.messages(
    chat_id, author_id, content, body, type, msg_type, assignment_id, created_at
  ) values (
    v_chat, v_user,
    case when v_is_trusted then 'Новое задание: ' || btrim(p_title)
         else 'Черновик задания: ' || btrim(p_title) end,
    case when v_is_trusted then 'Новое задание: ' || btrim(p_title)
         else 'Черновик задания: ' || btrim(p_title) end,
    v_msg_type, v_msg_type, v_assignment_id, now()
  ) returning id into v_message_id;

  return jsonb_build_object(
    'assignment_id', v_assignment_id,
    'message_id', v_message_id,
    'msg_type', v_msg_type,
    'status', v_status,
    'published', v_is_trusted
  );
end;
$$;

revoke all on function public.propose_assignment(uuid, text, text, text, text, jsonb)
  from public, anon;
grant execute on function public.propose_assignment(uuid, text, text, text, text, jsonb)
  to authenticated, service_role;

create or replace function public.publish_assignment(p_assignment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team uuid;
  v_chat uuid;
  v_allowed boolean;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select team_id into v_team from public.assignments where id = p_assignment_id;
  if v_team is null then
    raise exception 'assignment_not_found' using errcode = 'P0002';
  end if;
  if not private.is_active_team_member(v_team) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select exists(
    select 1 from public.team_members tm
    where tm.team_id = v_team
      and tm.user_id = auth.uid()
      and lower(coalesce(tm.role, '')) in ('starosta', 'teacher', 'admin', 'owner')
  ) into v_allowed;
  if not v_allowed then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select id into v_chat from public.chats
  where team_id = v_team and type = 'team_main' limit 1;
  if v_chat is not null and exists (
    select 1 from public.chat_academic_archives a where a.chat_id = v_chat
  ) then
    raise exception 'chat_archived' using errcode = '42501';
  end if;

  update public.assignments
  set status = 'published', published_at = coalesce(published_at, now())
  where id = p_assignment_id;

  update public.messages
     set type = 'assignmentPublished',
         msg_type = 'assignmentPublished',
         content = regexp_replace(coalesce(content, ''), '^Черновик задания:', 'Новое задание:'),
         body = regexp_replace(coalesce(body, ''), '^Черновик задания:', 'Новое задание:')
   where assignment_id = p_assignment_id
     and coalesce(type, msg_type) = 'assignmentDraft';
end;
$$;

revoke all on function public.publish_assignment(uuid) from public, anon;
grant execute on function public.publish_assignment(uuid)
  to authenticated, service_role;

create or replace function public.vote_assignment(p_assignment_id uuid)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_team uuid;
  v_votes int;
begin
  if v_user is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select team_id into v_team from public.assignments where id = p_assignment_id;
  if v_team is null then
    raise exception 'assignment_not_found' using errcode = 'P0002';
  end if;
  if not private.is_active_team_member(v_team) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  insert into public.assignment_votes(assignment_id, user_id, value)
  values (p_assignment_id, v_user, 1)
  on conflict (assignment_id, user_id) do update set value = 1;

  select count(*) into v_votes
  from public.assignment_votes
  where assignment_id = p_assignment_id and value = 1;

  if v_votes >= 2 then
    update public.assignments
    set status = 'published', published_at = coalesce(published_at, now())
    where id = p_assignment_id and published_at is null;

    update public.messages
       set type = 'assignmentPublished',
           msg_type = 'assignmentPublished',
           content = regexp_replace(coalesce(content, ''), '^Черновик задания:', 'Новое задание:'),
           body = regexp_replace(coalesce(body, ''), '^Черновик задания:', 'Новое задание:')
     where assignment_id = p_assignment_id
       and coalesce(type, msg_type) = 'assignmentDraft';
  end if;

  return json_build_object('votes', v_votes, 'published', v_votes >= 2);
end;
$$;

revoke all on function public.vote_assignment(uuid) from public, anon;
grant execute on function public.vote_assignment(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9) Collection FSM: participant cannot overwrite organizer statuses
-- ---------------------------------------------------------------------------
create or replace function public.upsert_my_collection_contribution(
  p_collection_id uuid,
  p_participation_status text default 'unmarked',
  p_payment_status text default 'unmarked',
  p_amount numeric default null,
  p_comment text default '',
  p_proof_file_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_existing public.group_collection_contributions%rowtype;
  v_id uuid;
  v_status text := coalesce(p_payment_status, 'unmarked');
  v_found boolean := false;
begin
  select * into v_collection
  from public.group_collections
  where id = p_collection_id
  for update;
  if not found or v_collection.status <> 'open'
     or not private.is_active_team_member(v_collection.team_id) then
    raise exception 'collection_unavailable' using errcode = '42501';
  end if;

  if v_status = 'pending_review' then
    v_status := 'reported';
  end if;
  if v_status not in ('unmarked', 'reported') then
    raise exception 'invalid_payment_status' using errcode = '22023';
  end if;

  select * into v_existing
  from public.group_collection_contributions
  where collection_id = p_collection_id and user_id = auth.uid()
  for update;
  v_found := found;

  if v_found and v_existing.payment_status in (
    'confirmed', 'not_received', 'needs_clarification', 'rejected'
  ) then
    -- Organizer-owned status: participant may attach proof/comment only.
    if p_proof_file_id is not null then
      if not exists (
        select 1
        from public.chat_files cf
        join public.chats ch on ch.id = cf.chat_id
        where cf.id = p_proof_file_id
          and cf.uploaded_by = auth.uid()
          and ch.team_id = v_collection.team_id
          and ch.type = 'team_main'
      ) then
        raise exception 'invalid_proof_file' using errcode = '22023';
      end if;
      update public.chat_files set is_sensitive = true where id = p_proof_file_id;
    end if;
    update public.group_collection_contributions
    set comment = case
          when btrim(coalesce(p_comment, '')) = '' then comment
          else p_comment
        end,
        proof_file_id = coalesce(p_proof_file_id, proof_file_id),
        updated_at = now()
    where collection_id = p_collection_id and user_id = auth.uid()
    returning id into v_id;
    insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
    values (
      p_collection_id, auth.uid(), 'contribution_note_updated',
      jsonb_build_object(
        'payment_status', v_existing.payment_status,
        'has_proof', p_proof_file_id is not null
      )
    );
    return v_id;
  end if;

  if p_proof_file_id is not null then
    if not exists (
      select 1
      from public.chat_files cf
      join public.chats ch on ch.id = cf.chat_id
      where cf.id = p_proof_file_id
        and cf.uploaded_by = auth.uid()
        and ch.team_id = v_collection.team_id
        and ch.type = 'team_main'
    ) then
      raise exception 'invalid_proof_file' using errcode = '22023';
    end if;
    update public.chat_files set is_sensitive = true where id = p_proof_file_id;
  end if;

  insert into public.group_collection_contributions(
    collection_id, user_id, participation_status, payment_status, amount, comment, proof_file_id
  ) values (
    p_collection_id, auth.uid(), p_participation_status, v_status, p_amount,
    coalesce(p_comment, ''), p_proof_file_id
  )
  on conflict (collection_id, user_id) do update
  set participation_status = excluded.participation_status,
      payment_status = excluded.payment_status,
      amount = excluded.amount,
      comment = excluded.comment,
      proof_file_id = coalesce(excluded.proof_file_id, public.group_collection_contributions.proof_file_id),
      updated_at = now()
  returning id into v_id;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id, auth.uid(), 'contribution_upserted',
    jsonb_build_object(
      'participation_status', p_participation_status,
      'payment_status', v_status,
      'has_proof', p_proof_file_id is not null
    )
  );
  return v_id;
end;
$$;

-- Target membership required for organizer confirm/manual mark.
create or replace function public.confirm_collection_contribution(
  p_collection_id uuid,
  p_user_id uuid,
  p_payment_status text,
  p_organizer_comment text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_chat uuid;
  v_status text := coalesce(p_payment_status, '');
  v_prev text;
  v_found boolean := false;
begin
  select * into v_collection
  from public.group_collections
  where id = p_collection_id
  for update;
  if not found then
    raise exception 'collection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_collections(v_collection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- Target must be an active member of this collection's team.
  if not exists (
    select 1
    from public.teams t
    where t.id = v_collection.team_id
      and t.kind = 'group_space'
      and t.group_id is not null
      and exists (
        select 1
        from public.student_enrollments se
        where se.user_id = p_user_id
          and se.group_id = t.group_id
          and se.status = 'active'
          and se.ended_at is null
      )
  ) then
    raise exception 'target_not_member' using errcode = '42501';
  end if;

  if v_status = 'rejected' then
    v_status := 'needs_clarification';
  end if;
  if v_status not in (
    'confirmed', 'not_received', 'needs_clarification', 'reported', 'unmarked'
  ) then
    raise exception 'forbidden_or_invalid_status' using errcode = '42501';
  end if;

  select payment_status into v_prev
  from public.group_collection_contributions
  where collection_id = p_collection_id and user_id = p_user_id
  for update;
  v_found := found;

  if not v_found then
    insert into public.group_collection_contributions(
      collection_id, user_id, participation_status, payment_status, comment
    ) values (
      p_collection_id, p_user_id, 'joining', v_status, coalesce(p_organizer_comment, '')
    );
  else
    update public.group_collection_contributions
    set payment_status = v_status,
        comment = case
          when p_organizer_comment is null then comment
          else p_organizer_comment
        end,
        updated_at = now()
    where collection_id = p_collection_id and user_id = p_user_id;
  end if;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id, auth.uid(), 'payment_reviewed',
    jsonb_build_object(
      'user_id', p_user_id,
      'status', v_status,
      'prev_status', v_prev,
      'has_comment', p_organizer_comment is not null and btrim(p_organizer_comment) <> ''
    )
  );

  if v_status = 'confirmed' then
    v_chat := private.team_main_chat_id(v_collection.team_id);
    perform private._enqueue_group_action_single(
      p_user_id, auth.uid(), 'collection_contribution_private',
      'Взнос подтверждён',
      'Организатор подтвердил ваш взнос в «' || v_collection.title || '»',
      v_chat, v_collection.team_id, null, p_collection_id,
      v_collection.card_message_id, p_collection_id::text,
      'collection_contribution_private:' || p_collection_id::text || ':' || p_user_id::text || ':confirmed'
    );
  end if;
end;
$$;

revoke all on function public.confirm_collection_contribution(uuid, uuid, text, text)
  from public, anon;
grant execute on function public.confirm_collection_contribution(uuid, uuid, text, text)
  to authenticated, service_role;

revoke all on function
  public.upsert_my_collection_contribution(uuid, text, text, numeric, text, uuid)
from public, anon;
grant execute on function
  public.upsert_my_collection_contribution(uuid, text, text, numeric, text, uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10) Separate organizer_comment from participant comment
-- ---------------------------------------------------------------------------
alter table public.group_collection_contributions
  add column if not exists organizer_comment text not null default '';

-- Participant append-path must not touch organizer_comment or overwrite
-- participant comment when organizer already left a review note in organizer_comment.
-- Re-define upsert after column add (latest wins).
create or replace function public.upsert_my_collection_contribution(
  p_collection_id uuid,
  p_participation_status text default 'unmarked',
  p_payment_status text default 'unmarked',
  p_amount numeric default null,
  p_comment text default '',
  p_proof_file_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_existing public.group_collection_contributions%rowtype;
  v_id uuid;
  v_status text := coalesce(p_payment_status, 'unmarked');
  v_found boolean := false;
begin
  select * into v_collection
  from public.group_collections
  where id = p_collection_id
  for update;
  if not found or v_collection.status <> 'open'
     or not private.is_active_team_member(v_collection.team_id) then
    raise exception 'collection_unavailable' using errcode = '42501';
  end if;

  if v_status = 'pending_review' then
    v_status := 'reported';
  end if;
  if v_status not in ('unmarked', 'reported') then
    raise exception 'invalid_payment_status' using errcode = '22023';
  end if;

  select * into v_existing
  from public.group_collection_contributions
  where collection_id = p_collection_id and user_id = auth.uid()
  for update;
  v_found := found;

  if v_found and v_existing.payment_status in (
    'confirmed', 'not_received', 'needs_clarification', 'rejected'
  ) then
    if p_proof_file_id is not null then
      if not exists (
        select 1
        from public.chat_files cf
        join public.chats ch on ch.id = cf.chat_id
        where cf.id = p_proof_file_id
          and cf.uploaded_by = auth.uid()
          and ch.team_id = v_collection.team_id
          and ch.type = 'team_main'
      ) then
        raise exception 'invalid_proof_file' using errcode = '22023';
      end if;
      update public.chat_files set is_sensitive = true where id = p_proof_file_id;
    end if;
    -- Never overwrite organizer_comment. Participant comment is additive only
    -- when non-empty; empty input preserves previous participant comment.
    update public.group_collection_contributions
    set comment = case
          when btrim(coalesce(p_comment, '')) = '' then comment
          else p_comment
        end,
        proof_file_id = coalesce(p_proof_file_id, proof_file_id),
        updated_at = now()
    where collection_id = p_collection_id and user_id = auth.uid()
    returning id into v_id;
    insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
    values (
      p_collection_id, auth.uid(), 'contribution_note_updated',
      jsonb_build_object(
        'payment_status', v_existing.payment_status,
        'has_proof', p_proof_file_id is not null,
        'has_participant_comment', btrim(coalesce(p_comment, '')) <> ''
      )
    );
    return v_id;
  end if;

  if p_proof_file_id is not null then
    if not exists (
      select 1
      from public.chat_files cf
      join public.chats ch on ch.id = cf.chat_id
      where cf.id = p_proof_file_id
        and cf.uploaded_by = auth.uid()
        and ch.team_id = v_collection.team_id
        and ch.type = 'team_main'
    ) then
      raise exception 'invalid_proof_file' using errcode = '22023';
    end if;
    update public.chat_files set is_sensitive = true where id = p_proof_file_id;
  end if;

  insert into public.group_collection_contributions(
    collection_id, user_id, participation_status, payment_status, amount, comment, proof_file_id
  ) values (
    p_collection_id, auth.uid(), p_participation_status, v_status, p_amount,
    coalesce(p_comment, ''), p_proof_file_id
  )
  on conflict (collection_id, user_id) do update
  set participation_status = excluded.participation_status,
      payment_status = excluded.payment_status,
      amount = excluded.amount,
      comment = excluded.comment,
      proof_file_id = coalesce(excluded.proof_file_id, public.group_collection_contributions.proof_file_id),
      updated_at = now()
  returning id into v_id;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id, auth.uid(), 'contribution_upserted',
    jsonb_build_object(
      'participation_status', p_participation_status,
      'payment_status', v_status,
      'has_proof', p_proof_file_id is not null
    )
  );
  return v_id;
end;
$$;

create or replace function public.confirm_collection_contribution(
  p_collection_id uuid,
  p_user_id uuid,
  p_payment_status text,
  p_organizer_comment text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_chat uuid;
  v_status text := coalesce(p_payment_status, '');
  v_prev text;
  v_found boolean := false;
begin
  select * into v_collection
  from public.group_collections
  where id = p_collection_id
  for update;
  if not found then
    raise exception 'collection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_collections(v_collection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (
    select 1
    from public.teams t
    where t.id = v_collection.team_id
      and t.kind = 'group_space'
      and t.group_id is not null
      and exists (
        select 1
        from public.student_enrollments se
        where se.user_id = p_user_id
          and se.group_id = t.group_id
          and se.status = 'active'
          and se.ended_at is null
      )
  ) then
    raise exception 'target_not_member' using errcode = '42501';
  end if;

  if v_status = 'rejected' then
    v_status := 'needs_clarification';
  end if;
  if v_status not in (
    'confirmed', 'not_received', 'needs_clarification', 'reported', 'unmarked'
  ) then
    raise exception 'forbidden_or_invalid_status' using errcode = '42501';
  end if;

  select payment_status into v_prev
  from public.group_collection_contributions
  where collection_id = p_collection_id and user_id = p_user_id
  for update;
  v_found := found;

  if not v_found then
    insert into public.group_collection_contributions(
      collection_id, user_id, participation_status, payment_status,
      comment, organizer_comment
    ) values (
      p_collection_id, p_user_id, 'joining', v_status,
      '', coalesce(p_organizer_comment, '')
    );
  else
    update public.group_collection_contributions
    set payment_status = v_status,
        organizer_comment = case
          when p_organizer_comment is null then organizer_comment
          else p_organizer_comment
        end,
        updated_at = now()
    where collection_id = p_collection_id and user_id = p_user_id;
  end if;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id, auth.uid(), 'payment_reviewed',
    jsonb_build_object(
      'user_id', p_user_id,
      'status', v_status,
      'prev_status', v_prev,
      'has_organizer_comment', p_organizer_comment is not null and btrim(p_organizer_comment) <> ''
    )
  );

  if v_status = 'confirmed' then
    v_chat := private.team_main_chat_id(v_collection.team_id);
    perform private._enqueue_group_action_single(
      p_user_id, auth.uid(), 'collection_contribution_private',
      'Взнос подтверждён',
      'Организатор подтвердил ваш взнос в «' || v_collection.title || '»',
      v_chat, v_collection.team_id, null, p_collection_id,
      v_collection.card_message_id, p_collection_id::text,
      'collection_contribution_private:' || p_collection_id::text || ':' || p_user_id::text || ':confirmed'
    );
  end if;
end;
$$;

revoke all on function public.confirm_collection_contribution(uuid, uuid, text, text)
  from public, anon;
grant execute on function public.confirm_collection_contribution(uuid, uuid, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 11) Legacy cleanup + defense: no topic picks on group_space
-- Stage 13.9 incorrectly allowed topic selections on permanent group chat.
-- Cancel any still-open group_space selections so pick_topic cannot continue.
-- ---------------------------------------------------------------------------
with closed as (
  update public.group_topic_selections s
  set status = 'cancelled',
      closed_at = coalesce(s.closed_at, now()),
      updated_at = now()
  from public.teams t
  where t.id = s.team_id
    and coalesce(t.kind, 'subject') = 'group_space'
    and s.status = 'open'
  returning s.id, s.created_by
)
insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
select
  closed.id,
  closed.created_by,
  'status_changed',
  jsonb_build_object(
    'status', 'cancelled',
    'reason', 'stage13_10_group_space_topic_cleanup'
  )
from closed;

create or replace function public.pick_topic(p_selection_id uuid, p_option_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
  v_kind text;
  v_capacity integer;
  v_count integer;
  v_existing uuid;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not found then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;

  select coalesce(kind, 'subject') into v_kind
  from public.teams
  where id = v_selection.team_id;
  if v_kind is distinct from 'subject' then
    raise exception 'topic_selection_subject_only' using errcode = '42501';
  end if;

  if not private.is_active_team_member(v_selection.team_id)
     or v_selection.status <> 'open'
     or (v_selection.deadline_at is not null and v_selection.deadline_at <= now()) then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;

  select capacity into v_capacity
  from public.group_topic_options
  where id = p_option_id and selection_id = p_selection_id
  for update;
  if v_capacity is null then
    raise exception 'invalid_option' using errcode = '22023';
  end if;

  select option_id into v_existing
  from public.group_topic_picks
  where selection_id = p_selection_id and user_id = auth.uid()
  for update;

  if v_existing is not null
     and (not v_selection.allow_change or v_existing = p_option_id) then
    if v_existing = p_option_id then
      return;
    end if;
    raise exception 'pick_change_forbidden' using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.group_topic_picks
  where selection_id = p_selection_id
    and option_id = p_option_id
    and user_id is distinct from auth.uid();
  if v_count >= v_capacity then
    raise exception 'option_full' using errcode = 'P0001';
  end if;

  if v_existing is not null then
    delete from public.group_topic_picks
    where selection_id = p_selection_id and user_id = auth.uid();
  end if;

  insert into public.group_topic_picks(selection_id, option_id, user_id)
  values (p_selection_id, p_option_id, auth.uid());

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id,
    auth.uid(),
    'picked',
    jsonb_build_object('option_id', p_option_id)
  );
end;
$$;

revoke all on function public.pick_topic(uuid, uuid) from public, anon;
grant execute on function public.pick_topic(uuid, uuid)
  to authenticated, service_role;
