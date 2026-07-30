-- Stage 17: vacancies domain (SPEC section 5).
--
-- Dedicated domain model (NOT overloaded content_items / news_posts):
-- vacancies + versions + audience junctions + assets + reports + moderation
-- actions. Full status machine draft → submitted → in_moderation →
-- approved → published → expired | archived | rejected.
--
-- Hard rules encoded here:
--   * a user submission NEVER auto-publishes (submit_vacancy writes 'submitted');
--   * contacts are readable ONLY through get_vacancy_contacts and ONLY while the
--     vacancy is published and visible to that caller;
--   * every table is FORCE RLS with no client DML.
--
-- Depends on: 20260721202054 (RBAC), 20260722110804 (require_admin_permission,
-- current_user_active_group_ids), 20260729133000 (content-media bucket,
-- content_write_domain_audit).
--
-- Local only. Not applied to remote in this session.

begin;

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

-- Repeated verbatim from the Stage 16 migration so this file is independently
-- re-appliable. See that migration for the moderation.action/write rationale.
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
create table if not exists public.vacancies (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  company_name text not null default '',
  summary text not null default '',
  description text not null default '',
  employment_type text null check (
    employment_type in ('internship', 'part_time', 'full_time', 'project', 'volunteer')
  ),
  work_format text null check (work_format in ('onsite', 'remote', 'hybrid')),
  location text null,
  salary_text text null,
  external_url text null,
  contacts jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (
    status in (
      'draft', 'submitted', 'in_moderation', 'approved',
      'published', 'expired', 'archived', 'rejected'
    )
  ),
  origin text not null default 'admin'
    check (origin in ('demo', 'admin', 'user_submission')),
  priority integer not null default 0,
  starts_at timestamptz null,
  ends_at timestamptz null,
  expires_at timestamptz null,
  is_hidden boolean not null default false,
  audience_mode text not null default 'all'
    check (audience_mode in ('all', 'groups', 'users', 'groups_and_users')),
  version_number integer not null default 1,
  row_version integer not null default 1,
  submitted_by uuid null references public.users (id) on delete set null,
  submitted_at timestamptz null,
  created_by uuid null references public.users (id) on delete set null,
  updated_by uuid null references public.users (id) on delete set null,
  moderated_by uuid null references public.users (id) on delete set null,
  moderated_at timestamptz null,
  published_by uuid null references public.users (id) on delete set null,
  published_at timestamptz null,
  rejection_reason text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vacancies_title_len check (
    btrim(title) <> '' and char_length(title) <= 200
  ),
  constraint vacancies_text_len check (
    char_length(company_name) <= 200
    and char_length(summary) <= 600
    and char_length(description) <= 12000
    and (location is null or char_length(location) <= 200)
    and (salary_text is null or char_length(salary_text) <= 120)
    and (external_url is null or char_length(external_url) <= 500)
    and (rejection_reason is null or char_length(rejection_reason) <= 500)
  ),
  constraint vacancies_schedule_chk check (
    ends_at is null or starts_at is null or ends_at > starts_at
  ),
  constraint vacancies_expiry_chk check (
    expires_at is null or starts_at is null or expires_at > starts_at
  ),
  constraint vacancies_contacts_object_chk check (jsonb_typeof(contacts) = 'object')
);

comment on table public.vacancies is
  'Vacancies domain root. contacts is PROTECTED: never returned by list RPCs, only by get_vacancy_contacts for a published+visible vacancy.';
comment on column public.vacancies.row_version is
  'Optimistic-concurrency token. Every mutating admin RPC takes p_expected_row_version.';

create index if not exists vacancies_status_idx
  on public.vacancies (status, priority desc, published_at desc nulls last);
create index if not exists vacancies_origin_idx on public.vacancies (origin);
create index if not exists vacancies_expiry_idx
  on public.vacancies (expires_at)
  where status = 'published';
create index if not exists vacancies_submitted_by_idx
  on public.vacancies (submitted_by)
  where submitted_by is not null;

create table if not exists public.vacancy_versions (
  id uuid primary key default gen_random_uuid(),
  vacancy_id uuid not null references public.vacancies (id) on delete cascade,
  version_number integer not null,
  snapshot jsonb not null,
  created_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint vacancy_versions_unique unique (vacancy_id, version_number)
);

create index if not exists vacancy_versions_vacancy_idx
  on public.vacancy_versions (vacancy_id, version_number desc);

create table if not exists public.vacancy_audience_groups (
  vacancy_id uuid not null references public.vacancies (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  primary key (vacancy_id, group_id)
);

create index if not exists vacancy_audience_groups_group_idx
  on public.vacancy_audience_groups (group_id);

create table if not exists public.vacancy_audience_users (
  vacancy_id uuid not null references public.vacancies (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  primary key (vacancy_id, user_id)
);

create index if not exists vacancy_audience_users_user_idx
  on public.vacancy_audience_users (user_id);

create table if not exists public.vacancy_assets (
  id uuid primary key default gen_random_uuid(),
  vacancy_id uuid not null references public.vacancies (id) on delete cascade,
  title text not null default '',
  storage_bucket text not null default 'content-media',
  storage_path text not null,
  mime_type text not null,
  byte_size bigint not null check (byte_size >= 0),
  checksum text null,
  created_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint vacancy_assets_object_unique unique (storage_bucket, storage_path),
  constraint vacancy_assets_title_len check (char_length(title) <= 200)
);

comment on table public.vacancy_assets is
  'Vacancy media. Owner is a real FK to vacancies (no polymorphic owner_kind). Reuses the private content-media bucket under the vacancy/ path prefix.';

create index if not exists vacancy_assets_vacancy_idx
  on public.vacancy_assets (vacancy_id);

create table if not exists public.vacancy_media_cleanup_queue (
  id uuid primary key default gen_random_uuid(),
  storage_bucket text not null,
  storage_path text not null,
  source_vacancy_id uuid null,
  source_title text null,
  enqueued_at timestamptz not null default now(),
  attempts integer not null default 0,
  last_error text null,
  processed_at timestamptz null
);

comment on table public.vacancy_media_cleanup_queue is
  'Pending vacancy media cleanup. Never store signed URLs or secrets. Mirrors news_media_cleanup_queue / content_media_cleanup_queue.';

create unique index if not exists vacancy_media_cleanup_queue_pending_uidx
  on public.vacancy_media_cleanup_queue (storage_bucket, storage_path)
  where processed_at is null;

create table if not exists public.vacancy_reports (
  id uuid primary key default gen_random_uuid(),
  vacancy_id uuid not null references public.vacancies (id) on delete cascade,
  reporter_user_id uuid not null references public.users (id) on delete cascade,
  reason_code text not null check (
    reason_code in ('spam', 'scam', 'abuse', 'outdated', 'privacy', 'other')
  ),
  note text null,
  status text not null default 'open'
    check (status in ('open', 'resolved', 'rejected')),
  resolved_by uuid null references public.users (id) on delete set null,
  resolved_at timestamptz null,
  created_at timestamptz not null default now(),
  constraint vacancy_reports_unique unique (vacancy_id, reporter_user_id),
  constraint vacancy_reports_note_len check (note is null or char_length(note) <= 500)
);

create index if not exists vacancy_reports_status_idx
  on public.vacancy_reports (status, created_at desc);

create table if not exists public.vacancy_moderation_actions (
  id uuid primary key default gen_random_uuid(),
  vacancy_id uuid not null references public.vacancies (id) on delete cascade,
  actor_user_id uuid null references public.users (id) on delete set null,
  -- `create_draft` and `submit` are authoring events, NOT moderation decisions:
  -- a draft must never be recorded as `take_in_moderation`, otherwise the trail
  -- claims a moderator looked at something nobody submitted yet.
  action text not null check (
    action in (
      'create_draft', 'submit', 'take_in_moderation', 'approve', 'reject',
      'publish', 'unpublish', 'expire', 'auto_expire', 'archive',
      'resolve_report', 'reject_report'
    )
  ),
  from_status text null,
  to_status text null,
  reason_text text not null default '',
  created_at timestamptz not null default now(),
  constraint vacancy_moderation_actions_reason_len check (
    char_length(reason_text) <= 500
  )
);

create index if not exists vacancy_moderation_actions_vacancy_idx
  on public.vacancy_moderation_actions (vacancy_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Lock down: RLS + FORCE RLS, no client DML, service_role only.
-- ---------------------------------------------------------------------------
alter table public.vacancies enable row level security;
alter table public.vacancies force row level security;
alter table public.vacancy_versions enable row level security;
alter table public.vacancy_versions force row level security;
alter table public.vacancy_audience_groups enable row level security;
alter table public.vacancy_audience_groups force row level security;
alter table public.vacancy_audience_users enable row level security;
alter table public.vacancy_audience_users force row level security;
alter table public.vacancy_assets enable row level security;
alter table public.vacancy_assets force row level security;
alter table public.vacancy_media_cleanup_queue enable row level security;
alter table public.vacancy_media_cleanup_queue force row level security;
alter table public.vacancy_reports enable row level security;
alter table public.vacancy_reports force row level security;
alter table public.vacancy_moderation_actions enable row level security;
alter table public.vacancy_moderation_actions force row level security;

revoke all on table public.vacancies from public, anon, authenticated;
revoke all on table public.vacancy_versions from public, anon, authenticated;
revoke all on table public.vacancy_audience_groups from public, anon, authenticated;
revoke all on table public.vacancy_audience_users from public, anon, authenticated;
revoke all on table public.vacancy_assets from public, anon, authenticated;
revoke all on table public.vacancy_media_cleanup_queue from public, anon, authenticated;
revoke all on table public.vacancy_reports from public, anon, authenticated;
revoke all on table public.vacancy_moderation_actions from public, anon, authenticated;

grant select, insert, update, delete on table public.vacancies to service_role;
grant select, insert, update, delete on table public.vacancy_versions to service_role;
grant select, insert, update, delete on table public.vacancy_audience_groups to service_role;
grant select, insert, update, delete on table public.vacancy_audience_users to service_role;
grant select, insert, update, delete on table public.vacancy_assets to service_role;
grant select, insert, update, delete on table public.vacancy_media_cleanup_queue to service_role;
grant select, insert, update, delete on table public.vacancy_reports to service_role;
grant select, insert, update, delete on table public.vacancy_moderation_actions to service_role;

-- ---------------------------------------------------------------------------
-- Status machine (SPEC 5). `archived` is terminal.
-- ---------------------------------------------------------------------------
create or replace function private.vacancy_assert_transition(
  p_from text,
  p_to text
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_from is null or p_to is null then
    raise exception 'invalid_status_transition' using errcode = '22023';
  end if;
  if p_from = p_to then
    return;
  end if;

  if not (
    (p_from = 'draft' and p_to in ('submitted', 'in_moderation', 'archived'))
    or (p_from = 'submitted' and p_to in ('in_moderation', 'rejected', 'archived'))
    or (p_from = 'in_moderation' and p_to in ('approved', 'rejected', 'archived'))
    or (p_from = 'approved' and p_to in ('published', 'rejected', 'draft', 'archived'))
    or (p_from = 'published' and p_to in ('expired', 'approved', 'archived'))
    or (p_from = 'expired' and p_to in ('published', 'archived'))
    or (p_from = 'rejected' and p_to in ('draft', 'archived'))
  ) then
    raise exception 'invalid_status_transition_%_to_%', p_from, p_to
      using errcode = '55000';
  end if;
end;
$$;

revoke all on function private.vacancy_assert_transition(text, text)
  from public, anon, authenticated;
grant execute on function private.vacancy_assert_transition(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Validation (fail-closed). No HTML/JS anywhere; contacts keys allowlisted.
-- ---------------------------------------------------------------------------
create or replace function private.vacancy_assert_contacts(p_contacts jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value jsonb := coalesce(p_contacts, '{}'::jsonb);
  v_allowed text[] := array['person', 'email', 'phone', 'telegram', 'url', 'note'];
  v_bad text;
  v_text text;
begin
  if jsonb_typeof(v_value) <> 'object' then
    raise exception 'invalid_type_contacts' using errcode = '22023';
  end if;

  select string_agg(t.key, ',' order by t.key)
  into v_bad
  from jsonb_object_keys(v_value) as t(key)
  where not (t.key = any (v_allowed));
  if v_bad is not null then
    raise exception 'unknown_contact_keys: %', v_bad using errcode = '22023';
  end if;

  if exists (
    select 1 from jsonb_each(v_value) kv where jsonb_typeof(kv.value) <> 'string'
  ) then
    raise exception 'invalid_contact_value_type' using errcode = '22023';
  end if;

  v_text := nullif(btrim(coalesce(v_value ->> 'person', '')), '');
  if v_text is not null and char_length(v_text) > 120 then
    raise exception 'invalid_contact_person' using errcode = '22023';
  end if;

  v_text := nullif(btrim(coalesce(v_value ->> 'email', '')), '');
  if v_text is not null
     and (char_length(v_text) > 200
          or v_text !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') then
    raise exception 'invalid_contact_email' using errcode = '22023';
  end if;

  v_text := nullif(btrim(coalesce(v_value ->> 'phone', '')), '');
  if v_text is not null
     and (char_length(v_text) > 32 or v_text !~ '^\+?[0-9 ()-]{5,32}$') then
    raise exception 'invalid_contact_phone' using errcode = '22023';
  end if;

  v_text := nullif(btrim(coalesce(v_value ->> 'telegram', '')), '');
  if v_text is not null and v_text !~ '^@[A-Za-z0-9_]{4,32}$' then
    raise exception 'invalid_contact_telegram' using errcode = '22023';
  end if;

  v_text := nullif(btrim(coalesce(v_value ->> 'url', '')), '');
  if v_text is not null
     and (char_length(v_text) > 500
          or v_text !~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9](:[0-9]{1,5})?(/[^[:space:]]*)?$') then
    raise exception 'invalid_contact_url' using errcode = '22023';
  end if;

  v_text := nullif(btrim(coalesce(v_value ->> 'note', '')), '');
  if v_text is not null and char_length(v_text) > 300 then
    raise exception 'invalid_contact_note' using errcode = '22023';
  end if;

  return v_value;
end;
$$;

revoke all on function private.vacancy_assert_contacts(jsonb)
  from public, anon, authenticated;
grant execute on function private.vacancy_assert_contacts(jsonb) to service_role;

create or replace function private.vacancy_assert_patch(
  p_patch jsonb,
  p_allowed text[]
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_bad text;
  v_text text;
begin
  if jsonb_typeof(coalesce(p_patch, '{}'::jsonb)) <> 'object' then
    raise exception 'invalid_patch' using errcode = '22023';
  end if;

  select string_agg(t.key, ',' order by t.key)
  into v_bad
  from jsonb_object_keys(coalesce(p_patch, '{}'::jsonb)) as t(key)
  where not (t.key = any (p_allowed));
  if v_bad is not null then
    raise exception 'unknown_patch_keys: %', v_bad using errcode = '22023';
  end if;

  if p_patch ? 'title' then
    v_text := nullif(btrim(coalesce(p_patch ->> 'title', '')), '');
    if v_text is null or char_length(v_text) > 200 then
      raise exception 'invalid_title' using errcode = '22023';
    end if;
  end if;
  if p_patch ? 'company_name'
     and char_length(coalesce(p_patch ->> 'company_name', '')) > 200 then
    raise exception 'invalid_company_name' using errcode = '22023';
  end if;
  if p_patch ? 'summary'
     and char_length(coalesce(p_patch ->> 'summary', '')) > 600 then
    raise exception 'invalid_summary' using errcode = '22023';
  end if;
  if p_patch ? 'description'
     and char_length(coalesce(p_patch ->> 'description', '')) > 12000 then
    raise exception 'invalid_description' using errcode = '22023';
  end if;
  if p_patch ? 'employment_type' then
    v_text := nullif(btrim(coalesce(p_patch ->> 'employment_type', '')), '');
    if v_text is not null
       and v_text not in ('internship', 'part_time', 'full_time', 'project', 'volunteer') then
      raise exception 'invalid_employment_type' using errcode = '22023';
    end if;
  end if;
  if p_patch ? 'work_format' then
    v_text := nullif(btrim(coalesce(p_patch ->> 'work_format', '')), '');
    if v_text is not null and v_text not in ('onsite', 'remote', 'hybrid') then
      raise exception 'invalid_work_format' using errcode = '22023';
    end if;
  end if;
  if p_patch ? 'location'
     and char_length(coalesce(p_patch ->> 'location', '')) > 200 then
    raise exception 'invalid_location' using errcode = '22023';
  end if;
  if p_patch ? 'salary_text'
     and char_length(coalesce(p_patch ->> 'salary_text', '')) > 120 then
    raise exception 'invalid_salary_text' using errcode = '22023';
  end if;
  if p_patch ? 'external_url' then
    v_text := nullif(btrim(coalesce(p_patch ->> 'external_url', '')), '');
    if v_text is not null
       and (char_length(v_text) > 500
            or v_text !~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9](:[0-9]{1,5})?(/[^[:space:]]*)?$') then
      raise exception 'invalid_external_url' using errcode = '22023';
    end if;
  end if;
  if p_patch ? 'contacts' then
    perform private.vacancy_assert_contacts(p_patch -> 'contacts');
  end if;
  if p_patch ? 'priority'
     and jsonb_typeof(p_patch -> 'priority') <> 'number' then
    raise exception 'invalid_priority' using errcode = '22023';
  end if;
end;
$$;

revoke all on function private.vacancy_assert_patch(jsonb, text[])
  from public, anon, authenticated;
grant execute on function private.vacancy_assert_patch(jsonb, text[]) to service_role;

-- ---------------------------------------------------------------------------
-- Concurrency helpers
-- ---------------------------------------------------------------------------
create or replace function private.vacancy_lock(
  p_id uuid,
  p_expected_row_version integer
)
returns public.vacancies
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.vacancies;
begin
  if p_id is null then
    raise exception 'invalid_id' using errcode = '22023';
  end if;
  if p_expected_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;

  select * into v_row from public.vacancies where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.row_version <> p_expected_row_version then
    raise exception 'row_version_conflict' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

revoke all on function private.vacancy_lock(uuid, integer)
  from public, anon, authenticated;
grant execute on function private.vacancy_lock(uuid, integer) to service_role;

-- ---------------------------------------------------------------------------
-- Audience resolution. One resolver shared by admin preview and student list.
-- ---------------------------------------------------------------------------
create or replace function private.vacancy_audience_matches(
  p_vacancy_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text;
begin
  if p_vacancy_id is null or p_user_id is null then
    return false;
  end if;

  select v.audience_mode into v_mode
  from public.vacancies v
  where v.id = p_vacancy_id;
  if not found then
    return false;
  end if;

  if not exists (
    select 1 from public.users u where u.id = p_user_id and u.is_active
  ) then
    return false;
  end if;

  -- Uniform eligibility: active user with an active, non-ended enrollment.
  if not exists (
    select 1
    from public.student_enrollments se
    where se.user_id = p_user_id
      and se.status = 'active'
      and se.ended_at is null
  ) then
    return false;
  end if;

  if v_mode = 'all' then
    return true;
  end if;

  if v_mode in ('groups', 'groups_and_users') then
    if exists (
      select 1
      from public.vacancy_audience_groups g
      join public.student_enrollments se
        on se.group_id = g.group_id
       and se.user_id = p_user_id
       and se.status = 'active'
       and se.ended_at is null
      where g.vacancy_id = p_vacancy_id
    ) then
      return true;
    end if;
  end if;

  if v_mode in ('users', 'groups_and_users') then
    if exists (
      select 1
      from public.vacancy_audience_users au
      where au.vacancy_id = p_vacancy_id
        and au.user_id = p_user_id
    ) then
      return true;
    end if;
  end if;

  return false;
end;
$$;

revoke all on function private.vacancy_audience_matches(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_audience_matches(uuid, uuid) to service_role;

create or replace function private.vacancy_deliverable_to_user(
  p_vacancy_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.vacancies;
  v_now timestamptz := now();
begin
  select * into v_row from public.vacancies where id = p_vacancy_id;
  if not found then
    return false;
  end if;
  if v_row.status <> 'published' or v_row.is_hidden then
    return false;
  end if;
  if v_row.starts_at is not null and v_row.starts_at > v_now then
    return false;
  end if;
  if v_row.ends_at is not null and v_row.ends_at <= v_now then
    return false;
  end if;
  if v_row.expires_at is not null and v_row.expires_at <= v_now then
    return false;
  end if;

  return private.vacancy_audience_matches(p_vacancy_id, p_user_id);
end;
$$;

revoke all on function private.vacancy_deliverable_to_user(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_deliverable_to_user(uuid, uuid) to service_role;

create or replace function private.vacancy_assert_audience_consistent(p_vacancy_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text;
  v_groups integer;
  v_users integer;
begin
  select v.audience_mode into v_mode
  from public.vacancies v
  where v.id = p_vacancy_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select count(*) into v_groups
  from public.vacancy_audience_groups g
  where g.vacancy_id = p_vacancy_id;
  select count(*) into v_users
  from public.vacancy_audience_users u
  where u.vacancy_id = p_vacancy_id;

  if v_mode = 'all' and (v_groups > 0 or v_users > 0) then
    raise exception 'audience_all_must_have_empty_junctions' using errcode = 'P0001';
  end if;
  if v_mode = 'groups' and (v_groups < 1 or v_users > 0) then
    raise exception 'audience_groups_invalid' using errcode = 'P0001';
  end if;
  if v_mode = 'users' and (v_users < 1 or v_groups > 0) then
    raise exception 'audience_users_invalid' using errcode = 'P0001';
  end if;
  if v_mode = 'groups_and_users' and (v_groups < 1 or v_users < 1) then
    raise exception 'audience_groups_and_users_invalid' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on function private.vacancy_assert_audience_consistent(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_assert_audience_consistent(uuid) to service_role;

-- Counts + safe breakdown only. Never returns a list of students.
create or replace function private.vacancy_preview_audience_count(p_vacancy_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text;
  v_count integer := 0;
  v_groups jsonb;
  v_explicit integer := 0;
begin
  select v.audience_mode into v_mode
  from public.vacancies v
  where v.id = p_vacancy_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select count(*)::integer into v_count
  from public.users u
  where u.is_active
    and exists (
      select 1
      from public.student_enrollments se
      where se.user_id = u.id
        and se.status = 'active'
        and se.ended_at is null
    )
    and (
      v_mode = 'all'
      or (
        v_mode in ('groups', 'groups_and_users')
        and exists (
          select 1
          from public.vacancy_audience_groups g
          join public.student_enrollments se
            on se.group_id = g.group_id
           and se.user_id = u.id
           and se.status = 'active'
           and se.ended_at is null
          where g.vacancy_id = p_vacancy_id
        )
      )
      or (
        v_mode in ('users', 'groups_and_users')
        and exists (
          select 1
          from public.vacancy_audience_users au
          where au.vacancy_id = p_vacancy_id
            and au.user_id = u.id
        )
      )
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object('id', gr.id, 'name', gr.name, 'member_count', gr.member_count)
      order by gr.name
    ),
    '[]'::jsonb
  )
  into v_groups
  from (
    select
      g0.id,
      g0.name,
      (
        select count(*)::integer
        from public.student_enrollments se
        join public.users u on u.id = se.user_id and u.is_active
        where se.group_id = g0.id
          and se.status = 'active'
          and se.ended_at is null
      ) as member_count
    from public.vacancy_audience_groups ag
    join public.groups g0 on g0.id = ag.group_id
    where ag.vacancy_id = p_vacancy_id
  ) gr;

  select count(distinct au.user_id)::integer into v_explicit
  from public.vacancy_audience_users au
  join public.users u on u.id = au.user_id and u.is_active
  where au.vacancy_id = p_vacancy_id;

  return jsonb_build_object(
    'vacancy_id', p_vacancy_id,
    'audience_mode', v_mode,
    'recipient_count', coalesce(v_count, 0),
    'breakdown', jsonb_build_object(
      'all', (v_mode = 'all'),
      'groups', v_groups,
      'explicit_users_count', coalesce(v_explicit, 0)
    )
  );
end;
$$;

revoke all on function private.vacancy_preview_audience_count(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_preview_audience_count(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Serialization + versioning
-- ---------------------------------------------------------------------------
create or replace function private.vacancy_to_admin_json(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.vacancies;
begin
  select * into v_row from public.vacancies where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'title', v_row.title,
    'company_name', v_row.company_name,
    'summary', v_row.summary,
    'description', v_row.description,
    'employment_type', v_row.employment_type,
    'work_format', v_row.work_format,
    'location', v_row.location,
    'salary_text', v_row.salary_text,
    'external_url', v_row.external_url,
    'contacts', v_row.contacts,
    'status', v_row.status,
    'origin', v_row.origin,
    'priority', v_row.priority,
    'starts_at', v_row.starts_at,
    'ends_at', v_row.ends_at,
    'expires_at', v_row.expires_at,
    'is_hidden', v_row.is_hidden,
    'audience_mode', v_row.audience_mode,
    'version_number', v_row.version_number,
    'row_version', v_row.row_version,
    'submitted_by', v_row.submitted_by,
    'submitted_at', v_row.submitted_at,
    'moderated_by', v_row.moderated_by,
    'moderated_at', v_row.moderated_at,
    'published_at', v_row.published_at,
    'rejection_reason', v_row.rejection_reason,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at,
    'audience_group_ids', coalesce(
      (
        select jsonb_agg(g.group_id order by g.group_id)
        from public.vacancy_audience_groups g
        where g.vacancy_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'audience_user_ids', coalesce(
      (
        select jsonb_agg(u.user_id order by u.user_id)
        from public.vacancy_audience_users u
        where u.vacancy_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'asset_ids', coalesce(
      (
        select jsonb_agg(a.id order by a.created_at, a.id)
        from public.vacancy_assets a
        where a.vacancy_id = v_row.id
      ),
      '[]'::jsonb
    ),
    'open_report_count', (
      select count(*)::integer
      from public.vacancy_reports r
      where r.vacancy_id = v_row.id and r.status = 'open'
    )
  );
end;
$$;

revoke all on function private.vacancy_to_admin_json(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_to_admin_json(uuid) to service_role;

create or replace function private.vacancy_snapshot_version(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.vacancies;
begin
  select * into v_row from public.vacancies where id = p_id;
  if not found then
    return;
  end if;

  insert into public.vacancy_versions (
    vacancy_id, version_number, snapshot, created_by
  ) values (
    v_row.id,
    v_row.version_number,
    private.vacancy_to_admin_json(p_id),
    auth.uid()
  )
  on conflict (vacancy_id, version_number) do update
    set snapshot = excluded.snapshot,
        created_by = excluded.created_by,
        created_at = now();
end;
$$;

revoke all on function private.vacancy_snapshot_version(uuid)
  from public, anon, authenticated;
grant execute on function private.vacancy_snapshot_version(uuid) to service_role;

create or replace function private.vacancy_record_action(
  p_vacancy_id uuid,
  p_action text,
  p_from_status text,
  p_to_status text,
  p_reason text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.vacancy_moderation_actions (
    vacancy_id, actor_user_id, action, from_status, to_status, reason_text
  ) values (
    p_vacancy_id,
    auth.uid(),
    p_action,
    p_from_status,
    p_to_status,
    left(coalesce(p_reason, ''), 500)
  );

  perform private.content_write_domain_audit(
    'vacancy.' || p_action,
    'vacancy',
    p_vacancy_id,
    jsonb_build_object('from_status', p_from_status, 'to_status', p_to_status)
  );
end;
$$;

revoke all on function private.vacancy_record_action(uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function private.vacancy_record_action(uuid, text, text, text, text)
  to service_role;

-- Prepared for cron: flip published vacancies past their expiry.
--
-- An automatic lifecycle change is still a lifecycle change, so it goes through
-- the same bookkeeping as a manual one: version bump, version snapshot and a
-- moderation-action + audit row. Row-by-row so every affected vacancy gets its
-- own snapshot and trail entry (`auto_expire`, actor NULL under cron) instead of
-- one silent set-based UPDATE.
--
-- The earlier draft of this file shipped a zero-argument version; drop it so a
-- re-apply cannot leave two overloads behind.
drop function if exists private.vacancy_expire_due();

create or replace function private.vacancy_expire_due(p_limit integer default 500)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 5000));
  v_id uuid;
begin
  for v_id in
    select v.id
    from public.vacancies v
    where v.status = 'published'
      and v.expires_at is not null
      and v.expires_at <= now()
    order by v.expires_at
    limit v_limit
    for update skip locked
  loop
    perform private.vacancy_assert_transition('published', 'expired');

    update public.vacancies v set
      status = 'expired',
      version_number = v.version_number + 1,
      row_version = v.row_version + 1,
      updated_at = now()
    where v.id = v_id;

    perform private.vacancy_snapshot_version(v_id);
    perform private.vacancy_record_action(
      v_id, 'auto_expire', 'published', 'expired', 'expires_at reached'
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function private.vacancy_expire_due(integer)
  from public, anon, authenticated;
grant execute on function private.vacancy_expire_due(integer) to service_role;

comment on function private.vacancy_expire_due(integer) is
  'Cron entry point: published -> expired past expires_at. Snapshots a version and writes an auto_expire moderation/audit row per vacancy.';

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_vacancies(
  p_status text default null,
  p_origin text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_origin text := nullif(btrim(coalesce(p_origin, '')), '');
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  v_uid := private.require_admin_permission('content.read');

  if v_status is not null
     and v_status not in (
       'draft', 'submitted', 'in_moderation', 'approved',
       'published', 'expired', 'archived', 'rejected'
     ) then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if v_origin is not null
     and v_origin not in ('demo', 'admin', 'user_submission') then
    raise exception 'invalid_origin' using errcode = '22023';
  end if;

  perform private.admin_write_audit(
    'vacancy.list',
    'vacancy',
    null,
    jsonb_build_object('status', v_status, 'origin', v_origin)
  );

  return coalesce(
    (
      select jsonb_agg(private.vacancy_to_admin_json(t.id) order by t.ord)
      from (
        select v.id, row_number() over (
          order by v.priority desc, v.updated_at desc
        ) as ord
        from public.vacancies v
        where (v_status is null or v.status = v_status)
          and (v_origin is null or v.origin = v_origin)
        order by v.priority desc, v.updated_at desc
        limit v_limit
        offset v_offset
      ) t
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_get_vacancy(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  v_uid := private.require_admin_permission('content.read');

  if not exists (select 1 from public.vacancies where id = p_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.admin_write_audit('vacancy.get', 'vacancy', p_id::text, '{}'::jsonb);

  return private.vacancy_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_create_vacancy_draft(
  p_patch jsonb,
  p_origin text default 'admin'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_origin text := coalesce(nullif(btrim(coalesce(p_origin, '')), ''), 'admin');
  v_row public.vacancies;
begin
  v_uid := private.require_admin_permission('content.write');

  -- Admin drafts are never user submissions: that path is submit_vacancy.
  if v_origin not in ('demo', 'admin') then
    raise exception 'invalid_origin' using errcode = '22023';
  end if;

  perform private.vacancy_assert_patch(v_patch, array[
    'title', 'company_name', 'summary', 'description', 'employment_type',
    'work_format', 'location', 'salary_text', 'external_url', 'contacts',
    'priority', 'starts_at', 'ends_at', 'expires_at'
  ]);

  if not (v_patch ? 'title') then
    raise exception 'invalid_title' using errcode = '22023';
  end if;

  insert into public.vacancies (
    title, company_name, summary, description, employment_type, work_format,
    location, salary_text, external_url, contacts, status, origin, priority,
    starts_at, ends_at, expires_at, audience_mode, created_by, updated_by
  ) values (
    btrim(v_patch ->> 'title'),
    coalesce(v_patch ->> 'company_name', ''),
    coalesce(v_patch ->> 'summary', ''),
    coalesce(v_patch ->> 'description', ''),
    nullif(btrim(coalesce(v_patch ->> 'employment_type', '')), ''),
    nullif(btrim(coalesce(v_patch ->> 'work_format', '')), ''),
    nullif(btrim(coalesce(v_patch ->> 'location', '')), ''),
    nullif(btrim(coalesce(v_patch ->> 'salary_text', '')), ''),
    nullif(btrim(coalesce(v_patch ->> 'external_url', '')), ''),
    coalesce(v_patch -> 'contacts', '{}'::jsonb),
    'draft',
    v_origin,
    coalesce((v_patch ->> 'priority')::integer, 0),
    nullif(v_patch ->> 'starts_at', '')::timestamptz,
    nullif(v_patch ->> 'ends_at', '')::timestamptz,
    nullif(v_patch ->> 'expires_at', '')::timestamptz,
    'all',
    v_uid,
    v_uid
  )
  returning * into v_row;

  perform private.vacancy_snapshot_version(v_row.id);
  -- Authoring event only: a draft has NOT entered moderation.
  perform private.vacancy_record_action(
    v_row.id, 'create_draft', null, 'draft', 'created'
  );

  return private.vacancy_to_admin_json(v_row.id);
end;
$$;

create or replace function public.admin_update_vacancy_draft(
  p_id uuid,
  p_patch jsonb,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_row public.vacancies;
begin
  v_uid := private.require_admin_permission('content.write');

  perform private.vacancy_assert_patch(v_patch, array[
    'title', 'company_name', 'summary', 'description', 'employment_type',
    'work_format', 'location', 'salary_text', 'external_url', 'contacts',
    'priority', 'starts_at', 'ends_at', 'expires_at', 'is_hidden'
  ]);

  v_row := private.vacancy_lock(p_id, p_expected_row_version);

  -- Content edits only in pre-publication states; published needs unpublish.
  if v_row.status not in ('draft', 'submitted', 'in_moderation', 'rejected', 'approved') then
    raise exception 'not_editable_in_status_%', v_row.status using errcode = '55000';
  end if;

  update public.vacancies v set
    title = case when v_patch ? 'title' then btrim(v_patch ->> 'title') else v.title end,
    company_name = case when v_patch ? 'company_name'
      then coalesce(v_patch ->> 'company_name', '') else v.company_name end,
    summary = case when v_patch ? 'summary'
      then coalesce(v_patch ->> 'summary', '') else v.summary end,
    description = case when v_patch ? 'description'
      then coalesce(v_patch ->> 'description', '') else v.description end,
    employment_type = case when v_patch ? 'employment_type'
      then nullif(btrim(coalesce(v_patch ->> 'employment_type', '')), '')
      else v.employment_type end,
    work_format = case when v_patch ? 'work_format'
      then nullif(btrim(coalesce(v_patch ->> 'work_format', '')), '')
      else v.work_format end,
    location = case when v_patch ? 'location'
      then nullif(btrim(coalesce(v_patch ->> 'location', '')), '') else v.location end,
    salary_text = case when v_patch ? 'salary_text'
      then nullif(btrim(coalesce(v_patch ->> 'salary_text', '')), '')
      else v.salary_text end,
    external_url = case when v_patch ? 'external_url'
      then nullif(btrim(coalesce(v_patch ->> 'external_url', '')), '')
      else v.external_url end,
    contacts = case when v_patch ? 'contacts'
      then coalesce(v_patch -> 'contacts', '{}'::jsonb) else v.contacts end,
    priority = case when v_patch ? 'priority'
      then coalesce((v_patch ->> 'priority')::integer, 0) else v.priority end,
    starts_at = case when v_patch ? 'starts_at'
      then nullif(v_patch ->> 'starts_at', '')::timestamptz else v.starts_at end,
    ends_at = case when v_patch ? 'ends_at'
      then nullif(v_patch ->> 'ends_at', '')::timestamptz else v.ends_at end,
    expires_at = case when v_patch ? 'expires_at'
      then nullif(v_patch ->> 'expires_at', '')::timestamptz else v.expires_at end,
    is_hidden = case when v_patch ? 'is_hidden'
      then coalesce((v_patch ->> 'is_hidden')::boolean, false) else v.is_hidden end,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'vacancy.update_draft',
    'vacancy',
    p_id,
    jsonb_build_object(
      'row_version', v_row.row_version,
      'patched_keys', (
        select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
        from jsonb_object_keys(v_patch) as k
      )
    )
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_set_vacancy_audience(
  p_id uuid,
  p_mode text,
  p_group_ids uuid[],
  p_user_ids uuid[],
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_mode text := nullif(btrim(coalesce(p_mode, '')), '');
  v_groups uuid[];
  v_users uuid[];
  v_missing uuid;
begin
  v_uid := private.require_admin_permission('content.write');

  if v_mode is null
     or v_mode not in ('all', 'groups', 'users', 'groups_and_users') then
    raise exception 'invalid_audience_mode' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_groups
  from unnest(coalesce(p_group_ids, '{}'::uuid[])) as x
  where x is not null;
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_users
  from unnest(coalesce(p_user_ids, '{}'::uuid[])) as x
  where x is not null;

  if v_mode = 'all' then
    v_groups := '{}'::uuid[];
    v_users := '{}'::uuid[];
  elsif v_mode = 'groups' then
    v_users := '{}'::uuid[];
    if coalesce(array_length(v_groups, 1), 0) = 0 then
      raise exception 'audience_groups_required' using errcode = '22023';
    end if;
  elsif v_mode = 'users' then
    v_groups := '{}'::uuid[];
    if coalesce(array_length(v_users, 1), 0) = 0 then
      raise exception 'audience_users_required' using errcode = '22023';
    end if;
  else
    if coalesce(array_length(v_groups, 1), 0) = 0
       or coalesce(array_length(v_users, 1), 0) = 0 then
      raise exception 'audience_groups_and_users_required' using errcode = '22023';
    end if;
  end if;

  v_row := private.vacancy_lock(p_id, p_expected_row_version);

  if v_row.status in ('published', 'archived') then
    raise exception 'not_editable_in_status_%', v_row.status using errcode = '55000';
  end if;

  select g into v_missing
  from unnest(v_groups) as g
  where not exists (select 1 from public.groups gr where gr.id = g)
  limit 1;
  if v_missing is not null then
    raise exception 'unknown_group_%', v_missing using errcode = '22023';
  end if;

  select u into v_missing
  from unnest(v_users) as u
  where not exists (
    select 1
    from public.users us
    where us.id = u
      and us.is_active
      and exists (
        select 1
        from public.student_enrollments se
        where se.user_id = us.id
          and se.status = 'active'
          and se.ended_at is null
      )
  )
  limit 1;
  if v_missing is not null then
    raise exception 'ineligible_audience_user_%', v_missing using errcode = '22023';
  end if;

  delete from public.vacancy_audience_groups where vacancy_id = p_id;
  delete from public.vacancy_audience_users where vacancy_id = p_id;

  insert into public.vacancy_audience_groups (vacancy_id, group_id)
  select p_id, g from unnest(v_groups) as g;
  insert into public.vacancy_audience_users (vacancy_id, user_id)
  select p_id, u from unnest(v_users) as u;

  update public.vacancies v set
    audience_mode = v_mode,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_assert_audience_consistent(p_id);
  perform private.vacancy_snapshot_version(p_id);

  perform private.content_write_domain_audit(
    'vacancy.set_audience',
    'vacancy',
    p_id,
    jsonb_build_object(
      'audience_mode', v_mode,
      'group_count', coalesce(array_length(v_groups, 1), 0),
      'user_count', coalesce(array_length(v_users, 1), 0)
    )
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_preview_vacancy_audience(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_result jsonb;
begin
  v_uid := private.require_admin_permission('content.read');

  if not exists (select 1 from public.vacancies where id = p_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_result := private.vacancy_preview_audience_count(p_id);

  perform private.admin_write_audit(
    'vacancy.preview_audience',
    'vacancy',
    p_id::text,
    jsonb_build_object('recipient_count', v_result -> 'recipient_count')
  );

  return v_result;
end;
$$;

create or replace function public.admin_moderate_vacancy(
  p_id uuid,
  p_action text,
  p_expected_row_version integer,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_action text := nullif(btrim(coalesce(p_action, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_from text;
  v_to text;
begin
  v_uid := private.require_any_admin_permission(
    array['moderation.action', 'moderation.write']
  );

  if v_action is null
     or v_action not in ('take_in_moderation', 'approve', 'reject') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;
  if v_action = 'reject' and v_reason is null then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  v_row := private.vacancy_lock(p_id, p_expected_row_version);
  v_from := v_row.status;

  -- A moderator must not approve their own submission.
  if v_row.submitted_by is not null and v_row.submitted_by = v_uid then
    raise exception 'cannot_moderate_own_submission' using errcode = '42501';
  end if;

  v_to := case v_action
    when 'take_in_moderation' then 'in_moderation'
    when 'approve' then 'approved'
    else 'rejected'
  end;

  perform private.vacancy_assert_transition(v_from, v_to);

  update public.vacancies v set
    status = v_to,
    moderated_by = v_uid,
    moderated_at = now(),
    rejection_reason = case when v_to = 'rejected' then v_reason else null end,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(p_id, v_action, v_from, v_to, coalesce(v_reason, ''));

  return private.vacancy_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_publish_vacancy(
  p_id uuid,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_from text;
  v_preview jsonb;
  v_count integer;
begin
  v_uid := private.require_admin_permission('content.publish');

  v_row := private.vacancy_lock(p_id, p_expected_row_version);
  v_from := v_row.status;

  -- Publication requires prior approval: no shortcut from draft/submitted.
  perform private.vacancy_assert_transition(v_from, 'published');

  perform private.vacancy_assert_contacts(v_row.contacts);
  perform private.vacancy_assert_audience_consistent(p_id);

  if v_row.expires_at is not null and v_row.expires_at <= now() then
    raise exception 'already_expired' using errcode = 'P0001';
  end if;

  v_preview := private.vacancy_preview_audience_count(p_id);
  v_count := coalesce((v_preview ->> 'recipient_count')::integer, 0);
  if v_row.audience_mode <> 'all' and v_count = 0 then
    raise exception 'empty_audience' using errcode = 'P0001';
  end if;

  update public.vacancies v set
    status = 'published',
    published_by = v_uid,
    published_at = coalesce(v.published_at, now()),
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(p_id, 'publish', v_from, 'published', '');

  return private.vacancy_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_set_vacancy_lifecycle(
  p_id uuid,
  p_action text,
  p_expected_row_version integer,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_action text := nullif(btrim(coalesce(p_action, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_from text;
  v_to text;
begin
  v_uid := private.require_admin_permission('content.publish');

  if v_action is null or v_action not in ('unpublish', 'expire', 'archive') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;

  v_row := private.vacancy_lock(p_id, p_expected_row_version);
  v_from := v_row.status;

  v_to := case v_action
    when 'unpublish' then 'approved'
    when 'expire' then 'expired'
    else 'archived'
  end;

  perform private.vacancy_assert_transition(v_from, v_to);

  update public.vacancies v set
    status = v_to,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(p_id, v_action, v_from, v_to, coalesce(v_reason, ''));

  return private.vacancy_to_admin_json(p_id);
end;
$$;

create or replace function public.admin_list_vacancy_versions(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  v_uid := private.require_admin_permission('content.read');

  if not exists (select 1 from public.vacancies where id = p_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', v.id,
          'vacancy_id', v.vacancy_id,
          'version_number', v.version_number,
          'created_at', v.created_at,
          'snapshot', v.snapshot
        )
        order by v.version_number desc
      )
      from public.vacancy_versions v
      where v.vacancy_id = p_id
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_list_vacancy_reports(
  p_status text default 'open',
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  v_uid := private.require_admin_permission('moderation.read');

  if v_status is not null
     and v_status not in ('open', 'resolved', 'rejected', 'all') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  -- Reporter identity intentionally omitted.
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', r.id,
          'vacancy_id', r.vacancy_id,
          'vacancy_title', v.title,
          'vacancy_status', v.status,
          'reason_code', r.reason_code,
          'note', r.note,
          'status', r.status,
          'created_at', r.created_at
        )
        order by r.created_at desc
      )
      from (
        select *
        from public.vacancy_reports r0
        where coalesce(v_status, 'open') = 'all' or r0.status = coalesce(v_status, 'open')
        order by r0.created_at desc
        limit v_limit
      ) r
      join public.vacancies v on v.id = r.vacancy_id
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_resolve_vacancy_report(
  p_report_id uuid,
  p_action text,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancy_reports;
  v_action text := nullif(btrim(coalesce(p_action, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  v_uid := private.require_any_admin_permission(
    array['moderation.action', 'moderation.write']
  );

  if v_action is null or v_action not in ('resolve', 'reject') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;

  select * into v_row from public.vacancy_reports where id = p_report_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'open' then
    raise exception 'already_closed' using errcode = '55000';
  end if;

  update public.vacancy_reports r set
    status = case when v_action = 'resolve' then 'resolved' else 'rejected' end,
    resolved_by = v_uid,
    resolved_at = now()
  where r.id = p_report_id
  returning * into v_row;

  perform private.vacancy_record_action(
    v_row.vacancy_id,
    case when v_action = 'resolve' then 'resolve_report' else 'reject_report' end,
    null,
    null,
    coalesce(v_reason, '')
  );

  return jsonb_build_object('ok', true, 'id', p_report_id, 'status', v_row.status);
end;
$$;

create or replace function public.admin_register_vacancy_asset(
  p_vacancy_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_title text default '',
  p_checksum text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancy_assets;
begin
  v_uid := private.require_admin_permission('content.write');

  if not exists (select 1 from public.vacancies where id = p_vacancy_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_storage_path is null
     or p_storage_path !~ '^vacancy/[0-9a-fA-F-]{36}/[A-Za-z0-9._-]+$'
     or char_length(p_storage_path) > 400 then
    raise exception 'invalid_storage_path' using errcode = '22023';
  end if;
  if p_mime_type not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf') then
    raise exception 'invalid_mime_type' using errcode = '22023';
  end if;
  if p_byte_size is null or p_byte_size < 0 or p_byte_size > 10485760 then
    raise exception 'invalid_byte_size' using errcode = '22023';
  end if;

  insert into public.vacancy_assets (
    vacancy_id, title, storage_bucket, storage_path, mime_type, byte_size,
    checksum, created_by
  ) values (
    p_vacancy_id,
    left(coalesce(p_title, ''), 200),
    'content-media',
    p_storage_path,
    p_mime_type,
    p_byte_size,
    nullif(btrim(coalesce(p_checksum, '')), ''),
    v_uid
  )
  returning * into v_row;

  perform private.content_write_domain_audit(
    'vacancy.register_asset',
    'vacancy',
    p_vacancy_id,
    jsonb_build_object('asset_id', v_row.id, 'mime_type', v_row.mime_type)
  );

  return jsonb_build_object(
    'id', v_row.id,
    'title', v_row.title,
    'mime_type', v_row.mime_type,
    'byte_size', v_row.byte_size,
    'created_at', v_row.created_at
  );
end;
$$;

create or replace function public.admin_delete_vacancy_asset(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancy_assets;
  v_status text;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_row from public.vacancy_assets where id = p_asset_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- Never break a live card: a published vacancy must be unpublished first.
  select v.status into v_status
  from public.vacancies v
  where v.id = v_row.vacancy_id
  for update;
  if v_status = 'published' then
    raise exception 'unpublish_vacancy_before_deleting_asset' using errcode = '55000';
  end if;

  insert into public.vacancy_media_cleanup_queue (
    storage_bucket, storage_path, source_vacancy_id, source_title
  ) values (
    v_row.storage_bucket, v_row.storage_path, v_row.vacancy_id, left(v_row.title, 200)
  )
  on conflict do nothing;

  delete from public.vacancy_assets where id = p_asset_id;

  perform private.content_write_domain_audit(
    'vacancy.delete_asset',
    'vacancy',
    v_row.vacancy_id,
    jsonb_build_object('asset_id', p_asset_id, 'queued_media', true)
  );

  return jsonb_build_object('deleted', true, 'id', p_asset_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Student RPCs
-- ---------------------------------------------------------------------------
create or replace function public.get_my_vacancies()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_groups uuid[];
  v_eligible boolean;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.users u where u.id = v_uid and u.is_active) then
    return '[]'::jsonb;
  end if;

  v_groups := private.current_user_active_group_ids();
  v_eligible := coalesce(array_length(v_groups, 1), 0) > 0;
  if not v_eligible then
    return '[]'::jsonb;
  end if;

  -- Set-based single statement. CONTACTS ARE NEVER INCLUDED HERE.
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', v.id,
          'title', v.title,
          'company_name', v.company_name,
          'summary', v.summary,
          'description', v.description,
          'employment_type', v.employment_type,
          'work_format', v.work_format,
          'location', v.location,
          'salary_text', v.salary_text,
          'external_url', v.external_url,
          'origin', v.origin,
          'is_demo', (v.origin = 'demo'),
          'published_at', v.published_at,
          'expires_at', v.expires_at,
          'has_contacts', (v.contacts <> '{}'::jsonb),
          'asset_ids', coalesce(
            (
              select jsonb_agg(a.id order by a.created_at, a.id)
              from public.vacancy_assets a
              where a.vacancy_id = v.id
            ),
            '[]'::jsonb
          )
        )
        order by v.priority desc, v.published_at desc nulls last
      )
      from public.vacancies v
      where v.status = 'published'
        and not v.is_hidden
        and (v.starts_at is null or v.starts_at <= v_now)
        and (v.ends_at is null or v.ends_at > v_now)
        and (v.expires_at is null or v.expires_at > v_now)
        and (
          v.audience_mode = 'all'
          or (
            v.audience_mode in ('groups', 'groups_and_users')
            and exists (
              select 1
              from public.vacancy_audience_groups g
              where g.vacancy_id = v.id
                and g.group_id = any (v_groups)
            )
          )
          or (
            v.audience_mode in ('users', 'groups_and_users')
            and exists (
              select 1
              from public.vacancy_audience_users au
              where au.vacancy_id = v.id
                and au.user_id = v_uid
            )
          )
        )
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.get_vacancy_contacts(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_contacts jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  -- Contacts leave the server ONLY for a published vacancy this caller can see.
  if not private.vacancy_deliverable_to_user(p_id, v_uid) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select v.contacts into v_contacts from public.vacancies v where v.id = p_id;

  return jsonb_build_object(
    'vacancy_id', p_id,
    'contacts', coalesce(v_contacts, '{}'::jsonb)
  );
end;
$$;

create or replace function public.submit_vacancy(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_row public.vacancies;
  v_recent integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not exists (
    select 1
    from public.users u
    join public.student_enrollments se
      on se.user_id = u.id and se.status = 'active' and se.ended_at is null
    where u.id = v_uid and u.is_active
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Students may only set content fields: no status / audience / schedule /
  -- priority / origin. Everything else is server-controlled.
  perform private.vacancy_assert_patch(v_patch, array[
    'title', 'company_name', 'summary', 'description', 'employment_type',
    'work_format', 'location', 'salary_text', 'external_url', 'contacts'
  ]);

  if not (v_patch ? 'title') then
    raise exception 'invalid_title' using errcode = '22023';
  end if;

  select count(*)::integer into v_recent
  from public.vacancies v
  where v.submitted_by = v_uid
    and v.created_at > now() - interval '24 hours';
  if v_recent >= 3 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.vacancies (
    title, company_name, summary, description, employment_type, work_format,
    location, salary_text, external_url, contacts,
    -- NEVER auto-published: a submission always enters the moderation queue.
    status, origin, audience_mode, submitted_by, submitted_at, created_by, updated_by
  ) values (
    btrim(v_patch ->> 'title'),
    coalesce(v_patch ->> 'company_name', ''),
    coalesce(v_patch ->> 'summary', ''),
    coalesce(v_patch ->> 'description', ''),
    nullif(btrim(coalesce(v_patch ->> 'employment_type', '')), ''),
    nullif(btrim(coalesce(v_patch ->> 'work_format', '')), ''),
    nullif(btrim(coalesce(v_patch ->> 'location', '')), ''),
    nullif(btrim(coalesce(v_patch ->> 'salary_text', '')), ''),
    nullif(btrim(coalesce(v_patch ->> 'external_url', '')), ''),
    coalesce(v_patch -> 'contacts', '{}'::jsonb),
    'submitted',
    'user_submission',
    'all',
    v_uid,
    now(),
    v_uid,
    v_uid
  )
  returning * into v_row;

  perform private.vacancy_snapshot_version(v_row.id);

  -- The student SUBMITTED it; a moderator has not taken it yet.
  perform private.vacancy_record_action(
    v_row.id, 'submit', null, 'submitted', 'user submission'
  );

  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status);
end;
$$;

create or replace function public.report_vacancy(
  p_vacancy_id uuid,
  p_reason_code text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_reason_code not in ('spam', 'scam', 'abuse', 'outdated', 'privacy', 'other') then
    raise exception 'invalid_reason' using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'note_too_long' using errcode = '22023';
  end if;

  if not private.vacancy_deliverable_to_user(p_vacancy_id, v_uid) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if exists (
    select 1
    from public.vacancies v
    where v.id = p_vacancy_id and v.submitted_by = v_uid
  ) then
    raise exception 'cannot_report_own' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.vacancy_reports r
    where r.reporter_user_id = v_uid
      and r.created_at > now() - interval '60 seconds'
  ) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.vacancy_reports (
    vacancy_id, reporter_user_id, reason_code, note
  ) values (
    p_vacancy_id, v_uid, p_reason_code, v_note
  )
  on conflict (vacancy_id, reporter_user_id) do update
    set reason_code = excluded.reason_code,
        note = excluded.note,
        status = 'open'
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants (RBAC enforced inside each function body)
-- ---------------------------------------------------------------------------
revoke all on function public.admin_list_vacancies(text, text, integer, integer)
  from public, anon;
grant execute on function public.admin_list_vacancies(text, text, integer, integer)
  to authenticated, service_role;

revoke all on function public.admin_get_vacancy(uuid) from public, anon;
grant execute on function public.admin_get_vacancy(uuid) to authenticated, service_role;

revoke all on function public.admin_create_vacancy_draft(jsonb, text) from public, anon;
grant execute on function public.admin_create_vacancy_draft(jsonb, text)
  to authenticated, service_role;

revoke all on function public.admin_update_vacancy_draft(uuid, jsonb, integer)
  from public, anon;
grant execute on function public.admin_update_vacancy_draft(uuid, jsonb, integer)
  to authenticated, service_role;

revoke all on function public.admin_set_vacancy_audience(uuid, text, uuid[], uuid[], integer)
  from public, anon;
grant execute on function public.admin_set_vacancy_audience(uuid, text, uuid[], uuid[], integer)
  to authenticated, service_role;

revoke all on function public.admin_preview_vacancy_audience(uuid) from public, anon;
grant execute on function public.admin_preview_vacancy_audience(uuid)
  to authenticated, service_role;

revoke all on function public.admin_moderate_vacancy(uuid, text, integer, text)
  from public, anon;
grant execute on function public.admin_moderate_vacancy(uuid, text, integer, text)
  to authenticated, service_role;

revoke all on function public.admin_publish_vacancy(uuid, integer) from public, anon;
grant execute on function public.admin_publish_vacancy(uuid, integer)
  to authenticated, service_role;

revoke all on function public.admin_set_vacancy_lifecycle(uuid, text, integer, text)
  from public, anon;
grant execute on function public.admin_set_vacancy_lifecycle(uuid, text, integer, text)
  to authenticated, service_role;

revoke all on function public.admin_list_vacancy_versions(uuid) from public, anon;
grant execute on function public.admin_list_vacancy_versions(uuid)
  to authenticated, service_role;

revoke all on function public.admin_list_vacancy_reports(text, integer) from public, anon;
grant execute on function public.admin_list_vacancy_reports(text, integer)
  to authenticated, service_role;

revoke all on function public.admin_resolve_vacancy_report(uuid, text, text)
  from public, anon;
grant execute on function public.admin_resolve_vacancy_report(uuid, text, text)
  to authenticated, service_role;

revoke all on function public.admin_register_vacancy_asset(
  uuid, text, text, bigint, text, text
) from public, anon;
grant execute on function public.admin_register_vacancy_asset(
  uuid, text, text, bigint, text, text
) to authenticated, service_role;

revoke all on function public.admin_delete_vacancy_asset(uuid) from public, anon;
grant execute on function public.admin_delete_vacancy_asset(uuid)
  to authenticated, service_role;

revoke all on function public.get_my_vacancies() from public, anon;
grant execute on function public.get_my_vacancies() to authenticated, service_role;

revoke all on function public.get_vacancy_contacts(uuid) from public, anon;
grant execute on function public.get_vacancy_contacts(uuid)
  to authenticated, service_role;

revoke all on function public.submit_vacancy(jsonb) from public, anon;
grant execute on function public.submit_vacancy(jsonb) to authenticated, service_role;

revoke all on function public.report_vacancy(uuid, text, text) from public, anon;
grant execute on function public.report_vacancy(uuid, text, text)
  to authenticated, service_role;

comment on function public.get_my_vacancies() is
  'Published, in-schedule, non-expired, audience-matched vacancies. Never returns contacts (only has_contacts).';
comment on function public.get_vacancy_contacts(uuid) is
  'Contacts for one vacancy, only when it is published and visible to the caller.';
comment on function public.submit_vacancy(jsonb) is
  'Student submission. Always lands in status=submitted / origin=user_submission; never auto-publishes.';

commit;
