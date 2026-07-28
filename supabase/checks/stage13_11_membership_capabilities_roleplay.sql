-- Stage 13.11 behavioral roleplay (disposable transaction).
-- Requires Stage 13.11 migration + existing enrollments/teams.
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_org uuid;
  v_stu uuid;
  v_outsider uuid;
  v_group uuid;
  v_space jsonb;
  v_space_team uuid;
  v_space_chat uuid;
  v_subject_team uuid;
  v_subject_chat uuid;
  v_dm_chat uuid;
  v_caps jsonb;
  v_sel jsonb;
  v_col uuid;
  v_foreign_sel jsonb;
begin
  select se.group_id into v_group
  from public.student_enrollments se
  where se.status = 'active' and se.ended_at is null
  group by se.group_id
  having count(*) >= 2
  order by count(*) desc
  limit 1;
  if v_group is null then
    raise exception 'roleplay_requires_group';
  end if;

  select se.user_id into v_org
  from public.student_enrollments se
  where se.group_id = v_group and se.status = 'active' and se.ended_at is null
  order by se.started_at nulls last
  limit 1;
  select se.user_id into v_stu
  from public.student_enrollments se
  where se.group_id = v_group and se.status = 'active' and se.ended_at is null
    and se.user_id <> v_org
  order by se.started_at nulls last
  limit 1;
  select se.user_id into v_outsider
  from public.student_enrollments se
  where se.group_id <> v_group and se.status = 'active' and se.ended_at is null
    and se.user_id not in (v_org, v_stu)
  limit 1;
  if v_outsider is null then
    select id into v_outsider from public.users
    where id not in (v_org, v_stu) limit 1;
  end if;
  if v_org is null or v_stu is null or v_outsider is null then
    raise exception 'roleplay_requires_users';
  end if;

  update public.users set primary_group_id = v_group where id = v_org;
  update public.users set primary_group_id = v_group where id = v_stu;
  insert into public.group_space_organizer_grants(group_id, user_id, source)
  values (v_group, v_org, 'admin')
  on conflict do nothing;

  perform set_config('request.jwt.claim.sub', v_org::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  v_space := public.ensure_group_space();
  v_space_team := coalesce((v_space->>'team_id')::uuid, private.group_space_team_id(v_group));
  v_space_chat := coalesce((v_space->>'chat_id')::uuid, private.team_main_chat_id(v_space_team));

  select t.id into v_subject_team
  from public.teams t
  where t.group_id = v_group and coalesce(t.kind, 'subject') = 'subject'
  limit 1;
  if v_subject_team is null then
    raise exception 'roleplay_requires_subject_team';
  end if;
  v_subject_chat := private.team_main_chat_id(v_subject_team);
  insert into public.team_members(team_id, user_id, role)
  values (v_subject_team, v_org, 'starosta'), (v_subject_team, v_stu, 'member')
  on conflict (team_id, user_id) do update set role = excluded.role;

  insert into public.chats(type) values ('dm') returning id into v_dm_chat;

  ------------------------------------------------------------------
  -- Ordinary member can create topic on subject (Stage 13.11)
  ------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  v_caps := public.get_chat_composer_capabilities(v_subject_chat);
  if coalesce((v_caps->>'can_create_topic_selection')::boolean, false) is not true then
    raise exception 'member_must_create_topic %', v_caps;
  end if;
  if coalesce((v_caps->>'can_moderate_topic_selection')::boolean, true) then
    raise exception 'member_must_not_moderate_topic %', v_caps;
  end if;
  if coalesce((v_caps->>'can_create_collection')::boolean, true) then
    raise exception 'subject_member_must_not_create_collection %', v_caps;
  end if;

  v_sel := public.publish_topic_selection_for_chat(
    v_subject_chat,
    'Темы докладов по экологии',
    'пояснение',
    now() + interval '2 days',
    null, true, true, null,
    '[{"title":"Тема A"},{"title":"Тема B"}]'::jsonb
  );
  if (v_sel->>'selection_id') is null then
    raise exception 'member_topic_publish_failed %', v_sel;
  end if;

  ------------------------------------------------------------------
  -- Ordinary member can create collection on group_space
  ------------------------------------------------------------------
  v_caps := public.get_chat_composer_capabilities(v_space_chat);
  if coalesce((v_caps->>'can_create_collection')::boolean, false) is not true then
    raise exception 'member_must_create_collection %', v_caps;
  end if;
  if coalesce((v_caps->>'can_create_topic_selection')::boolean, true) then
    raise exception 'space_member_must_not_create_topic %', v_caps;
  end if;
  if coalesce((v_caps->>'can_moderate_collection')::boolean, true) then
    raise exception 'member_must_not_moderate_collection %', v_caps;
  end if;

  v_col := public.create_group_collection(
    'Подарок преподавателю',
    'd', 'gift', now() + interval '3 days', 50, 'instr', 'secret',
    'per_person', null
  );
  if v_col is null then
    raise exception 'member_collection_create_failed';
  end if;

  ------------------------------------------------------------------
  -- DM forbidden
  ------------------------------------------------------------------
  v_caps := public.get_chat_composer_capabilities(v_dm_chat);
  if coalesce((v_caps->>'can_create_topic_selection')::boolean, true)
     or coalesce((v_caps->>'can_create_collection')::boolean, true)
     or coalesce((v_caps->>'can_create_assignment')::boolean, true) then
    raise exception 'dm_matrix_failed %', v_caps;
  end if;

  ------------------------------------------------------------------
  -- Non-member forbidden
  ------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform public.publish_topic_selection_for_chat(
      v_subject_chat, 'X', '', now() + interval '1 day', null, true, true, null,
      '[{"title":"t"}]'::jsonb
    );
    raise exception 'outsider_topic_allowed';
  exception when others then
    if position('outsider_topic_allowed' in sqlerrm) > 0 then raise; end if;
  end;

  ------------------------------------------------------------------
  -- Organizer deletes any group action; member cannot delete foreign
  ------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_org::text, true);
  v_caps := public.get_chat_composer_capabilities(v_space_chat);
  if coalesce((v_caps->>'can_delete_group_action')::boolean, false) is not true then
    raise exception 'organizer_must_delete %', v_caps;
  end if;
  perform public.delete_group_action('collection', v_col);

  v_foreign_sel := public.publish_topic_selection_for_chat(
    v_subject_chat, 'Org topic', '', now() + interval '3 days', null, true, true, null,
    '[{"title":"Z"}]'::jsonb
  );
  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  begin
    perform public.delete_group_action('topic', (v_foreign_sel->>'selection_id')::uuid);
    raise exception 'member_deleted_foreign_topic';
  exception when others then
    if position('member_deleted_foreign_topic' in sqlerrm) > 0 then raise; end if;
  end;

  ------------------------------------------------------------------
  -- Participant cannot self-confirm; cannot wipe organizer fields
  ------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_org::text, true);
  v_col := public.create_group_collection(
    'Ещё сбор', '', 'цель', now() + interval '2 days', null, '', '', 'none', null
  );
  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  perform public.upsert_my_collection_contribution(
    v_col, 'joining', 'reported', 100, 'ок', null
  );
  begin
    perform public.confirm_collection_contribution(
      v_col, v_stu, 'confirmed', 'self'
    );
    raise exception 'member_self_confirm_allowed';
  exception when others then
    if position('member_self_confirm_allowed' in sqlerrm) > 0 then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', v_org::text, true);
  perform public.confirm_collection_contribution(
    v_col, v_stu, 'confirmed', 'получено'
  );
  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  begin
    perform public.upsert_my_collection_contribution(
      v_col, 'joining', 'unmarked', null, 'wipe', null
    );
    raise exception 'member_wiped_organizer_status';
  exception when others then
    if position('member_wiped_organizer_status' in sqlerrm) > 0 then raise; end if;
  end;

  -- 24002820-style: student_id lookup if present must get create topic on subject
  if exists (
    select 1 from public.users u
    where u.login = '24002820'
  ) then
    select u.id into v_stu
    from public.users u
    where u.login = '24002820'
    limit 1;
    -- Prefer an active subject team (group_id + enrollment), never inactive orphans.
    select tm.team_id into v_subject_team
    from public.team_members tm
    join public.teams t on t.id = tm.team_id
    join public.student_enrollments se
      on se.user_id = tm.user_id
     and se.group_id = t.group_id
     and se.status = 'active'
     and se.ended_at is null
    where tm.user_id = v_stu
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
    order by t.name
    limit 1;
    if v_subject_team is not null then
      v_subject_chat := private.team_main_chat_id(v_subject_team);
      perform set_config('request.jwt.claim.sub', v_stu::text, true);
      v_caps := public.get_chat_composer_capabilities(v_subject_chat);
      if coalesce((v_caps->>'can_create_topic_selection')::boolean, false) is not true then
        raise exception 'account_24002820_missing_topic_create %', v_caps;
      end if;
    end if;
  end if;

  raise notice 'stage13_11 roleplay PASS';
end;
$$;

rollback;
