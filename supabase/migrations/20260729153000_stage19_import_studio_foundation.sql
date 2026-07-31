-- Stage 19: Import Studio foundation (SPEC section 7).
--
-- PARTIAL FOUNDATION — read the domain matrix before wiring any UI.
--
-- Admin hub audit tables + template → map → dry-run → diff → confirm apply
-- pipeline with idempotent batch keys. Apply WRAPS the existing Stage 13
-- domain import RPCs (admin_teacher_import_apply / admin_subject_import_apply /
-- admin_student_import_apply) instead of reimplementing them.
--
-- private.import_studio_domain_state is the single honest statement of what
-- exists:
--   apply           teachers, subjects, students
--   validate_only   groups, curriculum, terms   (dry run + diff; apply refused)
--   not_implemented offerings, teacher_links, enrollments
--                   (declared only; every call raises not_implemented_domain_*)
--
-- Rollback is a stub: admin_import_studio_rollback_batch refuses every batch
-- because no domain here has a reviewed reversible undo.
--
-- HARD RULES encoded here:
--   * the current term is NEVER flipped by an import (verified before/after);
--   * Autumn 2026 terms are rejected by the validator AND re-checked on apply;
--   * no service_role in Flutter Web / Admin Web: everything is a SECURITY
--     DEFINER RPC granted to `authenticated`, RBAC-checked per domain.
--
-- Depends on: 20260721202054 (RBAC), 20260727184156 (teacher import),
-- 20260727184238 (subject import), 20260727184423 (student import),
-- 20260727234755 (safe academic terms).
--
-- Local only. Not applied to remote in this session.

begin;

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

-- Repeated verbatim from the Stage 16 migration so this file is independently
-- re-appliable.
create or replace function private.require_any_admin_permission(p_permissions text[])
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_perm text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_permissions is null or coalesce(array_length(p_permissions, 1), 0) = 0 then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  foreach v_perm in array p_permissions loop
    if private.has_admin_permission(v_uid, v_perm, 'global', null) then
      return v_uid;
    end if;
  end loop;

  raise exception 'forbidden' using errcode = '42501';
end;
$$;

revoke all on function private.require_any_admin_permission(text[])
  from public, anon, authenticated;
grant execute on function private.require_any_admin_permission(text[]) to service_role;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.import_studio_batches (
  id uuid primary key default gen_random_uuid(),
  domain text not null check (
    domain in (
      'teachers', 'subjects', 'students', 'groups', 'curriculum', 'terms',
      -- Declared but NOT implemented in this foundation; see
      -- private.import_studio_domain_state.
      'offerings', 'teacher_links', 'enrollments'
    )
  ),
  status text not null default 'dry_run'
    check (status in ('dry_run', 'applied', 'cancelled', 'failed')),
  batch_key text not null,
  file_name text not null default '',
  payload_hash text not null,
  row_count integer not null default 0 check (row_count >= 0),
  error_count integer not null default 0 check (error_count >= 0),
  summary jsonb not null default '{}'::jsonb,
  delegated_result jsonb not null default '{}'::jsonb,
  -- Only a batch whose domain has a proven reversible undo may ever be rolled
  -- back. Nothing in this foundation sets it to true.
  rollback_safe boolean not null default false,
  created_by uuid not null references public.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  applied_by uuid null references public.users (id) on delete set null,
  applied_at timestamptz null,
  constraint import_studio_batches_key_unique unique (created_by, domain, batch_key),
  constraint import_studio_batches_key_len check (
    btrim(batch_key) <> '' and char_length(batch_key) <= 120
  ),
  constraint import_studio_batches_file_len check (char_length(file_name) <= 260)
);

comment on table public.import_studio_batches is
  'Import Studio audit. Idempotency key is (created_by, domain, batch_key): batches are per-operator, so one admin cannot replay, refresh or cancel another admin''s batch by guessing a key. Re-running your own dry run refreshes its rows; re-applying an applied batch is a no-op replay.';
comment on column public.import_studio_batches.created_by is
  'Owning operator. NOT NULL and mutation-scoped: dry-run refresh, apply, cancel and rollback all require created_by = auth.uid().';
comment on column public.import_studio_batches.rollback_safe is
  'True only for batches whose domain has a reviewed, reversible undo. Always false in the Stage 19 foundation, so admin_import_studio_rollback_batch refuses every batch.';

create index if not exists import_studio_batches_domain_idx
  on public.import_studio_batches (domain, created_at desc);
create index if not exists import_studio_batches_hash_idx
  on public.import_studio_batches (domain, payload_hash);

create table if not exists public.import_studio_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null
    references public.import_studio_batches (id) on delete cascade,
  row_number integer not null check (row_number > 0),
  classification text not null check (
    classification in ('new', 'update', 'duplicate', 'error', 'skip')
  ),
  source_payload jsonb not null default '{}'::jsonb,
  mapped_payload jsonb not null default '{}'::jsonb,
  validation jsonb not null default '{}'::jsonb,
  error_text text null,
  dedupe_key text null,
  -- Typed match targets instead of one free-form polymorphic id. A trigger
  -- asserts the populated column matches the batch domain.
  matched_teacher_id uuid null references public.teachers (id) on delete set null,
  matched_subject_id uuid null references public.subject_catalog (id) on delete set null,
  matched_user_id uuid null references public.users (id) on delete set null,
  matched_group_id uuid null references public.groups (id) on delete set null,
  constraint import_studio_rows_unique unique (batch_id, row_number),
  constraint import_studio_rows_error_len check (
    error_text is null or char_length(error_text) <= 500
  )
);

-- A row matches at most one *primary* entity, but some domains legitimately
-- resolve a supporting group as well (students -> user + group,
-- curriculum -> subject + group), so matched_group_id is not part of the XOR.
-- trg_import_studio_rows_domain below is what pins each column to its domain.
alter table public.import_studio_rows
  drop constraint if exists import_studio_rows_single_match;
alter table public.import_studio_rows
  add constraint import_studio_rows_single_match check (
    (
      (matched_teacher_id is not null)::integer
      + (matched_subject_id is not null)::integer
      + (matched_user_id is not null)::integer
    ) <= 1
  );

comment on table public.import_studio_rows is
  'Mapped + validated rows for one Import Studio batch. mapped_payload is what apply forwards to the domain import RPC.';

create index if not exists import_studio_rows_batch_idx
  on public.import_studio_rows (batch_id, row_number);
create index if not exists import_studio_rows_class_idx
  on public.import_studio_rows (batch_id, classification);

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

  if new.matched_teacher_id is not null and v_domain <> 'teachers' then
    raise exception 'match_domain_mismatch_teacher' using errcode = '22023';
  end if;
  if new.matched_subject_id is not null
     and v_domain not in ('subjects', 'curriculum') then
    raise exception 'match_domain_mismatch_subject' using errcode = '22023';
  end if;
  if new.matched_user_id is not null and v_domain <> 'students' then
    raise exception 'match_domain_mismatch_user' using errcode = '22023';
  end if;
  if new.matched_group_id is not null
     and v_domain not in ('groups', 'students', 'curriculum') then
    raise exception 'match_domain_mismatch_group' using errcode = '22023';
  end if;

  return new;
end;
$$;

revoke all on function private.import_studio_rows_assert_domain()
  from public, anon, authenticated;

drop trigger if exists trg_import_studio_rows_domain on public.import_studio_rows;
create trigger trg_import_studio_rows_domain
before insert or update on public.import_studio_rows
for each row execute function private.import_studio_rows_assert_domain();

alter table public.import_studio_batches enable row level security;
alter table public.import_studio_batches force row level security;
alter table public.import_studio_rows enable row level security;
alter table public.import_studio_rows force row level security;

revoke all on table public.import_studio_batches from public, anon, authenticated;
revoke all on table public.import_studio_rows from public, anon, authenticated;
grant select, insert, update, delete on table public.import_studio_batches to service_role;
grant select, insert, update, delete on table public.import_studio_rows to service_role;

-- ---------------------------------------------------------------------------
-- Domain registry + RBAC mapping (SPEC section 12: domain apply permissions).
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_domain_permission(p_domain text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_domain
    when 'teachers' then 'teachers.write'
    when 'subjects' then 'subjects.write'
    when 'students' then 'students.write'
    when 'groups' then 'groups.write'
    when 'curriculum' then 'subjects.write'
    when 'terms' then 'terms.manage'
    when 'offerings' then 'subjects.write'
    when 'teacher_links' then 'teachers.write'
    when 'enrollments' then 'students.write'
    else null
  end;
$$;

revoke all on function private.import_studio_domain_permission(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_domain_permission(text) to service_role;

-- ---------------------------------------------------------------------------
-- HONEST DOMAIN MATRIX. The hub must not advertise capability it does not have.
--
--   apply           — dry run + diff + confirm apply, delegated to the existing
--                     Stage 13 domain import RPC.
--   validate_only   — dry run + diff only; apply is refused. No reviewed,
--                     reversible apply path exists yet.
--   not_implemented — declared so the vocabulary is stable and so a client
--                     asking for it gets a clear error, but there is NO
--                     validator and NO apply. Everything raises.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_domain_state(p_domain text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_domain
    when 'teachers' then 'apply'
    when 'subjects' then 'apply'
    when 'students' then 'apply'
    when 'groups' then 'validate_only'
    when 'curriculum' then 'validate_only'
    when 'terms' then 'validate_only'
    when 'offerings' then 'not_implemented'
    when 'teacher_links' then 'not_implemented'
    when 'enrollments' then 'not_implemented'
    else null
  end;
$$;

revoke all on function private.import_studio_domain_state(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_domain_state(text) to service_role;

create or replace function private.import_studio_supports_apply(p_domain text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select private.import_studio_domain_state(p_domain) = 'apply';
$$;

revoke all on function private.import_studio_supports_apply(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_supports_apply(text) to service_role;

create or replace function private.import_studio_assert_domain(p_domain text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_domain is null or private.import_studio_domain_state(p_domain) is null then
    raise exception 'unknown_domain' using errcode = '22023';
  end if;
  return p_domain;
end;
$$;

revoke all on function private.import_studio_assert_domain(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_assert_domain(text) to service_role;

-- A declared-but-unbuilt domain fails loudly instead of pretending to work.
create or replace function private.import_studio_assert_implemented(p_domain text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  perform private.import_studio_assert_domain(p_domain);
  if private.import_studio_domain_state(p_domain) = 'not_implemented' then
    raise exception 'not_implemented_domain_%', p_domain using errcode = '0A000';
  end if;
  return p_domain;
end;
$$;

revoke all on function private.import_studio_assert_implemented(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_assert_implemented(text) to service_role;

-- Dry-run / diff read gate.
--
-- Staged rows carry raw personal data (logins, names, e-mails), so reading them
-- requires the DOMAIN's own permission. `academic.read` is deliberately NOT
-- accepted here: it is a broad read role and must never become a generic
-- cross-domain PII pass. It only opens the hub catalogue, which contains no
-- payloads.
create or replace function private.import_studio_require_read(p_domain text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.import_studio_assert_implemented(p_domain);
  return private.require_admin_permission(
    private.import_studio_domain_permission(p_domain)
  );
end;
$$;

revoke all on function private.import_studio_require_read(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_require_read(text) to service_role;

-- Apply gate: the domain write permission only. academic.read is NOT enough.
create or replace function private.import_studio_require_apply(p_domain text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.import_studio_assert_implemented(p_domain);
  return private.require_admin_permission(
    private.import_studio_domain_permission(p_domain)
  );
end;
$$;

revoke all on function private.import_studio_require_apply(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_require_apply(text) to service_role;

-- Ownership gate. Permissions say "may operate on this domain"; ownership says
-- "may operate on THIS batch". Both are required for every mutation and for
-- reading a batch's staged payload.
create or replace function private.import_studio_assert_owner(
  p_batch public.import_studio_batches,
  p_uid uuid
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_uid is null or p_batch.created_by is distinct from p_uid then
    raise exception 'batch_not_owned_by_caller' using errcode = '42501';
  end if;
end;
$$;

revoke all on function private.import_studio_assert_owner(
  public.import_studio_batches, uuid
) from public, anon, authenticated;
grant execute on function private.import_studio_assert_owner(
  public.import_studio_batches, uuid
) to service_role;

-- ---------------------------------------------------------------------------
-- Normalization helpers (reuse the live conventions).
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_norm(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(lower(regexp_replace(btrim(coalesce(p_value, '')), '\s+', ' ', 'g')), '');
$$;

revoke all on function private.import_studio_norm(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_norm(text) to service_role;

-- ---------------------------------------------------------------------------
-- Term-safety guards. Imports must never flip the current term and must never
-- create an Autumn 2026 term without the owner.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_term_fingerprint()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'current_term_id', (
      select t.id::text from public.academic_terms t where t.is_current limit 1
    ),
    'term_count', (select count(*)::integer from public.academic_terms),
    'autumn_2026_count', (
      select count(*)::integer
      from public.academic_terms t
      where t.starts_on >= date '2026-08-01'
        and t.starts_on <= date '2026-12-31'
    )
  );
$$;

revoke all on function private.import_studio_term_fingerprint()
  from public, anon, authenticated;
grant execute on function private.import_studio_term_fingerprint() to service_role;

create or replace function private.import_studio_assert_term_safety(p_before jsonb)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_after jsonb := private.import_studio_term_fingerprint();
begin
  if (p_before ->> 'current_term_id') is distinct from (v_after ->> 'current_term_id') then
    raise exception 'import_must_not_flip_current_term' using errcode = '55000';
  end if;
  if coalesce((v_after ->> 'autumn_2026_count')::integer, 0)
     > coalesce((p_before ->> 'autumn_2026_count')::integer, 0) then
    raise exception 'import_must_not_create_autumn_2026' using errcode = '55000';
  end if;
end;
$$;

revoke all on function private.import_studio_assert_term_safety(jsonb)
  from public, anon, authenticated;
grant execute on function private.import_studio_assert_term_safety(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Domain validators.
--
-- Each returns:
--   { classification, mapped, errors[], dedupe_key,
--     matched_teacher_id, matched_subject_id, matched_user_id, matched_group_id }
-- Unknown source keys are rejected (fail closed).
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_template(p_domain text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_domain
    when 'teachers' then array[
      'full_name', 'email', 'department', 'position', 'academic_degree', 'about_text'
    ]
    when 'subjects' then array[
      'canonical_name', 'description', 'department', 'control_form',
      'requirements', 'learning_outcomes'
    ]
    when 'students' then array['login', 'name', 'surname', 'group_name']
    when 'groups' then array['name']
    when 'curriculum' then array[
      'group_name', 'subject_name', 'semester_number', 'credits',
      'hours_total', 'control_form', 'block_name', 'subject_index'
    ]
    when 'terms' then array[
      'academic_year_name', 'name', 'term_in_year', 'starts_on', 'ends_on'
    ]
    -- offerings / teacher_links / enrollments have no template on purpose:
    -- they are declared, not implemented.
    else array[]::text[]
  end;
$$;

revoke all on function private.import_studio_template(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_template(text) to service_role;

create or replace function private.import_studio_validate_row(
  p_domain text,
  p_row jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row jsonb := coalesce(p_row, '{}'::jsonb);
  v_allowed text[] := private.import_studio_template(p_domain);
  v_errors text[] := '{}'::text[];
  v_mapped jsonb := '{}'::jsonb;
  v_key text;
  v_bad text;
  v_class text := 'new';
  v_teacher uuid;
  v_subject uuid;
  v_user uuid;
  v_group uuid;
  v_num numeric;
  v_start date;
  v_end date;
  v_term integer;
begin
  -- Defence in depth: the RPCs refuse an unbuilt domain up front, but a future
  -- caller must not be able to reach a silently-empty validator.
  perform private.import_studio_assert_implemented(p_domain);

  if jsonb_typeof(v_row) <> 'object' then
    return jsonb_build_object(
      'classification', 'error',
      'mapped', '{}'::jsonb,
      'errors', to_jsonb(array['row_not_object']),
      'dedupe_key', null
    );
  end if;

  select string_agg(t.key, ',' order by t.key)
  into v_bad
  from jsonb_object_keys(v_row) as t(key)
  where not (t.key = any (v_allowed));
  if v_bad is not null then
    v_errors := array_append(v_errors, 'unknown_columns:' || v_bad);
  end if;

  if p_domain = 'teachers' then
    v_key := private.import_studio_norm(v_row ->> 'full_name');
    if v_key is null then
      v_errors := array_append(v_errors, 'full_name_required');
    else
      v_key := private.normalize_person_name(v_row ->> 'full_name');
      select t.id into v_teacher
      from public.teachers t
      where t.normalized_name = v_key
      limit 1;
      if v_teacher is not null then
        v_class := 'update';
      end if;
    end if;
    if nullif(btrim(coalesce(v_row ->> 'email', '')), '') is not null
       and (v_row ->> 'email') !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' then
      v_errors := array_append(v_errors, 'invalid_email');
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'full_name', nullif(btrim(coalesce(v_row ->> 'full_name', '')), ''),
      'email', nullif(btrim(coalesce(v_row ->> 'email', '')), ''),
      'department', nullif(btrim(coalesce(v_row ->> 'department', '')), ''),
      'position', nullif(btrim(coalesce(v_row ->> 'position', '')), ''),
      'academic_degree', nullif(btrim(coalesce(v_row ->> 'academic_degree', '')), ''),
      'about_text', nullif(btrim(coalesce(v_row ->> 'about_text', '')), '')
    ));

  elsif p_domain = 'subjects' then
    v_key := private.import_studio_norm(v_row ->> 'canonical_name');
    if v_key is null then
      v_errors := array_append(v_errors, 'canonical_name_required');
    else
      select sc.id into v_subject
      from public.subject_catalog sc
      where private.import_studio_norm(sc.normalized_name) = v_key
         or private.import_studio_norm(sc.canonical_name) = v_key
      limit 1;
      if v_subject is not null then
        v_class := 'update';
      end if;
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'canonical_name', nullif(btrim(coalesce(v_row ->> 'canonical_name', '')), ''),
      'description', nullif(btrim(coalesce(v_row ->> 'description', '')), ''),
      'department', nullif(btrim(coalesce(v_row ->> 'department', '')), ''),
      'control_form', nullif(btrim(coalesce(v_row ->> 'control_form', '')), ''),
      'requirements', nullif(btrim(coalesce(v_row ->> 'requirements', '')), ''),
      'learning_outcomes', nullif(btrim(coalesce(v_row ->> 'learning_outcomes', '')), '')
    ));

  elsif p_domain = 'students' then
    v_key := lower(btrim(coalesce(v_row ->> 'login', '')));
    if v_key = '' then
      v_key := null;
      v_errors := array_append(v_errors, 'login_required');
    else
      select u.id into v_user
      from public.users u
      where lower(u.login) = v_key
      limit 1;
      if v_user is null then
        v_errors := array_append(v_errors, 'user_not_found');
      else
        v_class := 'update';
      end if;
    end if;
    if nullif(btrim(coalesce(v_row ->> 'group_name', '')), '') is not null then
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
      limit 1;
      if v_group is null then
        v_errors := array_append(v_errors, 'group_not_found');
      end if;
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'login', v_key,
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), ''),
      'surname', nullif(btrim(coalesce(v_row ->> 'surname', '')), ''),
      'group_name', nullif(btrim(coalesce(v_row ->> 'group_name', '')), '')
    ));

  elsif p_domain = 'groups' then
    v_key := private.import_studio_norm(v_row ->> 'name');
    if v_key is null then
      v_errors := array_append(v_errors, 'name_required');
    else
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = v_key
      limit 1;
      if v_group is not null then
        v_class := 'update';
      end if;
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), '')
    ));

  elsif p_domain = 'curriculum' then
    -- Curriculum chain is resolved to IDs; never to free-text names on apply.
    v_key := private.import_studio_norm(
      coalesce(v_row ->> 'group_name', '') || '|' ||
      coalesce(v_row ->> 'subject_name', '') || '|' ||
      coalesce(v_row ->> 'semester_number', '')
    );
    if private.import_studio_norm(v_row ->> 'group_name') is null then
      v_errors := array_append(v_errors, 'group_name_required');
    else
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
      limit 1;
      if v_group is null then
        v_errors := array_append(v_errors, 'group_not_found');
      end if;
    end if;
    if private.import_studio_norm(v_row ->> 'subject_name') is null then
      v_errors := array_append(v_errors, 'subject_name_required');
    else
      select sc.id into v_subject
      from public.subject_catalog sc
      where private.import_studio_norm(sc.normalized_name)
              = private.import_studio_norm(v_row ->> 'subject_name')
         or private.import_studio_norm(sc.canonical_name)
              = private.import_studio_norm(v_row ->> 'subject_name')
      limit 1;
      if v_subject is null then
        v_errors := array_append(v_errors, 'subject_not_found');
      end if;
    end if;
    begin
      v_num := nullif(btrim(coalesce(v_row ->> 'semester_number', '')), '')::numeric;
    exception when others then
      v_num := null;
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end;
    if v_num is null then
      v_errors := array_append(v_errors, 'semester_number_required');
    elsif v_num <> trunc(v_num) or v_num < 1 or v_num > 12 then
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'group_id', v_group,
      'subject_id', v_subject,
      'semester_number', v_num,
      'credits', nullif(btrim(coalesce(v_row ->> 'credits', '')), ''),
      'hours_total', nullif(btrim(coalesce(v_row ->> 'hours_total', '')), ''),
      'control_form', nullif(btrim(coalesce(v_row ->> 'control_form', '')), ''),
      'block_name', nullif(btrim(coalesce(v_row ->> 'block_name', '')), ''),
      'subject_index', nullif(btrim(coalesce(v_row ->> 'subject_index', '')), '')
    ));

  else
    -- terms: validate-only, with the two owner-level bans enforced here as well
    -- as on the apply path.
    v_key := private.import_studio_norm(
      coalesce(v_row ->> 'academic_year_name', '') || '|' || coalesce(v_row ->> 'name', '')
    );

    if v_row ? 'is_current' then
      v_errors := array_append(v_errors, 'current_term_flip_forbidden');
    end if;

    if private.import_studio_norm(v_row ->> 'name') is null then
      v_errors := array_append(v_errors, 'name_required');
    end if;
    if private.import_studio_norm(v_row ->> 'academic_year_name') is null then
      v_errors := array_append(v_errors, 'academic_year_name_required');
    end if;

    begin
      v_term := nullif(btrim(coalesce(v_row ->> 'term_in_year', '')), '')::integer;
    exception when others then
      v_term := null;
    end;
    if v_term is null or v_term not in (1, 2) then
      v_errors := array_append(v_errors, 'invalid_term_in_year');
    end if;

    begin
      v_start := nullif(btrim(coalesce(v_row ->> 'starts_on', '')), '')::date;
      v_end := nullif(btrim(coalesce(v_row ->> 'ends_on', '')), '')::date;
    exception when others then
      v_start := null;
      v_end := null;
      v_errors := array_append(v_errors, 'invalid_dates');
    end;
    if v_start is null or v_end is null then
      v_errors := array_append(v_errors, 'dates_required');
    elsif v_end < v_start then
      v_errors := array_append(v_errors, 'ends_before_starts');
    end if;

    -- Autumn 2026 must not be created in this session (owner decision).
    if (v_start is not null
        and v_start between date '2026-08-01' and date '2026-12-31')
       or (
         coalesce(v_row ->> 'name', '') ilike '%2026%'
         and (
           coalesce(v_row ->> 'name', '') ilike '%осен%'
           or coalesce(v_row ->> 'name', '') ilike '%autumn%'
           or coalesce(v_row ->> 'name', '') ilike '%fall%'
         )
       ) then
      v_errors := array_append(v_errors, 'autumn_2026_forbidden');
    end if;

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'academic_year_name', nullif(btrim(coalesce(v_row ->> 'academic_year_name', '')), ''),
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), ''),
      'term_in_year', v_term,
      'starts_on', v_start,
      'ends_on', v_end
    ));
  end if;

  if coalesce(array_length(v_errors, 1), 0) > 0 then
    v_class := 'error';
  end if;

  return jsonb_build_object(
    'classification', v_class,
    'mapped', v_mapped,
    'errors', to_jsonb(v_errors),
    'dedupe_key', v_key,
    'matched_teacher_id', v_teacher,
    'matched_subject_id', v_subject,
    'matched_user_id', v_user,
    'matched_group_id', v_group
  );
end;
$$;

revoke all on function private.import_studio_validate_row(text, jsonb)
  from public, anon, authenticated;
grant execute on function private.import_studio_validate_row(text, jsonb) to service_role;

create or replace function private.import_studio_batch_json(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_batch public.import_studio_batches;
begin
  select * into v_batch from public.import_studio_batches where id = p_batch_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'batch_id', v_batch.id,
    'domain', v_batch.domain,
    'status', v_batch.status,
    'batch_key', v_batch.batch_key,
    'file_name', v_batch.file_name,
    'row_count', v_batch.row_count,
    'error_count', v_batch.error_count,
    'summary', v_batch.summary,
    'delegated_result', v_batch.delegated_result,
    'domain_state', private.import_studio_domain_state(v_batch.domain),
    'supports_apply', private.import_studio_supports_apply(v_batch.domain),
    'apply_permission', private.import_studio_domain_permission(v_batch.domain),
    'rollback_safe', v_batch.rollback_safe,
    'created_at', v_batch.created_at,
    'applied_at', v_batch.applied_at
  );
end;
$$;

revoke all on function private.import_studio_batch_json(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_batch_json(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- RPC: domain catalogue for the Admin hub.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_list_domains()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  -- The catalogue contains capability metadata only — no staged payloads and no
  -- personal data — so a broad read role is enough to SEE it. Reading a batch's
  -- rows still requires the domain permission (import_studio_require_read).
  v_uid := private.require_any_admin_permission(array[
    'academic.read', 'teachers.write', 'subjects.write', 'students.write',
    'groups.write', 'terms.manage'
  ]);

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'domain', d.domain,
          'domain_state', private.import_studio_domain_state(d.domain),
          'apply_permission', private.import_studio_domain_permission(d.domain),
          'supports_apply', private.import_studio_supports_apply(d.domain),
          'template_columns', to_jsonb(private.import_studio_template(d.domain)),
          'can_dry_run',
            private.import_studio_domain_state(d.domain) <> 'not_implemented'
            and private.has_admin_permission(
              v_uid, private.import_studio_domain_permission(d.domain), 'global', null
            ),
          'can_apply', private.import_studio_supports_apply(d.domain)
            and private.has_admin_permission(
              v_uid, private.import_studio_domain_permission(d.domain), 'global', null
            ),
          'notes', case
            when private.import_studio_domain_state(d.domain) = 'not_implemented' then
              'NOT IMPLEMENTED in the Stage 19 foundation. Declared for a stable vocabulary only; every call raises not_implemented_domain_*.'
            when d.domain = 'terms' then
              'Validate-only. Imports never flip the current term and never create Autumn 2026.'
            when d.domain in ('curriculum', 'groups') then
              'Validate-only in Stage 19: no reviewed reversible apply path yet.'
            else 'Apply delegates to the existing domain import RPC.'
          end
        )
        order by d.domain
      )
      from (
        values ('teachers'), ('subjects'), ('students'),
               ('groups'), ('curriculum'), ('terms'),
               ('offerings'), ('teacher_links'), ('enrollments')
      ) as d(domain)
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: dry run. Stores mapped rows + validation. Idempotent per batch_key.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_start_dry_run(
  p_domain text,
  p_rows jsonb,
  p_file_name text default '',
  p_batch_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_domain text := private.import_studio_assert_domain(
    nullif(btrim(coalesce(p_domain, '')), '')
  );
  v_rows jsonb := coalesce(p_rows, '[]'::jsonb);
  v_hash text;
  v_key text;
  v_batch public.import_studio_batches;
  v_row jsonb;
  v_result jsonb;
  v_n integer := 0;
  v_errors integer := 0;
  v_new integer := 0;
  v_update integer := 0;
  v_duplicate integer := 0;
  v_seen text[] := '{}'::text[];
  v_dedupe text;
  v_class text;
begin
  v_uid := private.import_studio_require_read(v_domain);

  if jsonb_typeof(v_rows) <> 'array' then
    raise exception 'invalid_rows' using errcode = '22023';
  end if;
  if jsonb_array_length(v_rows) = 0 then
    raise exception 'empty_rows' using errcode = '22023';
  end if;
  if jsonb_array_length(v_rows) > 5000 then
    raise exception 'too_many_rows' using errcode = '22023';
  end if;

  v_hash := md5(v_domain || ':' || v_rows::text);
  v_key := coalesce(nullif(btrim(coalesce(p_batch_key, '')), ''), v_hash);
  if char_length(v_key) > 120 then
    raise exception 'invalid_batch_key' using errcode = '22023';
  end if;

  -- Scoped to the caller: another operator's batch with the same key is
  -- invisible here and cannot be refreshed or replayed.
  select * into v_batch
  from public.import_studio_batches b
  where b.created_by = v_uid
    and b.domain = v_domain
    and b.batch_key = v_key
  for update;

  if found then
    -- An applied batch is immutable: replay its stored result.
    if v_batch.status = 'applied' then
      return private.import_studio_batch_json(v_batch.id)
        || jsonb_build_object('already_applied', true);
    end if;
    delete from public.import_studio_rows where batch_id = v_batch.id;
    update public.import_studio_batches b set
      status = 'dry_run',
      file_name = left(coalesce(p_file_name, ''), 260),
      payload_hash = v_hash,
      created_by = v_uid,
      created_at = now(),
      applied_by = null,
      applied_at = null,
      delegated_result = '{}'::jsonb
    where b.id = v_batch.id
    returning * into v_batch;
  else
    insert into public.import_studio_batches (
      domain, status, batch_key, file_name, payload_hash, created_by
    ) values (
      v_domain, 'dry_run', v_key, left(coalesce(p_file_name, ''), 260), v_hash, v_uid
    )
    returning * into v_batch;
  end if;

  for v_row in select value from jsonb_array_elements(v_rows) loop
    v_n := v_n + 1;
    v_result := private.import_studio_validate_row(v_domain, v_row);
    v_class := v_result ->> 'classification';
    v_dedupe := v_result ->> 'dedupe_key';

    if v_dedupe is not null and v_dedupe = any (v_seen) then
      v_class := 'duplicate';
    elsif v_dedupe is not null then
      v_seen := array_append(v_seen, v_dedupe);
    end if;

    insert into public.import_studio_rows (
      batch_id, row_number, classification, source_payload, mapped_payload,
      validation, error_text, dedupe_key, matched_teacher_id, matched_subject_id,
      matched_user_id, matched_group_id
    ) values (
      v_batch.id,
      v_n,
      v_class,
      v_row,
      coalesce(v_result -> 'mapped', '{}'::jsonb),
      jsonb_build_object('errors', coalesce(v_result -> 'errors', '[]'::jsonb)),
      left(
        nullif(
          (
            select string_agg(e.value #>> '{}', ',')
            from jsonb_array_elements(coalesce(v_result -> 'errors', '[]'::jsonb)) as e(value)
          ),
          ''
        ),
        500
      ),
      v_dedupe,
      nullif(v_result ->> 'matched_teacher_id', '')::uuid,
      nullif(v_result ->> 'matched_subject_id', '')::uuid,
      nullif(v_result ->> 'matched_user_id', '')::uuid,
      nullif(v_result ->> 'matched_group_id', '')::uuid
    );

    if v_class = 'error' then
      v_errors := v_errors + 1;
    elsif v_class = 'duplicate' then
      v_duplicate := v_duplicate + 1;
    elsif v_class = 'update' then
      v_update := v_update + 1;
    else
      v_new := v_new + 1;
    end if;
  end loop;

  update public.import_studio_batches b set
    row_count = v_n,
    error_count = v_errors,
    summary = jsonb_build_object(
      'total', v_n,
      'new', v_new,
      'update', v_update,
      'duplicate', v_duplicate,
      'error', v_errors,
      'payload_hash', v_hash
    )
  where b.id = v_batch.id
  returning * into v_batch;

  perform private.admin_write_audit(
    'import_studio.dry_run',
    'import_studio_batch',
    v_batch.id::text,
    jsonb_build_object('domain', v_domain, 'summary', v_batch.summary)
  );

  return private.import_studio_batch_json(v_batch.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: diff for a batch.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_get_diff(
  p_batch_id uuid,
  p_classification text default null,
  p_limit integer default 200,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_batch public.import_studio_batches;
  v_class text := nullif(btrim(coalesce(p_classification, '')), '');
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 1000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  select * into v_batch from public.import_studio_batches where id = p_batch_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_uid := private.import_studio_require_read(v_batch.domain);
  -- The diff returns raw staged payloads, so batch ownership is required on top
  -- of the domain permission.
  perform private.import_studio_assert_owner(v_batch, v_uid);

  if v_class is not null
     and v_class not in ('new', 'update', 'duplicate', 'error', 'skip') then
    raise exception 'invalid_classification' using errcode = '22023';
  end if;

  return private.import_studio_batch_json(p_batch_id) || jsonb_build_object(
    'rows', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'row_number', r.row_number,
            'classification', r.classification,
            'source_payload', r.source_payload,
            'mapped_payload', r.mapped_payload,
            'validation', r.validation,
            'error_text', r.error_text,
            'matched_teacher_id', r.matched_teacher_id,
            'matched_subject_id', r.matched_subject_id,
            'matched_user_id', r.matched_user_id,
            'matched_group_id', r.matched_group_id
          )
          order by r.row_number
        )
        from (
          select *
          from public.import_studio_rows r0
          where r0.batch_id = p_batch_id
            and (v_class is null or r0.classification = v_class)
          order by r0.row_number
          limit v_limit
          offset v_offset
        ) r
      ),
      '[]'::jsonb
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: confirm apply.
--
-- Requires the domain write permission, an explicit batch_key confirmation and
-- a clean dry run. Delegates to the existing Stage 13 domain import RPC and
-- re-asserts the term-safety invariants afterwards.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_apply(
  p_batch_id uuid,
  p_confirm_batch_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_batch public.import_studio_batches;
  v_before jsonb;
  v_rows jsonb;
  v_fn text;
  v_signature text;
  v_result jsonb;
begin
  select * into v_batch
  from public.import_studio_batches
  where id = p_batch_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_uid := private.import_studio_require_apply(v_batch.domain);
  perform private.import_studio_assert_owner(v_batch, v_uid);

  if nullif(btrim(coalesce(p_confirm_batch_key, '')), '') is distinct from v_batch.batch_key then
    raise exception 'batch_key_confirmation_mismatch' using errcode = '22023';
  end if;

  -- Idempotent re-run: never apply the same batch twice.
  if v_batch.status = 'applied' then
    return private.import_studio_batch_json(p_batch_id)
      || jsonb_build_object('already_applied', true, 'idempotent_replay', true);
  end if;
  if v_batch.status <> 'dry_run' then
    raise exception 'batch_not_appliable' using errcode = '55000';
  end if;
  if not private.import_studio_supports_apply(v_batch.domain) then
    raise exception 'apply_not_supported_for_domain_%', v_batch.domain
      using errcode = '0A000';
  end if;
  if v_batch.error_count > 0 then
    raise exception 'batch_has_errors' using errcode = 'P0001';
  end if;
  if v_batch.row_count = 0 then
    raise exception 'empty_batch' using errcode = '22023';
  end if;

  v_before := private.import_studio_term_fingerprint();

  select coalesce(jsonb_agg(r.mapped_payload order by r.row_number), '[]'::jsonb)
  into v_rows
  from public.import_studio_rows r
  where r.batch_id = p_batch_id
    and r.classification in ('new', 'update');

  if jsonb_array_length(v_rows) = 0 then
    raise exception 'nothing_to_apply' using errcode = '22023';
  end if;

  v_fn := case v_batch.domain
    when 'teachers' then 'public.admin_teacher_import_apply'
    when 'subjects' then 'public.admin_subject_import_apply'
    else 'public.admin_student_import_apply'
  end;
  v_signature := v_fn || '(jsonb)';

  if to_regprocedure(v_signature) is null then
    raise exception 'domain_apply_rpc_missing_%', v_fn using errcode = '55000';
  end if;

  execute format('select %s($1)', v_fn) into v_result using v_rows;

  -- Neither the current term nor Autumn 2026 may change because of an import.
  perform private.import_studio_assert_term_safety(v_before);

  update public.import_studio_batches b set
    status = 'applied',
    applied_by = v_uid,
    applied_at = now(),
    delegated_result = coalesce(v_result, '{}'::jsonb)
  where b.id = p_batch_id
  returning * into v_batch;

  perform private.admin_write_audit(
    'import_studio.apply',
    'import_studio_batch',
    p_batch_id::text,
    jsonb_build_object(
      'domain', v_batch.domain,
      'row_count', v_batch.row_count,
      'delegated_to', v_fn
    )
  );

  return private.import_studio_batch_json(p_batch_id)
    || jsonb_build_object('already_applied', false);
end;
$$;

create or replace function public.admin_import_studio_list_batches(
  p_domain text default null,
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_domain text := nullif(btrim(coalesce(p_domain, '')), '');
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 200));
begin
  if v_domain is not null then
    v_domain := private.import_studio_assert_domain(v_domain);
    v_uid := private.import_studio_require_read(v_domain);
  else
    -- academic.read is intentionally absent: an import operator needs a write
    -- permission somewhere, and the result is scoped to their own batches.
    v_uid := private.require_any_admin_permission(array[
      'teachers.write', 'subjects.write', 'students.write',
      'groups.write', 'terms.manage'
    ]);
  end if;

  return coalesce(
    (
      select jsonb_agg(private.import_studio_batch_json(b.id) order by b.created_at desc)
      from (
        select id, created_at
        from public.import_studio_batches b0
        where b0.created_by = v_uid
          and (v_domain is null or b0.domain = v_domain)
        order by b0.created_at desc
        limit v_limit
      ) b
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_import_studio_cancel_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_batch public.import_studio_batches;
begin
  select * into v_batch
  from public.import_studio_batches
  where id = p_batch_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_uid := private.import_studio_require_apply(v_batch.domain);
  perform private.import_studio_assert_owner(v_batch, v_uid);

  if v_batch.status <> 'dry_run' then
    raise exception 'batch_not_cancellable' using errcode = '55000';
  end if;

  update public.import_studio_batches b set status = 'cancelled' where b.id = p_batch_id;

  perform private.admin_write_audit(
    'import_studio.cancel',
    'import_studio_batch',
    p_batch_id::text,
    jsonb_build_object('domain', v_batch.domain)
  );

  return private.import_studio_batch_json(p_batch_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: rollback — DELIBERATE STUB.
--
-- The contract exists so the Admin hub can wire the button and so the refusal
-- is explicit and audited rather than a missing feature. It rolls back ONLY a
-- batch flagged rollback_safe, and nothing in this foundation sets that flag:
--
--   * `students` provisions auth users, which is irreversible here;
--   * `teachers` / `subjects` upserts merge into rows that may have been edited
--     by hand afterwards, so a blind undo would destroy unrelated work.
--
-- Every call therefore raises a clear feature_not_supported error today. A real
-- undo needs a per-domain reverse plan captured at apply time, and owner sign-off.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_rollback_batch(
  p_batch_id uuid,
  p_confirm_batch_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_batch public.import_studio_batches;
begin
  select * into v_batch
  from public.import_studio_batches
  where id = p_batch_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_uid := private.import_studio_require_apply(v_batch.domain);
  perform private.import_studio_assert_owner(v_batch, v_uid);

  if nullif(btrim(coalesce(p_confirm_batch_key, '')), '') is distinct from v_batch.batch_key then
    raise exception 'batch_key_confirmation_mismatch' using errcode = '22023';
  end if;

  if v_batch.status <> 'applied' then
    raise exception 'batch_not_applied' using errcode = '55000';
  end if;

  -- Structured refusal (do not raise after audit — exception would roll back
  -- the audit insert). Clients treat ok=false as soft failure.
  perform private.admin_write_audit(
    'import_studio.rollback_refused',
    'import_studio_batch',
    p_batch_id::text,
    jsonb_build_object(
      'domain', v_batch.domain,
      'rollback_safe', v_batch.rollback_safe,
      'reason', case
        when not v_batch.rollback_safe then 'domain_not_rollback_safe'
        else 'rollback_plan_not_implemented'
      end
    )
  );

  return jsonb_build_object(
    'ok', false,
    'refused', true,
    'batch_id', p_batch_id,
    'domain', v_batch.domain,
    'rollback_safe', v_batch.rollback_safe,
    'error_code', case
      when not v_batch.rollback_safe then 'rollback_not_supported_for_batch'
      else 'rollback_plan_not_implemented'
    end,
    'message', format(
      'Откат batch для домена %s пока не поддерживается. Журнал отказа записан.',
      v_batch.domain
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants. No service_role key ever reaches Flutter Web / Admin Web: the Admin
-- console calls these RPCs as `authenticated` and RBAC is enforced in-body.
-- ---------------------------------------------------------------------------
revoke all on function public.admin_import_studio_list_domains() from public, anon;
grant execute on function public.admin_import_studio_list_domains()
  to authenticated, service_role;

revoke all on function public.admin_import_studio_start_dry_run(text, jsonb, text, text)
  from public, anon;
grant execute on function public.admin_import_studio_start_dry_run(text, jsonb, text, text)
  to authenticated, service_role;

revoke all on function public.admin_import_studio_get_diff(uuid, text, integer, integer)
  from public, anon;
grant execute on function public.admin_import_studio_get_diff(uuid, text, integer, integer)
  to authenticated, service_role;

revoke all on function public.admin_import_studio_apply(uuid, text) from public, anon;
grant execute on function public.admin_import_studio_apply(uuid, text)
  to authenticated, service_role;

revoke all on function public.admin_import_studio_list_batches(text, integer)
  from public, anon;
grant execute on function public.admin_import_studio_list_batches(text, integer)
  to authenticated, service_role;

revoke all on function public.admin_import_studio_cancel_batch(uuid) from public, anon;
grant execute on function public.admin_import_studio_cancel_batch(uuid)
  to authenticated, service_role;

revoke all on function public.admin_import_studio_rollback_batch(uuid, text)
  from public, anon;
grant execute on function public.admin_import_studio_rollback_batch(uuid, text)
  to authenticated, service_role;

comment on function public.admin_import_studio_apply(uuid, text) is
  'Confirm-apply an Import Studio batch. Requires the domain write permission, batch ownership, an exact batch_key confirmation and a zero-error dry run. Never flips the current term; never creates Autumn 2026.';
comment on function public.admin_import_studio_start_dry_run(text, jsonb, text, text) is
  'Map + validate rows into import_studio_rows. Idempotent per (created_by, domain, batch_key); an applied batch is never rewritten and another operator''s batch is never touched.';
comment on function public.admin_import_studio_rollback_batch(uuid, text) is
  'STUB. Rolls back only a rollback_safe applied batch; no domain in the Stage 19 foundation is rollback_safe, so every call raises feature_not_supported after writing an audit row.';
comment on function public.admin_import_studio_list_domains() is
  'Import Studio capability catalogue. domain_state is apply | validate_only | not_implemented; not_implemented domains are declared for a stable vocabulary and raise on every other call.';

commit;
