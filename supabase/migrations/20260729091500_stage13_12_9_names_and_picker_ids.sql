-- Stage 13.12.9: names for everyone + group-wide starosta manages all subject chats.
-- Local migration — apply remotely only with explicit OK.

-- ---------------------------------------------------------------------------
-- 1) Group starosta/owner can manage topics on ALL subject teams of the group
--    (not only on the one team where team_members.role = starosta).
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
        and t.group_id is not null
        and (
          -- Group-level organizer / starosta (any subject team or grant).
          private.is_group_space_organizer(t.group_id)
          -- Or explicit starosta/owner on this subject team.
          or exists (
            select 1
            from public.team_members tm
            where tm.team_id = t.id
              and tm.user_id = auth.uid()
              and lower(coalesce(tm.role, '')) in ('starosta', 'owner')
          )
        )
    );
$$;

revoke all on function private.can_manage_team_topics(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Contribution progress: real display names for organizers.
-- ---------------------------------------------------------------------------
create or replace function public.list_collection_contribution_progress(p_collection_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_manage boolean;
begin
  select * into v_collection from public.group_collections where id = p_collection_id;
  if not found or not private.is_active_team_member(v_collection.team_id) then
    return '[]'::jsonb;
  end if;
  v_manage := private.can_manage_team_collections(v_collection.team_id);

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'user_id', c.user_id,
          'display_name', nullif(
            trim(concat(coalesce(u.name, ''), ' ', coalesce(u.surname, ''))),
            ''
          ),
          'participation_status', c.participation_status,
          'payment_status', c.payment_status,
          'amount', c.amount,
          'has_proof', c.proof_file_id is not null,
          'proof_file_id', case
            when v_manage or c.user_id = auth.uid() then c.proof_file_id
            else null
          end,
          'comment', case
            when v_manage or c.user_id = auth.uid() then c.comment
            else null
          end
        )
        order by c.updated_at desc
      )
      from public.group_collection_contributions c
      left join public.users u on u.id = c.user_id
      where c.collection_id = p_collection_id
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) Topic options: picker names visible to ALL team members (not only
--    show_results_to_all / organizers). picker_user_ids for organizers.
-- ---------------------------------------------------------------------------
create or replace function public.list_topic_options_for_selection(p_selection_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
  v_can_manage boolean;
begin
  select * into v_selection from public.group_topic_selections where id = p_selection_id;
  if not found or v_selection.status = 'draft' then
    return '[]'::jsonb;
  end if;
  if not private.is_active_team_member(v_selection.team_id) then
    return '[]'::jsonb;
  end if;
  v_can_manage := private.can_manage_team_topics(v_selection.team_id);

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'selection_id', o.selection_id,
          'title', o.title,
          'capacity', o.capacity,
          'sort_order', o.sort_order,
          'taken', (
            select count(*) from public.group_topic_picks p where p.option_id = o.id
          ),
          'my_pick', exists (
            select 1 from public.group_topic_picks p
            where p.option_id = o.id and p.user_id = auth.uid()
          ),
          -- Names are always visible to every team member.
          'picker_names', (
            select coalesce(jsonb_agg(
              nullif(trim(concat(coalesce(u.name, ''), ' ', coalesce(u.surname, ''))), '')
            ), '[]'::jsonb)
            from public.group_topic_picks p
            join public.users u on u.id = p.user_id
            where p.option_id = o.id
          ),
          -- User ids only for organizers (release / reassign).
          'picker_user_ids', case
            when v_can_manage then (
              select coalesce(jsonb_agg(p.user_id::text), '[]'::jsonb)
              from public.group_topic_picks p
              where p.option_id = o.id
            )
            else '[]'::jsonb
          end
        )
        order by o.sort_order, o.created_at
      )
      from public.group_topic_options o
      where o.selection_id = p_selection_id
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) Unified details: same — names for everyone; user ids for organizers.
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
        'picker_names', coalesce((
          select jsonb_agg(trim(coalesce(u.name,'') || ' ' || coalesce(u.surname,'')))
          from public.group_topic_picks p
          join public.users u on u.id = p.user_id
          where p.option_id = o.id
        ), '[]'::jsonb),
        'picker_user_ids', case
          when v_is_org then coalesce((
            select jsonb_agg(p.user_id::text)
            from public.group_topic_picks p
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
