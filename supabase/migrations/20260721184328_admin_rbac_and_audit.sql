-- Stage 12.1 — Admin RBAC, scopes, audit log, and users privilege hardening.
-- LOCAL MIGRATION ONLY. Do not apply to remote without explicit review approval.
--
-- Design:
-- - Administrative rights live in dedicated tables, not users.role / JWT metadata.
-- - Clients access admin data only through granted RPCs.
-- - public.users self-update is a tight column whitelist (no group_name/role/etc).
-- - must_change_password is cleared only by an auth.users password-change trigger.
-- - Bootstrap of the first super_admin is intentionally NOT done here (see docs).

begin;

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;
grant usage on schema private to postgres;
grant usage on schema private to service_role;

-- ---------------------------------------------------------------------------
-- Catalog tables
-- ---------------------------------------------------------------------------

create table if not exists public.admin_roles (
  code text primary key,
  display_name text not null,
  description text not null default '',
  created_at timestamptz not null default now(),
  constraint admin_roles_code_not_blank check (btrim(code) <> '')
);

create table if not exists public.admin_permissions (
  code text primary key,
  description text not null default '',
  created_at timestamptz not null default now(),
  constraint admin_permissions_code_not_blank check (btrim(code) <> '')
);

create table if not exists public.admin_role_permissions (
  role_code text not null references public.admin_roles(code) on delete cascade,
  permission_code text not null references public.admin_permissions(code) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (role_code, permission_code)
);

create table if not exists public.admin_role_assignments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  role_code text not null references public.admin_roles(code) on delete restrict,
  scope_type text not null
    check (scope_type in ('global', 'group', 'subject')),
  scope_id uuid null,
  is_active boolean not null default true,
  expires_at timestamptz null,
  granted_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint admin_role_assignments_scope_shape check (
    (scope_type = 'global' and scope_id is null)
    or (scope_type in ('group', 'subject') and scope_id is not null)
  ),
  constraint admin_role_assignments_no_self_grant check (
    granted_by is null or granted_by <> user_id
  ),
  constraint admin_role_assignments_super_admin_rules check (
    role_code <> 'super_admin'
    or (
      scope_type = 'global'
      and scope_id is null
      and expires_at is null
    )
  )
);

-- Expression unique index so global scope_id NULL does not allow duplicates.
create unique index if not exists admin_role_assignments_active_unique_idx
  on public.admin_role_assignments (
    user_id,
    role_code,
    scope_type,
    coalesce(scope_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where is_active;

create index if not exists admin_role_assignments_user_idx
  on public.admin_role_assignments (user_id)
  where is_active;

create index if not exists admin_role_assignments_role_scope_idx
  on public.admin_role_assignments (role_code, scope_type, scope_id)
  where is_active;

create index if not exists admin_role_assignments_expires_idx
  on public.admin_role_assignments (expires_at)
  where is_active and expires_at is not null;

create table if not exists public.admin_audit_log (
  id bigserial primary key,
  actor_user_id uuid null references public.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint admin_audit_log_action_not_blank check (btrim(action) <> ''),
  constraint admin_audit_log_entity_type_not_blank check (btrim(entity_type) <> '')
);

create index if not exists admin_audit_log_created_at_idx
  on public.admin_audit_log (created_at desc);

create index if not exists admin_audit_log_actor_idx
  on public.admin_audit_log (actor_user_id, created_at desc);

create index if not exists admin_audit_log_entity_idx
  on public.admin_audit_log (entity_type, entity_id);

-- ---------------------------------------------------------------------------
-- Seed roles / permissions / matrix (idempotent)
-- ---------------------------------------------------------------------------

insert into public.admin_roles (code, display_name, description) values
  ('super_admin', 'Super Admin', 'Full administrative access'),
  ('content_editor', 'Content Editor', 'News and content management'),
  ('academic_editor', 'Academic Editor', 'Subjects and teachers management'),
  ('user_manager', 'User Manager', 'Student directory and suspensions'),
  ('moderator', 'Moderator', 'Moderation queues and actions'),
  ('viewer', 'Viewer', 'Read-only administrative visibility')
on conflict (code) do update
set display_name = excluded.display_name,
    description = excluded.description;

insert into public.admin_permissions (code, description) values
  ('dashboard.view', 'View admin dashboard'),
  ('content.read', 'Read content modules'),
  ('content.write', 'Create and edit content drafts'),
  ('content.publish', 'Publish content'),
  ('academic.read', 'Read academic modules'),
  ('subjects.write', 'Edit subjects'),
  ('teachers.write', 'Edit teachers'),
  ('students.read', 'Read students'),
  ('students.write', 'Edit students'),
  ('students.suspend', 'Suspend students'),
  ('moderation.read', 'Read moderation queues'),
  ('moderation.action', 'Take moderation actions'),
  ('roles.manage', 'Manage admin role assignments'),
  ('audit.read', 'Read admin audit log')
on conflict (code) do update
set description = excluded.description;

create temporary table if not exists _admin_role_perm_seed (
  role_code text not null,
  permission_code text not null
) on commit drop;

truncate _admin_role_perm_seed;

insert into _admin_role_perm_seed (role_code, permission_code) values
  ('super_admin', 'dashboard.view'),
  ('super_admin', 'content.read'),
  ('super_admin', 'content.write'),
  ('super_admin', 'content.publish'),
  ('super_admin', 'academic.read'),
  ('super_admin', 'subjects.write'),
  ('super_admin', 'teachers.write'),
  ('super_admin', 'students.read'),
  ('super_admin', 'students.write'),
  ('super_admin', 'students.suspend'),
  ('super_admin', 'moderation.read'),
  ('super_admin', 'moderation.action'),
  ('super_admin', 'roles.manage'),
  ('super_admin', 'audit.read'),
  ('content_editor', 'dashboard.view'),
  ('content_editor', 'content.read'),
  ('content_editor', 'content.write'),
  ('content_editor', 'content.publish'),
  ('academic_editor', 'dashboard.view'),
  ('academic_editor', 'academic.read'),
  ('academic_editor', 'subjects.write'),
  ('academic_editor', 'teachers.write'),
  ('user_manager', 'dashboard.view'),
  ('user_manager', 'students.read'),
  ('user_manager', 'students.write'),
  ('user_manager', 'students.suspend'),
  ('moderator', 'dashboard.view'),
  ('moderator', 'moderation.read'),
  ('moderator', 'moderation.action'),
  ('moderator', 'students.read'),
  -- viewer: read-only operational modules; NO audit.read
  ('viewer', 'dashboard.view'),
  ('viewer', 'content.read'),
  ('viewer', 'academic.read'),
  ('viewer', 'students.read'),
  ('viewer', 'moderation.read');

insert into public.admin_role_permissions (role_code, permission_code)
select role_code, permission_code from _admin_role_perm_seed
on conflict do nothing;

-- Remove previously seeded audit.read from viewer if present.
delete from public.admin_role_permissions
where role_code = 'viewer'
  and permission_code = 'audit.read';

-- ---------------------------------------------------------------------------
-- RLS: deny direct table access; RPCs only
-- ---------------------------------------------------------------------------

alter table public.admin_roles enable row level security;
alter table public.admin_roles force row level security;
alter table public.admin_permissions enable row level security;
alter table public.admin_permissions force row level security;
alter table public.admin_role_permissions enable row level security;
alter table public.admin_role_permissions force row level security;
alter table public.admin_role_assignments enable row level security;
alter table public.admin_role_assignments force row level security;
alter table public.admin_audit_log enable row level security;
alter table public.admin_audit_log force row level security;

revoke all on table public.admin_roles from public, anon, authenticated;
revoke all on table public.admin_permissions from public, anon, authenticated;
revoke all on table public.admin_role_permissions from public, anon, authenticated;
revoke all on table public.admin_role_assignments from public, anon, authenticated;
revoke all on table public.admin_audit_log from public, anon, authenticated;

grant select, insert, update, delete on table public.admin_roles to service_role;
grant select, insert, update, delete on table public.admin_permissions to service_role;
grant select, insert, update, delete on table public.admin_role_permissions to service_role;
grant select, insert, update, delete on table public.admin_role_assignments to service_role;
grant select, insert on table public.admin_audit_log to service_role;
grant usage, select on sequence public.admin_audit_log_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

create or replace function private.admin_assignment_is_effective(
  p_is_active boolean,
  p_expires_at timestamptz
)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select coalesce(p_is_active, false)
    and (p_expires_at is null or p_expires_at > now());
$$;

revoke all on function private.admin_assignment_is_effective(boolean, timestamptz)
  from public, anon, authenticated;

create or replace function private.admin_sanitize_audit_metadata(p_metadata jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog
as $$
  select coalesce(p_metadata, '{}'::jsonb)
    - 'password'
    - 'token'
    - 'access_token'
    - 'refresh_token'
    - 'jwt'
    - 'secret'
    - 'service_role'
    - 'service_role_key'
    - 'anon_key'
    - 'publishable_key'
    - 'authorization';
$$;

revoke all on function private.admin_sanitize_audit_metadata(jsonb)
  from public, anon, authenticated;

-- Actor is always auth.uid(); clients cannot spoof it.
create or replace function private.admin_write_audit(
  p_action text,
  p_entity_type text,
  p_entity_id text,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.admin_audit_log (
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    auth.uid(),
    p_action,
    p_entity_type,
    p_entity_id,
    private.admin_sanitize_audit_metadata(p_metadata)
  );
end;
$$;

revoke all on function private.admin_write_audit(text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function private.admin_write_audit(text, text, text, jsonb)
  to service_role;

create or replace function private.has_admin_permission(
  p_user_id uuid,
  p_permission text,
  p_scope_type text default 'global',
  p_scope_id uuid default null
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ok boolean := false;
begin
  if p_user_id is null or coalesce(btrim(p_permission), '') = '' then
    return false;
  end if;

  select exists (
    select 1
    from public.admin_role_assignments a
    join public.admin_role_permissions rp
      on rp.role_code = a.role_code
    where a.user_id = p_user_id
      and rp.permission_code = p_permission
      and private.admin_assignment_is_effective(a.is_active, a.expires_at)
      and (
        a.scope_type = 'global'
        or (
          p_scope_type is not null
          and a.scope_type = p_scope_type
          and a.scope_id is not distinct from p_scope_id
        )
      )
  ) into v_ok;

  return coalesce(v_ok, false);
end;
$$;

revoke all on function private.has_admin_permission(uuid, text, text, uuid)
  from public, anon, authenticated;
grant execute on function private.has_admin_permission(uuid, text, text, uuid)
  to service_role;

create or replace function private.is_current_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_role_assignments a
    where a.user_id = auth.uid()
      and private.admin_assignment_is_effective(a.is_active, a.expires_at)
  );
$$;

revoke all on function private.is_current_admin()
  from public, anon, authenticated;

-- Used by unapplied academic draft policies (manage = write capabilities).
create or replace function private.can_manage_academic()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    private.has_admin_permission(auth.uid(), 'subjects.write', 'global', null)
    or private.has_admin_permission(auth.uid(), 'teachers.write', 'global', null)
    or private.has_admin_permission(auth.uid(), 'roles.manage', 'global', null);
$$;

revoke all on function private.can_manage_academic()
  from public, anon, authenticated;

create or replace function private.count_active_super_admins()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from public.admin_role_assignments a
  where a.role_code = 'super_admin'
    and a.scope_type = 'global'
    and private.admin_assignment_is_effective(a.is_active, a.expires_at);
$$;

revoke all on function private.count_active_super_admins()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Password-change trigger (replaces clear_my_must_change_password RPC)
-- ---------------------------------------------------------------------------

create or replace function private.clear_must_change_password_on_auth_password_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and old.encrypted_password is distinct from new.encrypted_password
  then
    -- Allow private.guard_users_self_update to accept this server-driven clear.
    perform set_config('private.allow_must_change_password_clear', '1', true);
    update public.users as u
    set
      must_change_password = false,
      updated_at = now()
    where u.id = new.id;
  end if;
  return new;
end;
$$;

revoke all on function private.clear_must_change_password_on_auth_password_change()
  from public, anon, authenticated;

drop trigger if exists on_auth_user_password_changed on auth.users;
create trigger on_auth_user_password_changed
  after update of encrypted_password on auth.users
  for each row
  execute function private.clear_must_change_password_on_auth_password_change();

drop function if exists public.clear_my_must_change_password();

-- ---------------------------------------------------------------------------
-- Replace users.role-based is_admin with RBAC wrapper
-- ---------------------------------------------------------------------------

create or replace function public.is_admin(p_user uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  -- Never disclose admin status for an arbitrary UUID.
  if v_uid is null or p_user is distinct from v_uid then
    return false;
  end if;
  return private.is_current_admin();
end;
$$;

revoke all on function public.is_admin(uuid) from public, anon;
grant execute on function public.is_admin(uuid) to authenticated;
grant execute on function public.is_admin(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Public RPCs (authenticated only)
-- ---------------------------------------------------------------------------

create or replace function public.get_my_admin_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_permissions text[];
  v_scopes jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select coalesce(array_agg(distinct rp.permission_code order by rp.permission_code), '{}')
  into v_permissions
  from public.admin_role_assignments a
  join public.admin_role_permissions rp
    on rp.role_code = a.role_code
  where a.user_id = v_uid
    and private.admin_assignment_is_effective(a.is_active, a.expires_at);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'role_code', a.role_code,
        'scope_type', a.scope_type,
        'scope_id', a.scope_id,
        'expires_at', a.expires_at
      )
      order by a.role_code, a.scope_type, a.scope_id
    ),
    '[]'::jsonb
  )
  into v_scopes
  from public.admin_role_assignments a
  where a.user_id = v_uid
    and private.admin_assignment_is_effective(a.is_active, a.expires_at);

  return jsonb_build_object(
    'user_id', v_uid,
    'permissions', to_jsonb(v_permissions),
    'assignments', v_scopes
  );
end;
$$;

revoke all on function public.get_my_admin_capabilities() from public, anon;
grant execute on function public.get_my_admin_capabilities() to authenticated;
grant execute on function public.get_my_admin_capabilities() to service_role;

create or replace function public.admin_list_role_assignments()
returns table (
  id uuid,
  user_id uuid,
  role_code text,
  scope_type text,
  scope_id uuid,
  is_active boolean,
  expires_at timestamptz,
  granted_by uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not private.has_admin_permission(v_uid, 'roles.manage', 'global', null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select
    a.id,
    a.user_id,
    a.role_code,
    a.scope_type,
    a.scope_id,
    a.is_active,
    a.expires_at,
    a.granted_by,
    a.created_at,
    a.updated_at
  from public.admin_role_assignments a
  order by a.created_at desc;
end;
$$;

revoke all on function public.admin_list_role_assignments() from public, anon;
grant execute on function public.admin_list_role_assignments() to authenticated;
grant execute on function public.admin_list_role_assignments() to service_role;

create or replace function public.admin_assign_role(
  p_user_id uuid,
  p_role_code text,
  p_scope_type text default 'global',
  p_scope_id uuid default null,
  p_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not private.has_admin_permission(v_uid, 'roles.manage', 'global', null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_user_id is null then
    raise exception 'invalid_user' using errcode = '22023';
  end if;

  if p_user_id = v_uid then
    raise exception 'self_assignment_forbidden' using errcode = '42501';
  end if;

  if not exists (select 1 from public.users u where u.id = p_user_id) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.admin_roles r where r.code = p_role_code) then
    raise exception 'unknown_role' using errcode = '22023';
  end if;

  if p_scope_type not in ('global', 'group', 'subject') then
    raise exception 'invalid_scope_type' using errcode = '22023';
  end if;

  if p_scope_type = 'global' and p_scope_id is not null then
    raise exception 'invalid_scope' using errcode = '22023';
  end if;

  if p_scope_type in ('group', 'subject') and p_scope_id is null then
    raise exception 'invalid_scope' using errcode = '22023';
  end if;

  if p_role_code = 'super_admin' then
    if p_scope_type <> 'global' or p_scope_id is not null then
      raise exception 'super_admin_global_only' using errcode = '22023';
    end if;
    if p_expires_at is not null then
      raise exception 'super_admin_must_be_non_expiring' using errcode = '22023';
    end if;
  end if;

  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'invalid_expires_at' using errcode = '22023';
  end if;

  if p_scope_type = 'group'
     and not exists (select 1 from public.groups g where g.id = p_scope_id)
  then
    raise exception 'group_not_found' using errcode = 'P0002';
  end if;

  if p_scope_type = 'subject'
     and not exists (
       select 1 from public.subject_catalog s where s.id = p_scope_id
     )
  then
    raise exception 'subject_not_found' using errcode = 'P0002';
  end if;

  update public.admin_role_assignments a
  set
    expires_at = p_expires_at,
    granted_by = v_uid,
    updated_at = now(),
    is_active = true
  where a.user_id = p_user_id
    and a.role_code = p_role_code
    and a.scope_type = p_scope_type
    and a.scope_id is not distinct from p_scope_id
    and a.is_active
  returning a.id into v_id;

  if v_id is null then
    begin
      insert into public.admin_role_assignments (
        user_id,
        role_code,
        scope_type,
        scope_id,
        is_active,
        expires_at,
        granted_by
      ) values (
        p_user_id,
        p_role_code,
        p_scope_type,
        p_scope_id,
        true,
        p_expires_at,
        v_uid
      )
      returning id into v_id;
    exception
      when unique_violation then
        update public.admin_role_assignments a
        set
          expires_at = p_expires_at,
          granted_by = v_uid,
          updated_at = now(),
          is_active = true
        where a.user_id = p_user_id
          and a.role_code = p_role_code
          and a.scope_type = p_scope_type
          and a.scope_id is not distinct from p_scope_id
          and a.is_active
        returning a.id into v_id;
    end;
  end if;

  if v_id is null then
    raise exception 'assignment_failed' using errcode = 'P0001';
  end if;

  perform private.admin_write_audit(
    'admin_role.assign',
    'admin_role_assignment',
    v_id::text,
    jsonb_build_object(
      'user_id', p_user_id,
      'role_code', p_role_code,
      'scope_type', p_scope_type,
      'scope_id', p_scope_id,
      'expires_at', p_expires_at
    )
  );

  return v_id;
end;
$$;

revoke all on function public.admin_assign_role(uuid, text, text, uuid, timestamptz)
  from public, anon;
grant execute on function public.admin_assign_role(uuid, text, text, uuid, timestamptz)
  to authenticated;
grant execute on function public.admin_assign_role(uuid, text, text, uuid, timestamptz)
  to service_role;

create or replace function public.admin_revoke_role(
  p_assignment_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.admin_role_assignments%rowtype;
  v_active_supers integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not private.has_admin_permission(v_uid, 'roles.manage', 'global', null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Serialize concurrent revokes of super_admin so the last one cannot be removed.
  perform 1
  from public.admin_role_assignments a
  where a.role_code = 'super_admin'
    and a.scope_type = 'global'
    and a.is_active
  for update;

  select * into v_row
  from public.admin_role_assignments a
  where a.id = p_assignment_id
  for update;

  if not found then
    raise exception 'assignment_not_found' using errcode = 'P0002';
  end if;

  if v_row.user_id = v_uid then
    raise exception 'self_assignment_forbidden' using errcode = '42501';
  end if;

  if v_row.role_code = 'super_admin'
     and v_row.scope_type = 'global'
     and private.admin_assignment_is_effective(v_row.is_active, v_row.expires_at)
  then
    select private.count_active_super_admins() into v_active_supers;
    if coalesce(v_active_supers, 0) <= 1 then
      raise exception 'last_super_admin_protected' using errcode = '42501';
    end if;
  end if;

  update public.admin_role_assignments a
  set
    is_active = false,
    updated_at = now()
  where a.id = p_assignment_id;

  perform private.admin_write_audit(
    'admin_role.revoke',
    'admin_role_assignment',
    p_assignment_id::text,
    jsonb_build_object(
      'user_id', v_row.user_id,
      'role_code', v_row.role_code,
      'scope_type', v_row.scope_type,
      'scope_id', v_row.scope_id
    )
  );
end;
$$;

revoke all on function public.admin_revoke_role(uuid) from public, anon;
grant execute on function public.admin_revoke_role(uuid) to authenticated;
grant execute on function public.admin_revoke_role(uuid) to service_role;

create or replace function public.admin_list_audit_log(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id bigint,
  actor_user_id uuid,
  action text,
  entity_type text,
  entity_id text,
  metadata jsonb,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer;
  v_offset integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not private.has_admin_permission(v_uid, 'audit.read', 'global', null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Hard max page size.
  v_limit := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset := greatest(0, coalesce(p_offset, 0));

  return query
  select
    l.id,
    l.actor_user_id,
    l.action,
    l.entity_type,
    l.entity_id,
    l.metadata,
    l.created_at
  from public.admin_audit_log l
  order by l.created_at desc, l.id desc
  limit v_limit
  offset v_offset;
end;
$$;

revoke all on function public.admin_list_audit_log(integer, integer)
  from public, anon;
grant execute on function public.admin_list_audit_log(integer, integer)
  to authenticated;
grant execute on function public.admin_list_audit_log(integer, integer)
  to service_role;

-- ---------------------------------------------------------------------------
-- Harden public.users privileges + backward-compatible self-update guard
--
-- Old installed app (HEAD before 12.1) sends UPDATE payloads with:
--   profile_repository: name, surname, university, group_name, status?
--   edit_profile: avatar_url | status
--   change_password: must_change_password=false (after auth.updateUser)
-- Presence uses RPC touch_my_presence — no direct last_seen_at UPDATE.
-- Signup uses register_local_user RPC — no anon INSERT needed.
--
-- Strategy:
-- - revoke table-level UPDATE from authenticated
-- - grant column UPDATE for safe fields + old-payload fields
-- - BEFORE UPDATE trigger blocks real changes to protected columns
--   while allowing unchanged values in legacy payloads
-- ---------------------------------------------------------------------------

revoke all on table public.users from anon;
revoke insert, update, delete, truncate, references, trigger
  on table public.users
  from authenticated;

grant select on table public.users to authenticated;

-- Statement-level column privileges for current + legacy payloads.
grant update (
  name,
  surname,
  avatar_url,
  status,
  updated_at,
  university,
  group_name,
  must_change_password
) on table public.users to authenticated;

grant select, insert, update, delete on table public.users to service_role;

create or replace function private.guard_users_self_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_jwt_role text := coalesce(
    auth.jwt() ->> 'role',
    current_setting('request.jwt.claim.role', true),
    ''
  );
begin
  -- Server / service_role paths (seed, import, auth triggers, Dashboard SQL).
  if v_uid is null or v_jwt_role = 'service_role' then
    return new;
  end if;

  if new.id is distinct from v_uid then
    raise exception 'users_update_own_row_only' using errcode = '42501';
  end if;

  if new.role is distinct from old.role then
    raise exception 'users_role_immutable' using errcode = '42501';
  end if;

  if new.is_active is distinct from old.is_active then
    raise exception 'users_is_active_immutable' using errcode = '42501';
  end if;

  if new.primary_group_id is distinct from old.primary_group_id then
    raise exception 'users_primary_group_immutable' using errcode = '42501';
  end if;

  if new.group_name is distinct from old.group_name then
    raise exception 'users_group_name_immutable' using errcode = '42501';
  end if;

  if new.university is distinct from old.university then
    raise exception 'users_university_immutable' using errcode = '42501';
  end if;

  if new.login is distinct from old.login then
    raise exception 'users_login_immutable' using errcode = '42501';
  end if;

  -- Legacy change_password sends must_change_password=false after Auth password
  -- update. Auth trigger usually clears the flag first (false -> false = ok).
  -- Direct true -> false without Auth password change is blocked.
  -- Auth trigger sets private.allow_must_change_password_clear=1 for true -> false.
  if new.must_change_password is distinct from old.must_change_password then
    if current_setting('private.allow_must_change_password_clear', true) = '1'
       and new.must_change_password = false
    then
      null;
    else
      raise exception 'users_must_change_password_immutable' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.guard_users_self_update()
  from public, anon, authenticated;

drop trigger if exists trg_users_guard_self_update on public.users;
create trigger trg_users_guard_self_update
  before update on public.users
  for each row
  execute function private.guard_users_self_update();

-- ---------------------------------------------------------------------------
-- If legacy academic draft admin policies were ever applied elsewhere, rewrite
-- them to RBAC. Remote preflight: these draft migrations are NOT applied.
-- ---------------------------------------------------------------------------

do $fix_academic_admin_policies$
declare
  r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and (
        policyname like '%_admin_manage'
        or policyname = 'subject_difficulty_votes_admin_read'
      )
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      r.policyname,
      r.schemaname,
      r.tablename
    );

    if r.policyname = 'subject_difficulty_votes_admin_read' then
      execute format(
        'create policy %I on %I.%I for select to authenticated using (private.can_manage_academic())',
        r.policyname,
        r.schemaname,
        r.tablename
      );
    else
      execute format(
        'create policy %I on %I.%I for all to authenticated using (private.can_manage_academic()) with check (private.can_manage_academic())',
        r.policyname,
        r.schemaname,
        r.tablename
      );
    end if;
  end loop;
end;
$fix_academic_admin_policies$;

-- NOTE: Unapplied repo drafts
--   20260609093000_academic_rls_policies_draft.sql
--   20260609133500_subject_student_knowledge_rls_draft.sql
-- still contain users.role = 'admin' text. They must be rewritten to
-- private.can_manage_academic() before any future apply. Do not edit their
-- historical filenames once applied; ship a follow-up migration instead.

commit;
