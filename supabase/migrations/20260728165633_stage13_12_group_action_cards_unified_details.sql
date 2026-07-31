-- Stage 13.12 — group action cards batch/details + topic option mutators
-- + get_chat_messages_page body/content split (never dump card JSON into text).
-- Do NOT edit applied 13.9–13.11 migrations.

begin;

-- ---------------------------------------------------------------------------
-- 0) Optimistic concurrency versions
-- ---------------------------------------------------------------------------
alter table public.group_topic_selections
  add column if not exists row_version integer not null default 1;

alter table public.group_topic_options
  add column if not exists row_version integer not null default 1;

alter table public.group_collections
  add column if not exists row_version integer not null default 1;

-- ---------------------------------------------------------------------------
-- 1) Recreate get_chat_messages_page: prefer body for text; expose content
--    messages.content is TEXT (not jsonb). Preserve membership, archive,
--    cleared_at, sensitive-file exclusion.
-- ---------------------------------------------------------------------------
drop function if exists public.get_chat_messages_page(uuid, integer, timestamptz, uuid);

create function public.get_chat_messages_page(
  p_chat_id uuid,
  p_limit integer default 50,
  p_before_at timestamp with time zone default null,
  p_before_id uuid default null
)
returns table (
  id uuid,
  chat_id uuid,
  author_id uuid,
  author_login text,
  author_name text,
  author_avatar_url text,
  text text,
  content text,
  type text,
  msg_type text,
  at timestamptz,
  created_at timestamptz,
  edited_at timestamptz,
  reply_to_id uuid,
  assignment_id uuid,
  file_id uuid,
  attachments jsonb,
  reactions jsonb,
  user_reactions text[],
  is_pinned boolean,
  has_more boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := (select auth.uid());
  v_limit integer;
  v_chat_type text;
  v_team_id uuid;
  v_cleared_at timestamptz;
  v_allowed boolean := false;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;
  if p_chat_id is null then
    raise exception using errcode = 'P0001', message = 'chat_id_required';
  end if;

  v_limit := greatest(1, least(coalesce(p_limit, 50), 100));

  select c.type, c.team_id
    into v_chat_type, v_team_id
  from public.chats c
  where c.id = p_chat_id;

  if v_chat_type is null then
    raise exception using errcode = 'P0001', message = 'chat_not_found';
  end if;

  if exists (
    select 1
    from public.chat_academic_archives a
    where a.chat_id = p_chat_id
      and a.expired_at is not null
  ) then
    raise exception using errcode = 'P0001', message = 'academic_chat_expired';
  end if;

  if v_chat_type = 'dm' then
    v_allowed := exists (
      select 1 from public.chat_members cm
      where cm.chat_id = p_chat_id and cm.user_id = v_me
    );
  elsif v_chat_type = 'team_main' and v_team_id is not null then
    v_allowed := exists (
      select 1 from public.team_members tm
      where tm.team_id = v_team_id and tm.user_id = v_me
    ) or exists (
      select 1
      from public.teams t
      join public.users u on u.id = v_me
      where t.id = v_team_id
        and t.group_name is not null
        and t.group_name = u.group_name
    );
  end if;

  if not v_allowed then
    raise exception using errcode = 'P0001', message = 'forbidden';
  end if;

  select s.cleared_at into v_cleared_at
  from public.chat_user_settings s
  where s.user_id = v_me and s.chat_id = p_chat_id;

  return query
  with page as (
    select
      m.id,
      m.chat_id,
      m.author_id,
      u.login::text as author_login,
      trim(
        coalesce(u.name::text, '') || ' ' || coalesce(u.surname::text, '')
      )::text as author_name,
      u.avatar_url::text as author_avatar_url,
      -- Never dump structured card JSON into text (body first; content separate).
      coalesce(nullif(btrim(coalesce(m.body::text, '')), ''), '')::text as text,
      nullif(btrim(coalesce(m.content::text, '')), '')::text as content,
      coalesce(m.msg_type::text, m.type::text, 'text')::text as type,
      coalesce(m.msg_type::text, m.type::text, 'text')::text as msg_type,
      m.created_at as at,
      m.created_at,
      m.edited_at,
      m.reply_to_id,
      m.assignment_id,
      m.file_id,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', cf.id,
            'chat_id', cf.chat_id,
            'message_id', cf.message_id,
            'file_name', cf.file_name,
            'file_key', cf.file_key,
            'file_url', cf.file_url,
            'file_type', cf.file_type,
            'file_size', cf.file_size,
            'uploaded_by', cf.uploaded_by,
            'uploaded_at', cf.uploaded_at,
            'is_deleted', cf.is_deleted
          )
          order by cf.uploaded_at asc
        )
        from public.chat_files cf
        where cf.message_id = m.id
          and coalesce(cf.is_deleted, false) = false
          and coalesce(cf.is_sensitive, false) = false
      ), '[]'::jsonb) as attachments,
      (
        select coalesce(jsonb_object_agg(t.emoji, t.cnt), '{}'::jsonb)
        from (
          select mr.emoji, count(*)::bigint as cnt
          from public.message_reactions mr
          where mr.message_id = m.id
          group by mr.emoji
        ) t
      ) as reactions,
      (
        select array_agg(mr.emoji::text)
        from public.message_reactions mr
        where mr.message_id = m.id and mr.user_id = v_me
      ) as user_reactions,
      m.is_pinned,
      m.created_at as sort_at,
      m.id as sort_id
    from public.messages m
    left join public.users u on u.id = m.author_id
    where m.chat_id = p_chat_id
      and (v_cleared_at is null or m.created_at > v_cleared_at)
      and (
        p_before_at is null
        or m.created_at < p_before_at
        or (m.created_at = p_before_at and p_before_id is not null and m.id < p_before_id)
      )
    order by m.created_at desc, m.id desc
    limit v_limit + 1
  ),
  trimmed as (
    select * from page
    order by sort_at desc, sort_id desc
    limit v_limit
  ),
  meta as (
    select (select count(*)::int from page) > v_limit as has_more
  )
  select
    t.id, t.chat_id, t.author_id, t.author_login, t.author_name, t.author_avatar_url,
    t.text, t.content, t.type, t.msg_type, t.at, t.created_at, t.edited_at,
    t.reply_to_id, t.assignment_id, t.file_id, t.attachments, t.reactions,
    t.user_reactions, t.is_pinned, meta.has_more
  from trimmed t
  cross join meta
  order by t.at asc, t.id asc;
end;
$function$;

revoke all on function public.get_chat_messages_page(uuid, integer, timestamptz, uuid)
  from public, anon;
grant execute on function public.get_chat_messages_page(uuid, integer, timestamptz, uuid)
  to authenticated;

comment on function public.get_chat_messages_page(uuid, integer, timestamptz, uuid) is
  'Stage 13.12: body as text + structured content; sensitive attachments excluded.';

-- ---------------------------------------------------------------------------
-- 3) Batch card projections (bounded, chat-bound, privacy-safe)
-- ---------------------------------------------------------------------------
create or replace function public.get_chat_action_cards_batch(
  p_chat_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_team_id uuid;
  v_chat_type text;
  v_items jsonb := coalesce(p_items, '[]'::jsonb);
  v_count int;
  v_out jsonb := '[]'::jsonb;
  v_item jsonb;
  v_kind text;
  v_entity uuid;
  v_msg uuid;
  v_sel public.group_topic_selections%rowtype;
  v_col public.group_collections%rowtype;
  v_free int;
  v_taken int;
  v_total int;
  v_my_pick text;
  v_my_status text;
  v_confirmed int;
  v_pending int;
  v_is_org boolean;
  v_card jsonb;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_chat_id is null then
    raise exception 'chat_id_required' using errcode = '22023';
  end if;
  if jsonb_typeof(v_items) <> 'array' then
    raise exception 'invalid_items' using errcode = '22023';
  end if;

  v_count := jsonb_array_length(v_items);
  if v_count > 50 then
    raise exception 'items_limit_exceeded' using errcode = '22023';
  end if;

  select c.type, c.team_id into v_chat_type, v_team_id
  from public.chats c where c.id = p_chat_id;
  if v_chat_type is null or v_team_id is null then
    raise exception 'chat_not_found' using errcode = 'P0002';
  end if;

  if not private.is_active_team_member(v_team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  for v_item in select * from jsonb_array_elements(v_items)
  loop
    v_kind := lower(btrim(coalesce(v_item->>'kind', v_item->>'card', '')));
    begin
      v_entity := nullif(v_item->>'entity_id', '')::uuid;
    exception when others then
      v_entity := null;
    end;
    begin
      v_msg := nullif(coalesce(v_item->>'card_message_id', v_item->>'message_id'), '')::uuid;
    exception when others then
      v_msg := null;
    end;

    v_card := jsonb_build_object(
      'kind', v_kind,
      'entity_id', v_entity,
      'card_message_id', v_msg,
      'available', false,
      'status', 'unavailable'
    );

    -- Require chat-bound card_message_id for trusted projection.
    if v_entity is null or v_kind = '' or v_msg is null then
      v_out := v_out || jsonb_build_array(v_card);
      continue;
    end if;

    if v_kind in ('topic_selection', 'topic') then
      select * into v_sel
      from public.group_topic_selections s
      where s.id = v_entity
        and s.team_id = v_team_id
        and s.card_message_id = v_msg
        and exists (
          select 1 from public.messages m
          where m.id = v_msg
            and m.chat_id = p_chat_id
        );
      if found then
        select
          coalesce(sum(o.capacity), 0)::int,
          coalesce(sum(sub.taken), 0)::int
        into v_total, v_taken
        from public.group_topic_options o
        left join lateral (
          select count(*)::int as taken
          from public.group_topic_picks p
          where p.option_id = o.id
        ) sub on true
        where o.selection_id = v_sel.id;
        v_free := greatest(v_total - v_taken, 0);
        select o.title into v_my_pick
        from public.group_topic_picks p
        join public.group_topic_options o on o.id = p.option_id
        where p.selection_id = v_sel.id and p.user_id = v_me
        limit 1;

        -- Legacy group_space topic selections are product-forbidden as active.
        if v_sel.group_id is not null and exists (
          select 1 from public.teams t
          where t.id = v_sel.team_id and coalesce(t.kind, '') = 'group_space'
        ) and v_sel.status = 'open' then
          v_card := jsonb_build_object(
            'kind', 'topic_selection',
            'entity_id', v_sel.id,
            'card_message_id', v_sel.card_message_id,
            'available', true,
            'legacy_group_space', true,
            'status', 'completed',
            'title', v_sel.title,
            'description', coalesce(v_sel.description, ''),
            'row_version', v_sel.row_version,
            'deadline_at', v_sel.deadline_at,
            'free_slots', 0,
            'taken_slots', v_taken,
            'total_capacity', v_total,
            'my_pick_text', v_my_pick,
            'compact_completed', true
          );
        else
          v_card := jsonb_build_object(
            'kind', 'topic_selection',
            'entity_id', v_sel.id,
            'card_message_id', v_sel.card_message_id,
            'available', true,
            'legacy_group_space', false,
            'status', v_sel.status,
            'title', v_sel.title,
            'description', coalesce(v_sel.description, ''),
            'row_version', v_sel.row_version,
            'deadline_at', coalesce(v_sel.deadline_at, v_sel.completion_deadline_at),
            'allow_change', v_sel.allow_change,
            'free_slots', v_free,
            'taken_slots', v_taken,
            'total_capacity', v_total,
            'my_pick_text', v_my_pick,
            'created_by', v_sel.created_by,
            'compact_completed', v_sel.status in ('closed', 'cancelled', 'completed')
          );
        end if;
      end if;
    elsif v_kind in ('collection', 'group_collection') then
      select * into v_col
      from public.group_collections c
      where c.id = v_entity
        and c.team_id = v_team_id
        and c.card_message_id = v_msg
        and exists (
          select 1 from public.messages m
          where m.id = v_msg
            and m.chat_id = p_chat_id
        );
      if found then
        v_is_org := private.can_manage_team_collections(v_col.team_id);
        select
          count(*) filter (where coalesce(cc.payment_status, '') in ('confirmed', 'received'))::int,
          count(*) filter (where coalesce(cc.payment_status, '') in ('pending', 'reported', 'awaiting'))::int
        into v_confirmed, v_pending
        from public.group_collection_contributions cc
        where cc.collection_id = v_col.id;

        select coalesce(cc.payment_status, 'none') into v_my_status
        from public.group_collection_contributions cc
        where cc.collection_id = v_col.id and cc.user_id = v_me
        limit 1;

        v_card := jsonb_build_object(
          'kind', 'group_collection',
          'entity_id', v_col.id,
          'card_message_id', v_col.card_message_id,
          'available', true,
          'status', v_col.status,
          'title', v_col.title,
          'description', coalesce(v_col.description, ''),
          'purpose', coalesce(v_col.purpose, ''),
          'row_version', v_col.row_version,
          'deadline_at', v_col.deadline_at,
          'amount_mode', v_col.amount_mode,
          'amount_optional', v_col.amount_optional,
          'amount_total', v_col.amount_total,
          'my_status', coalesce(v_my_status, 'none'),
          'created_by', v_col.created_by,
          'compact_completed', v_col.status in ('closed', 'cancelled', 'completed'),
          -- Organizer aggregates only; never proof URLs / peer comments.
          'organizer_stats', case when v_is_org then jsonb_build_object(
            'confirmed', coalesce(v_confirmed, 0),
            'pending', coalesce(v_pending, 0)
          ) else null end
        );
      end if;
    end if;

    v_out := v_out || jsonb_build_array(v_card);
  end loop;

  return v_out;
end;
$$;

revoke all on function public.get_chat_action_cards_batch(uuid, jsonb) from public, anon;
grant execute on function public.get_chat_action_cards_batch(uuid, jsonb)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) Unified task details (p_chat_id REQUIRED)
-- ---------------------------------------------------------------------------
create or replace function public.get_task_details(
  p_kind text,
  p_entity_id uuid,
  p_chat_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_team_id uuid;
  v_batch jsonb;
  v_card jsonb;
  v_options jsonb := '[]'::jsonb;
  v_sel public.group_topic_selections%rowtype;
  v_is_org boolean;
  v_show_names boolean;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_chat_id is null or p_entity_id is null then
    raise exception 'chat_and_entity_required' using errcode = '22023';
  end if;

  select c.team_id into v_team_id from public.chats c where c.id = p_chat_id;
  if v_team_id is null then
    raise exception 'chat_not_found' using errcode = 'P0002';
  end if;

  if not private.is_active_team_member(v_team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_kind in ('topic_selection', 'topic') then
    select * into v_sel
    from public.group_topic_selections s
    where s.id = p_entity_id
      and s.team_id = v_team_id
      and s.card_message_id is not null
      and exists (
        select 1 from public.messages m
        where m.id = s.card_message_id
          and m.chat_id = p_chat_id
      );
    if not found then
      return jsonb_build_object('available', false, 'status', 'unavailable');
    end if;

    v_batch := public.get_chat_action_cards_batch(
      p_chat_id,
      jsonb_build_array(jsonb_build_object(
        'kind', 'topic_selection',
        'entity_id', p_entity_id,
        'card_message_id', v_sel.card_message_id
      ))
    );
    v_card := v_batch->0;
    if coalesce((v_card->>'available')::boolean, false) is not true then
      return jsonb_build_object('available', false, 'status', 'unavailable');
    end if;

    v_is_org := private.can_manage_team_topics(v_sel.team_id);
    v_show_names := v_is_org or coalesce(v_sel.show_results_to_all, false);

    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id', o.id,
        'title', o.title,
        'capacity', o.capacity,
        'taken', coalesce(t.taken, 0),
        'sort_order', o.sort_order,
        'row_version', o.row_version,
        'my_pick', exists (
          select 1 from public.group_topic_picks p
          where p.option_id = o.id and p.user_id = v_me
        ),
        'picker_names', case
          when v_show_names then coalesce((
            select jsonb_agg(trim(coalesce(u.name,'') || ' ' || coalesce(u.surname,'')))
            from public.group_topic_picks p
            join public.users u on u.id = p.user_id
            where p.option_id = o.id
          ), '[]'::jsonb)
          else '[]'::jsonb
        end
      )
      order by o.sort_order, o.created_at
    ), '[]'::jsonb)
    into v_options
    from public.group_topic_options o
    left join lateral (
      select count(*)::int as taken from public.group_topic_picks p where p.option_id = o.id
    ) t on true
    where o.selection_id = p_entity_id;

    return v_card || jsonb_build_object(
      'options', v_options,
      'can_manage', v_is_org,
      'details_kind', 'topic_selection'
    );
  end if;

  if v_kind in ('collection', 'group_collection') then
    if not exists (
      select 1
      from public.group_collections c
      where c.id = p_entity_id
        and c.team_id = v_team_id
        and c.card_message_id is not null
        and exists (
          select 1 from public.messages m
          where m.id = c.card_message_id and m.chat_id = p_chat_id
        )
    ) then
      return jsonb_build_object('available', false, 'status', 'unavailable');
    end if;

    v_batch := public.get_chat_action_cards_batch(
      p_chat_id,
      jsonb_build_array(jsonb_build_object(
        'kind', 'group_collection',
        'entity_id', p_entity_id,
        'card_message_id', (
          select c.card_message_id from public.group_collections c
          where c.id = p_entity_id
        )
      ))
    );
    v_card := v_batch->0;
    if coalesce((v_card->>'available')::boolean, false) is not true then
      return jsonb_build_object('available', false, 'status', 'unavailable');
    end if;

    return v_card || jsonb_build_object(
      'details_kind', 'group_collection',
      'can_manage', private.can_manage_team_collections(v_team_id)
    );
  end if;

  if v_kind = 'assignment' then
    -- Bind assignment to the chat team; never authorize by entity UUID alone.
    if not exists (
      select 1
      from public.assignments a
      where a.id = p_entity_id
        and a.team_id = v_team_id
    ) then
      return jsonb_build_object('available', false, 'status', 'unavailable');
    end if;
    return jsonb_build_object(
      'available', true,
      'kind', 'assignment',
      'entity_id', p_entity_id,
      'details_kind', 'assignment',
      'chat_id', p_chat_id,
      'team_id', v_team_id
    );
  end if;

  raise exception 'invalid_kind' using errcode = '22023';
end;
$$;

revoke all on function public.get_task_details(text, uuid, uuid) from public, anon;
grant execute on function public.get_task_details(text, uuid, uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) Topic option mutators (expected_version, row lock, audit)
-- ---------------------------------------------------------------------------
create or replace function private.assert_topic_selection_mutable(
  p_selection_id uuid,
  p_team_id uuid,
  p_created_by uuid,
  p_status text,
  p_row_version integer,
  p_expected_version integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status <> 'open' then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;
  if p_expected_version is not null
     and p_row_version is distinct from p_expected_version then
    raise exception 'version_conflict' using errcode = 'P0001';
  end if;
  if private.can_manage_team_topics(p_team_id) then
    return;
  end if;
  if p_created_by = auth.uid()
     and not private.topic_selection_has_activity(p_selection_id) then
    return;
  end if;
  raise exception 'forbidden' using errcode = '42501';
end;
$$;

revoke all on function private.assert_topic_selection_mutable(
  uuid, uuid, uuid, text, integer, integer
) from public, anon, authenticated;

create or replace function public.update_topic_selection(
  p_selection_id uuid,
  p_expected_version integer,
  p_title text default null,
  p_description text default null,
  p_deadline_at timestamptz default null,
  p_allow_change boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sel public.group_topic_selections%rowtype;
  v_new_version int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_sel from public.group_topic_selections
  where id = p_selection_id for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  perform private.assert_topic_selection_mutable(
    v_sel.id, v_sel.team_id, v_sel.created_by, v_sel.status, v_sel.row_version, p_expected_version
  );

  update public.group_topic_selections
  set title = coalesce(nullif(btrim(coalesce(p_title, '')), ''), title),
      description = coalesce(p_description, description),
      deadline_at = coalesce(p_deadline_at, deadline_at),
      allow_change = coalesce(p_allow_change, allow_change),
      row_version = row_version + 1,
      updated_at = now()
  where id = p_selection_id
  returning row_version into v_new_version;

  -- Keep chat preview body in sync when title changes.
  if v_sel.card_message_id is not null and p_title is not null
     and nullif(btrim(p_title), '') is not null then
    update public.messages
    set body = 'Выбор темы: ' || btrim(p_title)
    where id = v_sel.card_message_id;
  end if;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id, auth.uid(), 'edited',
    jsonb_build_object(
      'by_organizer', private.can_manage_team_topics(v_sel.team_id),
      'row_version', v_new_version
    )
  );

  return jsonb_build_object('ok', true, 'row_version', v_new_version);
end;
$$;

revoke all on function public.update_topic_selection(
  uuid, integer, text, text, timestamptz, boolean
) from public, anon;
grant execute on function public.update_topic_selection(
  uuid, integer, text, text, timestamptz, boolean
) to authenticated, service_role;

create or replace function public.update_topic_option(
  p_option_id uuid,
  p_expected_version integer,
  p_title text default null,
  p_capacity integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_opt public.group_topic_options%rowtype;
  v_sel public.group_topic_selections%rowtype;
  v_taken int;
  v_new_sel_version int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_opt from public.group_topic_options where id = p_option_id for update;
  if not found then
    raise exception 'option_not_found' using errcode = 'P0002';
  end if;
  select * into v_sel from public.group_topic_selections
  where id = v_opt.selection_id for update;
  perform private.assert_topic_selection_mutable(
    v_sel.id, v_sel.team_id, v_sel.created_by, v_sel.status, v_sel.row_version, p_expected_version
  );

  select count(*)::int into v_taken
  from public.group_topic_picks where option_id = p_option_id;

  if p_capacity is not null then
    if p_capacity < 1 then
      raise exception 'invalid_capacity' using errcode = '22023';
    end if;
    if p_capacity < v_taken then
      raise exception 'option_occupied' using errcode = '42501';
    end if;
  end if;

  update public.group_topic_options
  set title = coalesce(nullif(btrim(coalesce(p_title, '')), ''), title),
      capacity = coalesce(p_capacity, capacity),
      row_version = row_version + 1
  where id = p_option_id;

  update public.group_topic_selections
  set row_version = row_version + 1, updated_at = now()
  where id = v_sel.id
  returning row_version into v_new_sel_version;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    v_sel.id, auth.uid(), 'option_edited',
    jsonb_build_object('option_id', p_option_id, 'row_version', v_new_sel_version)
  );

  return jsonb_build_object('ok', true, 'row_version', v_new_sel_version);
end;
$$;

revoke all on function public.update_topic_option(uuid, integer, text, integer)
  from public, anon;
grant execute on function public.update_topic_option(uuid, integer, text, integer)
  to authenticated, service_role;

create or replace function public.reorder_topic_options(
  p_selection_id uuid,
  p_expected_version integer,
  p_option_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sel public.group_topic_selections%rowtype;
  v_existing uuid[];
  v_new_version int;
  v_i int;
  v_len int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_sel from public.group_topic_selections
  where id = p_selection_id for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  perform private.assert_topic_selection_mutable(
    v_sel.id, v_sel.team_id, v_sel.created_by, v_sel.status, v_sel.row_version, p_expected_version
  );

  select coalesce(array_agg(o.id order by o.sort_order, o.created_at), array[]::uuid[])
  into v_existing
  from public.group_topic_options o
  where o.selection_id = p_selection_id;

  v_len := coalesce(array_length(p_option_ids, 1), 0);
  if p_option_ids is null
     or v_len is distinct from coalesce(array_length(v_existing, 1), 0)
     or (
       select count(distinct x)::int from unnest(p_option_ids) as x
     ) is distinct from v_len
     or exists (
       select 1 from unnest(p_option_ids) as x
       where not (x = any (v_existing))
     ) then
    raise exception 'reorder_set_mismatch' using errcode = '22023';
  end if;

  for v_i in 1 .. v_len loop
    update public.group_topic_options
    set sort_order = v_i - 1,
        row_version = row_version + 1
    where id = p_option_ids[v_i] and selection_id = p_selection_id;
  end loop;

  update public.group_topic_selections
  set row_version = row_version + 1, updated_at = now()
  where id = p_selection_id
  returning row_version into v_new_version;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id, auth.uid(), 'options_reordered',
    jsonb_build_object('row_version', v_new_version)
  );

  return jsonb_build_object('ok', true, 'row_version', v_new_version);
end;
$$;

revoke all on function public.reorder_topic_options(uuid, integer, uuid[])
  from public, anon;
grant execute on function public.reorder_topic_options(uuid, integer, uuid[])
  to authenticated, service_role;

create or replace function public.remove_topic_option(
  p_option_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_opt public.group_topic_options%rowtype;
  v_sel public.group_topic_selections%rowtype;
  v_taken int;
  v_new_version int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_opt from public.group_topic_options where id = p_option_id for update;
  if not found then
    raise exception 'option_not_found' using errcode = 'P0002';
  end if;
  select * into v_sel from public.group_topic_selections
  where id = v_opt.selection_id for update;
  perform private.assert_topic_selection_mutable(
    v_sel.id, v_sel.team_id, v_sel.created_by, v_sel.status, v_sel.row_version, p_expected_version
  );

  select count(*)::int into v_taken
  from public.group_topic_picks where option_id = p_option_id;
  if v_taken > 0 then
    raise exception 'option_occupied' using errcode = '42501';
  end if;

  delete from public.group_topic_options where id = p_option_id;

  update public.group_topic_selections
  set row_version = row_version + 1, updated_at = now()
  where id = v_sel.id
  returning row_version into v_new_version;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    v_sel.id, auth.uid(), 'option_removed',
    jsonb_build_object('option_id', p_option_id, 'row_version', v_new_version)
  );

  return jsonb_build_object('ok', true, 'row_version', v_new_version);
end;
$$;

revoke all on function public.remove_topic_option(uuid, integer) from public, anon;
grant execute on function public.remove_topic_option(uuid, integer)
  to authenticated, service_role;

-- Harden legacy add_topic_option(uuid,text,int,int)->uuid: author-before-activity
-- OR organizer; bumps selection.row_version. Keep return type for older clients.
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
  v_sel public.group_topic_selections%rowtype;
  v_id uuid;
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_cap int := greatest(1, coalesce(p_capacity, 1));
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if v_title is null then
    raise exception 'title_required' using errcode = '22023';
  end if;

  select * into v_sel from public.group_topic_selections
  where id = p_selection_id for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  perform private.assert_topic_selection_mutable(
    v_sel.id, v_sel.team_id, v_sel.created_by, v_sel.status, v_sel.row_version, null
  );

  insert into public.group_topic_options(selection_id, title, capacity, sort_order)
  values (p_selection_id, v_title, v_cap, coalesce(p_sort_order, 0))
  returning id into v_id;

  update public.group_topic_selections
  set row_version = row_version + 1, updated_at = now()
  where id = p_selection_id;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id, auth.uid(), 'option_added',
    jsonb_build_object('option_id', v_id)
  );

  return v_id;
end;
$$;

revoke all on function public.add_topic_option(uuid, text, integer, integer)
  from public, anon;
grant execute on function public.add_topic_option(uuid, text, integer, integer)
  to authenticated, service_role;

-- Versioned add for editor optimistic concurrency.
create or replace function public.add_topic_option_with_version(
  p_selection_id uuid,
  p_title text,
  p_capacity integer default 1,
  p_expected_version integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sel public.group_topic_selections%rowtype;
  v_id uuid;
  v_order int;
  v_new_version int;
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_cap int := greatest(1, coalesce(p_capacity, 1));
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if v_title is null then
    raise exception 'title_required' using errcode = '22023';
  end if;

  select * into v_sel from public.group_topic_selections
  where id = p_selection_id for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  perform private.assert_topic_selection_mutable(
    v_sel.id, v_sel.team_id, v_sel.created_by, v_sel.status, v_sel.row_version, p_expected_version
  );

  select coalesce(max(sort_order), -1) + 1 into v_order
  from public.group_topic_options where selection_id = p_selection_id;

  insert into public.group_topic_options(selection_id, title, capacity, sort_order)
  values (p_selection_id, v_title, v_cap, v_order)
  returning id into v_id;

  update public.group_topic_selections
  set row_version = row_version + 1, updated_at = now()
  where id = p_selection_id
  returning row_version into v_new_version;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id, auth.uid(), 'option_added',
    jsonb_build_object('option_id', v_id, 'row_version', v_new_version)
  );

  return jsonb_build_object('ok', true, 'option_id', v_id, 'row_version', v_new_version);
end;
$$;

revoke all on function public.add_topic_option_with_version(uuid, text, integer, integer)
  from public, anon;
grant execute on function public.add_topic_option_with_version(uuid, text, integer, integer)
  to authenticated, service_role;

-- list_my_group_action_deadlines already excludes group_space topics
-- (coalesce(t.kind,'subject')='subject' in Stage 13.10). Left unchanged.

commit;
