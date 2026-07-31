-- Stage 13.11 — membership-based creation, split capabilities, delete moderation.
-- Remote applied as 20260728140108_stage13_11_membership_capabilities_ux.

-- ---------------------------------------------------------------------------
-- 1) Create vs moderate helpers (do NOT reuse one isOrganizer for all actions)
-- ---------------------------------------------------------------------------
create or replace function private.can_create_team_topics(p_team_id uuid)
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
        and t.group_id is not null
        and private.is_active_subject_team_for_group(t.id, t.group_id)
        and not exists (
          select 1
          from public.chats c
          join public.chat_academic_archives a on a.chat_id = c.id
          where c.team_id = t.id
            and c.type = 'team_main'
        )
    );
$$;

revoke all on function private.can_create_team_topics(uuid)
  from public, anon, authenticated;

create or replace function private.can_create_team_collections(p_team_id uuid)
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
        and t.kind = 'group_space'
    );
$$;

revoke all on function private.can_create_team_collections(uuid)
  from public, anon, authenticated;

-- Moderation remains organizer/starosta/owner (subject) or group organizer.
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

create or replace function private.can_manage_team_collections(p_team_id uuid)
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
        and t.kind = 'group_space'
        and private.is_group_space_organizer(t.group_id)
    );
$$;

revoke all on function private.can_manage_team_collections(uuid)
  from public, anon, authenticated;

create or replace function private.can_delete_group_action(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.can_manage_team_topics(p_team_id)
      or private.can_manage_team_collections(p_team_id);
$$;

revoke all on function private.can_delete_group_action(uuid)
  from public, anon, authenticated;

create or replace function private.topic_selection_has_activity(p_selection_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.group_topic_picks p where p.selection_id = p_selection_id
  );
$$;

revoke all on function private.topic_selection_has_activity(uuid)
  from public, anon, authenticated;

create or replace function private.collection_has_activity(p_collection_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_collection_contributions c
    where c.collection_id = p_collection_id
      and (
        coalesce(c.payment_status, 'unmarked') <> 'unmarked'
        or coalesce(c.participation_status, 'unmarked') not in ('unmarked', '')
        or coalesce(c.proof_file_id::text, '') <> ''
      )
  );
$$;

revoke all on function private.collection_has_activity(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Collection amount mode (per_person XOR total)
-- ---------------------------------------------------------------------------
alter table public.group_collections
  add column if not exists amount_mode text not null default 'none';

alter table public.group_collections
  add column if not exists amount_total numeric;

alter table public.group_collections
  drop constraint if exists group_collections_amount_mode_check;

update public.group_collections
set amount_mode = case
  when amount_optional is not null
       and amount_total is null
       and coalesce(amount_mode, 'none') in ('none', 'per_person')
    then 'per_person'
  when amount_total is not null
       and coalesce(amount_mode, 'none') in ('none', 'total')
    then 'total'
  when coalesce(amount_mode, 'none') not in ('none', 'per_person', 'total')
    then 'none'
  else coalesce(amount_mode, 'none')
end
where true;

-- Normalize contradictory pairs before CHECK (XOR amount columns).
update public.group_collections
set amount_optional = null
where amount_mode = 'total';

update public.group_collections
set amount_total = null
where amount_mode = 'per_person';

update public.group_collections
set amount_optional = null,
    amount_total = null
where amount_mode = 'none';

update public.group_collections
set amount_mode = 'none',
    amount_optional = null,
    amount_total = null
where amount_mode = 'per_person' and amount_optional is null;

update public.group_collections
set amount_mode = 'none',
    amount_optional = null,
    amount_total = null
where amount_mode = 'total' and amount_total is null;

alter table public.group_collections
  add constraint group_collections_amount_mode_check
  check (
    (
      amount_mode = 'none'
      and amount_optional is null
      and amount_total is null
    )
    or (
      amount_mode = 'per_person'
      and amount_optional is not null
      and amount_total is null
    )
    or (
      amount_mode = 'total'
      and amount_total is not null
      and amount_optional is null
    )
  );

-- ---------------------------------------------------------------------------
-- 3) Composer capabilities SoT — split create vs moderate
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
  v_can_create_topic boolean := false;
  v_can_create_collection boolean := false;
  v_can_edit_own boolean := false;
  v_can_moderate_topic boolean := false;
  v_can_moderate_collection boolean := false;
  v_can_manage_receipts boolean := false;
  v_can_delete boolean := false;
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
      'can_create_assignment', false,
      'can_create_topic_selection', false,
      'can_create_collection', false,
      'can_edit_own_before_activity', false,
      'can_moderate_topic_selection', false,
      'can_moderate_collection', false,
      'can_manage_collection_receipts', false,
      'can_delete_group_action', false,
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

  v_can_propose := v_is_member
    and v_chat.type = 'team_main'
    and not v_is_dm
    and (
      v_kind = 'group_space'
      or v_is_active_subject
    );

  -- Creation: any active member of a suitable chat (NOT organizer-gated).
  v_can_create_topic := v_chat.type = 'team_main'
    and private.can_create_team_topics(v_team.id);
  v_can_create_collection := v_chat.type = 'team_main'
    and private.can_create_team_collections(v_team.id);

  v_can_edit_own := v_is_member and v_chat.type = 'team_main' and not v_is_dm;
  v_can_moderate_topic := private.can_manage_team_topics(v_team.id);
  v_can_moderate_collection := private.can_manage_team_collections(v_team.id);
  v_can_manage_receipts := v_can_moderate_collection;
  v_can_delete := v_can_moderate_topic or v_can_moderate_collection;

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
    'can_create_assignment', v_can_propose,
    'can_create_topic_selection', v_can_create_topic,
    'can_create_collection', v_can_create_collection,
    'can_edit_own_before_activity', v_can_edit_own,
    'can_moderate_topic_selection', v_can_moderate_topic,
    'can_moderate_collection', v_can_moderate_collection,
    'can_manage_collection_receipts', v_can_manage_receipts,
    'can_delete_group_action', v_can_delete,
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
        when not v_is_member then 'not_member'
        when not v_is_active_subject then 'subject_inactive'
        when not v_can_create_topic then 'forbidden'
        else null
      end,
      'collection', case
        when v_is_dm then 'dm_not_allowed'
        when v_kind <> 'group_space' then 'subject_not_allowed'
        when not v_is_member then 'not_member'
        when not v_can_create_collection then 'forbidden'
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
-- 4) publish_topic_selection_for_chat — any active subject member
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
  if not private.can_create_team_topics(v_team.id) then
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

revoke all on function public.publish_topic_selection_for_chat(
  uuid, text, text, timestamptz, timestamptz, boolean, boolean, uuid, jsonb
) from public, anon;
grant execute on function public.publish_topic_selection_for_chat(
  uuid, text, text, timestamptz, timestamptz, boolean, boolean, uuid, jsonb
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) create_group_collection — any active group_space member + amount mode
-- ---------------------------------------------------------------------------
drop function if exists public.create_group_collection(
  text, text, text, timestamptz, numeric, text, text
);

create or replace function public.create_group_collection(
  p_title text,
  p_description text default '',
  p_purpose text default '',
  p_deadline_at timestamptz default null,
  p_amount_optional numeric default null,
  p_instructions text default '',
  p_payment_details text default '',
  p_amount_mode text default 'none',
  p_amount_total numeric default null
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
  v_mode text := lower(btrim(coalesce(p_amount_mode, 'none')));
  v_per numeric := p_amount_optional;
  v_total numeric := p_amount_total;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'title_required' using errcode = '22023';
  end if;

  v_team := private.group_space_team_id(v_group);
  if v_team is null or not private.can_create_team_collections(v_team) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_mode not in ('none', 'per_person', 'total') then
    raise exception 'invalid_amount_mode' using errcode = '22023';
  end if;
  if v_mode = 'none' then
    v_per := null;
    v_total := null;
  elsif v_mode = 'per_person' then
    if v_per is null or v_per <= 0 then
      raise exception 'amount_required' using errcode = '22023';
    end if;
    v_total := null;
  elsif v_mode = 'total' then
    if v_total is null or v_total <= 0 then
      raise exception 'amount_required' using errcode = '22023';
    end if;
    v_per := null;
  end if;

  v_chat := private.team_main_chat_id(v_team);

  insert into public.group_collections(
    group_id, team_id, created_by, title, description, purpose, deadline_at,
    amount_optional, amount_mode, amount_total, instructions, status
  ) values (
    v_group, v_team, auth.uid(), btrim(p_title), coalesce(p_description, ''),
    coalesce(p_purpose, ''), p_deadline_at, v_per, v_mode, v_total,
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
      'Скинуться: ' || btrim(p_title),
      jsonb_build_object('card', 'collection', 'collection_id', v_id),
      'text'
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
    jsonb_build_object(
      'has_payment_details', btrim(coalesce(p_payment_details, '')) <> '',
      'amount_mode', v_mode
    )
  );
  return v_id;
end;
$$;

revoke all on function public.create_group_collection(
  text, text, text, timestamptz, numeric, text, text, text, numeric
) from public, anon;
grant execute on function public.create_group_collection(
  text, text, text, timestamptz, numeric, text, text, text, numeric
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6) Author edit/cancel before activity; organizer delete/close any action
-- ---------------------------------------------------------------------------
create or replace function public.update_topic_selection_before_activity(
  p_selection_id uuid,
  p_title text default null,
  p_description text default null,
  p_deadline_at timestamptz default null,
  p_allow_change boolean default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  if private.can_manage_team_topics(v_selection.team_id) then
    null; -- organizers may edit anytime while open
  elsif v_selection.created_by = auth.uid()
        and not private.topic_selection_has_activity(v_selection.id) then
    null;
  else
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_selection.status <> 'open' then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;

  update public.group_topic_selections
  set title = coalesce(nullif(btrim(coalesce(p_title, '')), ''), title),
      description = coalesce(p_description, description),
      deadline_at = coalesce(p_deadline_at, deadline_at),
      allow_change = coalesce(p_allow_change, allow_change),
      updated_at = now()
  where id = p_selection_id;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id, auth.uid(), 'edited',
    jsonb_build_object('by_organizer', private.can_manage_team_topics(v_selection.team_id))
  );
end;
$$;

revoke all on function public.update_topic_selection_before_activity(
  uuid, text, text, timestamptz, boolean
) from public, anon;
grant execute on function public.update_topic_selection_before_activity(
  uuid, text, text, timestamptz, boolean
) to authenticated, service_role;

create or replace function public.delete_group_action(
  p_kind text,
  p_entity_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_selection public.group_topic_selections%rowtype;
  v_collection public.group_collections%rowtype;
  v_is_org boolean := false;
  v_is_author boolean := false;
  v_has_activity boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if v_kind in ('topic', 'topic_selection') then
    select * into v_selection
    from public.group_topic_selections
    where id = p_entity_id
    for update;
    if not found then
      raise exception 'selection_not_found' using errcode = 'P0002';
    end if;
    v_is_org := private.can_manage_team_topics(v_selection.team_id);
    v_is_author := v_selection.created_by = auth.uid();
    v_has_activity := private.topic_selection_has_activity(v_selection.id);
    if not v_is_org and not (v_is_author and not v_has_activity) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    update public.group_topic_selections
    set status = 'cancelled', updated_at = now()
    where id = p_entity_id;
    insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
    values (
      p_entity_id, auth.uid(), 'deleted',
      jsonb_build_object('by_organizer', v_is_org, 'had_activity', v_has_activity)
    );
    return;
  end if;

  if v_kind in ('collection', 'group_collection') then
    select * into v_collection
    from public.group_collections
    where id = p_entity_id
    for update;
    if not found then
      raise exception 'collection_not_found' using errcode = 'P0002';
    end if;
    v_is_org := private.can_manage_team_collections(v_collection.team_id);
    v_is_author := v_collection.created_by = auth.uid();
    v_has_activity := private.collection_has_activity(v_collection.id);
    if not v_is_org and not (v_is_author and not v_has_activity) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    update public.group_collections
    set status = 'cancelled', updated_at = now()
    where id = p_entity_id;
    insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
    values (
      p_entity_id, auth.uid(), 'deleted',
      jsonb_build_object('by_organizer', v_is_org, 'had_activity', v_has_activity)
    );
    return;
  end if;

  raise exception 'invalid_kind' using errcode = '22023';
end;
$$;

revoke all on function public.delete_group_action(text, uuid) from public, anon;
grant execute on function public.delete_group_action(text, uuid)
  to authenticated, service_role;

-- Keep close_topic_selection organizer-only (already uses can_manage_team_topics).
-- Ensure confirm_collection_contribution rejects self-confirm of own transfer.
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
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

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
  -- Participant must never self-confirm receipt.
  if p_user_id = auth.uid() and p_payment_status in ('confirmed') then
    raise exception 'self_confirm_forbidden' using errcode = '42501';
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

-- Participant upsert must never touch organizer_comment / organizer statuses.
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
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

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
  -- Participants may only set unmarked/reported — never organizer outcomes.
  if v_status not in ('unmarked', 'reported') then
    raise exception 'invalid_payment_status' using errcode = '22023';
  end if;

  select * into v_existing
  from public.group_collection_contributions
  where collection_id = p_collection_id and user_id = auth.uid()
  for update;
  v_found := found;

  if v_found
     and coalesce(v_existing.payment_status, 'unmarked') in (
       'confirmed', 'not_received', 'needs_clarification'
     )
     and v_status = 'unmarked' then
    -- Do not let participant wipe organizer decision by resetting status.
    raise exception 'organizer_status_locked' using errcode = '42501';
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

  if not v_found then
    insert into public.group_collection_contributions(
      collection_id, user_id, participation_status, payment_status,
      amount, comment, proof_file_id, organizer_comment
    ) values (
      p_collection_id, auth.uid(), coalesce(p_participation_status, 'unmarked'),
      v_status, p_amount, coalesce(p_comment, ''), p_proof_file_id, ''
    )
    returning id into v_id;
  else
    update public.group_collection_contributions
    set participation_status = coalesce(p_participation_status, participation_status),
        payment_status = v_status,
        amount = coalesce(p_amount, amount),
        comment = coalesce(p_comment, comment),
        proof_file_id = coalesce(p_proof_file_id, proof_file_id),
        -- organizer_comment intentionally untouched
        updated_at = now()
    where id = v_existing.id
    returning id into v_id;
  end if;

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

revoke all on function
  public.upsert_my_collection_contribution(uuid, text, text, numeric, text, uuid)
from public, anon;
grant execute on function
  public.upsert_my_collection_contribution(uuid, text, text, numeric, text, uuid)
to authenticated, service_role;

-- Direct table writes stay closed; grants unchanged from Stage 13.9/13.10.

-- ---------------------------------------------------------------------------
-- 5) list_group_collections — expose has_activity + amount mode for UI gating
-- ---------------------------------------------------------------------------
create or replace function public.list_group_collections()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_group uuid := private.current_active_group_id();
  v_manage boolean;
begin
  if v_group is null or not private.is_group_space_member(v_group) then
    return '[]'::jsonb;
  end if;
  v_manage := private.is_group_space_organizer(v_group);
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', c.id,
          'title', c.title,
          'description', c.description,
          'purpose', c.purpose,
          'status', c.status,
          'deadline_at', c.deadline_at,
          'amount_optional', c.amount_optional,
          'amount_mode', c.amount_mode,
          'amount_total', c.amount_total,
          'created_by', c.created_by,
          'has_activity', private.collection_has_activity(c.id),
          'instructions', c.instructions,
          'payment_details', case
            when v_manage then coalesce((
              select s.payment_details
              from public.group_collection_secrets s
              where s.collection_id = c.id
            ), '')
            else ''
          end,
          'card_message_id', c.card_message_id,
          'joined_count', (
            select count(*) from public.group_collection_contributions x
            where x.collection_id = c.id and x.participation_status = 'joining'
          ),
          'confirmed_count', (
            select count(*) from public.group_collection_contributions x
            where x.collection_id = c.id and x.payment_status = 'confirmed'
          ),
          'paid_count', (
            select count(*) from public.group_collection_contributions x
            where x.collection_id = c.id
              and coalesce(x.payment_status, 'unmarked') <> 'unmarked'
          )
        )
        order by c.created_at desc
      )
      from public.group_collections c
      where c.group_id = v_group and c.status <> 'cancelled'
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.list_group_collections() from public, anon;
grant execute on function public.list_group_collections()
  to authenticated, service_role;
