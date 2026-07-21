# Admin RBAC bootstrap (after migration review)

Do **not** apply `supabase/migrations/20260721184328_admin_rbac_and_audit.sql`
until an explicit review approval.

This migration intentionally does **not** assign any `super_admin` by email or UUID.

## After the migration is applied

1. Sign in to the Supabase Dashboard with a trusted operator account.
2. Identify the Auth user UUID that should become the first super admin
   (`Authentication → Users`, copy `id`). Confirm the matching `public.users.id`.
3. Using the SQL editor **as a privileged operator / service role session**, insert
   exactly one global assignment:

```sql
insert into public.admin_role_assignments (
  user_id,
  role_code,
  scope_type,
  scope_id,
  is_active,
  expires_at,
  granted_by
) values (
  '<TARGET_USER_UUID>'::uuid,
  'super_admin',
  'global',
  null,
  true,
  null,
  null -- bootstrap has no granter
);
```

4. Verify:

```sql
select public.get_my_admin_capabilities(); -- as that user session
-- or inspect assignments:
select * from public.admin_role_assignments where is_active;
```

5. Further role grants must go through `admin_assign_role(...)` so audit rows are written.

## Password flag

`must_change_password` is cleared automatically by trigger
`private.clear_must_change_password_on_auth_password_change` on
`auth.users.encrypted_password` updates. Clients must not call any clear RPC.

## Never do

- Put `service_role` into Flutter Web / dart-define / localStorage.
- Trust `public.users.role`, `user_metadata`, or URL query flags for admin access.
- Assign yourself additional roles through a self-targeting call
  (`self_assignment_forbidden` is enforced by RPC).
- Let students UPDATE `group_name` / `role` / `university` via PostgREST.
