-- Stage 19.1a: durable curriculum-plan import preview and persistence.
--
-- Forward-only. This migration does not import data by itself. Browser hashes
-- remain untrusted metadata; only a reviewed preview owned by the caller can
-- be applied.

begin;

-- ---------------------------------------------------------------------------
-- Curriculum occurrence storage.
-- ---------------------------------------------------------------------------

alter table public.curriculum_subjects
  add column if not exists source_subject_key text null,
  add column if not exists is_aggregate_owner boolean null,
  add column if not exists assessment_types text[] null,
  add column if not exists workload jsonb null;

update public.curriculum_subjects
set is_aggregate_owner = false,
    assessment_types = '{}'::text[],
    workload = '{}'::jsonb
where curriculum_plan_id is not null
  and (
    is_aggregate_owner is null
    or assessment_types is null
    or workload is null
  );

create or replace function private.academic_assessment_types_canonical(
  p_values text[]
)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(v order by v), '{}'::text[])
  from (
    select distinct btrim(value) as v
    from unnest(coalesce(p_values, '{}'::text[])) as item(value)
    where nullif(btrim(value), '') is not null
  ) normalized;
$$;

create or replace function private.academic_control_form_from_assessments(
  p_values text[]
)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    array_to_string(
      private.academic_assessment_types_canonical(p_values),
      ','
    ),
    ''
  );
$$;

create or replace function private.academic_workload_is_valid(p_value jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when jsonb_typeof(coalesce(p_value, '{}'::jsonb)) <> 'object' then false
    else not exists (
      select 1
      from jsonb_each(coalesce(p_value, '{}'::jsonb)) item
      where case
        when jsonb_typeof(item.value) <> 'number' then true
        else (item.value #>> '{}')::numeric < 0
      end
    )
  end;
$$;

revoke all on function private.academic_assessment_types_canonical(text[])
  from public, anon, authenticated;
revoke all on function private.academic_control_form_from_assessments(text[])
  from public, anon, authenticated;
revoke all on function private.academic_workload_is_valid(jsonb)
  from public, anon, authenticated;
grant execute on function private.academic_assessment_types_canonical(text[])
  to service_role;
grant execute on function private.academic_control_form_from_assessments(text[])
  to service_role;
grant execute on function private.academic_workload_is_valid(jsonb)
  to service_role;

alter table public.curriculum_subjects
  drop constraint if exists curriculum_subjects_plan_subject_key_check;
alter table public.curriculum_subjects
  add constraint curriculum_subjects_plan_subject_key_check check (
    curriculum_plan_id is null
    or (
      nullif(btrim(source_subject_key), '') is not null
      and is_aggregate_owner is not null
      and assessment_types is not null
      and workload is not null
    )
  ) not valid;
alter table public.curriculum_subjects
  validate constraint curriculum_subjects_plan_subject_key_check;

alter table public.curriculum_subjects
  drop constraint if exists curriculum_subjects_assessment_types_check;
alter table public.curriculum_subjects
  add constraint curriculum_subjects_assessment_types_check check (
    curriculum_plan_id is null
    or (
      assessment_types
        = private.academic_assessment_types_canonical(assessment_types)
      and assessment_types <@ array[
        'exam', 'credit', 'graded_credit', 'course_project', 'course_work',
        'control_work'
      ]::text[]
    )
  ) not valid;
alter table public.curriculum_subjects
  validate constraint curriculum_subjects_assessment_types_check;

alter table public.curriculum_subjects
  drop constraint if exists curriculum_subjects_workload_check;
alter table public.curriculum_subjects
  add constraint curriculum_subjects_workload_check check (
    curriculum_plan_id is null
    or private.academic_workload_is_valid(workload)
  ) not valid;
alter table public.curriculum_subjects
  validate constraint curriculum_subjects_workload_check;

alter table public.curriculum_subjects
  drop constraint if exists curriculum_subjects_aggregate_storage_check;
alter table public.curriculum_subjects
  add constraint curriculum_subjects_aggregate_storage_check check (
    curriculum_plan_id is null
    or is_aggregate_owner
    or (hours_total is null and credits is null)
  ) not valid;
alter table public.curriculum_subjects
  validate constraint curriculum_subjects_aggregate_storage_check;

create unique index if not exists
  curriculum_subjects_plan_source_aggregate_owner_unique
on public.curriculum_subjects(curriculum_plan_id, source_subject_key)
where curriculum_plan_id is not null and is_aggregate_owner;

create index if not exists curriculum_subjects_plan_source_subject_idx
  on public.curriculum_subjects(curriculum_plan_id, source_subject_key)
  where curriculum_plan_id is not null;

create or replace function private.curriculum_subject_plan_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_id uuid := coalesce(new.curriculum_plan_id, old.curriculum_plan_id);
  v_status text;
begin
  if tg_op = 'UPDATE'
     and old.curriculum_plan_id is not null
     and (
       new.curriculum_plan_id is distinct from old.curriculum_plan_id
       or new.source_occurrence_key is distinct from old.source_occurrence_key
       or new.source_subject_key is distinct from old.source_subject_key
       or new.subject_id is distinct from old.subject_id
     ) then
    raise exception 'curriculum_occurrence_identity_immutable'
      using errcode = '22023';
  end if;

  if v_plan_id is not null then
    select cp.status into v_status
    from public.curriculum_plans cp
    where cp.id = v_plan_id;
    if v_status is distinct from 'draft' then
      raise exception 'curriculum_plan_not_draft' using errcode = 'P0001';
    end if;
  end if;

  if tg_op <> 'DELETE' and new.curriculum_plan_id is not null then
    new.source_subject_key := btrim(new.source_subject_key);
    new.source_occurrence_key := btrim(new.source_occurrence_key);
    new.assessment_types :=
      private.academic_assessment_types_canonical(new.assessment_types);
    new.control_form :=
      private.academic_control_form_from_assessments(new.assessment_types);
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function private.curriculum_subject_plan_guard()
  from public, anon, authenticated;

drop trigger if exists trg_curriculum_subject_plan_guard
  on public.curriculum_subjects;
create trigger trg_curriculum_subject_plan_guard
before insert or update or delete on public.curriculum_subjects
for each row execute function private.curriculum_subject_plan_guard();

-- The aggregate workload is projected to every occurrence for display without
-- duplicating hours/credits in storage.
create or replace view public.curriculum_subject_occurrence_display
with (security_invoker = true)
as
select
  occurrence.*,
  aggregate_row.hours_total as display_hours_total,
  aggregate_row.credits as display_credits
from public.curriculum_subjects occurrence
left join public.curriculum_subjects aggregate_row
  on aggregate_row.curriculum_plan_id = occurrence.curriculum_plan_id
 and aggregate_row.source_subject_key = occurrence.source_subject_key
 and aggregate_row.is_aggregate_owner;

revoke all on table public.curriculum_subject_occurrence_display
  from public, anon, authenticated;
grant select on table public.curriculum_subject_occurrence_display
  to service_role;

-- ---------------------------------------------------------------------------
-- Durable preview fields on the existing Import Studio infrastructure.
-- ---------------------------------------------------------------------------

alter table public.import_studio_batches
  drop constraint if exists import_studio_batches_domain_check;
alter table public.import_studio_batches
  add constraint import_studio_batches_domain_check check (
    domain in (
      'teachers', 'subjects', 'students', 'groups', 'curriculum', 'terms',
      'offerings', 'teacher_links', 'enrollments', 'curriculum_plan_v2'
    )
  );

alter table public.import_studio_rows
  drop constraint if exists import_studio_rows_classification_check;
alter table public.import_studio_rows
  add constraint import_studio_rows_classification_check check (
    classification in (
      'new', 'update', 'unchanged', 'duplicate', 'error', 'skip'
    )
  );

alter table public.import_studio_batches
  add column if not exists target_curriculum_plan_id uuid null
    references public.curriculum_plans(id) on delete restrict,
  add column if not exists expected_target_row_version integer null,
  add column if not exists parser_contract_version text null,
  add column if not exists preview_expires_at timestamptz null,
  add column if not exists consumed_at timestamptz null,
  add column if not exists normalized_payload_hash text null,
  add column if not exists source_reviewed boolean not null default false,
  add column if not exists source_mime_type text null,
  add column if not exists client_source_sha256 text null;

alter table public.import_studio_batches
  drop constraint if exists import_studio_batches_curriculum_v2_shape_check;
alter table public.import_studio_batches
  add constraint import_studio_batches_curriculum_v2_shape_check check (
    domain <> 'curriculum_plan_v2'
    or (
      target_curriculum_plan_id is not null
      and expected_target_row_version is not null
      and expected_target_row_version > 0
      and parser_contract_version = 'curriculum-document-v2'
      and preview_expires_at is not null
      and normalized_payload_hash ~ '^[0-9a-f]{64}$'
    )
  );

create index if not exists import_studio_batches_curriculum_v2_target_idx
  on public.import_studio_batches(target_curriculum_plan_id, created_at desc)
  where domain = 'curriculum_plan_v2';

-- Keep the original RPC signature for Admin compatibility, but make v2 the
-- accepted contract for new ingestion while retaining v1 for old tests/drafts.
create or replace function public.admin_upsert_curriculum_plan(
  p_id uuid default null,
  p_educational_program_id uuid default null,
  p_admission_year integer default null,
  p_plan_code text default '',
  p_version_label text default '',
  p_nominal_semesters integer default null,
  p_status text default 'draft',
  p_source_title text default null,
  p_source_file_name text default null,
  p_source_mime_type text default null,
  p_source_sha256 text default null,
  p_parser_contract_version text default null,
  p_expected_row_version integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_current public.curriculum_plans%rowtype;
  v_reviewed_by uuid;
  v_reviewed_at timestamptz;
  v_action text;
begin
  if not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_educational_program_id is null
     or not exists (
       select 1 from public.educational_programs ep
       where ep.id = p_educational_program_id
     )
     or p_admission_year not between 2000 and 2100
     or nullif(btrim(p_plan_code), '') is null
     or nullif(btrim(p_version_label), '') is null
     or p_nominal_semesters not between 1 and 20
     or p_status not in ('draft', 'reviewed', 'active', 'archived')
     or p_parser_contract_version not in (
       'curriculum-document-v1', 'curriculum-document-v2'
     )
     or (
       p_source_sha256 is not null
       and lower(btrim(p_source_sha256)) !~ '^[0-9a-f]{64}$'
     ) then
    raise exception 'invalid_curriculum_plan' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(concat_ws(
    '|', p_educational_program_id::text, p_admission_year::text,
    private.academic_ingestion_norm(p_plan_code),
    private.academic_ingestion_norm(p_version_label)
  ), 0));

  if p_status <> 'draft' then
    v_reviewed_by := auth.uid();
    v_reviewed_at := now();
  end if;

  if p_id is null then
    insert into public.curriculum_plans(
      educational_program_id, admission_year, plan_code, version_label,
      nominal_semesters, status, source_title, source_file_name,
      source_mime_type, source_sha256, source_verified,
      parser_contract_version, reviewed_by, reviewed_at, created_by, updated_by
    ) values (
      p_educational_program_id, p_admission_year, btrim(p_plan_code),
      btrim(p_version_label), p_nominal_semesters, p_status,
      nullif(btrim(p_source_title), ''),
      nullif(btrim(p_source_file_name), ''),
      nullif(lower(btrim(p_source_mime_type)), ''),
      nullif(lower(btrim(p_source_sha256)), ''), false,
      p_parser_contract_version, v_reviewed_by, v_reviewed_at,
      auth.uid(), auth.uid()
    )
    returning id into v_id;
    v_action := 'curriculum_plan.create';
  else
    select * into v_current
    from public.curriculum_plans cp
    where cp.id = p_id
    for update;
    if not found then
      raise exception 'curriculum_plan_not_found' using errcode = 'P0002';
    end if;
    if p_expected_row_version is null
       or p_expected_row_version <> v_current.row_version then
      raise exception 'row_version_conflict' using errcode = '40001';
    end if;
    if v_current.status = 'active' and p_status = 'draft' then
      raise exception 'active_plan_cannot_return_to_draft'
        using errcode = 'P0001';
    end if;
    if exists (
      select 1 from public.curriculum_subjects cs
      where cs.curriculum_plan_id = p_id
    ) and (
      p_educational_program_id is distinct from
        v_current.educational_program_id
      or p_admission_year is distinct from v_current.admission_year
      or private.academic_ingestion_norm(p_plan_code) is distinct from
        private.academic_ingestion_norm(v_current.plan_code)
      or private.academic_ingestion_norm(p_version_label) is distinct from
        private.academic_ingestion_norm(v_current.version_label)
      or p_nominal_semesters is distinct from v_current.nominal_semesters
    ) then
      raise exception 'curriculum_plan_identity_immutable_after_import'
        using errcode = '22023';
    end if;

    update public.curriculum_plans
    set educational_program_id = p_educational_program_id,
        admission_year = p_admission_year,
        plan_code = btrim(p_plan_code),
        version_label = btrim(p_version_label),
        nominal_semesters = p_nominal_semesters,
        status = p_status,
        source_title = nullif(btrim(p_source_title), ''),
        source_file_name = nullif(btrim(p_source_file_name), ''),
        source_mime_type = nullif(lower(btrim(p_source_mime_type)), ''),
        source_sha256 = nullif(lower(btrim(p_source_sha256)), ''),
        source_verified = false,
        parser_contract_version = p_parser_contract_version,
        reviewed_by = case
          when p_status = 'draft' then null
          else coalesce(v_reviewed_by, reviewed_by)
        end,
        reviewed_at = case
          when p_status = 'draft' then null
          else coalesce(v_reviewed_at, reviewed_at)
        end,
        updated_by = auth.uid(),
        updated_at = now(),
        row_version = row_version + 1
    where id = p_id
    returning id into v_id;
    v_action := 'curriculum_plan.update';
  end if;

  perform private.admin_write_audit(
    v_action,
    'curriculum_plan',
    v_id::text,
    jsonb_build_object(
      'educational_program_id', p_educational_program_id,
      'admission_year', p_admission_year,
      'plan_code', btrim(p_plan_code),
      'version_label', btrim(p_version_label),
      'status', p_status,
      'parser_contract_version', p_parser_contract_version,
      'source_verified', false
    )
  );
  return v_id;
exception
  when unique_violation then
    raise exception 'curriculum_plan_identity_conflict'
      using errcode = '23505';
end;
$$;

-- Extend the pre-existing domain trigger without weakening other domains.
create or replace function private.import_studio_rows_assert_domain()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_domain text;
begin
  select b.domain into v_domain
  from public.import_studio_batches b
  where b.id = new.batch_id;
  if not found then
    raise exception 'batch_not_found' using errcode = 'P0002';
  end if;

  if new.matched_teacher_id is not null
     and v_domain not in ('teachers', 'teacher_links') then
    raise exception 'match_domain_mismatch_teacher' using errcode = '22023';
  end if;
  if new.matched_subject_id is not null
     and v_domain not in (
       'subjects', 'curriculum', 'offerings', 'teacher_links',
       'curriculum_plan_v2'
     ) then
    raise exception 'match_domain_mismatch_subject' using errcode = '22023';
  end if;
  if new.matched_user_id is not null
     and v_domain not in ('students', 'enrollments') then
    raise exception 'match_domain_mismatch_user' using errcode = '22023';
  end if;
  if new.matched_group_id is not null
     and v_domain not in (
       'groups', 'students', 'curriculum', 'offerings', 'teacher_links',
       'enrollments'
     ) then
    raise exception 'match_domain_mismatch_group' using errcode = '22023';
  end if;
  if new.matched_curriculum_subject_id is not null
     and v_domain not in ('curriculum', 'curriculum_plan_v2') then
    raise exception 'match_domain_mismatch_curriculum_subject'
      using errcode = '22023';
  end if;
  if new.matched_term_id is not null
     and v_domain not in ('terms', 'offerings', 'teacher_links') then
    raise exception 'match_domain_mismatch_term' using errcode = '22023';
  end if;
  if new.matched_offering_id is not null
     and v_domain not in ('offerings', 'teacher_links') then
    raise exception 'match_domain_mismatch_offering' using errcode = '22023';
  end if;
  if new.matched_teacher_link_id is not null
     and v_domain <> 'teacher_links' then
    raise exception 'match_domain_mismatch_teacher_link'
      using errcode = '22023';
  end if;
  if new.matched_enrollment_id is not null
     and v_domain <> 'enrollments' then
    raise exception 'match_domain_mismatch_enrollment'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

revoke all on function private.import_studio_rows_assert_domain()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Shared validator. Dry-run and apply both call this exact function.
-- ---------------------------------------------------------------------------

create or replace function private.validate_curriculum_plan_v2_rows(
  p_curriculum_plan_id uuid,
  p_parser_contract_version text,
  p_source_reviewed boolean,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.curriculum_plans%rowtype;
  v_row jsonb;
  v_n integer := 0;
  v_errors text[];
  v_occurrence_key text;
  v_source_subject_key text;
  v_subject_name text;
  v_subject_index text;
  v_block_name text;
  v_semester integer;
  v_hours integer;
  v_credits numeric;
  v_page integer;
  v_owner boolean;
  v_subject_id uuid;
  v_explicit_subject_id uuid;
  v_subject_count integer;
  v_existing public.curriculum_subjects%rowtype;
  v_assessments text[];
  v_assessment jsonb;
  v_assessment_type text;
  v_assessment_semester integer;
  v_items jsonb := '[]'::jsonb;
  v_mapped jsonb;
  v_class text;
  v_inserted integer := 0;
  v_updated integer := 0;
  v_unchanged integer := 0;
  v_blocked integer := 0;
  v_matched integer := 0;
begin
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) = 0
     or jsonb_array_length(p_rows) > 5000 then
    raise exception 'invalid_curriculum_plan_import_payload'
      using errcode = '22023';
  end if;
  if p_parser_contract_version <> 'curriculum-document-v2'
     or not coalesce(p_source_reviewed, false) then
    raise exception 'invalid_provenance_or_parser_contract'
      using errcode = '22023';
  end if;

  select * into v_plan
  from public.curriculum_plans cp
  where cp.id = p_curriculum_plan_id;
  if not found then
    raise exception 'curriculum_plan_not_found' using errcode = 'P0002';
  end if;
  if v_plan.status <> 'draft' then
    raise exception 'curriculum_plan_not_draft' using errcode = 'P0001';
  end if;
  if v_plan.parser_contract_version <> 'curriculum-document-v2' then
    raise exception 'curriculum_plan_parser_contract_mismatch'
      using errcode = '22023';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_n := v_n + 1;
    v_errors := '{}'::text[];
    v_subject_id := null;
    v_explicit_subject_id := null;
    v_existing := null;
    v_assessments := '{}'::text[];
    v_semester := null;
    v_hours := null;
    v_credits := null;
    v_page := null;
    v_owner := coalesce((v_row ->> 'is_aggregate_owner')::boolean, false);
    v_occurrence_key := nullif(btrim(v_row ->> 'source_occurrence_key'), '');
    v_source_subject_key :=
      nullif(btrim(v_row ->> 'source_subject_key'), '');
    v_subject_name := nullif(btrim(v_row ->> 'subject_name'), '');
    v_subject_index := nullif(btrim(v_row ->> 'subject_index'), '');
    v_block_name := nullif(btrim(v_row ->> 'block_name'), '');

    if v_occurrence_key is null then
      v_errors := array_append(v_errors, 'source_occurrence_key_required');
    end if;
    if v_source_subject_key is null then
      v_errors := array_append(v_errors, 'source_subject_key_required');
    end if;
    if v_subject_name is null then
      v_errors := array_append(v_errors, 'subject_name_required');
    end if;
    if coalesce(
         (v_row ->> 'reviewer_confirmed')::boolean,
         (v_row ->> 'review_attested')::boolean,
         false
       ) is false
       or coalesce(
         (v_row ->> 'has_unresolved_markers')::boolean,
         false
       )
       or jsonb_array_length(
         coalesce(v_row -> 'blocking_issues', '[]'::jsonb)
       ) > 0
       or jsonb_array_length(
         coalesce(v_row -> 'unresolved_assessments', '[]'::jsonb)
       ) > 0 then
      v_errors := array_append(v_errors, 'unresolved_review_markers');
    end if;
    if v_row ->> 'source_parser_version' <> 'local-layout-v2'
       or coalesce(
         (v_row ->> 'source_reviewed')::boolean,
         (v_row ->> 'review_attested')::boolean,
         false
       ) is false then
      v_errors := array_append(v_errors, 'invalid_row_provenance');
    end if;

    begin
      v_semester := (v_row ->> 'semester_number')::integer;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end;
    if v_semester is null
       or v_semester < 1
       or v_semester > v_plan.nominal_semesters then
      v_errors := array_append(v_errors, 'semester_outside_plan');
    end if;

    begin
      v_hours := nullif(btrim(v_row ->> 'hours_total'), '')::integer;
      v_credits :=
        replace(nullif(btrim(v_row ->> 'credits'), ''), ',', '.')::numeric;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_aggregate_workload');
    end;
    if coalesce(v_hours, 0) < 0 or coalesce(v_credits, 0) < 0
       or (not v_owner and (v_hours is not null or v_credits is not null)) then
      v_errors := array_append(v_errors, 'aggregate_workload_owner_mismatch');
    end if;

    begin
      v_page := nullif(btrim(v_row ->> 'source_page'), '')::integer;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_source_page');
    end;
    if v_page is null or v_page < 1
       or jsonb_typeof(coalesce(v_row -> 'source_region', 'null'::jsonb))
            <> 'object' then
      v_errors := array_append(v_errors, 'invalid_source_provenance');
    end if;
    if not private.academic_workload_is_valid(
      coalesce(v_row -> 'workload', '{}'::jsonb)
    ) then
      v_errors := array_append(v_errors, 'invalid_workload');
    end if;

    if jsonb_typeof(coalesce(v_row -> 'assessments', 'null'::jsonb)) = 'array'
    then
      for v_assessment in
        select value from jsonb_array_elements(v_row -> 'assessments')
      loop
        v_assessment_type := nullif(btrim(v_assessment ->> 'type'), '');
        begin
          v_assessment_semester :=
            (v_assessment ->> 'semester_number')::integer;
        exception when others then
          v_assessment_semester := null;
        end;
        if v_assessment_type not in (
          'exam', 'credit', 'graded_credit', 'course_project', 'course_work',
          'control_work'
        ) then
          v_errors := array_append(v_errors, 'unknown_assessment_type');
        elsif v_assessment_type = any(v_assessments) then
          v_errors := array_append(v_errors, 'duplicate_assessment_type');
        else
          v_assessments := array_append(v_assessments, v_assessment_type);
        end if;
        if v_assessment_semester is distinct from v_semester then
          v_errors := array_append(v_errors, 'assessment_semester_mismatch');
        end if;
        if coalesce((v_assessment ->> 'reviewer_confirmed')::boolean, false)
             is false then
          v_errors := array_append(v_errors, 'unreviewed_assessment');
        end if;
      end loop;
    elsif jsonb_typeof(
      coalesce(v_row -> 'assessment_types', 'null'::jsonb)
    ) = 'array' then
      for v_assessment_type in
        select value #>> '{}'
        from jsonb_array_elements(v_row -> 'assessment_types')
      loop
        if v_assessment_type not in (
          'exam', 'credit', 'graded_credit', 'course_project', 'course_work',
          'control_work'
        ) then
          v_errors := array_append(v_errors, 'unknown_assessment_type');
        elsif v_assessment_type = any(v_assessments) then
          v_errors := array_append(v_errors, 'duplicate_assessment_type');
        else
          v_assessments := array_append(v_assessments, v_assessment_type);
        end if;
      end loop;
    else
      v_errors := array_append(v_errors, 'assessments_array_required');
    end if;
    v_assessments :=
      private.academic_assessment_types_canonical(v_assessments);

    begin
      v_explicit_subject_id :=
        nullif(btrim(coalesce(
          v_row ->> 'reviewed_subject_id',
          v_row ->> 'subject_id'
        )), '')::uuid;
    exception when others then
      v_errors := array_append(v_errors, 'invalid_reviewed_subject_id');
    end;
    if v_explicit_subject_id is not null then
      select sc.id into v_subject_id
      from public.subject_catalog sc
      where sc.id = v_explicit_subject_id
        and sc.status <> 'archived';
      if not found then
        v_errors := array_append(v_errors, 'reviewed_subject_not_found');
      end if;
    elsif v_subject_name is not null then
      select count(distinct candidate.id), min(candidate.id::text)::uuid
        into v_subject_count, v_subject_id
      from (
        select sc.id
        from public.subject_catalog sc
        where (
          private.academic_ingestion_norm(sc.canonical_name)
            = private.academic_ingestion_norm(v_subject_name)
          or private.academic_ingestion_norm(sc.normalized_name)
            = private.academic_ingestion_norm(v_subject_name)
        )
          and sc.status <> 'archived'
        union all
        select sa.subject_id
        from public.subject_aliases sa
        join public.subject_catalog alias_subject
          on alias_subject.id = sa.subject_id
        where (
          private.academic_ingestion_norm(sa.alias)
            = private.academic_ingestion_norm(v_subject_name)
          or private.academic_ingestion_norm(sa.normalized_alias)
            = private.academic_ingestion_norm(v_subject_name)
        )
          and alias_subject.status <> 'archived'
      ) candidate;
      if v_subject_count = 0 then
        v_subject_id := null;
        v_errors := array_append(v_errors, 'subject_match_missing');
      elsif v_subject_count > 1 then
        v_subject_id := null;
        v_errors := array_append(v_errors, 'subject_match_ambiguous');
      end if;
    end if;

    if v_occurrence_key is not null then
      select * into v_existing
      from public.curriculum_subjects cs
      where cs.curriculum_plan_id = p_curriculum_plan_id
        and cs.source_occurrence_key = v_occurrence_key;
      if found and (
        v_existing.source_subject_key is distinct from v_source_subject_key
        or v_existing.subject_id is distinct from v_subject_id
      ) then
        v_errors := array_append(v_errors, 'immutable_identity_change');
      end if;
    end if;

    if v_occurrence_key is not null and (
      select count(*) from jsonb_array_elements(p_rows) duplicate_row
      where btrim(duplicate_row ->> 'source_occurrence_key')
              = v_occurrence_key
    ) > 1 then
      v_errors := array_append(v_errors, 'duplicate_occurrence_key');
    end if;
    if v_source_subject_key is not null and (
      select count(*) from jsonb_array_elements(p_rows) owner_row
      where btrim(owner_row ->> 'source_subject_key') = v_source_subject_key
        and coalesce((owner_row ->> 'is_aggregate_owner')::boolean, false)
    ) <> 1 then
      v_errors := array_append(v_errors, 'aggregate_owner_count_invalid');
    end if;
    if v_source_subject_key is not null and exists (
      select 1
      from jsonb_array_elements(p_rows) sibling
      where btrim(sibling ->> 'source_subject_key') = v_source_subject_key
        and (
          private.academic_ingestion_norm(sibling ->> 'subject_name')
            <> private.academic_ingestion_norm(v_subject_name)
          or nullif(btrim(sibling ->> 'subject_index'), '')
               is distinct from v_subject_index
          or nullif(btrim(sibling ->> 'block_name'), '')
               is distinct from v_block_name
          or nullif(btrim(coalesce(
               sibling ->> 'reviewed_subject_id',
               sibling ->> 'subject_id'
             )), '') is distinct from nullif(btrim(coalesce(
               v_row ->> 'reviewed_subject_id',
               v_row ->> 'subject_id'
             )), '')
        )
    ) then
      v_errors := array_append(v_errors, 'conflicting_source_subject_metadata');
    end if;

    v_mapped := jsonb_build_object(
      'source_occurrence_key', v_occurrence_key,
      'source_subject_key', v_source_subject_key,
      'subject_name', v_subject_name,
      'subject_index', v_subject_index,
      'block_name', v_block_name,
      'semester_number', v_semester,
      'hours_total', v_hours,
      'credits', v_credits,
      'is_aggregate_owner', v_owner,
      'assessment_types', to_jsonb(v_assessments),
      'workload', coalesce(v_row -> 'workload', '{}'::jsonb),
      'reviewed_subject_id', v_subject_id,
      'reviewer_confirmed', true,
      'source_reviewed', true,
      'source_page', v_page,
      'source_region', v_row -> 'source_region',
      'source_parser_version', v_row ->> 'source_parser_version',
      'blocking_issues', '[]'::jsonb,
      'unresolved_assessments', '[]'::jsonb
    );

    if cardinality(v_errors) > 0 then
      v_class := 'error';
      v_blocked := v_blocked + 1;
    elsif v_existing.id is null then
      v_class := 'new';
      v_inserted := v_inserted + 1;
    elsif (v_existing.semester_number, v_existing.is_aggregate_owner,
           v_existing.hours_total, v_existing.credits,
           v_existing.assessment_types, v_existing.workload,
           v_existing.subject_index,
           v_existing.block_name, v_existing.source_page,
           v_existing.source_region, v_existing.source_parser_version)
          is not distinct from
          (v_semester, v_owner, v_hours, v_credits, v_assessments,
           coalesce(v_row -> 'workload', '{}'::jsonb),
           v_subject_index, v_block_name, v_page, v_row -> 'source_region',
           v_row ->> 'source_parser_version') then
      v_class := 'unchanged';
      v_unchanged := v_unchanged + 1;
      v_matched := v_matched + 1;
    else
      v_class := 'update';
      v_updated := v_updated + 1;
      v_matched := v_matched + 1;
    end if;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'row_number', v_n,
      'classification', v_class,
      'errors', to_jsonb(v_errors),
      'mapped', v_mapped,
      'matched_subject_id', v_subject_id,
      'matched_curriculum_subject_id', v_existing.id
    ));
  end loop;

  return jsonb_build_object(
    'ok', v_blocked = 0,
    'summary', jsonb_build_object(
      'inserted', v_inserted,
      'updated', v_updated,
      'unchanged', v_unchanged,
      'blocked', v_blocked,
      'matched_subjects', v_matched + v_inserted,
      'total', v_n
    ),
    'items', v_items
  );
end;
$$;

revoke all on function private.validate_curriculum_plan_v2_rows(
  uuid, text, boolean, jsonb
) from public, anon, authenticated;
grant execute on function private.validate_curriculum_plan_v2_rows(
  uuid, text, boolean, jsonb
) to service_role;

-- ---------------------------------------------------------------------------
-- Durable dry-run.
-- ---------------------------------------------------------------------------

create or replace function public.admin_curriculum_plan_import_dry_run_v2(
  p_curriculum_plan_id uuid,
  p_expected_row_version integer,
  p_parser_contract_version text,
  p_rows jsonb,
  p_source_reviewed boolean,
  p_file_name text default '',
  p_source_mime_type text default null,
  p_client_source_sha256 text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_plan public.curriculum_plans%rowtype;
  v_validation jsonb;
  v_item jsonb;
  v_batch_id uuid := gen_random_uuid();
  v_normalized jsonb;
  v_hash text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_plan
  from public.curriculum_plans cp
  where cp.id = p_curriculum_plan_id;
  if not found then
    raise exception 'curriculum_plan_not_found' using errcode = 'P0002';
  end if;
  if v_plan.row_version <> p_expected_row_version then
    raise exception 'row_version_conflict' using errcode = '40001';
  end if;

  v_validation := private.validate_curriculum_plan_v2_rows(
    p_curriculum_plan_id,
    p_parser_contract_version,
    p_source_reviewed,
    p_rows
  );
  select jsonb_agg(item -> 'mapped' order by (item ->> 'row_number')::integer)
    into v_normalized
  from jsonb_array_elements(v_validation -> 'items') item;
  v_hash := encode(
    extensions.digest(convert_to(v_normalized::text, 'UTF8'), 'sha256'),
    'hex'
  );

  insert into public.import_studio_batches(
    id, domain, status, batch_key, file_name, payload_hash,
    normalized_payload_hash, row_count, error_count, summary,
    rollback_safe, created_by, target_curriculum_plan_id,
    expected_target_row_version, parser_contract_version,
    preview_expires_at, source_reviewed, source_mime_type,
    client_source_sha256
  ) values (
    v_batch_id, 'curriculum_plan_v2', 'dry_run', v_batch_id::text,
    left(coalesce(p_file_name, ''), 260), v_hash, v_hash,
    jsonb_array_length(p_rows),
    coalesce((v_validation -> 'summary' ->> 'blocked')::integer, 0),
    v_validation -> 'summary', false, v_uid, p_curriculum_plan_id,
    p_expected_row_version, p_parser_contract_version,
    now() + interval '30 minutes', p_source_reviewed,
    nullif(lower(btrim(p_source_mime_type)), ''),
    case
      when lower(btrim(coalesce(p_client_source_sha256, '')))
             ~ '^[0-9a-f]{64}$'
        then lower(btrim(p_client_source_sha256))
      else null
    end
  );

  for v_item in
    select value from jsonb_array_elements(v_validation -> 'items')
  loop
    insert into public.import_studio_rows(
      batch_id, row_number, classification, source_payload, mapped_payload,
      validation, error_text, dedupe_key, matched_subject_id,
      matched_curriculum_subject_id
    ) values (
      v_batch_id,
      (v_item ->> 'row_number')::integer,
      v_item ->> 'classification',
      v_item -> 'mapped',
      v_item -> 'mapped',
      jsonb_build_object('errors', v_item -> 'errors'),
      left(nullif(array_to_string(array(
        select value #>> '{}'
        from jsonb_array_elements(v_item -> 'errors')
      ), ','), ''), 500),
      v_item -> 'mapped' ->> 'source_occurrence_key',
      nullif(v_item ->> 'matched_subject_id', '')::uuid,
      nullif(v_item ->> 'matched_curriculum_subject_id', '')::uuid
    );
  end loop;

  perform private.admin_write_audit(
    'curriculum_plan_import.preview',
    'import_studio_batch',
    v_batch_id::text,
    jsonb_build_object(
      'curriculum_plan_id', p_curriculum_plan_id,
      'status', 'dry_run',
      'source_mime_type', nullif(lower(btrim(p_source_mime_type)), ''),
      'payload_hash', v_hash,
      'summary', v_validation -> 'summary'
    )
  );

  return jsonb_build_object(
    'preview_token', v_batch_id,
    'curriculum_plan_id', p_curriculum_plan_id,
    'expected_row_version', p_expected_row_version,
    'expires_at', now() + interval '30 minutes',
    'payload_hash', v_hash,
    'apply_enabled', (v_validation ->> 'ok')::boolean,
    'summary', v_validation -> 'summary',
    'items', v_validation -> 'items'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Apply the exact stored preview. No omission ever deletes a target row.
-- ---------------------------------------------------------------------------

create or replace function public.admin_curriculum_plan_import_apply_v2(
  p_preview_token uuid,
  p_exact_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_batch public.import_studio_batches%rowtype;
  v_plan public.curriculum_plans%rowtype;
  v_rows jsonb;
  v_validation jsonb;
  v_hash text;
  v_item jsonb;
  v_mapped jsonb;
  v_id uuid;
  v_existing public.curriculum_subjects%rowtype;
  v_inserted integer := 0;
  v_updated integer := 0;
  v_unchanged integer := 0;
  v_omitted integer := 0;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_batch
  from public.import_studio_batches b
  where b.id = p_preview_token
    and b.domain = 'curriculum_plan_v2'
  for update;
  if not found then
    raise exception 'preview_not_found' using errcode = 'P0002';
  end if;
  if v_batch.created_by <> v_uid then
    raise exception 'preview_owner_mismatch' using errcode = '42501';
  end if;
  if v_batch.status = 'applied' then
    return v_batch.delegated_result
      || jsonb_build_object('already_applied', true);
  end if;
  if v_batch.status <> 'dry_run'
     or v_batch.consumed_at is not null
     or v_batch.preview_expires_at <= now() then
    raise exception 'preview_expired_or_consumed' using errcode = '40001';
  end if;
  if v_batch.error_count <> 0 then
    raise exception 'preview_has_blockers' using errcode = '22023';
  end if;

  select * into v_plan
  from public.curriculum_plans cp
  where cp.id = v_batch.target_curriculum_plan_id
  for update;
  if not found then
    raise exception 'curriculum_plan_not_found' using errcode = 'P0002';
  end if;
  if v_plan.status <> 'draft'
     or v_plan.row_version <> v_batch.expected_target_row_version then
    raise exception 'stale_preview' using errcode = '40001';
  end if;
  if p_exact_confirmation is distinct from v_plan.plan_code then
    raise exception 'confirmation_mismatch' using errcode = '22023';
  end if;

  select jsonb_agg(r.mapped_payload order by r.row_number)
    into v_rows
  from public.import_studio_rows r
  where r.batch_id = v_batch.id;
  v_hash := encode(
    extensions.digest(convert_to(v_rows::text, 'UTF8'), 'sha256'),
    'hex'
  );
  if v_hash is distinct from v_batch.normalized_payload_hash then
    raise exception 'preview_payload_hash_mismatch' using errcode = '40001';
  end if;

  v_validation := private.validate_curriculum_plan_v2_rows(
    v_batch.target_curriculum_plan_id,
    v_batch.parser_contract_version,
    v_batch.source_reviewed,
    v_rows
  );
  if not (v_validation ->> 'ok')::boolean then
    raise exception 'preview_no_longer_clean' using errcode = '40001';
  end if;

  -- Prevent transient duplicate aggregate owners while allowing a reviewed
  -- owner move inside the same source-subject group.
  update public.curriculum_subjects cs
  set is_aggregate_owner = false,
      hours_total = null,
      credits = null
  where cs.curriculum_plan_id = v_batch.target_curriculum_plan_id
    and cs.source_subject_key in (
      select distinct item -> 'mapped' ->> 'source_subject_key'
      from jsonb_array_elements(v_validation -> 'items') item
    )
    and cs.is_aggregate_owner;

  for v_item in
    select value from jsonb_array_elements(v_validation -> 'items')
    order by (value ->> 'row_number')::integer
  loop
    v_mapped := v_item -> 'mapped';
    select * into v_existing
    from public.curriculum_subjects cs
    where cs.curriculum_plan_id = v_batch.target_curriculum_plan_id
      and cs.source_occurrence_key =
        v_mapped ->> 'source_occurrence_key'
    for update;

    if found then
      if v_existing.source_subject_key
           is distinct from (v_mapped ->> 'source_subject_key')
         or v_existing.subject_id
           is distinct from (v_mapped ->> 'reviewed_subject_id')::uuid then
        raise exception 'immutable_identity_change' using errcode = '40001';
      end if;
      update public.curriculum_subjects
      set raw_subject_name = v_mapped ->> 'subject_name',
          display_name = v_mapped ->> 'subject_name',
          semester_number = (v_mapped ->> 'semester_number')::integer,
          hours_total = (v_mapped ->> 'hours_total')::integer,
          credits = (v_mapped ->> 'credits')::numeric,
          is_aggregate_owner =
            (v_mapped ->> 'is_aggregate_owner')::boolean,
          assessment_types = array(
            select value #>> '{}'
            from jsonb_array_elements(v_mapped -> 'assessment_types')
          ),
          workload = coalesce(v_mapped -> 'workload', '{}'::jsonb),
          subject_index = v_mapped ->> 'subject_index',
          block_name = v_mapped ->> 'block_name',
          source_page = (v_mapped ->> 'source_page')::integer,
          source_region = v_mapped -> 'source_region',
          source_parser_version = v_mapped ->> 'source_parser_version',
          reviewed_by = v_uid,
          reviewed_at = now()
      where id = v_existing.id;
      if v_item ->> 'classification' = 'unchanged' then
        v_unchanged := v_unchanged + 1;
      else
        v_updated := v_updated + 1;
      end if;
      v_id := v_existing.id;
    else
      insert into public.curriculum_subjects(
        curriculum_plan_id, subject_id, raw_subject_name, display_name,
        semester_number, hours_total, credits, subject_index, block_name,
        source_occurrence_key, source_subject_key, is_aggregate_owner,
        assessment_types, workload, source_page, source_region,
        source_parser_version, reviewed_by, reviewed_at
      ) values (
        v_batch.target_curriculum_plan_id,
        (v_mapped ->> 'reviewed_subject_id')::uuid,
        v_mapped ->> 'subject_name',
        v_mapped ->> 'subject_name',
        (v_mapped ->> 'semester_number')::integer,
        (v_mapped ->> 'hours_total')::integer,
        (v_mapped ->> 'credits')::numeric,
        v_mapped ->> 'subject_index',
        v_mapped ->> 'block_name',
        v_mapped ->> 'source_occurrence_key',
        v_mapped ->> 'source_subject_key',
        (v_mapped ->> 'is_aggregate_owner')::boolean,
        array(
          select value #>> '{}'
          from jsonb_array_elements(v_mapped -> 'assessment_types')
        ),
        coalesce(v_mapped -> 'workload', '{}'::jsonb),
        (v_mapped ->> 'source_page')::integer,
        v_mapped -> 'source_region',
        v_mapped ->> 'source_parser_version',
        v_uid,
        now()
      )
      returning id into v_id;
      v_inserted := v_inserted + 1;
    end if;

    update public.import_studio_rows
    set matched_curriculum_subject_id = v_id,
        apply_created = v_existing.id is null
    where batch_id = v_batch.id
      and row_number = (v_item ->> 'row_number')::integer;
  end loop;

  select count(*) into v_omitted
  from public.curriculum_subjects cs
  where cs.curriculum_plan_id = v_batch.target_curriculum_plan_id
    and not exists (
      select 1
      from jsonb_array_elements(v_validation -> 'items') item
      where item -> 'mapped' ->> 'source_occurrence_key'
              = cs.source_occurrence_key
    );

  update public.curriculum_plans
  set row_version = row_version + 1,
      updated_by = v_uid,
      updated_at = now()
  where id = v_batch.target_curriculum_plan_id;

  v_result := jsonb_build_object(
    'preview_token', v_batch.id,
    'curriculum_plan_id', v_batch.target_curriculum_plan_id,
    'inserted', v_inserted,
    'updated', v_updated,
    'unchanged', v_unchanged,
    'omitted', v_omitted,
    'blocked', 0,
    'matched_subjects',
      (v_validation -> 'summary' ->> 'matched_subjects')::integer,
    'row_version', v_plan.row_version + 1,
    'already_applied', false
  );

  update public.import_studio_batches
  set status = 'applied',
      consumed_at = now(),
      applied_by = v_uid,
      applied_at = now(),
      delegated_result = v_result,
      summary = v_result
  where id = v_batch.id;

  perform private.admin_write_audit(
    'curriculum_plan_import.apply',
    'import_studio_batch',
    v_batch.id::text,
    jsonb_build_object(
      'curriculum_plan_id', v_batch.target_curriculum_plan_id,
      'status', 'applied',
      'source_mime_type', v_batch.source_mime_type,
      'payload_hash', v_batch.normalized_payload_hash,
      'result', v_result
    )
  );
  return v_result;
end;
$$;

-- Admin-compatible v2 overload. The original three-argument v1 function
-- remains available and apply-disabled for legacy tests.
create or replace function public.admin_curriculum_plan_import_dry_run(
  p_curriculum_plan_id uuid,
  p_parser_contract_version text,
  p_rows jsonb,
  p_file_name text,
  p_source_mime_type text,
  p_client_sha256 text,
  p_source_reviewed boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version integer;
  v_result jsonb;
begin
  select cp.row_version into v_version
  from public.curriculum_plans cp
  where cp.id = p_curriculum_plan_id;
  if not found then
    raise exception 'curriculum_plan_not_found' using errcode = 'P0002';
  end if;

  v_result := public.admin_curriculum_plan_import_dry_run_v2(
    p_curriculum_plan_id,
    v_version,
    p_parser_contract_version,
    p_rows,
    p_source_reviewed,
    p_file_name,
    p_source_mime_type,
    p_client_sha256
  );
  return v_result || jsonb_build_object(
    'ok', (v_result ->> 'apply_enabled')::boolean,
    'preview_id', v_result -> 'preview_token',
    'apply_blocker', case
      when (v_result ->> 'apply_enabled')::boolean then null
      else 'validation_failed'
    end
  );
end;
$$;

create or replace function public.admin_curriculum_plan_import_apply(
  p_preview_id uuid,
  p_confirm_plan_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  v_result := public.admin_curriculum_plan_import_apply_v2(
    p_preview_id,
    p_confirm_plan_code
  );
  return jsonb_build_object(
    'ok', true,
    'idempotent_replay',
      coalesce((v_result ->> 'already_applied')::boolean, false),
    'summary', v_result - 'already_applied'
  );
end;
$$;

revoke all on function public.admin_curriculum_plan_import_dry_run_v2(
  uuid, integer, text, jsonb, boolean, text, text, text
) from public, anon, authenticated;
grant execute on function public.admin_curriculum_plan_import_dry_run_v2(
  uuid, integer, text, jsonb, boolean, text, text, text
) to authenticated;

revoke all on function public.admin_curriculum_plan_import_apply_v2(
  uuid, text
) from public, anon, authenticated;
grant execute on function public.admin_curriculum_plan_import_apply_v2(
  uuid, text
) to authenticated;

revoke all on function public.admin_curriculum_plan_import_dry_run(
  uuid, text, jsonb, text, text, text, boolean
) from public, anon, authenticated;
grant execute on function public.admin_curriculum_plan_import_dry_run(
  uuid, text, jsonb, text, text, text, boolean
) to authenticated;

revoke all on function public.admin_curriculum_plan_import_apply(uuid, text)
  from public, anon, authenticated;
grant execute on function public.admin_curriculum_plan_import_apply(uuid, text)
  to authenticated;

commit;
