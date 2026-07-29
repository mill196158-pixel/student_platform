-- Stage 16–19 P1 behavioral role-play (disposable transaction).
--
-- Requires a LOCAL apply of:
--   20260729150500_stage16_1_subject_card_foundation.sql
--   20260729150600_stage16_2_subject_assets.sql
--   20260729150700_stage16_3_reference_corrections.sql
--   20260729151000_stage17_vacancies_domain.sql
--   20260729152000_stage18_reviews_points_moderation.sql
--   20260729153000_stage19_import_studio_foundation.sql
--
-- Never run against production / never --linked. The whole script runs inside a
-- transaction that ends in ROLLBACK, so nothing it writes survives.
--
-- Fixture absence => explicit SKIP rows, never a silent PASS.
--
-- This file exists to cover the Codex round-1 P1 findings BEHAVIORALLY, next to
-- the static structural reviews (stage16_1 / 16_2 / 16_3 / 17 / 18 / 19
-- *_security_review.sql). Scope, by stage:
--
--   16.2  IDOR on the asset version chain; a published card cannot lose its
--         current file; students never receive storage paths.
--   16.3  IDOR on reporting; one open report per (item, reporter); reporter
--         anonymity towards moderators; no double resolution.
--   17    a draft is not recorded as `take_in_moderation`; cron expiry snapshots
--         and audits; a published vacancy's file cannot be deleted; contacts
--         stay private outside the audience.
--   18    an approval is recorded as `approve`; the legacy RPC cannot bypass
--         points compensation; re-credit after a debit; rejected -> resubmit ->
--         pending; the backfill is idempotent.
--   19    per-operator batch ownership; unimplemented domains raise; rollback
--         refuses.
--
-- Role simulation follows the Stage 15.2 role-play convention: the JWT claim is
-- swapped with set_config so auth.uid() inside the SECURITY DEFINER RPCs sees
-- the acting user, and RBAC is exercised for real. Direct table writes are used
-- ONLY to build fixtures (publishing states, backdating rate-limit windows)
-- that a single transaction cannot reach through the RPCs.

begin;

create temporary table if not exists stage16_19_roleplay_results (
  scenario text primary key,
  status text not null check (status in ('PASS', 'FAIL', 'SKIP')),
  detail text not null default ''
) on commit drop;

grant all on table stage16_19_roleplay_results to authenticated, anon, service_role;

create or replace function pg_temp.rp_pass(
  p_scenario text,
  p_ok boolean,
  p_detail text default ''
)
returns void
language plpgsql as $fn$
begin
  insert into stage16_19_roleplay_results(scenario, status, detail)
  values (p_scenario, case when p_ok then 'PASS' else 'FAIL' end, coalesce(p_detail, ''))
  on conflict (scenario) do update
    set status = excluded.status, detail = excluded.detail;
end;
$fn$;

create or replace function pg_temp.rp_skip(
  p_scenario text,
  p_detail text default ''
)
returns void
language plpgsql as $fn$
begin
  insert into stage16_19_roleplay_results(scenario, status, detail)
  values (p_scenario, 'SKIP', coalesce(p_detail, ''))
  on conflict (scenario) do update
    set status = excluded.status, detail = excluded.detail;
end;
$fn$;

-- Runs p_sql and PASSes only if it raised, optionally matching sqlstate and/or
-- message. A success where a refusal was expected is a FAIL, never a SKIP.
create or replace function pg_temp.rp_expect_exception(
  p_scenario text,
  p_sql text,
  p_errcode text default null,
  p_message_like text default null
)
returns void
language plpgsql as $fn$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
    perform pg_temp.rp_pass(p_scenario, false, 'expected exception, got success');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform pg_temp.rp_pass(
      p_scenario,
      (p_errcode is null or v_state = p_errcode)
        and (p_message_like is null or v_msg ilike '%' || p_message_like || '%'),
      format('state=%s msg=%s', v_state, v_msg)
    );
  end;
end;
$fn$;

create or replace function pg_temp.rp_expect_success(
  p_scenario text,
  p_sql text
)
returns void
language plpgsql as $fn$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
    perform pg_temp.rp_pass(p_scenario, true, 'ok');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform pg_temp.rp_pass(
      p_scenario, false, format('unexpected state=%s msg=%s', v_state, v_msg)
    );
  end;
end;
$fn$;

create or replace function pg_temp.rp_as_user(p_user_id uuid)
returns void
language plpgsql as $fn$
begin
  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_user_id::text, 'role', 'authenticated')::text,
    true
  );
end;
$fn$;

create or replace function pg_temp.rp_as_nobody()
returns void
language plpgsql as $fn$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
end;
$fn$;

-- Any active admin holding every listed permission.
create or replace function pg_temp.rp_admin_with(p_permissions text[])
returns uuid
language plpgsql as $fn$
declare
  v_uid uuid;
begin
  select a.user_id into v_uid
  from public.admin_role_assignments a
  where a.is_active
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and not exists (
      select 1 from unnest(p_permissions) as perm(code)
      where not private.has_admin_permission(a.user_id, perm.code, 'global', null)
    )
  limit 1;
  return v_uid;
end;
$fn$;

-- A second, distinct admin with the same permissions (for cross-operator IDOR).
create or replace function pg_temp.rp_other_admin_with(
  p_permissions text[],
  p_exclude uuid
)
returns uuid
language plpgsql as $fn$
declare
  v_uid uuid;
begin
  select a.user_id into v_uid
  from public.admin_role_assignments a
  where a.is_active
    and a.user_id is distinct from p_exclude
    and private.admin_assignment_is_effective(a.is_active, a.expires_at)
    and not exists (
      select 1 from unnest(p_permissions) as perm(code)
      where not private.has_admin_permission(a.user_id, perm.code, 'global', null)
    )
  limit 1;
  return v_uid;
end;
$fn$;

-- ===========================================================================
-- Stage 16.2 — subject files / private assets
-- ===========================================================================
do $$
declare
  v_admin uuid;
  v_student uuid;
  v_outsider uuid;
  v_subject uuid;
  v_other_subject uuid;
  v_offering uuid;
  v_group uuid;
  v_asset uuid;
  v_asset_v2 uuid;
  v_json jsonb;
begin
  v_admin := pg_temp.rp_admin_with(array['subjects.write']);
  if v_admin is null then
    perform pg_temp.rp_skip('16.2 all', 'no active admin with subjects.write');
    return;
  end if;

  -- A subject whose card is PUBLISHED: that is the state a delete must protect.
  select p.subject_id into v_subject
  from public.subject_student_profiles p
  join public.subject_catalog sc on sc.id = p.subject_id
  where p.moderation_status = 'published'
    and sc.status = 'published'
  limit 1;

  if v_subject is null then
    perform pg_temp.rp_skip(
      '16.2 all', 'no published subject card fixture (subject_student_profiles)'
    );
    return;
  end if;

  select sc.id into v_other_subject
  from public.subject_catalog sc
  where sc.id is distinct from v_subject
  limit 1;

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_register_subject_asset(
    p_subject_catalog_id => v_subject,
    p_subject_offering_id => null,
    p_storage_path => 'subject/' || v_subject::text || '/roleplay-v1.pdf',
    p_mime_type => 'application/pdf',
    p_byte_size => 1024,
    p_title => 'roleplay v1'
  );
  v_asset := (v_json ->> 'id')::uuid;
  perform pg_temp.rp_pass(
    '16.2.1 admin can register a subject file',
    v_asset is not null and (v_json ->> 'version_number')::int = 1,
    v_json::text
  );

  -- Descriptors must never carry the storage location.
  perform pg_temp.rp_pass(
    '16.2.2 register returns no storage path',
    not (v_json ? 'storage_path') and not (v_json ? 'storage_bucket'),
    v_json::text
  );

  -- IDOR: a "new version" may not adopt a file owned by a DIFFERENT subject.
  if v_other_subject is null then
    perform pg_temp.rp_skip(
      '16.2.3 supersede across owners is refused', 'only one subject in catalog'
    );
  else
    perform pg_temp.rp_as_user(v_admin);
    perform pg_temp.rp_expect_exception(
      '16.2.3 supersede across owners is refused',
      format(
        'select public.admin_register_subject_asset(%L::uuid, null::uuid, %L, %L, 1024, %L, null, %L::uuid)',
        v_other_subject,
        'subject/' || v_other_subject::text || '/roleplay-hijack.pdf',
        'application/pdf',
        'hijack attempt',
        v_asset
      ),
      '42501',
      'asset_foreign_owner'
    );
  end if;

  -- A published card must not lose its CURRENT file.
  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_exception(
    '16.2.4 current file of a published card cannot be deleted',
    format('select public.admin_delete_subject_asset(%L::uuid)', v_asset),
    '55000',
    'unpublish_card_before_deleting_current_asset'
  );

  -- Superseding is the supported way forward, and the superseded (non-current)
  -- file is then removable even while the card stays published.
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_register_subject_asset(
    p_subject_catalog_id => v_subject,
    p_subject_offering_id => null,
    p_storage_path => 'subject/' || v_subject::text || '/roleplay-v2.pdf',
    p_mime_type => 'application/pdf',
    p_byte_size => 2048,
    p_title => 'roleplay v2',
    p_supersedes_asset_id => v_asset
  );
  v_asset_v2 := (v_json ->> 'id')::uuid;
  perform pg_temp.rp_pass(
    '16.2.5 supersede bumps the version and demotes the old file',
    (v_json ->> 'version_number')::int = 2
      and not (select is_current from public.subject_assets where id = v_asset),
    v_json::text
  );

  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_success(
    '16.2.6 superseded file is removable while the card stays published',
    format('select public.admin_delete_subject_asset(%L::uuid)', v_asset)
  );

  perform pg_temp.rp_pass(
    '16.2.7 delete enqueues the private storage object',
    exists (
      select 1 from public.subject_media_cleanup_queue q
      where q.storage_path = 'subject/' || v_subject::text || '/roleplay-v1.pdf'
        and q.processed_at is null
    ),
    'cleanup queue'
  );

  -- Student read path.
  select so.id, so.group_id into v_offering, v_group
  from public.subject_offerings so
  where so.subject_id = v_subject
  limit 1;

  if v_offering is null then
    perform pg_temp.rp_skip('16.2.8 student read path', 'subject has no offering');
  else
    select se.user_id into v_student
    from public.student_enrollments se
    join public.users u on u.id = se.user_id and u.is_active
    where se.group_id = v_group
      and se.status = 'active'
      and se.ended_at is null
    limit 1;

    if v_student is null then
      perform pg_temp.rp_skip(
        '16.2.8 student read path', 'no active enrollment in the offering group'
      );
    else
      perform pg_temp.rp_as_user(v_student);
      v_json := public.get_subject_card_assets(v_offering);
      perform pg_temp.rp_pass(
        '16.2.8 enrolled student sees descriptors without storage paths',
        v_json ? 'subject_assets'
          and v_json::text not ilike '%storage_path%'
          and v_json::text not ilike '%roleplay-v2.pdf%',
        left(v_json::text, 400)
      );

      select se.user_id into v_outsider
      from public.student_enrollments se
      join public.users u on u.id = se.user_id and u.is_active
      where se.group_id is distinct from v_group
        and se.status = 'active'
        and se.ended_at is null
        and not exists (
          select 1 from public.student_enrollments se2
          where se2.user_id = se.user_id
            and se2.group_id = v_group
            and se2.status = 'active'
            and se2.ended_at is null
        )
      limit 1;

      if v_outsider is null then
        perform pg_temp.rp_skip(
          '16.2.9 outsider cannot read the card files', 'no student outside the group'
        );
      else
        perform pg_temp.rp_as_user(v_outsider);
        perform pg_temp.rp_expect_exception(
          '16.2.9 outsider cannot read the card files',
          format('select public.get_subject_card_assets(%L::uuid)', v_offering),
          '42501'
        );
      end if;
    end if;
  end if;

  perform pg_temp.rp_as_nobody();
end
$$;

-- ===========================================================================
-- Stage 16.3 — reference corrections
-- ===========================================================================
do $$
declare
  v_moderator uuid;
  v_reporter uuid;
  v_item uuid;
  v_other_item uuid;
  v_report uuid;
  v_json jsonb;
  v_count integer;
begin
  v_moderator := pg_temp.rp_admin_with(array['moderation.read', 'moderation.action']);
  if v_moderator is null then
    v_moderator := pg_temp.rp_admin_with(array['moderation.read', 'moderation.write']);
  end if;

  -- A (deliverable item, reporter) pair is what the submit gate requires.
  select ci.id, se.user_id into v_item, v_reporter
  from public.content_items ci
  cross join lateral (
    select se.user_id
    from public.student_enrollments se
    join public.users u on u.id = se.user_id and u.is_active
    where se.status = 'active'
      and se.ended_at is null
      and private.content_item_deliverable_to_user(ci.id, se.user_id)
    limit 1
  ) se
  limit 1;

  if v_item is null then
    perform pg_temp.rp_skip(
      '16.3 all', 'no deliverable content_items fixture for any active student'
    );
    return;
  end if;

  -- IDOR: an item the caller cannot be delivered is not reportable, and the
  -- refusal must not disclose that the item exists.
  select ci.id into v_other_item
  from public.content_items ci
  where ci.id is distinct from v_item
    and not private.content_item_deliverable_to_user(ci.id, v_reporter)
  limit 1;

  if v_other_item is null then
    perform pg_temp.rp_skip(
      '16.3.1 undeliverable item is not reportable', 'no undeliverable item fixture'
    );
  else
    perform pg_temp.rp_as_user(v_reporter);
    perform pg_temp.rp_expect_exception(
      '16.3.1 undeliverable item is not reportable',
      format(
        'select public.submit_content_correction(%L::uuid, %L)',
        v_other_item, 'роль-плей: чужой материал'
      ),
      'P0002'
    );
  end if;

  perform pg_temp.rp_as_user(v_reporter);
  v_json := public.submit_content_correction(v_item, 'роль-плей: опечатка в тексте');
  v_report := (v_json ->> 'id')::uuid;
  perform pg_temp.rp_pass(
    '16.3.2 student can report a deliverable item',
    v_report is not null,
    v_json::text
  );

  -- The 60s window is real; a single transaction cannot wait it out, so the
  -- fixture is backdated to exercise the SECOND submit instead of the limiter.
  update public.content_corrections
  set created_at = now() - interval '10 minutes'
  where id = v_report;

  perform pg_temp.rp_as_user(v_reporter);
  v_json := public.submit_content_correction(v_item, 'роль-плей: уточнение');
  perform pg_temp.rp_pass(
    '16.3.3 re-reporting updates the open report instead of flooding',
    (v_json ->> 'id')::uuid = v_report
      and (
        select count(*) from public.content_corrections c
        where c.content_item_id = v_item
          and c.reporter_user_id = v_reporter
          and c.status = 'open'
      ) = 1,
    v_json::text
  );

  -- The rate limiter itself must still bite on an immediate third attempt.
  perform pg_temp.rp_as_user(v_reporter);
  perform pg_temp.rp_expect_exception(
    '16.3.4 rapid re-reporting is rate limited',
    format(
      'select public.submit_content_correction(%L::uuid, %L)', v_item, 'роль-плей: спам'
    ),
    'P0001',
    'rate_limited'
  );

  if v_moderator is null then
    perform pg_temp.rp_skip(
      '16.3.5 moderator queue hides the reporter', 'no admin with moderation.read'
    );
    perform pg_temp.rp_as_nobody();
    return;
  end if;

  perform pg_temp.rp_as_user(v_moderator);
  v_json := public.admin_list_content_corrections('open', v_item);
  perform pg_temp.rp_pass(
    '16.3.5 moderator queue hides the reporter',
    v_json::text not ilike '%reporter%'
      and v_json::text ilike '%роль-плей: уточнение%',
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_moderator);
  perform pg_temp.rp_expect_success(
    '16.3.6 moderator can resolve the report',
    format(
      'select public.admin_resolve_content_correction(%L::uuid, %L, %L)',
      v_report, 'resolve', 'исправлено'
    )
  );

  perform pg_temp.rp_as_user(v_moderator);
  perform pg_temp.rp_expect_exception(
    '16.3.7 a closed report cannot be resolved twice',
    format(
      'select public.admin_resolve_content_correction(%L::uuid, %L, %L)',
      v_report, 'reject', 'повторно'
    ),
    '55000',
    'already_closed'
  );

  select count(*) into v_count
  from public.admin_audit_log l
  where l.entity_type = 'content_correction'
    and l.entity_id = v_report::text;
  perform pg_temp.rp_pass(
    '16.3.8 resolution is audited',
    v_count >= 1,
    format('audit rows=%s', v_count)
  );

  perform pg_temp.rp_as_nobody();
end
$$;

-- ===========================================================================
-- Stage 17 — vacancies lifecycle, expiry, contacts, asset safety
-- ===========================================================================
do $$
declare
  v_admin uuid;
  v_student uuid;
  v_vacancy uuid;
  v_asset uuid;
  v_json jsonb;
  v_versions_before integer;
  v_versions_after integer;
  v_expired integer;
  v_status text;
begin
  v_admin := pg_temp.rp_admin_with(array['content.write']);
  if v_admin is null then
    perform pg_temp.rp_skip('17 all', 'no active admin with content.write');
    return;
  end if;

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_create_vacancy_draft(
    jsonb_build_object(
      'title', 'Роль-плей вакансия',
      'company_name', 'РП Компани',
      'summary', 'проверка жизненного цикла',
      'contacts', jsonb_build_object('email', 'rp@example.test')
    ),
    'admin'
  );
  v_vacancy := (v_json ->> 'id')::uuid;
  perform pg_temp.rp_pass(
    '17.1 admin can create a draft',
    v_vacancy is not null and (v_json ->> 'status') = 'draft',
    left(v_json::text, 300)
  );

  -- A draft is an AUTHORING event: it must not claim it entered moderation.
  perform pg_temp.rp_pass(
    '17.2 draft creation records create_draft, not take_in_moderation',
    exists (
      select 1 from public.vacancy_moderation_actions a
      where a.vacancy_id = v_vacancy and a.action = 'create_draft'
    )
    and not exists (
      select 1 from public.vacancy_moderation_actions a
      where a.vacancy_id = v_vacancy and a.action = 'take_in_moderation'
    ),
    (
      select coalesce(string_agg(a.action, ',' order by a.created_at), '(none)')
      from public.vacancy_moderation_actions a
      where a.vacancy_id = v_vacancy
    )
  );

  -- Fixture: force the published+overdue state that cron is meant to find. The
  -- normal route (submit -> moderate -> publish) is covered by the Stage 17
  -- lifecycle scenarios; here only the cron transition is under test.
  update public.vacancies v set
    status = 'published',
    audience_mode = 'all',
    expires_at = now() - interval '1 day',
    published_at = now() - interval '7 days'
  where v.id = v_vacancy;

  select count(*) into v_versions_before
  from public.vacancy_versions vv where vv.vacancy_id = v_vacancy;

  -- Cron runs unauthenticated: actor is NULL, and every audit column is
  -- nullable, so the trail must still be written.
  perform pg_temp.rp_as_nobody();
  v_expired := private.vacancy_expire_due();

  select status into v_status from public.vacancies where id = v_vacancy;
  select count(*) into v_versions_after
  from public.vacancy_versions vv where vv.vacancy_id = v_vacancy;

  perform pg_temp.rp_pass(
    '17.3 cron expiry moves published -> expired',
    v_status = 'expired' and v_expired >= 1,
    format('status=%s expired=%s', v_status, v_expired)
  );

  perform pg_temp.rp_pass(
    '17.4 cron expiry snapshots a version',
    v_versions_after > v_versions_before,
    format('before=%s after=%s', v_versions_before, v_versions_after)
  );

  perform pg_temp.rp_pass(
    '17.5 cron expiry writes the auto_expire moderation trail',
    exists (
      select 1 from public.vacancy_moderation_actions a
      where a.vacancy_id = v_vacancy
        and a.action = 'auto_expire'
        and a.from_status = 'published'
        and a.to_status = 'expired'
    ),
    'moderation trail'
  );

  perform pg_temp.rp_pass(
    '17.6 cron expiry writes the domain audit',
    exists (
      select 1 from public.content_audit_log l
      where l.entity_type = 'vacancy'
        and l.entity_id = v_vacancy
        and l.action = 'vacancy.auto_expire'
    ),
    'content_audit_log'
  );

  -- Asset safety: a PUBLISHED vacancy must not lose a file under it.
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_register_vacancy_asset(
    p_vacancy_id => v_vacancy,
    p_storage_path => 'vacancy/' || v_vacancy::text || '/roleplay.pdf',
    p_mime_type => 'application/pdf',
    p_byte_size => 4096,
    p_title => 'роль-плей вложение'
  );
  v_asset := (v_json ->> 'id')::uuid;

  update public.vacancies v set status = 'published' where v.id = v_vacancy;

  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_exception(
    '17.7 a published vacancy file cannot be deleted',
    format('select public.admin_delete_vacancy_asset(%L::uuid)', v_asset),
    '55000',
    'unpublish_vacancy_before_deleting_asset'
  );

  update public.vacancies v set status = 'draft' where v.id = v_vacancy;

  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_success(
    '17.8 after unpublishing, the file is removable',
    format('select public.admin_delete_vacancy_asset(%L::uuid)', v_asset)
  );

  -- Contact privacy: a draft vacancy is deliverable to nobody, so contacts must
  -- not leave the server even for a legitimate student.
  select se.user_id into v_student
  from public.student_enrollments se
  join public.users u on u.id = se.user_id and u.is_active
  where se.status = 'active' and se.ended_at is null
  limit 1;

  if v_student is null then
    perform pg_temp.rp_skip('17.9 contacts stay private', 'no active student');
  else
    perform pg_temp.rp_as_user(v_student);
    perform pg_temp.rp_expect_exception(
      '17.9 contacts of an unpublished vacancy stay private',
      format('select public.get_vacancy_contacts(%L::uuid)', v_vacancy),
      'P0002'
    );
  end if;

  perform pg_temp.rp_as_nobody();
end
$$;

-- ===========================================================================
-- Stage 18 — review moderation, points credit / debit / re-credit
-- ===========================================================================
do $$
declare
  v_moderator uuid;
  v_author uuid;
  v_subject uuid;
  v_tag text;
  v_review uuid;
  v_json jsonb;
  v_balance integer;
  v_cycles integer;
  v_credited integer;
  v_credited_again integer;
  v_status text;
begin
  v_moderator := pg_temp.rp_admin_with(array['moderation.action']);
  if v_moderator is null then
    v_moderator := pg_temp.rp_admin_with(array['moderation.write']);
  end if;
  if v_moderator is null then
    perform pg_temp.rp_skip('18 all', 'no active admin with moderation.action/write');
    return;
  end if;

  select sc.id into v_subject
  from public.subject_catalog sc
  where sc.status = 'published'
  limit 1;
  if v_subject is null then
    perform pg_temp.rp_skip('18 all', 'no published subject to review');
    return;
  end if;

  select t.code into v_tag
  from public.review_tags t
  where t.entity_type = 'subject' and t.is_active
  limit 1;
  if v_tag is null then
    perform pg_temp.rp_skip('18 all', 'no active subject review tag');
    return;
  end if;

  select u.id into v_author
  from public.users u
  join public.student_enrollments se
    on se.user_id = u.id and se.status = 'active' and se.ended_at is null
  where u.is_active
    and u.id is distinct from v_moderator
    and not exists (
      select 1 from public.entity_reviews r
      where r.author_user_id = u.id
        and r.entity_type = 'subject'
        and r.entity_id = v_subject
    )
  limit 1;
  if v_author is null then
    perform pg_temp.rp_skip(
      '18 all', 'no active student without an existing review for this subject'
    );
    return;
  end if;

  -- Fixture: the moderated flow is the one under test, so pin the flags inside
  -- this transaction instead of depending on the current environment.
  insert into public.app_feature_flags(key, enabled, description)
  values
    ('reviews.structured_enabled', true, 'roleplay'),
    ('reviews.text_enabled', true, 'roleplay'),
    ('reviews.moderation_required', true, 'roleplay')
  on conflict (key) do update set enabled = true;

  perform pg_temp.rp_as_user(v_author);
  v_json := public.submit_my_entity_review(
    'subject', v_subject, jsonb_build_object(v_tag, 4), 'роль-плей отзыв'
  );
  v_review := (v_json ->> 'review_id')::uuid;
  perform pg_temp.rp_pass(
    '18.1 a submitted review waits for moderation and earns nothing yet',
    v_review is not null
      and (v_json ->> 'moderation_status') = 'pending'
      and (v_json ->> 'status') = 'hidden'
      and not exists (
        select 1 from public.student_points_ledger l where l.review_id = v_review
      ),
    v_json::text
  );

  -- APPROVAL must be recorded as `approve`, never disguised as `restore`.
  perform pg_temp.rp_as_user(v_moderator);
  v_json := public.admin_moderate_review_v2(v_review, 'approve');
  perform pg_temp.rp_pass(
    '18.2 approval is recorded as approve, not restore',
    exists (
      select 1 from public.review_moderation_actions a
      where a.review_id = v_review and a.action = 'approve'
    )
    and not exists (
      select 1 from public.review_moderation_actions a
      where a.review_id = v_review and a.action = 'restore'
    ),
    (
      select coalesce(string_agg(a.action, ',' order by a.created_at), '(none)')
      from public.review_moderation_actions a where a.review_id = v_review
    )
  );

  select coalesce(sum(l.delta), 0) into v_balance
  from public.student_points_ledger l where l.review_id = v_review;
  perform pg_temp.rp_pass(
    '18.3 approval credits exactly +1 in cycle 1',
    v_balance = 1
      and exists (
        select 1 from public.student_points_ledger l
        where l.review_id = v_review
          and l.reason_code = 'review_approved'
          and l.cycle_number = 1
          and l.delta = 1
      ),
    format('balance=%s', v_balance)
  );

  -- The LEGACY Stage 13.6 entry point must not bypass compensation.
  perform pg_temp.rp_as_user(v_moderator);
  perform public.admin_moderate_review(v_review, 'hide', 'роль-плей нарушение');

  select coalesce(sum(l.delta), 0) into v_balance
  from public.student_points_ledger l where l.review_id = v_review;
  perform pg_temp.rp_pass(
    '18.4 the legacy RPC still compensates the point',
    v_balance = 0
      and exists (
        select 1 from public.student_points_ledger l
        where l.review_id = v_review
          and l.reason_code = 'review_credit_revoked'
          and l.cycle_number = 1
          and l.delta = -1
      ),
    format('balance=%s', v_balance)
  );

  -- RE-CREDIT AFTER COMPENSATION: the old (review_id, reason_code) uniqueness
  -- made this impossible; with cycles it must succeed as cycle 2.
  perform pg_temp.rp_as_user(v_moderator);
  perform public.admin_moderate_review(v_review, 'restore', 'роль-плей апелляция');

  select coalesce(sum(l.delta), 0) into v_balance
  from public.student_points_ledger l where l.review_id = v_review;
  select count(distinct l.cycle_number) into v_cycles
  from public.student_points_ledger l where l.review_id = v_review;
  perform pg_temp.rp_pass(
    '18.5 a restored review can be credited again in a new cycle',
    v_balance = 1
      and v_cycles = 2
      and exists (
        select 1 from public.student_points_ledger l
        where l.review_id = v_review
          and l.reason_code = 'review_approved'
          and l.cycle_number = 2
          and l.delta = 1
      ),
    format('balance=%s cycles=%s', v_balance, v_cycles)
  );

  -- REJECTED -> RESUBMIT -> PENDING.
  perform pg_temp.rp_as_user(v_moderator);
  perform public.admin_moderate_review_v2(v_review, 'reject', 'роль-плей причина');

  select moderation_status into v_status
  from public.entity_reviews where id = v_review;
  select coalesce(sum(l.delta), 0) into v_balance
  from public.student_points_ledger l where l.review_id = v_review;
  perform pg_temp.rp_pass(
    '18.6 rejection hides the review and takes the point back',
    v_status = 'rejected' and v_balance = 0,
    format('moderation_status=%s balance=%s', v_status, v_balance)
  );

  -- The 30s author window is real; backdate so the RESUBMIT is what is tested.
  update public.entity_reviews set updated_at = now() - interval '10 minutes'
  where id = v_review;

  perform pg_temp.rp_as_user(v_author);
  v_json := public.submit_my_entity_review(
    'subject', v_subject, jsonb_build_object(v_tag, 5), 'роль-плей исправленный отзыв'
  );
  perform pg_temp.rp_pass(
    '18.7 a rejected review can be resubmitted back to pending',
    (v_json ->> 'review_id')::uuid = v_review
      and (v_json ->> 'moderation_status') = 'pending'
      and (
        select moderation_reason is null and hidden_reason is null
        from public.entity_reviews where id = v_review
      ),
    v_json::text
  );

  -- The idempotent backfill must credit nothing while nothing is owed, and must
  -- stay a no-op on a second run.
  perform pg_temp.rp_as_user(v_moderator);
  v_json := public.admin_backfill_review_points(1000);
  v_credited := coalesce((v_json ->> 'credited')::integer, -1);
  perform pg_temp.rp_as_user(v_moderator);
  v_json := public.admin_backfill_review_points(1000);
  v_credited_again := coalesce((v_json ->> 'credited')::integer, -1);
  perform pg_temp.rp_pass(
    '18.8 the points backfill is idempotent',
    v_credited >= 0 and v_credited_again = 0,
    format('first=%s second=%s', v_credited, v_credited_again)
  );

  -- The author holds no moderation permission, so neither entry point is even
  -- reachable for them (the own-review guard is the second line of defence).
  perform pg_temp.rp_as_user(v_author);
  perform pg_temp.rp_expect_exception(
    '18.9 a student cannot moderate a review at all',
    format('select public.admin_moderate_review_v2(%L::uuid, %L)', v_review, 'approve'),
    '42501'
  );

  perform pg_temp.rp_as_user(v_author);
  perform pg_temp.rp_expect_exception(
    '18.9b the legacy entry point is closed to students too',
    format('select public.admin_moderate_review(%L::uuid, %L, %L)', v_review, 'hide', 'x'),
    '42501'
  );

  perform pg_temp.rp_as_nobody();
end
$$;

-- ===========================================================================
-- Stage 19 — Import Studio ownership, honest domains, rollback refusal
-- ===========================================================================
do $$
declare
  v_admin uuid;
  v_other uuid;
  v_json jsonb;
  v_batch uuid;
  v_other_batch uuid;
  v_key text := 'roleplay-shared-key';
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('full_name', 'РП Тестовый Преподаватель')
  );
begin
  v_admin := pg_temp.rp_admin_with(array['teachers.write']);
  if v_admin is null then
    perform pg_temp.rp_skip('19 all', 'no active admin with teachers.write');
    return;
  end if;

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_start_dry_run(
    'teachers', v_rows, 'roleplay.csv', v_key
  );
  v_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '19.1 a dry run creates a batch owned by the caller',
    v_batch is not null
      and (select created_by from public.import_studio_batches where id = v_batch) = v_admin,
    left(v_json::text, 300)
  );

  -- Honest matrix: an unimplemented domain must RAISE, not pretend to work.
  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_exception(
    '19.2 an unimplemented domain refuses a dry run',
    format(
      'select public.admin_import_studio_start_dry_run(%L, %L::jsonb, %L, %L)',
      'offerings', v_rows::text, 'roleplay.csv', 'roleplay-offerings'
    ),
    '0A000',
    'not_implemented_domain'
  );

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_list_domains();
  perform pg_temp.rp_pass(
    '19.3 the hub advertises the unimplemented domains honestly',
    v_json::text ilike '%not_implemented%'
      and v_json::text ilike '%offerings%'
      and v_json::text ilike '%teacher_links%'
      and v_json::text ilike '%enrollments%',
    left(v_json::text, 400)
  );

  -- Rollback: refuse, audit, and never silently succeed.
  update public.import_studio_batches set status = 'applied', applied_at = now(),
    applied_by = v_admin
  where id = v_batch;

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_rollback_batch(v_batch, v_key);
  perform pg_temp.rp_pass(
    '19.4 rollback refuses a batch that is not rollback_safe',
    coalesce((v_json->>'ok')::boolean, true) = false
      and coalesce((v_json->>'refused')::boolean, false) = true
      and v_json->>'error_code' = 'rollback_not_supported_for_batch',
    left(v_json::text, 400)
  );
  perform pg_temp.rp_pass(
    '19.4b rollback refusal is audited',
    exists (
      select 1 from public.admin_audit_log a
      where a.action = 'import_studio.rollback_refused'
        and a.entity_id = v_batch::text
    ),
    'missing import_studio.rollback_refused audit row'
  );

  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_exception(
    '19.5 rollback requires the batch key confirmation',
    format(
      'select public.admin_import_studio_rollback_batch(%L::uuid, %L)',
      v_batch, 'wrong-key'
    ),
    '22023',
    'batch_key_confirmation_mismatch'
  );

  -- Cross-operator isolation.
  v_other := pg_temp.rp_other_admin_with(array['teachers.write'], v_admin);
  if v_other is null then
    perform pg_temp.rp_skip(
      '19.6 cross-operator batch isolation', 'no second admin with teachers.write'
    );
    perform pg_temp.rp_skip(
      '19.7 the same batch key is reusable per operator',
      'no second admin with teachers.write'
    );
    perform pg_temp.rp_as_nobody();
    return;
  end if;

  perform pg_temp.rp_as_user(v_other);
  perform pg_temp.rp_expect_exception(
    '19.6 cross-operator batch isolation',
    format('select public.admin_import_studio_get_diff(%L::uuid)', v_batch),
    '42501',
    'batch_not_owned_by_caller'
  );

  perform pg_temp.rp_as_user(v_other);
  perform pg_temp.rp_expect_exception(
    '19.6b another operator cannot cancel the batch',
    format('select public.admin_import_studio_cancel_batch(%L::uuid)', v_batch),
    '42501',
    'batch_not_owned_by_caller'
  );

  perform pg_temp.rp_as_user(v_other);
  perform pg_temp.rp_expect_exception(
    '19.6c another operator cannot apply the batch',
    format(
      'select public.admin_import_studio_apply(%L::uuid, %L)', v_batch, v_key
    ),
    '42501',
    'batch_not_owned_by_caller'
  );

  -- The key is per operator, so the SAME key must be usable independently and
  -- must not touch the first operator's batch.
  perform pg_temp.rp_as_user(v_other);
  v_json := public.admin_import_studio_start_dry_run(
    'teachers', v_rows, 'roleplay-other.csv', v_key
  );
  v_other_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '19.7 the same batch key is reusable per operator',
    v_other_batch is not null
      and v_other_batch is distinct from v_batch
      and (
        select created_by from public.import_studio_batches where id = v_other_batch
      ) = v_other
      and (
        select status from public.import_studio_batches where id = v_batch
      ) = 'applied',
    format('mine=%s other=%s', v_batch, v_other_batch)
  );

  perform pg_temp.rp_as_user(v_other);
  v_json := public.admin_import_studio_list_batches('teachers', 20);
  perform pg_temp.rp_pass(
    '19.8 the batch list is scoped to the calling operator',
    v_json::text not ilike '%' || v_batch::text || '%',
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_nobody();
end
$$;

select scenario, status, detail
from stage16_19_roleplay_results
order by scenario;

select
  count(*) filter (where status = 'PASS') as pass_count,
  count(*) filter (where status = 'FAIL') as fail_count,
  count(*) filter (where status = 'SKIP') as skip_count,
  count(*) as total
from stage16_19_roleplay_results;

do $$
declare
  v_fail int;
begin
  select count(*) into v_fail from stage16_19_roleplay_results where status = 'FAIL';
  if v_fail > 0 then
    raise exception 'stage16_19 P1 scenarios failed: %', (
      select string_agg(scenario || ': ' || detail, '; ' order by scenario)
      from stage16_19_roleplay_results where status = 'FAIL'
    );
  end if;
  raise notice 'stage16_19_p1_roleplay PASS (SKIP rows mean a missing fixture, not a pass)';
end
$$;

rollback;
