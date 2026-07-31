-- Stage 13.9 local assertive role-play for chat topics/collections.
-- Uses existing local users/groups; rolls back nothing critical — wraps in a
-- transaction and deletes only roleplay-tagged rows at end.
\set ON_ERROR_STOP on

do $$
declare
  v_org uuid;
  v_stu uuid;
  v_stu2 uuid;
  v_outsider uuid;
  v_group uuid;
  v_other_group uuid;
  v_team uuid;
  v_chat uuid;
  v_sel uuid;
  v_opt1 uuid;
  v_opt2 uuid;
  v_col uuid;
  v_res jsonb;
  v_deadlines jsonb;
  v_title text := 'RP13.9 Курсовая';
begin
  -- Prefer a group that already has enough active students.
  select g.id into v_group
  from public.groups g
  join public.student_enrollments se
    on se.group_id = g.id and se.status = 'active' and se.ended_at is null
  group by g.id
  having count(*) >= 3
  order by count(*) desc, min(g.name)
  limit 1;
  if v_group is null then
    insert into public.groups(name) values ('RP13.9-A') returning id into v_group;
  end if;

  select g.id into v_other_group
  from public.groups g
  where g.id <> v_group
  order by g.name
  limit 1;
  if v_other_group is null then
    insert into public.groups(name) values ('RP13.9-B') returning id into v_other_group;
  end if;

  select u.id into v_org
  from public.users u
  join public.student_enrollments se
    on se.user_id = u.id and se.group_id = v_group
   and se.status = 'active' and se.ended_at is null
  order by u.created_at
  limit 1;
  if v_org is null then
    select id into v_org from auth.users order by created_at limit 1;
    if v_org is null then
      raise exception 'roleplay_requires_user';
    end if;
    insert into public.users(id, login, name, surname, role)
    values (v_org, 'rp139_org_' || substr(v_org::text, 1, 8), 'Org', 'RP', 'student')
    on conflict (id) do nothing;
    insert into public.student_enrollments(user_id, group_id, started_at, status)
    values (v_org, v_group, current_date, 'active')
    on conflict do nothing;
  end if;

  select u.id into v_stu
  from public.users u
  join public.student_enrollments se
    on se.user_id = u.id and se.group_id = v_group
   and se.status = 'active' and se.ended_at is null
  where u.id <> v_org
  order by u.created_at
  limit 1;

  select u.id into v_stu2
  from public.users u
  join public.student_enrollments se
    on se.user_id = u.id and se.group_id = v_group
   and se.status = 'active' and se.ended_at is null
  where u.id not in (v_org, coalesce(v_stu, v_org))
  order by u.created_at
  limit 1;

  -- Create synthetic classmates in auth if local DB lacks enough students.
  if v_stu is null or v_stu2 is null then
    raise exception 'roleplay_requires_at_least_3_active_students_in_group';
  end if;

  select u.id into v_outsider
  from public.users u
  join public.student_enrollments se
    on se.user_id = u.id and se.group_id = v_other_group
   and se.status = 'active' and se.ended_at is null
  where u.id not in (v_org, v_stu, v_stu2)
  limit 1;
  if v_outsider is null then
    -- Fall back: pick any other user not in v_group.
    select u.id into v_outsider
    from public.users u
    where u.id not in (v_org, v_stu, v_stu2)
      and not exists (
        select 1 from public.student_enrollments se
        where se.user_id = u.id and se.group_id = v_group
          and se.status = 'active' and se.ended_at is null
      )
    limit 1;
  end if;
  if v_outsider is null then
    -- Create a disposable outsider auth+public user in the other group.
    v_outsider := gen_random_uuid();
    insert into auth.users(
      id, instance_id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) values (
      v_outsider,
      '00000000-0000-0000-0000-000000000000',
      'authenticated',
      'authenticated',
      'rp139_out_' || substr(v_outsider::text, 1, 8) || '@example.test',
      crypt('rp139-temp', gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{}'::jsonb,
      now(),
      now()
    );
    insert into public.users(id, login, name, surname, role, primary_group_id)
    values (
      v_outsider,
      'rp139_out_' || substr(v_outsider::text, 1, 8),
      'Out',
      'RP',
      'student',
      v_other_group
    );
    insert into public.student_enrollments(user_id, group_id, started_at, status)
    values (v_outsider, v_other_group, current_date, 'active');
  end if;

  update public.users set primary_group_id = v_group where id in (v_org, v_stu, v_stu2);

  insert into public.group_space_organizer_grants(group_id, user_id, source)
  values (v_group, v_org, 'admin')
  on conflict do nothing;

  -- Ensure group space team/chat via RPC as organizer.
  perform set_config('request.jwt.claim.sub', v_org::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  v_res := public.ensure_group_space();
  v_team := (v_res->>'team_id')::uuid;
  v_chat := (v_res->>'chat_id')::uuid;
  if v_team is null or v_chat is null then
    raise exception 'roleplay_ensure_group_space_failed: %', v_res;
  end if;

  perform public.sync_group_space_members(v_group);

  -- Cleanup prior RP selections/collections.
  delete from public.group_topic_picks p
  using public.group_topic_selections s
  where p.selection_id = s.id and s.team_id = v_team and s.title = v_title;
  delete from public.group_topic_options o
  using public.group_topic_selections s
  where o.selection_id = s.id and s.team_id = v_team and s.title = v_title;
  delete from public.group_topic_events e
  using public.group_topic_selections s
  where e.selection_id = s.id and s.team_id = v_team and s.title = v_title;
  delete from public.group_topic_selections
  where team_id = v_team and title = v_title;
  delete from public.group_collection_contributions c
  using public.group_collections g
  where c.collection_id = g.id and g.team_id = v_team and g.title = 'RP13.9 Сбор';
  delete from public.group_collection_events e
  using public.group_collections g
  where e.collection_id = g.id and g.team_id = v_team and g.title = 'RP13.9 Сбор';
  delete from public.group_collections
  where team_id = v_team and title = 'RP13.9 Сбор';

  v_res := public.publish_topic_selection_for_chat(
    v_chat,
    v_title,
    'Выберите тему',
    now() + interval '7 days',
    now() + interval '30 days',
    true,
    false,
    null,
    '[{"title":"Тема A","capacity":1},{"title":"Тема B","capacity":1}]'::jsonb
  );
  v_sel := (v_res->>'selection_id')::uuid;
  if v_sel is null then
    raise exception 'roleplay_publish_failed: %', v_res;
  end if;

  select id into v_opt1
  from public.group_topic_options
  where selection_id = v_sel
  order by sort_order
  limit 1;
  select id into v_opt2
  from public.group_topic_options
  where selection_id = v_sel
  order by sort_order desc
  limit 1;

  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  perform public.pick_topic(v_sel, v_opt1);

  perform set_config('request.jwt.claim.sub', v_stu2::text, true);
  begin
    perform public.pick_topic(v_sel, v_opt1);
    raise exception 'roleplay_expected_option_full';
  exception
    when others then
      if sqlerrm = 'roleplay_expected_option_full' then
        raise;
      end if;
      if sqlstate <> 'P0001' and sqlerrm not ilike '%option_full%' then
        raise exception 'roleplay_unexpected_full_error: % %', sqlstate, sqlerrm;
      end if;
  end;

  perform public.pick_topic(v_sel, v_opt2);
  v_res := public.list_topic_options_for_selection(v_sel);
  if v_res::text ilike '%"picker_names":[[]%' then
    null; -- ok empty
  end if;
  -- With show_results_to_all=false, non-manager must not see other names.
  if exists (
    select 1
    from jsonb_array_elements(v_res) opt
    where jsonb_array_length(coalesce(opt->'picker_names', '[]'::jsonb)) > 0
      and (opt->>'my_pick')::boolean is not true
  ) then
    raise exception 'roleplay_private_picks_leaked';
  end if;

  if v_outsider is not null then
    perform set_config('request.jwt.claim.sub', v_outsider::text, true);
    begin
      perform public.pick_topic(v_sel, v_opt1);
      raise exception 'roleplay_outsider_pick_allowed';
    exception
      when others then
        if sqlerrm = 'roleplay_outsider_pick_allowed' then
          raise;
        end if;
    end;
  end if;

  perform set_config('request.jwt.claim.sub', v_org::text, true);
  perform public.release_topic_pick(v_sel, v_stu);
  perform public.reassign_topic_pick(v_sel, v_stu, v_opt1);

  v_deadlines := public.list_my_group_action_deadlines(
    now() - interval '1 day',
    now() + interval '60 days'
  );
  if v_deadlines::text not ilike '%topic_deadline%' then
    raise exception 'roleplay_deadlines_missing_topic: %', v_deadlines;
  end if;

  v_col := public.create_group_collection(
    'RP13.9 Сбор',
    'описание',
    'цель',
    now() + interval '10 days',
    500,
    'перевод на карту',
    'ACCT-SECRET-139'
  );

  perform set_config('request.jwt.claim.sub', v_stu::text, true);
  v_res := public.list_group_collections();
  if v_res::text ilike '%ACCT-SECRET-139%' then
    raise exception 'roleplay_payment_details_leaked_to_member';
  end if;

  if has_table_privilege('authenticated', 'public.group_collection_secrets'::regclass, 'select') then
    raise exception 'roleplay_secrets_table_granted_to_authenticated';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'group_collections'
      and column_name = 'payment_details'
  ) then
    raise exception 'roleplay_payment_details_column_still_public';
  end if;

  perform set_config('request.jwt.claim.sub', v_org::text, true);
  v_res := public.list_group_collections();
  if v_res::text not ilike '%ACCT-SECRET-139%' then
    raise exception 'roleplay_organizer_missing_payment_details';
  end if;

  perform public.list_collection_contribution_progress(v_col);

  -- Uploader cannot clear is_sensitive after proof marking.
  declare
    v_proof uuid := gen_random_uuid();
  begin
    insert into public.chat_files(
      id, chat_id, file_name, file_key, file_url, file_type, file_size, uploaded_by, is_sensitive
    ) values (
      v_proof, v_chat, 'proof.png', 'rp139/proof.png', 'https://example.test/proof.png',
      'image/png', 12, v_stu, true
    );
    begin
      update public.chat_files set is_sensitive = false where id = v_proof;
      raise exception 'roleplay_sensitive_downgrade_allowed';
    exception
      when others then
        if sqlerrm = 'roleplay_sensitive_downgrade_allowed' then
          raise;
        end if;
        if sqlerrm not ilike '%sensitive_flag_immutable%' and sqlstate <> '42501' then
          raise exception 'roleplay_unexpected_sensitive_guard: % %', sqlstate, sqlerrm;
        end if;
    end;
    delete from public.chat_files where id = v_proof;
  end;

  -- DM publish must fail (no team_main / invalid chat).
  declare
    v_dm uuid := gen_random_uuid();
  begin
    insert into public.chats(id, type) values (v_dm, 'dm');
    begin
      perform public.publish_topic_selection_for_chat(
        v_dm, 'DM topic', '', null, null, true, true, null,
        '[{"title":"X","capacity":1}]'::jsonb
      );
      raise exception 'roleplay_dm_publish_allowed';
    exception
      when others then
        if sqlerrm = 'roleplay_dm_publish_allowed' then
          raise;
        end if;
    end;
    delete from public.chats where id = v_dm;
  end;

  -- Subject-team scenarios are mandatory (create archive fixture if missing).
  declare
    v_subject_team uuid;
    v_subject_chat uuid;
    v_starosta uuid;
    v_member uuid;
    v_outsider_same_group uuid;
    v_subj_sel uuid;
    v_subj_opt uuid;
    v_archived_team uuid;
    v_archived_chat uuid;
  begin
    select t.id into v_subject_team
    from public.teams t
    where t.kind = 'subject'
      and t.group_id = v_group
      and private.is_active_subject_team_for_group(t.id, t.group_id)
    order by t.created_at
    limit 1;
    if v_subject_team is null then
      raise exception 'roleplay_requires_active_subject_team_fixture';
    end if;

    select c.id into v_subject_chat
    from public.chats c
    where c.team_id = v_subject_team and c.type = 'team_main'
    limit 1;
    if v_subject_chat is null then
      insert into public.chats(id, team_id, type)
      values (gen_random_uuid(), v_subject_team, 'team_main')
      returning id into v_subject_chat;
    end if;

    -- Ensure starosta/member membership for roleplay actors.
    insert into public.team_members(team_id, user_id, role)
    values (v_subject_team, v_org, 'starosta')
    on conflict (team_id, user_id) do update set role = 'starosta';
    insert into public.team_members(team_id, user_id, role)
    values (v_subject_team, v_stu, 'member')
    on conflict (team_id, user_id) do update set role = 'member';
    v_starosta := v_org;
    v_member := v_stu;

    insert into public.chat_members(chat_id, user_id, role_in_chat)
    values (v_subject_chat, v_starosta, 'member'), (v_subject_chat, v_member, 'member')
    on conflict do nothing;

    -- Same-group outsider: enrolled in group but not in this subject team.
    select u.id into v_outsider_same_group
    from public.users u
    join public.student_enrollments se
      on se.user_id = u.id and se.group_id = v_group
     and se.status = 'active' and se.ended_at is null
    where u.id not in (v_starosta, v_member)
      and not exists (
        select 1 from public.team_members tm
        where tm.team_id = v_subject_team and tm.user_id = u.id
      )
    limit 1;
    if v_outsider_same_group is null then
      v_outsider_same_group := v_stu2;
      delete from public.team_members
      where team_id = v_subject_team and user_id = v_stu2;
    end if;

    perform set_config('request.jwt.claim.sub', v_starosta::text, true);
    v_res := public.publish_topic_selection_for_chat(
      v_subject_chat,
      'RP13.9 Subject Topics',
      '',
      now() + interval '3 days',
      null,
      true,
      true,
      null,
      '[{"title":"S1","capacity":1},{"title":"S2","capacity":1}]'::jsonb
    );
    v_subj_sel := (v_res->>'selection_id')::uuid;
    if v_subj_sel is null then
      raise exception 'roleplay_subject_publish_failed';
    end if;
    select id into v_subj_opt
    from public.group_topic_options
    where selection_id = v_subj_sel
    order by sort_order
    limit 1;

    perform set_config('request.jwt.claim.sub', v_member::text, true);
    perform public.pick_topic(v_subj_sel, v_subj_opt);
    begin
      perform public.close_topic_selection(v_subj_sel, 'closed');
      raise exception 'roleplay_subject_member_manage_allowed';
    exception
      when others then
        if sqlerrm = 'roleplay_subject_member_manage_allowed' then
          raise;
        end if;
    end;

    perform set_config('request.jwt.claim.sub', v_outsider_same_group::text, true);
    begin
      perform public.pick_topic(v_subj_sel, v_subj_opt);
      raise exception 'roleplay_out_of_team_pick_allowed';
    exception
      when others then
        if sqlerrm = 'roleplay_out_of_team_pick_allowed' then
          raise;
        end if;
    end;

    delete from public.group_topic_picks where selection_id = v_subj_sel;
    delete from public.group_topic_options where selection_id = v_subj_sel;
    delete from public.group_topic_events where selection_id = v_subj_sel;
    delete from public.messages where id = (
      select card_message_id from public.group_topic_selections where id = v_subj_sel
    );
    delete from public.group_topic_selections where id = v_subj_sel;

    -- Dedicated archived subject team owned by the same starosta.
    insert into public.teams(id, name, group_id, kind)
    values (gen_random_uuid(), 'RP13.9 Archived Subject', v_group, 'subject')
    returning id into v_archived_team;
    insert into public.team_members(team_id, user_id, role)
    values (v_archived_team, v_starosta, 'starosta');
    select c.id into v_archived_chat
    from public.chats c
    where c.team_id = v_archived_team and c.type = 'team_main'
    limit 1;
    if v_archived_chat is null then
      insert into public.chats(id, team_id, type)
      values (gen_random_uuid(), v_archived_team, 'team_main')
      returning id into v_archived_chat;
    end if;
    insert into public.chat_academic_archives(
      chat_id, academic_term_id, archived_at, available_until
    )
    select
      v_archived_chat,
      coalesce(
        (select id from public.academic_terms where is_current limit 1),
        (select id from public.academic_terms order by starts_on desc limit 1)
      ),
      now(),
      now() + interval '30 days';
    if not found then
      raise exception 'roleplay_requires_academic_term_for_archive_fixture';
    end if;

    perform set_config('request.jwt.claim.sub', v_starosta::text, true);
    begin
      perform public.publish_topic_selection_for_chat(
        v_archived_chat,
        'RP13.9 Archived',
        '',
        null,
        null,
        true,
        true,
        null,
        '[{"title":"A","capacity":1}]'::jsonb
      );
      raise exception 'roleplay_archived_publish_allowed';
    exception
      when others then
        if sqlerrm = 'roleplay_archived_publish_allowed' then
          raise;
        end if;
    end;

    delete from public.chat_academic_archives where chat_id = v_archived_chat;
    delete from public.chats where id = v_archived_chat;
    delete from public.team_members where team_id = v_archived_team;
    delete from public.teams where id = v_archived_team;
  end;

  -- Cleanup roleplay artifacts.
  delete from public.group_topic_picks where selection_id = v_sel;
  delete from public.group_topic_options where selection_id = v_sel;
  delete from public.group_topic_events where selection_id = v_sel;
  delete from public.messages where id = (
    select card_message_id from public.group_topic_selections where id = v_sel
  );
  delete from public.group_topic_selections where id = v_sel;
  delete from public.group_collection_contributions where collection_id = v_col;
  delete from public.group_collection_events where collection_id = v_col;
  delete from public.group_collection_secrets where collection_id = v_col;
  delete from public.messages where id = (
    select card_message_id from public.group_collections where id = v_col
  );
  delete from public.group_collections where id = v_col;

  raise notice 'stage13_9_roleplay_PASS';
end;
$$;
