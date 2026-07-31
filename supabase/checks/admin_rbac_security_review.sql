-- Stage 12.1 security review + post-apply verification queries.
-- Run AFTER applying 20260721202054_admin_rbac_and_audit.sql on a LOCAL review DB.
-- Do not run against production without approval. Do not insert real secrets.
--
-- Runtime role-play requires a local Postgres/Supabase with a student JWT.
-- If Docker/local Supabase is unavailable, run sections A + static review only
-- and treat B/C/D as a documented runtime blocker.

-- =============================================================================
-- A) Privilege inventory
-- =============================================================================

-- A1) Table privileges on users / admin_* for anon/authenticated
select table_name, grantee, privilege_type
from information_schema.table_privileges
where table_schema = 'public'
  and table_name in (
    'users',
    'admin_roles',
    'admin_permissions',
    'admin_role_permissions',
    'admin_role_assignments',
    'admin_audit_log'
  )
  and grantee in ('anon', 'authenticated', 'PUBLIC')
order by 1, 2, 3;

-- Expect for users:
--   authenticated: SELECT only at table level (no INSERT/UPDATE/DELETE/TRUNCATE)
--   anon: none
-- Expect for admin_*: no privileges for anon/authenticated

-- A2) Column UPDATE privileges on users (compatibility whitelist)
select column_name, grantee, privilege_type
from information_schema.column_privileges
where table_schema = 'public'
  and table_name = 'users'
  and grantee in ('anon', 'authenticated')
  and privilege_type in ('UPDATE', 'INSERT')
order by 1, 2, 3;

-- Expect authenticated UPDATE only on:
--   name, surname, avatar_url, status, updated_at,
--   university, group_name, must_change_password
--   (last two + must_change_password are for legacy payload statement privileges;
--    real changes are blocked by private.guard_users_self_update)
-- Expect ZERO UPDATE for: role, is_active, primary_group_id, login, id, last_seen_at
-- Expect ZERO rows for anon

-- A3) Hard-denied columns must have no client UPDATE
select column_name, grantee, privilege_type
from information_schema.column_privileges
where table_schema = 'public'
  and table_name = 'users'
  and column_name in (
    'role',
    'is_active',
    'primary_group_id',
    'login',
    'id',
    'last_seen_at'
  )
  and grantee in ('anon', 'authenticated')
  and privilege_type in ('UPDATE', 'INSERT')
order by 1, 2, 3;
-- Expect: zero rows.

-- A4) Compatibility columns are granted but trigger-guarded
select column_name, grantee, privilege_type
from information_schema.column_privileges
where table_schema = 'public'
  and table_name = 'users'
  and column_name in ('group_name', 'university', 'must_change_password')
  and grantee = 'authenticated'
  and privilege_type = 'UPDATE'
order by 1;
-- Expect: exactly those three columns.

-- A5) RPC execute matrix
select
  n.nspname,
  p.proname,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where (n.nspname, p.proname) in (
  ('public', 'get_my_admin_capabilities'),
  ('public', 'admin_list_role_assignments'),
  ('public', 'admin_assign_role'),
  ('public', 'admin_revoke_role'),
  ('public', 'admin_list_audit_log'),
  ('public', 'is_admin'),
  ('public', 'clear_my_must_change_password'),
  ('public', 'register_local_user'),
  ('public', 'touch_my_presence'),
  ('private', 'has_admin_permission'),
  ('private', 'admin_write_audit'),
  ('private', 'can_manage_academic'),
  ('private', 'guard_users_self_update'),
  ('private', 'clear_must_change_password_on_auth_password_change')
)
order by 1, 2;

-- Expect:
--   clear_my_must_change_password: function absent
--   private helpers: anon_exec=false, auth_exec=false
--   public admin RPCs: anon_exec=false, auth_exec=true
--   is_admin: anon_exec=false, auth_exec=true
--   register_local_user: anon_exec=true (signup path) OR authenticated-only if
--     designed that way — confirm matches pre-12.1 grants
--   touch_my_presence: authenticated=true, anon=false

-- A6) Self-update guard trigger present
select tgname, tgenabled
from pg_trigger
where tgrelid = 'public.users'::regclass
  and not tgisinternal
  and tgname = 'trg_users_guard_self_update';
-- Expect: one row, enabled.

-- A7) viewer must not have audit.read
select role_code, permission_code
from public.admin_role_permissions
where role_code = 'viewer'
  and permission_code = 'audit.read';
-- Expect: zero rows.

-- A8) Anon table writes absent
select table_name, privilege_type
from information_schema.table_privileges
where table_schema = 'public'
  and table_name in (
    'users',
    'admin_roles',
    'admin_permissions',
    'admin_role_permissions',
    'admin_role_assignments',
    'admin_audit_log'
  )
  and grantee in ('anon', 'PUBLIC')
  and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
order by 1, 2;
-- Expect: zero rows (signup must go through register_local_user / security definer).

-- =============================================================================
-- B) Backward-compatible payload probes (run as a student JWT session)
-- =============================================================================
-- Replace auth.uid() context with a real student session before uncommenting.

-- B1) Old profile payload with UNCHANGED group_name/university MUST succeed:
-- update public.users
-- set
--   name = name,
--   surname = surname,
--   university = university,
--   group_name = group_name,
--   status = status
-- where id = auth.uid();
-- Expect: SUCCESS (legacy profile_repository.updateProfile).

-- B2) Changing group_name MUST fail (trigger):
-- update public.users
-- set group_name = coalesce(group_name, '') || '_hacked'
-- where id = auth.uid();
-- Expect: ERROR users_group_name_immutable

-- B3) Changing role MUST fail (no column privilege and/or trigger):
-- update public.users set role = 'admin' where id = auth.uid();
-- Expect: privilege error OR users_role_immutable

-- B4) Old presence path MUST work (RPC, not column UPDATE):
-- select public.touch_my_presence();
-- Expect: SUCCESS; users.last_seen_at updated for auth.uid()

-- B5) Direct last_seen_at UPDATE must not be available to clients:
-- update public.users set last_seen_at = now() where id = auth.uid();
-- Expect: privilege error (no column UPDATE grant)

-- B6) must_change_password cannot be cleared by direct client UPDATE:
-- -- precondition: must_change_password = true for the session user
-- update public.users set must_change_password = false where id = auth.uid();
-- Expect: ERROR users_must_change_password_immutable

-- B7) After real Auth password change, flag is cleared by trigger; legacy
--     false -> false UPDATE must succeed:
-- -- 1) via client/API: auth.updateUser({ password: '...' })
-- -- 2) verify: select must_change_password from public.users where id = auth.uid();
-- --    Expect: false
-- -- 3) legacy follow-up (old change_password_screen):
-- update public.users set must_change_password = false where id = auth.uid();
-- Expect: SUCCESS (no value change)

-- B8) Safe fields still updatable:
-- update public.users set name = name, avatar_url = avatar_url, status = status
-- where id = auth.uid();
-- Expect: SUCCESS

-- B9) Other-row UPDATE must fail:
-- update public.users set name = 'x' where id = '<other-uuid>';
-- Expect: 0 rows / RLS deny / users_update_own_row_only

-- B10) Password flag bypass RPC must not exist:
-- select public.clear_my_must_change_password();
-- Expect: undefined_function

-- =============================================================================
-- C) Signup / first-login path (anon + authenticated)
-- =============================================================================
-- C1) Confirm register_local_user still exists and is executable for signup role:
select
  p.proname,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'register_local_user';
-- Expect: function present, security_definer=true, EXECUTE preserved for signup.

-- C2) Anon must NOT insert into public.users directly:
-- set role anon;
-- insert into public.users(id, login) values (gen_random_uuid(), 'x');
-- Expect: privilege error
-- reset role;

-- C3) Manual signup smoke (LOCAL only, synthetic login):
-- select public.register_local_user(
--   'preflight_user_' || substr(gen_random_uuid()::text, 1, 8),
--   'TempPass123!',
--   'Test',
--   'User',
--   'Test University',
--   'TEST-GROUP'
-- );
-- Then signInWithPassword with normalized auth email — Expect: SUCCESS
-- Cleanup synthetic auth/public rows after review.

-- C4) First login SELECT path (login_screen) still works for authenticated:
-- select id, login, name, surname, university, group_name, avatar_url, status,
--        role, must_change_password
-- from public.users
-- where id = auth.uid();
-- Expect: SUCCESS (SELECT grant retained)

-- =============================================================================
-- D) Role-play checklist (admin RBAC — short, not full audit)
-- =============================================================================
-- student:
--   select public.get_my_admin_capabilities(); -- permissions []
--   select public.admin_assign_role(...); -- forbidden
-- content_editor / scoped academic_editor / expired / super_admin:
--   unchanged from 12.1 design (see ADMIN_RBAC_BOOTSTRAP.md)
-- anon:
--   no writes on users/admin_*; no EXECUTE on admin RPCs
--   signup via register_local_user only
