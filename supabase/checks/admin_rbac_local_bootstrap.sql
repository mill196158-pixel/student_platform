-- LOCAL ROLE-PLAY BOOTSTRAP ONLY (not a production migration).
-- Used when the repo migration chain cannot apply from empty DB
-- (incomplete history / draft migrations). Apply before
-- 20260721202054_admin_rbac_and_audit.sql on a fresh local Supabase.
-- Do not apply to remote.

begin;

create extension if not exists pgcrypto;

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.subject_catalog (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  login text not null unique,
  name text,
  surname text,
  university text,
  group_name text,
  avatar_url text,
  status text,
  role text not null default 'student',
  is_active boolean not null default true,
  primary_group_id uuid null references public.groups(id) on delete set null,
  must_change_password boolean not null default false,
  last_seen_at timestamptz null,
  last_login_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.users enable row level security;

drop policy if exists users_select_authenticated on public.users;
create policy users_select_authenticated
  on public.users
  for select
  to authenticated
  using (true);

drop policy if exists users_update_own on public.users;
create policy users_update_own
  on public.users
  for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

grant select, insert, update, delete on table public.users to authenticated;
grant select, insert, update, delete on table public.users to anon;
grant select, insert, update, delete on table public.users to service_role;
grant select on table public.groups to authenticated;
grant select on table public.subject_catalog to authenticated;

create or replace function public.touch_my_presence()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_now timestamptz := now();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  update public.users
  set last_seen_at = v_now
  where id = v_me;

  return v_now;
end;
$$;

revoke all on function public.touch_my_presence() from public, anon;
grant execute on function public.touch_my_presence() to authenticated;
grant execute on function public.touch_my_presence() to service_role;

create or replace function public.register_local_user(
  p_login text,
  p_password text,
  p_name text,
  p_surname text,
  p_university text,
  p_group text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_email text := lower(btrim(p_login)) || '@local.student';
begin
  if coalesce(btrim(p_login), '') = '' then
    raise exception 'login_required' using errcode = '22023';
  end if;

  insert into auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_id,
    'authenticated',
    'authenticated',
    v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  );

  insert into auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  ) values (
    v_id,
    v_id,
    jsonb_build_object('sub', v_id::text, 'email', v_email),
    'email',
    v_id::text,
    now(),
    now(),
    now()
  );

  insert into public.users (
    id, login, name, surname, university, group_name, role, must_change_password
  ) values (
    v_id,
    btrim(p_login),
    nullif(btrim(p_name), ''),
    nullif(btrim(p_surname), ''),
    nullif(btrim(p_university), ''),
    nullif(btrim(p_group), ''),
    'student',
    false
  );

  return v_id;
end;
$$;

revoke all on function public.register_local_user(text, text, text, text, text, text)
  from public;
grant execute on function public.register_local_user(text, text, text, text, text, text)
  to anon, authenticated, service_role;

commit;
