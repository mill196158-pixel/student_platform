-- Stage 19 COMPLETION behavioral role-play (disposable transaction).
--
-- Requires a LOCAL apply of:
--   20260729153000_stage19_import_studio_foundation.sql
--   20260729153050_stage19_import_studio_p1_hardening.sql
--   20260729154000_stage19_import_studio_completion.sql
--
-- Never run against production / never --linked. The whole script runs
-- inside a transaction that ends in ROLLBACK, so nothing it writes survives.
-- Fixture absence => explicit SKIP rows, never a silent PASS.
--
-- This complements the static structural review
-- (stage19_import_studio_security_review.sql, sections 60-70 + hard gate 0d)
-- with END-TO-END behavior for the six domains the completion migration
-- promotes to `apply`: groups, terms, curriculum, offerings, teacher_links,
-- enrollments. teachers/subjects/students keep delegating to their existing
-- Stage 13 RPCs (unchanged) and are already covered by
-- stage16_19_p1_roleplay.sql, so they are out of scope here.
--
-- Scope, by domain:
--   groups          new group is created; the dry-run warns about the
--                   group_space team/chat side effect; rollback is refused
--                   (not in the rollback-safe allow-list) and audited.
--   terms           new term (+ new academic_year if needed) is created
--                   without touching is_current; the current-term-flip and
--                   Autumn-2026 bans still hold on THIS apply path; rollback
--                   of an unused term succeeds.
--   curriculum -> offerings -> teacher_links (chained workflow)
--                   a new curriculum_subjects row, a new subject_offerings
--                   row against a brand-new term, and a new offering_teachers
--                   link are created in sequence; rollback is attempted
--                   bottom-up and top-down to prove the explicit dependency
--                   blockers (not bare FK violations) really gate it:
--                   curriculum/term rollback is blocked while the offering
--                   exists, offering rollback is blocked while the teacher
--                   link exists; removing the teacher link unblocks the
--                   offering, which unblocks the term and curriculum.
--   enrollments     an EXACT replay of an existing active enrollment applies
--                   as an idempotent no-op; a cross-group transfer for the
--                   same student is refused at validation time (batch never
--                   applies); rollback is always refused.
--   cross-cutting   rollback_safe is persisted correctly per domain; a
--                   second operator remains locked out of a groups batch
--                   they do not own (ownership isolation extends to the new
--                   domains too, not just teachers/subjects/students).
--
-- Role simulation follows the Stage 16-19 P1 role-play convention: the JWT
-- claim is swapped with set_config so auth.uid() inside the SECURITY
-- DEFINER RPCs sees the acting user, and RBAC/ownership is exercised for
-- real through the public RPCs only (no private.* or direct-table writes
-- except to read back results and build fixtures a single transaction
-- cannot reach otherwise, e.g. seeking a free semester slot).

begin;

create temporary table if not exists stage19_completion_roleplay_results (
  scenario text primary key,
  status text not null check (status in ('PASS', 'FAIL', 'SKIP')),
  detail text not null default ''
) on commit drop;

grant all on table stage19_completion_roleplay_results to authenticated, anon, service_role;

create or replace function pg_temp.rp_pass(
  p_scenario text,
  p_ok boolean,
  p_detail text default ''
)
returns void
language plpgsql as $fn$
begin
  insert into stage19_completion_roleplay_results(scenario, status, detail)
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
  insert into stage19_completion_roleplay_results(scenario, status, detail)
  values (p_scenario, 'SKIP', coalesce(p_detail, ''))
  on conflict (scenario) do update
    set status = excluded.status, detail = excluded.detail;
end;
$fn$;

-- Runs p_sql and PASSes only if it raised, optionally matching sqlstate
-- and/or message. A success where a refusal was expected is a FAIL, never a
-- SKIP.
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

-- A second, distinct admin with the same permissions (for cross-operator
-- ownership isolation).
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
-- GROUPS — create, warn about group_space, rollback refused
-- ===========================================================================
do $$
declare
  v_admin uuid;
  v_json jsonb;
  v_batch uuid;
  v_key text := 'roleplay-completion-groups';
  v_group_name text := 'РП-Завершение Группа 3025';
  v_rows jsonb;
begin
  v_admin := pg_temp.rp_admin_with(array['groups.write']);
  if v_admin is null then
    perform pg_temp.rp_skip('[groups] G0 all', 'no active admin with groups.write');
    return;
  end if;

  v_rows := jsonb_build_array(jsonb_build_object('name', v_group_name));

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_start_dry_run('groups', v_rows, 'roleplay.csv', v_key);
  v_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '[groups] G1 dry run classifies a brand-new group name as new',
    v_batch is not null and (v_json -> 'summary' ->> 'new') = '1',
    left(v_json::text, 400)
  );

  perform pg_temp.rp_pass(
    '[groups] G2 dry run warns about the group_space team/chat side effect',
    coalesce(v_json -> 'summary' -> 'warnings', '[]'::jsonb)::text ilike '%group_space%',
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_apply(v_batch, v_key);
  perform pg_temp.rp_pass(
    '[groups] G3 apply creates the group',
    coalesce((v_json ->> 'ok')::boolean, false)
      and exists (
        select 1 from public.groups g
        where private.import_studio_norm(g.name) = private.import_studio_norm(v_group_name)
      ),
    left(v_json::text, 400)
  );

  perform pg_temp.rp_pass(
    '[groups] G4 rollback_safe is persisted as false for groups',
    (select rollback_safe from public.import_studio_batches where id = v_batch) = false,
    'rollback_safe'
  );

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_rollback_batch(v_batch, v_key);
  perform pg_temp.rp_pass(
    '[groups] G5 rollback of a groups batch is refused',
    coalesce((v_json ->> 'ok')::boolean, true) = false
      and v_json ->> 'error_code' = 'rollback_not_supported_for_batch',
    left(v_json::text, 400)
  );
  perform pg_temp.rp_pass(
    '[groups] G6 the rollback refusal is audited',
    exists (
      select 1 from public.admin_audit_log a
      where a.action = 'import_studio.rollback_refused'
        and a.entity_id = v_batch::text
    ),
    'missing import_studio.rollback_refused audit row'
  );

  -- Ownership isolation extends to groups, not just teachers/subjects/students.
  declare
    v_other uuid := pg_temp.rp_other_admin_with(array['groups.write'], v_admin);
  begin
    if v_other is null then
      perform pg_temp.rp_skip(
        '[groups] G7 cross-operator isolation on a groups batch', 'no second admin with groups.write'
      );
    else
      perform pg_temp.rp_as_user(v_other);
      perform pg_temp.rp_expect_exception(
        '[groups] G7 cross-operator isolation on a groups batch',
        format('select public.admin_import_studio_get_diff(%L::uuid)', v_batch),
        '42501',
        'batch_not_owned_by_caller'
      );
    end if;
  end;

  perform pg_temp.rp_as_nobody();
end
$$;

-- ===========================================================================
-- TERMS — safe creation, current-term-flip / Autumn-2026 bans, rollback
-- ===========================================================================
do $$
declare
  v_admin uuid;
  v_json jsonb;
  v_batch uuid;
  v_batch_id uuid;
  v_term_id uuid;
begin
  v_admin := pg_temp.rp_admin_with(array['terms.manage']);
  if v_admin is null then
    perform pg_temp.rp_skip('[terms] T0 all', 'no active admin with terms.manage');
    return;
  end if;

  -- T1: a plain new term, far in the future, must apply and leave is_current
  -- untouched (the completion helper never sets it; academic_terms itself
  -- also guards this at the trigger level).
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_start_dry_run(
    'terms',
    jsonb_build_array(jsonb_build_object(
      'academic_year_name', '3025/3026',
      'name', 'РП Семестр 1',
      'term_in_year', 1,
      'starts_on', '3025-09-01',
      'ends_on', '3026-01-31'
    )),
    'roleplay.csv',
    'roleplay-completion-terms-1'
  );
  v_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '[terms] T1 a future term dry-runs clean (no error rows)',
    v_batch is not null and (v_json ->> 'error_count')::int = 0,
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_apply(v_batch, 'roleplay-completion-terms-1');
  perform pg_temp.rp_pass(
    '[terms] T2 apply creates the term without flipping is_current anywhere',
    coalesce((v_json ->> 'ok')::boolean, false)
      and not exists (
        select 1 from public.academic_terms t
        join public.academic_years ay on ay.id = t.academic_year_id
        where ay.name = '3025/3026' and t.is_current
      ),
    left(v_json::text, 400)
  );

  select ir.matched_term_id into v_term_id
  from public.import_studio_rows ir
  where ir.batch_id = v_batch
  limit 1;

  perform pg_temp.rp_pass(
    '[terms] T3 rollback_safe is persisted as true for terms',
    (select rollback_safe from public.import_studio_batches where id = v_batch) = true,
    'rollback_safe'
  );

  -- T4: the current-term-flip ban must still gate THIS apply path (a row
  -- carrying is_current at all is refused at validation, before it ever
  -- reaches the new terms helper).
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_start_dry_run(
    'terms',
    jsonb_build_array(jsonb_build_object(
      'academic_year_name', '3025/3026',
      'name', 'РП Флип',
      'term_in_year', 2,
      'starts_on', '3026-02-01',
      'ends_on', '3026-06-30',
      'is_current', true
    )),
    'roleplay.csv',
    'roleplay-completion-terms-flip'
  );
  v_batch_id := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '[terms] T4 a row carrying is_current is flagged current_term_flip_forbidden',
    (v_json ->> 'error_count')::int = 1
      and exists (
        select 1 from public.import_studio_rows ir
        where ir.batch_id = v_batch_id and ir.error_text ilike '%current_term_flip_forbidden%'
      ),
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin);
  perform pg_temp.rp_expect_exception(
    '[terms] T5 apply refuses a batch that still has the is_current error row',
    format(
      'select public.admin_import_studio_apply(%L::uuid, %L)',
      v_batch_id, 'roleplay-completion-terms-flip'
    ),
    'P0001',
    'batch_has_errors'
  );

  -- T6: the Autumn-2026 ban must still gate THIS apply path.
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_start_dry_run(
    'terms',
    jsonb_build_array(jsonb_build_object(
      'academic_year_name', '2026/2027',
      'name', 'Осень 2026',
      'term_in_year', 1,
      'starts_on', '2026-09-01',
      'ends_on', '2026-12-31'
    )),
    'roleplay.csv',
    'roleplay-completion-terms-autumn'
  );
  perform pg_temp.rp_pass(
    '[terms] T6 Autumn 2026 is flagged autumn_2026_forbidden',
    (v_json ->> 'error_count')::int = 1
      and exists (
        select 1 from public.import_studio_rows ir
        where ir.batch_id = (v_json ->> 'batch_id')::uuid
          and ir.error_text ilike '%autumn_2026_forbidden%'
      ),
    left(v_json::text, 400)
  );

  -- T7: rollback of the unused term from T1/T2 succeeds (no dependents yet).
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_rollback_batch(v_batch, 'roleplay-completion-terms-1');
  perform pg_temp.rp_pass(
    '[terms] T7 rollback of an unused new term succeeds',
    coalesce((v_json ->> 'ok')::boolean, false)
      and not exists (select 1 from public.academic_terms where id = v_term_id),
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_nobody();
end
$$;

-- ===========================================================================
-- CURRICULUM -> OFFERINGS -> TEACHER_LINKS — chained workflow, blocked-then-
-- allowed rollback proving the EXPLICIT dependency blockers, not bare FK
-- violations, gate the undo.
-- ===========================================================================
do $$
declare
  v_admin_subjects uuid;
  v_admin_terms uuid;
  v_admin_teachers uuid;
  v_group_id uuid;
  v_group_name text;
  v_subject_id uuid;
  v_subject_name text;
  v_teacher_id uuid;
  v_teacher_name text;
  v_semester integer;
  v_json jsonb;
  v_term_batch uuid;
  v_term_id uuid;
  v_curriculum_batch uuid;
  v_curriculum_id uuid;
  v_offering_batch uuid;
  v_offering_id uuid;
  v_link_batch uuid;
  v_link_id uuid;
begin
  v_admin_subjects := pg_temp.rp_admin_with(array['subjects.write']);
  v_admin_terms := pg_temp.rp_admin_with(array['terms.manage']);
  v_admin_teachers := pg_temp.rp_admin_with(array['teachers.write']);
  if v_admin_subjects is null or v_admin_terms is null or v_admin_teachers is null then
    perform pg_temp.rp_skip(
      '[curriculum] CO0 all',
      'missing admin with subjects.write / terms.manage / teachers.write'
    );
    perform pg_temp.rp_skip(
      '[offerings] CO0 all',
      'missing admin with subjects.write / terms.manage / teachers.write'
    );
    perform pg_temp.rp_skip(
      '[teacher_links] CO0 all',
      'missing admin with subjects.write / terms.manage / teachers.write'
    );
    return;
  end if;

  select g.id, g.name into v_group_id, v_group_name from public.groups g limit 1;
  select sc.id, sc.canonical_name into v_subject_id, v_subject_name
  from public.subject_catalog sc limit 1;
  select t.id, t.full_name into v_teacher_id, v_teacher_name from public.teachers t limit 1;

  if v_group_id is null or v_subject_id is null or v_teacher_id is null then
    perform pg_temp.rp_skip(
      '[curriculum] CO0 all', 'no fixture group/subject/teacher in the catalogue'
    );
    perform pg_temp.rp_skip(
      '[offerings] CO0 all', 'no fixture group/subject/teacher in the catalogue'
    );
    perform pg_temp.rp_skip(
      '[teacher_links] CO0 all', 'no fixture group/subject/teacher in the catalogue'
    );
    return;
  end if;

  select n into v_semester
  from generate_series(1, 12) n
  where not exists (
    select 1 from public.curriculum_subjects cs
    where cs.subject_id = v_subject_id and cs.semester_number = n
  )
  order by n desc
  limit 1;

  if v_semester is null then
    perform pg_temp.rp_skip(
      '[curriculum] CO0 all', 'subject fixture has curriculum rows for every semester 1-12'
    );
    perform pg_temp.rp_skip(
      '[offerings] CO0 all', 'subject fixture has curriculum rows for every semester 1-12'
    );
    perform pg_temp.rp_skip(
      '[teacher_links] CO0 all', 'subject fixture has curriculum rows for every semester 1-12'
    );
    return;
  end if;

  -- A fresh term to hang the offering off, isolated from the TERMS block
  -- above so its rollback stays blocked until the chain below unwinds.
  perform pg_temp.rp_as_user(v_admin_terms);
  v_json := public.admin_import_studio_start_dry_run(
    'terms',
    jsonb_build_array(jsonb_build_object(
      'academic_year_name', '3026/3027',
      'name', 'РП Семестр Workflow',
      'term_in_year', 1,
      'starts_on', '3026-09-01',
      'ends_on', '3027-01-31'
    )),
    'roleplay.csv',
    'roleplay-completion-workflow-term'
  );
  v_term_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_as_user(v_admin_terms);
  v_json := public.admin_import_studio_apply(v_term_batch, 'roleplay-completion-workflow-term');
  select ir.matched_term_id into v_term_id
  from public.import_studio_rows ir where ir.batch_id = v_term_batch limit 1;
  perform pg_temp.rp_pass(
    '[terms] CO1 workflow term is created',
    v_term_id is not null,
    left(v_json::text, 300)
  );

  -- Curriculum: new curriculum_subjects row for (subject, free semester).
  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_start_dry_run(
    'curriculum',
    jsonb_build_array(jsonb_build_object(
      'group_name', v_group_name,
      'subject_name', v_subject_name,
      'semester_number', v_semester,
      'credits', 3
    )),
    'roleplay.csv',
    'roleplay-completion-curriculum'
  );
  v_curriculum_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '[curriculum] CO2 curriculum dry run resolves the existing group + subject',
    v_curriculum_batch is not null and (v_json ->> 'error_count')::int = 0,
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_apply(v_curriculum_batch, 'roleplay-completion-curriculum');
  select ir.matched_curriculum_subject_id into v_curriculum_id
  from public.import_studio_rows ir where ir.batch_id = v_curriculum_batch limit 1;
  perform pg_temp.rp_pass(
    '[curriculum] CO3 apply creates the curriculum_subjects row',
    coalesce((v_json ->> 'ok')::boolean, false) and v_curriculum_id is not null,
    left(v_json::text, 300)
  );

  -- Curriculum with an unknown group_name is refused at validation (the
  -- dependency check for context, not a write target).
  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_start_dry_run(
    'curriculum',
    jsonb_build_array(jsonb_build_object(
      'group_name', 'РП-Несуществующая-Группа-Xyz',
      'subject_name', v_subject_name,
      'semester_number', v_semester
    )),
    'roleplay.csv',
    'roleplay-completion-curriculum-badgroup'
  );
  perform pg_temp.rp_pass(
    '[curriculum] CO4 curriculum with an unknown group_name is flagged group_not_found',
    (v_json ->> 'error_count')::int = 1
      and exists (
        select 1 from public.import_studio_rows ir
        where ir.batch_id = (v_json ->> 'batch_id')::uuid
          and ir.error_text ilike '%group_not_found%'
      ),
    left(v_json::text, 400)
  );

  -- Offerings: new subject_offerings row against the brand-new term, same
  -- semester as the curriculum row so the offerings helper's best-effort
  -- curriculum_subject_id link forms (exactly one match).
  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_start_dry_run(
    'offerings',
    jsonb_build_array(jsonb_build_object(
      'group_name', v_group_name,
      'subject_name', v_subject_name,
      'academic_year_name', '3026/3027',
      'term_name', 'РП Семестр Workflow',
      'semester_number', v_semester
    )),
    'roleplay.csv',
    'roleplay-completion-offerings'
  );
  v_offering_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '[offerings] CO5 offerings dry run resolves group + subject + the new term',
    v_offering_batch is not null and (v_json ->> 'error_count')::int = 0,
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_apply(v_offering_batch, 'roleplay-completion-offerings');
  select ir.matched_offering_id into v_offering_id
  from public.import_studio_rows ir where ir.batch_id = v_offering_batch limit 1;
  perform pg_temp.rp_pass(
    '[offerings] CO6 apply creates the subject_offerings row linked to the new curriculum row',
    coalesce((v_json ->> 'ok')::boolean, false)
      and v_offering_id is not null
      and (
        select curriculum_subject_id from public.subject_offerings where id = v_offering_id
      ) = v_curriculum_id,
    left(v_json::text, 300)
  );

  -- Teacher links: new offering_teachers row against that offering.
  perform pg_temp.rp_as_user(v_admin_teachers);
  v_json := public.admin_import_studio_start_dry_run(
    'teacher_links',
    jsonb_build_array(jsonb_build_object(
      'offering_id', v_offering_id::text,
      'teacher_full_name', v_teacher_name,
      'role', 'lecturer'
    )),
    'roleplay.csv',
    'roleplay-completion-teacher-links'
  );
  v_link_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '[teacher_links] CO7 teacher_links dry run resolves the offering + teacher',
    v_link_batch is not null and (v_json ->> 'error_count')::int = 0,
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin_teachers);
  v_json := public.admin_import_studio_apply(v_link_batch, 'roleplay-completion-teacher-links');
  select ir.matched_teacher_link_id into v_link_id
  from public.import_studio_rows ir where ir.batch_id = v_link_batch limit 1;
  perform pg_temp.rp_pass(
    '[teacher_links] CO8 apply creates the offering_teachers link',
    coalesce((v_json ->> 'ok')::boolean, false) and v_link_id is not null,
    left(v_json::text, 300)
  );

  -- Blocked-then-allowed rollback chain.
  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_rollback_batch(
    v_curriculum_batch, 'roleplay-completion-curriculum'
  );
  perform pg_temp.rp_pass(
    '[curriculum] CO9 curriculum rollback is blocked while the offering references it',
    coalesce((v_json ->> 'ok')::boolean, true) = false
      and v_json ->> 'error_code' = 'rollback_blocked_by_dependency'
      and exists (select 1 from public.curriculum_subjects where id = v_curriculum_id),
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin_terms);
  v_json := public.admin_import_studio_rollback_batch(v_term_batch, 'roleplay-completion-workflow-term');
  perform pg_temp.rp_pass(
    '[terms] CO10 term rollback is blocked while the offering references it',
    coalesce((v_json ->> 'ok')::boolean, true) = false
      and v_json ->> 'error_code' = 'rollback_blocked_by_dependency'
      and exists (select 1 from public.academic_terms where id = v_term_id),
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_rollback_batch(v_offering_batch, 'roleplay-completion-offerings');
  perform pg_temp.rp_pass(
    '[offerings] CO11 offering rollback is blocked while the teacher link references it',
    coalesce((v_json ->> 'ok')::boolean, true) = false
      and v_json ->> 'error_code' = 'rollback_blocked_by_dependency'
      and exists (select 1 from public.subject_offerings where id = v_offering_id),
    left(v_json::text, 400)
  );

  -- offering_teachers is a pure junction row: its rollback is unconditional.
  perform pg_temp.rp_as_user(v_admin_teachers);
  v_json := public.admin_import_studio_rollback_batch(
    v_link_batch, 'roleplay-completion-teacher-links'
  );
  perform pg_temp.rp_pass(
    '[teacher_links] CO12 teacher_link rollback succeeds (no dependents)',
    coalesce((v_json ->> 'ok')::boolean, false)
      and not exists (select 1 from public.offering_teachers where id = v_link_id),
    left(v_json::text, 400)
  );

  -- With the link gone, the offering is now unblocked.
  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_rollback_batch(v_offering_batch, 'roleplay-completion-offerings');
  perform pg_temp.rp_pass(
    '[offerings] CO13 offering rollback now succeeds once the teacher link is gone',
    coalesce((v_json ->> 'ok')::boolean, false)
      and not exists (select 1 from public.subject_offerings where id = v_offering_id),
    left(v_json::text, 400)
  );

  -- With the offering gone, both term and curriculum are unblocked.
  perform pg_temp.rp_as_user(v_admin_subjects);
  v_json := public.admin_import_studio_rollback_batch(
    v_curriculum_batch, 'roleplay-completion-curriculum'
  );
  perform pg_temp.rp_pass(
    '[curriculum] CO14 curriculum rollback now succeeds once the offering is gone',
    coalesce((v_json ->> 'ok')::boolean, false)
      and not exists (select 1 from public.curriculum_subjects where id = v_curriculum_id),
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin_terms);
  v_json := public.admin_import_studio_rollback_batch(v_term_batch, 'roleplay-completion-workflow-term');
  perform pg_temp.rp_pass(
    '[terms] CO15 term rollback now succeeds once the offering is gone',
    coalesce((v_json ->> 'ok')::boolean, false)
      and not exists (select 1 from public.academic_terms where id = v_term_id),
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_nobody();
end
$$;

-- ===========================================================================
-- ENROLLMENTS — idempotent exact replay, cross-group transfer refused,
-- rollback always refused.
-- ===========================================================================
do $$
declare
  v_admin uuid;
  v_json jsonb;
  v_login text;
  v_user_id uuid;
  v_home_group_id uuid;
  v_home_group_name text;
  v_other_group_name text;
  v_batch uuid;
  v_enrollment_count_before integer;
  v_enrollment_count_after integer;
begin
  v_admin := pg_temp.rp_admin_with(array['students.write']);
  if v_admin is null then
    perform pg_temp.rp_skip('[enrollments] E0 all', 'no active admin with students.write');
    return;
  end if;

  select u.login, se.user_id, se.group_id, g.name
  into v_login, v_user_id, v_home_group_id, v_home_group_name
  from public.student_enrollments se
  join public.users u on u.id = se.user_id and u.is_active
  join public.groups g on g.id = se.group_id
  where se.status = 'active' and se.ended_at is null
  limit 1;

  if v_login is null then
    perform pg_temp.rp_skip('[enrollments] E0 all', 'no active student enrollment fixture');
    return;
  end if;

  select g.name into v_other_group_name
  from public.groups g
  where g.id is distinct from v_home_group_id
  limit 1;

  select count(*) into v_enrollment_count_before
  from public.student_enrollments where user_id = v_user_id;

  -- E1: an exact replay of the existing active enrollment (same login, same
  -- group) must be a no-op update, never a duplicate row.
  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_start_dry_run(
    'enrollments',
    jsonb_build_array(jsonb_build_object('login', v_login, 'group_name', v_home_group_name)),
    'roleplay.csv',
    'roleplay-completion-enrollments-replay'
  );
  v_batch := (v_json ->> 'batch_id')::uuid;
  perform pg_temp.rp_pass(
    '[enrollments] E1 an exact replay of an existing enrollment dry-runs clean',
    v_batch is not null and (v_json ->> 'error_count')::int = 0,
    left(v_json::text, 400)
  );

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_apply(v_batch, 'roleplay-completion-enrollments-replay');
  select count(*) into v_enrollment_count_after
  from public.student_enrollments where user_id = v_user_id;
  perform pg_temp.rp_pass(
    '[enrollments] E2 apply of an exact replay is idempotent (no duplicate enrollment)',
    coalesce((v_json ->> 'ok')::boolean, false)
      and v_enrollment_count_after = v_enrollment_count_before,
    format('before=%s after=%s', v_enrollment_count_before, v_enrollment_count_after)
  );

  perform pg_temp.rp_pass(
    '[enrollments] E3 rollback_safe is persisted as false for enrollments',
    (select rollback_safe from public.import_studio_batches where id = v_batch) = false,
    'rollback_safe'
  );

  perform pg_temp.rp_as_user(v_admin);
  v_json := public.admin_import_studio_rollback_batch(
    v_batch, 'roleplay-completion-enrollments-replay'
  );
  perform pg_temp.rp_pass(
    '[enrollments] E4 rollback of an enrollments batch is refused',
    coalesce((v_json ->> 'ok')::boolean, true) = false
      and v_json ->> 'error_code' = 'rollback_not_supported_for_batch',
    left(v_json::text, 400)
  );

  -- E5: a cross-group transfer for the SAME student is refused at
  -- validation (Import Studio never touches team membership).
  if v_other_group_name is null then
    perform pg_temp.rp_skip(
      '[enrollments] E5 a cross-group transfer is refused at validation', 'only one group in fixtures'
    );
  else
    perform pg_temp.rp_as_user(v_admin);
    v_json := public.admin_import_studio_start_dry_run(
      'enrollments',
      jsonb_build_array(jsonb_build_object('login', v_login, 'group_name', v_other_group_name)),
      'roleplay.csv',
      'roleplay-completion-enrollments-transfer'
    );
    perform pg_temp.rp_pass(
      '[enrollments] E5 a cross-group transfer is refused at validation',
      (v_json ->> 'error_count')::int = 1
        and exists (
          select 1 from public.import_studio_rows ir
          where ir.batch_id = (v_json ->> 'batch_id')::uuid
            and ir.error_text ilike '%user_already_enrolled_in_other_group%'
        ),
      left(v_json::text, 400)
    );

    perform pg_temp.rp_as_user(v_admin);
    perform pg_temp.rp_expect_exception(
      '[enrollments] E6 apply refuses the cross-group-transfer batch (it never touches team membership)',
      format(
        'select public.admin_import_studio_apply(%L::uuid, %L)',
        (v_json ->> 'batch_id')::uuid, 'roleplay-completion-enrollments-transfer'
      ),
      'P0001',
      'batch_has_errors'
    );
  end if;

  perform pg_temp.rp_as_nobody();
end
$$;

select scenario, status, detail
from stage19_completion_roleplay_results
order by scenario;

select
  count(*) filter (where status = 'PASS') as pass_count,
  count(*) filter (where status = 'FAIL') as fail_count,
  count(*) filter (where status = 'SKIP') as skip_count,
  count(*) as total
from stage19_completion_roleplay_results;

do $$
declare
  v_fail int;
  v_pass int;
  v_skip int;
  v_total int;
begin
  select
    count(*) filter (where status = 'FAIL'),
    count(*) filter (where status = 'PASS'),
    count(*) filter (where status = 'SKIP'),
    count(*)
  into v_fail, v_pass, v_skip, v_total
  from stage19_completion_roleplay_results;

  if v_fail > 0 then
    raise exception 'stage19 completion roleplay FAILED: %', (
      select string_agg(scenario || ': ' || detail, '; ' order by scenario)
      from stage19_completion_roleplay_results where status = 'FAIL'
    );
  end if;

  -- P1: one global PASS across the whole file is NOT enough — each
  -- completion domain block (tagged "[domain] ..." on every scenario name
  -- above) must itself have at least one PASS. A domain that is entirely
  -- SKIP (e.g. missing fixtures for that domain only) must BLOCK the whole
  -- run, never hide behind an unrelated domain's PASS (found: "roleplay
  -- per-domain SKIP still global PASS").
  declare
    v_domain text;
    v_domain_pass int;
    v_domain_skip int;
    v_domain_total int;
    v_missing text[] := array[]::text[];
  begin
    foreach v_domain in array array[
      'groups', 'terms', 'curriculum', 'offerings', 'teacher_links', 'enrollments'
    ]
    loop
      select
        count(*) filter (where status = 'PASS'),
        count(*) filter (where status = 'SKIP'),
        count(*)
      into v_domain_pass, v_domain_skip, v_domain_total
      from stage19_completion_roleplay_results
      where starts_with(scenario, '[' || v_domain || ']');

      if v_domain_pass = 0 then
        v_missing := array_append(
          v_missing,
          format(
            '%s (pass=%s skip=%s total=%s)',
            v_domain, v_domain_pass, v_domain_skip, v_domain_total
          )
        );
      end if;
    end loop;

    if array_length(v_missing, 1) > 0 then
      raise exception
        'stage19 completion roleplay BLOCKED: per-domain PASS coverage missing for: % '
        '— a global PASS is not enough, every completion domain block needs its own PASS scenario',
        array_to_string(v_missing, '; ');
    end if;
  end;

  -- Empty results or fixtures-only SKIP must never report PASS (found:
  -- "roleplay all-SKIP still PASS"). A run with zero recorded scenarios, or
  -- one where every scenario was skipped for missing fixtures, is BLOCKED,
  -- not a pass — mirrors the stage14_managed_content_roleplay fix.
  if v_total = 0 then
    raise exception
      'stage19 completion roleplay FAIL: results table empty (no scenarios recorded)';
  end if;
  if v_pass = 0 then
    raise exception
      'stage19 completion roleplay BLOCKED/SKIP: pass=0 skip=% total=% (fixtures missing or no asserted run)',
      v_skip, v_total;
  end if;

  raise notice
    'stage19_import_studio_roleplay PASS (pass=% skip=% total=%; SKIP rows mean a missing fixture, not a pass)',
    v_pass, v_skip, v_total;
end
$$;

rollback;
