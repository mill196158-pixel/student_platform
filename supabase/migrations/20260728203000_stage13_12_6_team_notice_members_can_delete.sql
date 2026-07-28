-- Stage 13.12.6
-- - team chat notice (organizer comment) per subject/group team
-- - alphabetical member directory RPC
-- - can_delete on chat card batch + deadline projections

-- ---------------------------------------------------------------------------
-- team_chat_notices
-- ---------------------------------------------------------------------------
create table if not exists public.team_chat_notices (
  team_id uuid primary key references public.teams(id) on delete cascade,
  body text not null default '',
  updated_by uuid references public.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  row_version integer not null default 1,
  constraint team_chat_notices_body_len check (char_length(body) <= 2000)
);

comment on table public.team_chat_notices is
  'Per-team organizer notice shown in subject/group chat header (rules, deadlines).';

alter table public.team_chat_notices enable row level security;
alter table public.team_chat_notices force row level security;

drop policy if exists team_chat_notices_select on public.team_chat_notices;
create policy team_chat_notices_select
  on public.team_chat_notices
  for select
  to authenticated
  using (private.is_active_team_member(team_id));

revoke all on table public.team_chat_notices from public, anon;
grant select on table public.team_chat_notices to authenticated;

create or replace function private.can_edit_team_chat_notice(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.can_manage_team_topics(p_team_id)
      or private.can_manage_team_collections(p_team_id);
$$;

revoke all on function private.can_edit_team_chat_notice(uuid)
  from public, anon, authenticated;

create or replace function public.get_team_chat_notice(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.team_chat_notices%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_team_id is null then
    raise exception 'team_id_required' using errcode = '22023';
  end if;
  if not private.is_active_team_member(p_team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_row
  from public.team_chat_notices n
  where n.team_id = p_team_id;

  if not found then
    return jsonb_build_object(
      'team_id', p_team_id,
      'body', '',
      'updated_by', null,
      'updated_at', null,
      'row_version', 0,
      'can_edit', private.can_edit_team_chat_notice(p_team_id)
    );
  end if;

  return jsonb_build_object(
    'team_id', v_row.team_id,
    'body', coalesce(v_row.body, ''),
    'updated_by', v_row.updated_by,
    'updated_at', v_row.updated_at,
    'row_version', v_row.row_version,
    'can_edit', private.can_edit_team_chat_notice(p_team_id)
  );
end;
$$;

revoke all on function public.get_team_chat_notice(uuid) from public, anon;
grant execute on function public.get_team_chat_notice(uuid) to authenticated;

create or replace function public.upsert_team_chat_notice(
  p_team_id uuid,
  p_body text,
  p_expected_version integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_body text := btrim(coalesce(p_body, ''));
  v_row public.team_chat_notices%rowtype;
  v_exists boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_team_id is null then
    raise exception 'team_id_required' using errcode = '22023';
  end if;
  if char_length(v_body) > 2000 then
    raise exception 'body_too_long' using errcode = '22023';
  end if;
  if not private.can_edit_team_chat_notice(p_team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_row
  from public.team_chat_notices n
  where n.team_id = p_team_id
  for update;
  v_exists := found;

  if v_exists then
    if p_expected_version is not null
       and v_row.row_version is distinct from p_expected_version then
      raise exception 'version_conflict' using errcode = '40001';
    end if;
    update public.team_chat_notices
    set body = v_body,
        updated_by = auth.uid(),
        updated_at = now(),
        row_version = v_row.row_version + 1
    where team_id = p_team_id
    returning * into v_row;
  else
    if p_expected_version is not null and p_expected_version <> 0 then
      raise exception 'version_conflict' using errcode = '40001';
    end if;
    insert into public.team_chat_notices(team_id, body, updated_by, updated_at, row_version)
    values (p_team_id, v_body, auth.uid(), now(), 1)
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'team_id', v_row.team_id,
    'body', coalesce(v_row.body, ''),
    'updated_by', v_row.updated_by,
    'updated_at', v_row.updated_at,
    'row_version', v_row.row_version,
    'can_edit', true
  );
end;
$$;

revoke all on function public.upsert_team_chat_notice(uuid, text, integer)
  from public, anon;
grant execute on function public.upsert_team_chat_notice(uuid, text, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Member directory (alphabetical by surname+name)
-- ---------------------------------------------------------------------------
create or replace function public.list_team_members_directory(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_team_id is null then
    raise exception 'team_id_required' using errcode = '22023';
  end if;
  if not private.is_active_team_member(p_team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'user_id', x.user_id,
          'display_name', x.display_name,
          'role', x.role,
          'avatar_url', x.avatar_url
        )
        order by x.sort_key, x.user_id
      )
      from (
        select
          tm.user_id,
          coalesce(nullif(btrim(tm.role), ''), 'member') as role,
          nullif(btrim(coalesce(u.avatar_url, '')), '') as avatar_url,
          nullif(
            btrim(concat_ws(' ', nullif(btrim(coalesce(u.surname, '')), ''),
                                 nullif(btrim(coalesce(u.name, '')), ''))),
            ''
          ) as display_name,
          lower(
            coalesce(
              nullif(
                btrim(concat_ws(' ', nullif(btrim(coalesce(u.surname, '')), ''),
                                     nullif(btrim(coalesce(u.name, '')), ''))),
                ''
              ),
              coalesce(u.login::text, tm.user_id::text)
            )
          ) as sort_key
        from public.team_members tm
        join public.users u on u.id = tm.user_id
        where tm.team_id = p_team_id
          and tm.user_id in (
            select private.active_team_member_user_ids(p_team_id)
          )
          and coalesce(u.is_active, true) = true
      ) x
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.list_team_members_directory(uuid)
  from public, anon;
grant execute on function public.list_team_members_directory(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Batch cards: include can_delete (server SoT, no N+1)
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
      'status', 'unavailable',
      'can_delete', false
    );

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
            'compact_completed', true,
            'can_delete', false
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
            'compact_completed', v_sel.status in ('closed', 'cancelled', 'completed'),
            'can_delete', (
              v_sel.status = 'open'
              and (
                private.can_manage_team_topics(v_sel.team_id)
                or (
                  v_sel.created_by = v_me
                  and not private.topic_selection_has_activity(v_sel.id)
                )
              )
            )
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
          'organizer_stats', case when v_is_org then jsonb_build_object(
            'confirmed', coalesce(v_confirmed, 0),
            'pending', coalesce(v_pending, 0)
          ) else null end,
          'can_delete', (
            v_col.status = 'open'
            and (
              v_is_org
              or (
                v_col.created_by = v_me
                and not private.collection_has_activity(v_col.id)
              )
            )
          )
        );
      end if;
    end if;

    v_out := v_out || jsonb_build_array(v_card);
  end loop;

  return v_out;
end;
$$;

revoke all on function public.get_chat_action_cards_batch(uuid, jsonb)
  from public, anon;
grant execute on function public.get_chat_action_cards_batch(uuid, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Deadlines (home/calendar): include can_delete
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
      public.group_action_can_delete('topic_selection', s.id) as can_delete,
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
      public.group_action_can_delete('group_collection', c.id) as can_delete,
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
        'can_delete', coalesce(x.can_delete, false),
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
  to authenticated;
