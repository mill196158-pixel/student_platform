-- Stage 13.12.5 — harden author delete + expose can_delete for details UI.

create or replace function public.group_action_can_delete(
  p_kind text,
  p_entity_id uuid
)
returns boolean
language plpgsql
stable
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
    return false;
  end if;

  if v_kind in ('topic', 'topic_selection') then
    select * into v_selection
    from public.group_topic_selections
    where id = p_entity_id;
    if not found then
      return false;
    end if;
    if not private.is_active_team_member(v_selection.team_id) then
      return false;
    end if;
    v_is_org := private.can_manage_team_topics(v_selection.team_id);
    v_is_author := v_selection.created_by = auth.uid();
    v_has_activity := private.topic_selection_has_activity(v_selection.id);
    return v_is_org or (v_is_author and not v_has_activity);
  end if;

  if v_kind in ('collection', 'group_collection') then
    select * into v_collection
    from public.group_collections
    where id = p_entity_id;
    if not found then
      return false;
    end if;
    if not private.is_active_team_member(v_collection.team_id) then
      return false;
    end if;
    v_is_org := private.can_manage_team_collections(v_collection.team_id);
    v_is_author := v_collection.created_by = auth.uid();
    v_has_activity := private.collection_has_activity(v_collection.id);
    return v_is_org or (v_is_author and not v_has_activity);
  end if;

  return false;
end;
$$;

revoke all on function public.group_action_can_delete(text, uuid)
  from public, anon;
grant execute on function public.group_action_can_delete(text, uuid)
  to authenticated, service_role;

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
    if not private.is_active_team_member(v_selection.team_id) then
      raise exception 'forbidden' using errcode = '42501';
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
    if not private.is_active_team_member(v_collection.team_id) then
      raise exception 'forbidden' using errcode = '42501';
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
