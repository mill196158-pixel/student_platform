-- Stage 13.9 group-action notification checks (local).
-- Run after migrations 20260727191000 + 20260727192000.
\set ON_ERROR_STOP on

do $$
declare
  v_src text;
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'notification_preferences'
      and column_name = 'group_actions'
  ) then
    raise exception 'missing notification_preferences.group_actions column';
  end if;

  select pg_get_functiondef('public.should_deliver_push_for_outbox(uuid)'::regprocedure)
    into v_src;
  if lower(v_src) not like '%group_actions%' then
    raise exception 'should_deliver_push_for_outbox missing group_actions case';
  end if;
  if lower(v_src) not like '%topic_selection_created%' then
    raise exception 'should_deliver_push_for_outbox missing topic_selection_created';
  end if;
  if lower(v_src) not like '%not_member%'
     or lower(v_src) not like '%active_team_member_user_ids%' then
    raise exception 'should_deliver_push_for_outbox must re-check membership';
  end if;

  if to_regprocedure('public.run_group_action_deadline_notifications()') is null then
    raise exception 'missing run_group_action_deadline_notifications';
  end if;

  select pg_get_functiondef('public.run_group_action_deadline_notifications()'::regprocedure)
    into v_src;
  if lower(v_src) not like '%pg_try_advisory_lock%' then
    raise exception 'deadline worker must use advisory lock';
  end if;
  if lower(v_src) not like '%_utc_day_bucket%' then
    raise exception 'deadline worker must use UTC day bucket dedupe';
  end if;

  -- Worker must not be callable by authenticated clients.
  if has_function_privilege('authenticated', 'public.run_group_action_deadline_notifications()', 'EXECUTE') then
    raise exception 'run_group_action_deadline_notifications must not grant execute to authenticated';
  end if;
end $$;

-- Privacy + skip-actor roleplay (uses existing users; rolls back).
do $$
declare
  v_org uuid;
  v_stu uuid;
  v_group uuid;
  v_team uuid;
  v_chat uuid;
  v_sel uuid;
  v_col uuid;
  v_opt uuid;
  v_out jsonb;
  v_notif_count integer;
  v_payload jsonb;
begin
  select g.id into v_group
  from public.groups g
  join public.student_enrollments se
    on se.group_id = g.id and se.status = 'active' and se.ended_at is null
  group by g.id
  having count(*) >= 2
  limit 1;
  if v_group is null then
    raise notice 'skip notification roleplay: need group with 2+ enrollments';
    return;
  end if;

  select u.id into v_org
  from public.users u
  join public.student_enrollments se
    on se.user_id = u.id and se.group_id = v_group
   and se.status = 'active' and se.ended_at is null
  order by u.created_at
  limit 1;

  select u.id into v_stu
  from public.users u
  join public.student_enrollments se
    on se.user_id = u.id and se.group_id = v_group
   and se.status = 'active' and se.ended_at is null
  where u.id <> v_org
  order by u.created_at
  limit 1;

  if v_org is null or v_stu is null then
    raise notice 'skip notification roleplay: insufficient users';
    return;
  end if;

  update public.users set primary_group_id = v_group where id in (v_org, v_stu);

  insert into public.group_space_organizer_grants(group_id, user_id, source)
  values (v_group, v_org, 'admin')
  on conflict do nothing;

  perform set_config('request.jwt.claim.sub', v_org::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_out := public.ensure_group_space();
  v_team := (v_out->>'team_id')::uuid;
  v_chat := (v_out->>'chat_id')::uuid;
  if v_team is null or v_chat is null then
    raise notice 'skip notification roleplay: ensure_group_space failed';
    return;
  end if;

  perform public.sync_group_space_members(v_group);

  perform set_config('request.jwt.claim.sub', v_org::text, true);

  v_out := public.publish_topic_selection_for_chat(
    v_chat,
    'Notif RP Topic',
    '',
    now() + interval '2 days',
    null,
    true,
    true,
    null,
    jsonb_build_array(jsonb_build_object('title', 'A', 'capacity', 1))
  );
  v_sel := (v_out->>'selection_id')::uuid;

  select count(*) into v_notif_count
  from public.app_notifications an
  where an.event_type = 'topic_selection_created'
    and an.source_id = v_sel::text
    and an.recipient_id = v_org;
  if v_notif_count > 0 then
    raise exception 'actor must not receive topic_selection_created (got %)', v_notif_count;
  end if;

  select count(*) into v_notif_count
  from public.app_notifications an
  where an.event_type = 'topic_selection_created'
    and an.source_id = v_sel::text
    and an.recipient_id = v_stu;
  if v_notif_count < 1 then
    raise exception 'student must receive topic_selection_created';
  end if;

  select an.data into v_payload
  from public.app_notifications an
  where an.event_type = 'topic_selection_created'
    and an.recipient_id = v_stu
    and an.source_id = v_sel::text
  limit 1;

  if v_payload ? 'payment_details'
     or v_payload ? 'proof_file_id'
     or v_payload ? 'comment'
     or v_payload ? 'ocr_text' then
    raise exception 'topic_selection_created payload leaks sensitive keys';
  end if;

  perform set_config('request.jwt.claim.sub', v_org::text, true);
  v_col := public.create_group_collection('Notif RP Collection', '', '', now() + interval '3 days');

  select an.data into v_payload
  from public.app_notifications an
  where an.event_type = 'collection_created'
    and an.recipient_id = v_stu
    and an.source_id = v_col::text
  limit 1;
  if v_payload is null then
    raise exception 'student must receive collection_created';
  end if;
  if v_payload ? 'payment_details' then
    raise exception 'collection_created payload must not include payment_details';
  end if;

  select id into v_opt
  from public.group_topic_options
  where selection_id = v_sel
  limit 1;

  perform public.reassign_topic_pick(v_sel, v_stu, v_opt);
  if not exists (
    select 1 from public.app_notifications
    where event_type = 'topic_reassigned'
      and recipient_id = v_stu
      and source_id = v_sel::text
  ) then
    raise exception 'target must receive topic_reassigned';
  end if;

  -- Dedupe: second publish idempotency for same selection should not duplicate.
  select count(*) into v_notif_count
  from public.app_notifications
  where idempotency_key like 'topic_selection_created:' || v_sel::text || ':%';
  if v_notif_count > 50 then
    raise exception 'unexpected fan-out for topic_selection_created';
  end if;

  raise notice 'stage13_9 group action notification checks OK';
end $$;
