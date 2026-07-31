-- DRAFT ONLY. Do not apply without separate confirmation.
--
-- Adds a compatibility flag for frontend-enforced password change after the
-- first login. The default keeps existing users unchanged from the app's point
-- of view.

alter table public.users
  add column if not exists must_change_password boolean not null default false;

create index if not exists users_must_change_password_idx
  on public.users (must_change_password)
  where must_change_password = true;
