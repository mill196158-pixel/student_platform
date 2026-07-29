-- Stage 13.12.11: keep picker_names and picker_user_ids index-aligned.
-- Local migration — apply remotely only with explicit OK.
--
-- Both arrays are built from the same ordered pick set
-- (ORDER BY p.created_at, p.user_id) so organizers can release by index.

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
          'picker_names', (
            select coalesce(
              jsonb_agg(
                nullif(trim(concat(coalesce(u.name, ''), ' ', coalesce(u.surname, ''))), '')
                order by p.created_at, p.user_id
              ),
              '[]'::jsonb
            )
            from public.group_topic_picks p
            join public.users u on u.id = p.user_id
            where p.option_id = o.id
          ),
          'picker_user_ids', case
            when v_can_manage then (
              select coalesce(
                jsonb_agg(p.user_id::text order by p.created_at, p.user_id),
                '[]'::jsonb
              )
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

revoke all on function public.list_topic_options_for_selection(uuid)
  from public, anon;
grant execute on function public.list_topic_options_for_selection(uuid)
  to authenticated, service_role;

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
          select jsonb_agg(
            trim(coalesce(u.name, '') || ' ' || coalesce(u.surname, ''))
            order by p.created_at, p.user_id
          )
          from public.group_topic_picks p
          join public.users u on u.id = p.user_id
          where p.option_id = o.id
        ), '[]'::jsonb),
        'picker_user_ids', case
          when v_is_org then coalesce((
            select jsonb_agg(p.user_id::text order by p.created_at, p.user_id)
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
