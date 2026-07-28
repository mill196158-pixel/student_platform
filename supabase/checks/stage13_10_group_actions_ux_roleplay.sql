-- Stage 13.10 behavioral local roleplay (disposable transaction).
-- Requires Stage 13.10 migration + optional ephemeral_assignments_baseline.sql.
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
  v_res jsonb;
  v_col uuid;
  v_sel jsonb;
  v_status text;
  v_org_comment text;
  v_comment text;
  v_deadlines jsonb;
  v_title text;
  v_has_completion boolean;
  v_legacy uuid;
  v_opt uuid;
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
  -- Product matrix via capabilities
  ------------------------------------------------------------------
  v_caps := public.get_chat_composer_capabilities(v_dm_chat);
  if coalesce((v_caps->>'show_propose_assignment')::boolean, true)
     or coalesce((v_caps->>'show_topic_selection')::boolean, true)
     or coalesce((v_caps->>'show_collection')::boolean, true)
     or coalesce((v_caps->>'can_propose_assignment')::boolean, true)
     or coalesce((v_caps->>'can_create_topic_selection')::boolean, true)
     or coalesce((v_caps->>'can_create_collection')::boolean, true) then
    raise exception 'dm_matrix_failed %', v_caps;
  end if;

  v_caps := public.get_chat_composer_capabilities(v_subject_chat);
  if not coalesce((v_caps->>'show_propose_assignment')::boolean, false)
     or not coalesce((v_caps->>'show_topic_selection')::boolean, false)
     or coalesce((v_caps->>'show_collection')::boolean, true)
     or not coalesce((v_caps->>'can_create_topic_selection')::boolean, false) then
    raise exception 'subject_matrix_failed %', v_caps;
  end if;

  v_caps := public.get_chat_composer_capabilities(v_space_chat);
  if not coalesce((v_caps->>'show_propose_assignment')::boolean, false)
     or coalesce((v_caps->>'show_topic_selection')::boolean, true)
     or not coalesce((v_caps->>'show_collection')::boolean, false)
     or not coalesce((v_caps->>'can_create_collection')::boolean, false)
     or coalesce((v_caps->>'can_create_topic_selection')::boolean, true) then
    raise exception 'group_space_matrix_failed %', v_caps;
  end if;

  -- Non-organizer member: topic/collection create disabled, propose may remain.
  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  v_caps := public.get_chat_composer_capabilities(v_subject_chat);
  if coalesce((v_caps->>'can_create_topic_selection')::boolean, true) then
    raise exception 'member_should_not_create_topic %', v_caps;
  end if;
  v_caps := public.get_chat_composer_capabilities(v_space_chat);
  if coalesce((v_caps->>'can_create_collection')::boolean, true) then
    raise exception 'member_should_not_create_collection %', v_caps;
  end if;

  ------------------------------------------------------------------
  -- Ordinary assignments (requires ephemeral baseline / Stage 4.2 table)
  ------------------------------------------------------------------
  if to_regclass('public.assignments') is null then
    raise exception 'assignments_table_missing_apply_ephemeral_baseline';
  end if;

  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform public.propose_assignment(v_subject_team, 'RP13.10 Out', 'x');
    raise exception 'outsider_propose_allowed';
  exception when others then
    if position('outsider_propose_allowed' in sqlerrm) > 0 then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  v_res := public.propose_assignment(v_subject_team, 'RP13.10 Draft', 'member desc');
  if (v_res->>'status') <> 'draft' then
    raise exception 'member_draft_expected %', v_res;
  end if;

  perform set_config('request.jwt.claim.sub', v_org::text, true);
  v_res := public.propose_assignment(v_space_team, 'RP13.10 Group HW', 'group space assignment');
  if (v_res->>'status') <> 'published' then
    raise exception 'group_space_assignment_expected_published %', v_res;
  end if;

  v_res := public.propose_assignment(v_subject_team, 'RP13.10 Subject HW', 'subject assignment');
  if (v_res->>'status') <> 'published' then
    raise exception 'subject_assignment_expected_published %', v_res;
  end if;

  ------------------------------------------------------------------
  -- Topic: subject only, one deadline, schedule projection title
  ------------------------------------------------------------------
  begin
    perform public.publish_topic_selection_for_chat(
      v_space_chat, 'RP13.10 Bad Topic', '', now() + interval '1 day', null,
      true, true, null, '[{"title":"T1"}]'::jsonb
    );
    raise exception 'space_topic_allowed';
  exception when others then
    if position('space_topic_allowed' in sqlerrm) > 0 then raise; end if;
    if position('topic_selection_subject_only' in sqlerrm) = 0
       and position('forbidden' in lower(sqlerrm)) = 0 then
      raise;
    end if;
  end;

  -- DM cannot publish topic
  begin
    perform public.publish_topic_selection_for_chat(
      v_dm_chat, 'RP13.10 DM Topic', '', now() + interval '1 day', null,
      true, true, null, '[{"title":"T1"}]'::jsonb
    );
    raise exception 'dm_topic_allowed';
  exception when others then
    if position('dm_topic_allowed' in sqlerrm) > 0 then raise; end if;
  end;

  v_sel := public.publish_topic_selection_for_chat(
    v_subject_chat,
    'Выбрать тему доклада',
    'optional',
    now() + interval '2 days',
    now() + interval '9 days', -- legacy completion arg ignored for write
    true, true, null,
    '[{"title":"Тема A"},{"title":"Тема B"}]'::jsonb
  );
  if (v_sel->>'selection_id') is null then
    raise exception 'topic_publish_failed %', v_sel;
  end if;

  select (completion_deadline_at is not null)
    into v_has_completion
  from public.group_topic_selections
  where id = (v_sel->>'selection_id')::uuid;
  if v_has_completion then
    raise exception 'completion_deadline_should_be_null_on_new_rows';
  end if;

  v_deadlines := public.list_my_group_action_deadlines(
    now() - interval '1 day', now() + interval '30 days'
  );
  if jsonb_typeof(v_deadlines) <> 'array'
     or not exists (
       select 1 from jsonb_array_elements(v_deadlines) e
       where e->>'title' = 'Выбрать тему доклада'
         and e->>'event_type' = 'topic_deadline'
     ) then
    raise exception 'schedule_missing_real_topic_title %', v_deadlines;
  end if;
  -- Ensure no technical type labels leak into title fields.
  if exists (
    select 1 from jsonb_array_elements(v_deadlines) e
    where e->>'title' in ('Выбор темы', 'Сбор', 'topic_selection', 'collection')
  ) then
    raise exception 'schedule_has_technical_titles %', v_deadlines;
  end if;

  ------------------------------------------------------------------
  -- Collection: group-space only; participant cannot self-confirm;
  -- organizer_comment preserved
  ------------------------------------------------------------------
  v_col := public.create_group_collection(
    'Скинуться на подарок преподавателю',
    'd', 'gift', now() + interval '3 days', 50, 'instr', 'secret'
  );

  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  perform public.upsert_my_collection_contribution(
    v_col, 'joining', 'reported', null, 'paid', null
  );
  -- Participant cannot set confirmed
  begin
    perform public.upsert_my_collection_contribution(
      v_col, 'joining', 'confirmed', null, 'hack', null
    );
    raise exception 'participant_self_confirm_allowed';
  exception when others then
    if position('participant_self_confirm_allowed' in sqlerrm) > 0 then raise; end if;
    if position('invalid_payment_status' in sqlerrm) = 0 then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', v_org::text, true);
  perform public.confirm_collection_contribution(
    v_col, v_stu, 'needs_clarification', 'Нужен другой скрин'
  );
  select payment_status, organizer_comment, comment
    into v_status, v_org_comment, v_comment
  from public.group_collection_contributions
  where collection_id = v_col and user_id = v_stu;
  if v_status <> 'needs_clarification' or v_org_comment <> 'Нужен другой скрин' then
    raise exception 'organizer_note_missing % %', v_status, v_org_comment;
  end if;

  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  perform public.upsert_my_collection_contribution(
    v_col, 'joining', 'reported', null, 'new note', null
  );
  select payment_status, organizer_comment, comment
    into v_status, v_org_comment, v_comment
  from public.group_collection_contributions
  where collection_id = v_col and user_id = v_stu;
  if v_status <> 'needs_clarification' then
    raise exception 'status_overwritten %', v_status;
  end if;
  if v_org_comment <> 'Нужен другой скрин' then
    raise exception 'organizer_comment_overwritten %', v_org_comment;
  end if;

  -- Collection must not appear as diary/material; schedule deadline title is real.
  perform set_config('request.jwt.claim.sub', v_org::text, true);
  v_deadlines := public.list_my_group_action_deadlines(
    now() - interval '1 day', now() + interval '30 days'
  );
  if not exists (
    select 1 from jsonb_array_elements(v_deadlines) e
    where e->>'event_type' = 'collection_deadline'
      and e->>'title' = 'Скинуться на подарок преподавателю'
  ) then
    raise exception 'collection_schedule_title_missing %', v_deadlines;
  end if;
  v_title := 'Скинуться на подарок преподавателю';

  -- Cross-group confirm denied
  begin
    perform public.confirm_collection_contribution(v_col, v_outsider, 'confirmed', null);
    raise exception 'cross_group_confirm_allowed';
  exception when others then
    if position('cross_group_confirm_allowed' in sqlerrm) > 0 then raise; end if;
    if position('target_not_member' in sqlerrm) = 0 then raise; end if;
  end;

  -- Collection create is organizer/space only: subject member path already
  -- denied by can_manage_team_collections (no subject create RPC).

  -- Legacy group_space topic: even if an open row exists, pick is denied.
  insert into public.group_topic_selections(
    group_id, team_id, created_by, title, description, deadline_at, status,
    allow_change, show_results_to_all
  ) values (
    v_group, v_space_team, v_org, 'RP13.10 Legacy Space Topic', '',
    now() + interval '2 days', 'open', true, true
  ) returning id into v_legacy;
  insert into public.group_topic_options(selection_id, title, capacity, sort_order)
  values (v_legacy, 'Opt', 5, 1)
  returning id into v_opt;
  begin
    perform public.pick_topic(v_legacy, v_opt);
    raise exception 'space_pick_allowed';
  exception when others then
    if position('space_pick_allowed' in sqlerrm) > 0 then raise; end if;
    if position('topic_selection_subject_only' in sqlerrm) = 0
       and position('selection_unavailable' in sqlerrm) = 0 then
      raise;
    end if;
  end;

  -- Mirror migration cleanup: open group_space topics become cancelled.
  update public.group_topic_selections s
  set status = 'cancelled',
      closed_at = coalesce(s.closed_at, now()),
      updated_at = now()
  from public.teams t
  where t.id = s.team_id
    and coalesce(t.kind, 'subject') = 'group_space'
    and s.status = 'open'
    and s.id = v_legacy;
  if exists (
    select 1 from public.group_topic_selections
    where id = v_legacy and status = 'open'
  ) then
    raise exception 'legacy_space_topic_still_open';
  end if;

  -- Archive deny: if subject chat archived, propose forbidden
  insert into public.chat_academic_archives(
    chat_id, academic_term_id, archived_at, available_until
  )
  select
    v_subject_chat,
    at.id,
    now(),
    now() + interval '30 days'
  from public.academic_terms at
  order by at.created_at nulls last
  limit 1
  on conflict (chat_id) do update
    set archived_at = excluded.archived_at,
        available_until = excluded.available_until;
  begin
    perform public.propose_assignment(v_subject_team, 'RP13.10 Archived', 'x');
    raise exception 'archived_propose_allowed';
  exception when others then
    if position('archived_propose_allowed' in sqlerrm) > 0 then raise; end if;
    -- Either explicit archive gate or membership/active-subject collapse is OK.
    if position('chat_archived' in sqlerrm) = 0
       and position('forbidden' in sqlerrm) = 0
       and position('subject_inactive' in sqlerrm) = 0 then
      raise;
    end if;
  end;
  delete from public.chat_academic_archives where chat_id = v_subject_chat;

  raise notice 'stage13_10_group_actions_ux_roleplay BEHAVIORAL PASS';
end $$;

rollback;
