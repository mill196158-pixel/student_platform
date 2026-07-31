-- Stage 17.1 ready-publish roleplay (LOCAL ONLY, disposable).
-- Asserts: admin/demo draft OK; user_submission forbidden; submitter forbidden;
-- stale row_version fails with unchanged state; journal has 3 steps.
-- Never run against production / never --linked.

begin;

do $$
declare
  v_admin uuid;
  v_student uuid;
  v_admin_draft uuid;
  v_demo_draft uuid;
  v_user_draft uuid;
  v_submitter_draft uuid;
  v_stale uuid;
  v_rv integer;
  v_status text;
  v_actions integer;
  v_err text;
begin
  select a.user_id into v_admin
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and (
      private.has_admin_permission(a.user_id, 'moderation.action', 'global', null)
      or private.has_admin_permission(a.user_id, 'moderation.write', 'global', null)
    )
    and private.has_admin_permission(a.user_id, 'content.publish', 'global', null)
  limit 1;

  if v_admin is null then
    raise exception
      'stage17_1 ready_publish roleplay BLOCKED: missing moderation.* + content.publish admin';
  end if;

  select u.id into v_student
  from public.users u
  where u.is_active
    and u.id <> v_admin
  limit 1;
  if v_student is null then
    v_student := gen_random_uuid();
    insert into public.users (id, email)
    values (v_student, 'ready-publish-student@example.com')
    on conflict (id) do nothing;
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  insert into public.vacancies (
    id, title, company_name, summary, description, status, origin,
    audience_mode, created_by, updated_by, row_version, version_number
  ) values (
    gen_random_uuid(), 'Ready Admin', 'Org', 'Sum', 'Desc body',
    'draft', 'admin', 'all', v_admin, v_admin, 1, 1
  ) returning id, row_version into v_admin_draft, v_rv;

  insert into public.vacancies (
    id, title, company_name, summary, description, status, origin,
    audience_mode, created_by, updated_by, row_version, version_number
  ) values (
    gen_random_uuid(), 'Ready Demo', 'Org', 'Sum', 'Desc body',
    'draft', 'demo', 'all', v_admin, v_admin, 1, 1
  ) returning id into v_demo_draft;

  insert into public.vacancies (
    id, title, company_name, summary, description, status, origin,
    audience_mode, created_by, updated_by, row_version, version_number
  ) values (
    gen_random_uuid(), 'User Sub', 'Org', 'Sum', 'Desc body',
    'draft', 'user_submission', 'all', v_student, v_student, 1, 1
  ) returning id into v_user_draft;

  insert into public.vacancies (
    id, title, company_name, summary, description, status, origin,
    audience_mode, submitted_by, submitted_at, created_by, updated_by,
    row_version, version_number
  ) values (
    gen_random_uuid(), 'Has Submitter', 'Org', 'Sum', 'Desc body',
    'draft', 'admin', 'all', v_student, now(), v_admin, v_admin, 1, 1
  ) returning id into v_submitter_draft;

  insert into public.vacancies (
    id, title, company_name, summary, description, status, origin,
    audience_mode, created_by, updated_by, row_version, version_number
  ) values (
    gen_random_uuid(), 'Stale RV', 'Org', 'Sum', 'Desc body',
    'draft', 'admin', 'all', v_admin, v_admin, 3, 1
  ) returning id into v_stale;

  -- Happy path admin draft
  perform public.admin_ready_publish_vacancy(v_admin_draft, v_rv);
  select status into v_status from public.vacancies where id = v_admin_draft;
  if v_status <> 'published' then
    raise exception 'expected published, got %', v_status;
  end if;
  select count(*)::integer into v_actions
  from public.vacancy_moderation_actions
  where vacancy_id = v_admin_draft
    and action in ('take_in_moderation', 'approve', 'publish');
  if v_actions < 3 then
    raise exception 'expected 3 journal actions, got %', v_actions;
  end if;

  -- Demo draft
  select row_version into v_rv from public.vacancies where id = v_demo_draft;
  perform public.admin_ready_publish_vacancy(v_demo_draft, v_rv);
  select status into v_status from public.vacancies where id = v_demo_draft;
  if v_status <> 'published' then
    raise exception 'demo expected published, got %', v_status;
  end if;

  -- user_submission forbidden
  begin
    select row_version into v_rv from public.vacancies where id = v_user_draft;
    perform public.admin_ready_publish_vacancy(v_user_draft, v_rv);
    raise exception 'user_submission should fail';
  exception
    when others then
      v_err := sqlerrm;
      if position('ready_publish_origin_forbidden' in v_err) = 0 then
        raise;
      end if;
  end;
  select status into v_status from public.vacancies where id = v_user_draft;
  if v_status <> 'draft' then
    raise exception 'user_submission partial state %', v_status;
  end if;

  -- submitted_by forbidden
  begin
    select row_version into v_rv from public.vacancies where id = v_submitter_draft;
    perform public.admin_ready_publish_vacancy(v_submitter_draft, v_rv);
    raise exception 'submitter draft should fail';
  exception
    when others then
      v_err := sqlerrm;
      if position('ready_publish_has_submitter' in v_err) = 0 then
        raise;
      end if;
  end;
  select status into v_status from public.vacancies where id = v_submitter_draft;
  if v_status <> 'draft' then
    raise exception 'submitter partial state %', v_status;
  end if;

  -- stale row_version: expect conflict and unchanged draft
  begin
    perform public.admin_ready_publish_vacancy(v_stale, 1); -- actual rv=3
    raise exception 'stale row_version should fail';
  exception
    when others then
      v_err := sqlerrm;
      if position('row_version' in lower(v_err)) = 0
         and position('conflict' in lower(v_err)) = 0
         and position('changed' in lower(v_err)) = 0 then
        raise exception 'unexpected stale error: %', v_err;
      end if;
  end;
  select status, row_version into v_status, v_rv
  from public.vacancies where id = v_stale;
  if v_status <> 'draft' or v_rv <> 3 then
    raise exception 'stale call mutated state status=% rv=%', v_status, v_rv;
  end if;

  raise notice 'stage17_1 ready_publish roleplay OK';
end;
$$;

rollback;
