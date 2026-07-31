-- Stage 13.8 local assertive role-play for safe academic terms.
-- Run as a privileged local role (postgres/service). Fixtures are created first,
-- then JWT is switched to authenticated for RPC/direct-write assertions.
\set ON_ERROR_STOP on

do $$
declare
  v_admin uuid;
  v_student uuid;
  v_group uuid;
  v_year_a uuid := gen_random_uuid();
  v_year_b uuid := gen_random_uuid();
  v_current uuid := gen_random_uuid();
  v_next uuid := gen_random_uuid();
  v_past uuid := gen_random_uuid();
  v_skip uuid := gen_random_uuid();
  v_subject uuid := gen_random_uuid();
  v_curriculum uuid := gen_random_uuid();
  v_before_current uuid;
  v_archives_before integer;
  v_archives_after integer;
  v_result jsonb;
  v_group_space_archived integer;
  v_current_count integer;
begin
  -- Privileged fixture setup (must happen before authenticated role switch).
  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is not null then
    execute $q$
      select u.id
      from public.users u
      where private.has_admin_permission(u.id, 'terms.manage', 'global', null::uuid)
      limit 1
    $q$ into v_admin;
  end if;
  if v_admin is null then
    select id into v_admin from auth.users order by created_at limit 1;
  end if;
  if v_admin is null then
    raise exception 'roleplay_requires_admin_user';
  end if;

  select g.id into v_group from public.groups g order by g.name limit 1;
  if v_group is null then
    raise exception 'roleplay_requires_group';
  end if;

  select se.user_id into v_student
  from public.student_enrollments se
  where se.group_id = v_group
    and se.status = 'active'
    and se.ended_at is null
  limit 1;
  if v_student is null then
    select u.id into v_student
    from public.users u
    where private.stage13_5_is_student_account(u.id)
    limit 1;
  end if;
  if v_student is null then
    raise exception 'roleplay_requires_student';
  end if;

  if not exists (
    select 1 from public.student_enrollments se
    where se.user_id = v_student and se.group_id = v_group
      and se.status = 'active' and se.ended_at is null
  ) then
    insert into public.student_enrollments(user_id, group_id, started_at, status)
    values (v_student, v_group, current_date, 'active');
  end if;

  insert into public.academic_years(id, name, start_year, starts_on, ends_on, is_current)
  values
    (v_year_a, 'roleplay-13-8-a', 2090, '2090-09-01', '2091-08-31', false),
    (v_year_b, 'roleplay-13-8-b', 2091, '2091-09-01', '2092-08-31', false);

  perform set_config('private.allow_term_current_flip', '1', true);
  update public.academic_terms set is_current = false where is_current;
  insert into public.academic_terms(
    id, academic_year_id, term_in_year, term_sequence, name, starts_on, ends_on, is_current
  ) values
    (v_past, v_year_a, 1, 20901, 'roleplay past', '2090-02-01', '2090-06-30', false),
    (v_current, v_year_a, 2, 20902, 'roleplay current', '2090-09-01', '2091-01-31', true),
    (v_next, v_year_b, 1, 20903, 'roleplay next', '2091-02-01', '2091-06-30', false),
    (v_skip, v_year_b, 2, 20904, 'roleplay skip', '2091-09-01', '2092-01-31', false);
  perform set_config('private.allow_term_current_flip', '0', true);

  if to_regclass('public.subject_catalog') is not null then
    insert into public.subject_catalog(id, canonical_name, normalized_name, status)
    values (v_subject, 'RP 13.8 Subject', 'rp 13.8 subject', 'published')
    on conflict (id) do nothing;
  end if;

  if to_regclass('public.curriculum_subjects') is not null then
    insert into public.curriculum_subjects(
      id, subject_id, raw_subject_name, display_name, semester_number, is_elective
    ) values (
      v_curriculum, v_subject, 'RP 13.8 Subject', 'RP 13.8 Subject', 1, false
    )
    on conflict (id) do nothing;
  end if;

  if to_regclass('public.group_term_semesters') is not null then
    execute $q$
      insert into public.group_term_semesters(
        group_id, academic_year_id, academic_term_id, semester_number
      ) values
        ($1, $2, $3, 2),
        ($1, $4, $5, 1)
      on conflict do nothing
    $q$ using v_group, v_year_a, v_current, v_year_b, v_next;
  end if;

  -- JWT claims make SECURITY DEFINER RPCs see the admin actor.
  -- Keep privileged role for fixture/count reads; use SET LOCAL ROLE only for
  -- direct-table denial checks.
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  -- Permission must be proven via public SECURITY DEFINER RPC, not private helper.
  begin
    perform public.admin_term_readiness(v_next);
  exception when others then
    if sqlerrm ilike '%forbidden%' or sqlerrm ilike '%not_authenticated%' then
      raise exception 'roleplay_admin_lacks_terms_manage';
    end if;
    raise;
  end;

  select id into v_before_current from public.academic_terms where is_current limit 1;
  select count(*)::integer into v_archives_before from public.chat_academic_archives;

  v_result := public.admin_term_backfill(v_next);
  if coalesce((v_result->>'current_unchanged')::boolean, false) is not true then
    raise exception 'backfill_must_keep_current';
  end if;
  if (select id from public.academic_terms where is_current limit 1) is distinct from v_before_current then
    raise exception 'backfill_changed_current';
  end if;
  select count(*)::integer into v_archives_after from public.chat_academic_archives;
  if v_archives_after <> v_archives_before then
    raise exception 'backfill_archived_chats';
  end if;

  begin
    perform public.admin_start_next_term(v_past, 'roleplay past');
    raise exception 'past_term_activation_succeeded';
  exception when others then
    if sqlerrm like '%past_term_activation_succeeded%' then raise; end if;
  end;

  begin
    perform public.admin_start_next_term(v_skip, 'roleplay skip');
    raise exception 'skip_ahead_activation_succeeded';
  exception when others then
    if sqlerrm like '%skip_ahead_activation_succeeded%' then raise; end if;
  end;

  begin
    perform public.admin_set_current_term(v_past);
    raise exception 'set_current_succeeded';
  exception when others then
    if sqlerrm like '%set_current_succeeded%' then raise; end if;
  end;

  begin
    perform public.admin_prepare_term_apply(v_next, true);
    raise exception 'prepare_set_current_succeeded';
  exception when others then
    if sqlerrm like '%prepare_set_current_succeeded%' then raise; end if;
  end;

  begin
    execute 'set local role authenticated';
    update public.academic_terms set is_current = true where id = v_past;
    raise exception 'direct_update_succeeded';
  exception when others then
    execute 'reset role';
    if sqlerrm like '%direct_update_succeeded%' then raise; end if;
  end;
  execute 'reset role';

  -- Required successful forward transition.
  v_result := public.admin_start_next_term(v_next, 'roleplay next');
  select count(*)::integer into v_current_count from public.academic_terms where is_current;
  if v_current_count <> 1 then
    raise exception 'current_not_unique_after_transition';
  end if;
  if not exists (select 1 from public.academic_terms where id = v_next and is_current) then
    raise exception 'next_not_current_after_transition';
  end if;

  select count(*)::integer into v_group_space_archived
  from public.chat_academic_archives caa
  join public.chats c on c.id = caa.chat_id
  join public.teams t on t.id = c.team_id
  where caa.academic_term_id = v_current
    and t.kind = 'group_space';
  if v_group_space_archived > 0 then
    raise exception 'group_space_was_archived';
  end if;

  -- Intentional failure path: confirm mismatch must fully roll back.
  begin
    perform public.admin_start_next_term(v_skip, 'wrong name');
    raise exception 'confirm_mismatch_succeeded';
  exception when others then
    if sqlerrm like '%confirm_mismatch_succeeded%' then raise; end if;
  end;
  if not exists (select 1 from public.academic_terms where id = v_next and is_current) then
    raise exception 'rollback_lost_current_after_failed_skip';
  end if;

  raise notice 'stage13_8 assertive roleplay completed';
end;
$$;
