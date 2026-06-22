-- DRAFT ONLY. Do not apply until the dry-run is reviewed and explicitly approved.
--
-- Scope:
-- - import VV 2024 students from public.stage_students_vv_2024 into public.users
--   and public.student_enrollments;
-- - do not create Supabase Auth users;
-- - do not touch auth.users, teams, chats, team_members, curriculum, subjects, or RLS.
--
-- Important schema constraint:
-- public.users.id references auth.users(id) and has no default. Therefore this
-- draft creates public.users rows only for credentials already marked as created
-- in public.stage_student_auth_credentials_vv_2024 by the Admin API script.

begin;

with staged as (
  select
    s.*,
    nullif(trim(s.login), '') as normalized_login
  from public.stage_students_vv_2024 s
  where nullif(trim(s.login), '') is not null
    and nullif(trim(s.record_book), '') is not null
    and nullif(trim(s.group_name), '') is not null
    and coalesce(s.admission_year, 2024) = 2024
    and coalesce(s.current_semester_number, 4) = 4
),
resolved as (
  select
    s.*,
    g.id as group_id,
    u.id as existing_user_id,
    c.auth_user_id,
    c.need_password_change
  from staged s
  join public.groups g on g.name = s.group_name
  left join public.stage_student_auth_credentials_vv_2024 c
    on lower(c.login) = lower(s.normalized_login)
   and c.created_in_auth = true
   and c.auth_user_id is not null
  left join public.users u on lower(u.login::text) = lower(s.normalized_login)
),
new_public_users as (
  insert into public.users (
    id,
    login,
    name,
    surname,
    group_name,
    role,
    is_active,
    primary_group_id,
    updated_at
  )
  select
    r.auth_user_id,
    r.normalized_login,
    coalesce(nullif(trim(r.name), ''), ''),
    coalesce(nullif(trim(r.surname), ''), ''),
    r.group_name,
    'student',
    coalesce(r.is_active, true),
    r.group_id,
    now()
  from resolved r
  where r.existing_user_id is null
    and r.auth_user_id is not null
    and not exists (
      select 1
      from public.users existing
      where lower(existing.login::text) = lower(r.normalized_login)
         or existing.id = r.auth_user_id
    )
  on conflict do nothing
  returning id, login
),
safe_existing_user_updates as (
  update public.users u
  set
    name = case
      when nullif(trim(coalesce(u.name, '')), '') is null then coalesce(nullif(trim(r.name), ''), u.name)
      else u.name
    end,
    surname = case
      when nullif(trim(coalesce(u.surname, '')), '') is null then coalesce(nullif(trim(r.surname), ''), u.surname)
      else u.surname
    end,
    group_name = case
      when nullif(trim(coalesce(u.group_name, '')), '') is null then r.group_name
      else u.group_name
    end,
    primary_group_id = coalesce(u.primary_group_id, r.group_id),
    role = case
      when nullif(trim(coalesce(u.role, '')), '') is null then 'student'
      else u.role
    end,
    updated_at = now()
  from resolved r
  where u.id = r.existing_user_id
    and r.existing_user_id is not null
    and r.group_id is not null
    and lower(coalesce(u.role, 'student')) in ('', 'student')
    and (
      nullif(trim(coalesce(u.group_name, '')), '') is null
      or trim(u.group_name) = trim(r.group_name)
    )
    and (
      u.primary_group_id is null
      or u.primary_group_id = r.group_id
    )
    and not exists (
      select 1
      from public.student_enrollments ae
      where ae.user_id = u.id
        and ae.status = 'active'
        and ae.ended_at is null
        and ae.group_id <> r.group_id
    )
    and (
      nullif(trim(coalesce(u.name, '')), '') is null
      or nullif(trim(coalesce(u.surname, '')), '') is null
      or nullif(trim(coalesce(u.group_name, '')), '') is null
      or u.primary_group_id is null
      or nullif(trim(coalesce(u.role, '')), '') is null
    )
  returning u.id, u.login
),
users_after_insert as (
  select
    r.*,
    coalesce(r.existing_user_id, npu.id) as user_id
  from resolved r
  left join new_public_users npu on lower(npu.login::text) = lower(r.normalized_login)
  where coalesce(r.existing_user_id, npu.id) is not null
),
enrollment_candidates as (
  select uai.*
  from users_after_insert uai
  where uai.group_id is not null
    and not exists (
      select 1
      from public.student_enrollments same_group
      where same_group.user_id = uai.user_id
        and same_group.group_id = uai.group_id
        and same_group.status = 'active'
        and same_group.ended_at is null
    )
    and not exists (
      select 1
      from public.student_enrollments other_group
      where other_group.user_id = uai.user_id
        and other_group.group_id <> uai.group_id
        and other_group.status = 'active'
        and other_group.ended_at is null
    )
),
inserted_enrollments as (
  insert into public.student_enrollments (
    user_id,
    group_id,
    started_at,
    ended_at,
    status,
    transfer_reason,
    updated_at
  )
  select
    ec.user_id,
    ec.group_id,
    date '2024-09-01',
    null,
    'active',
    'vv_2024_stage_import',
    now()
  from enrollment_candidates ec
  where not exists (
    select 1
    from public.student_enrollments existing
    where existing.user_id = ec.user_id
      and existing.group_id = ec.group_id
      and existing.status = 'active'
      and existing.ended_at is null
  )
  returning id, user_id, group_id
)
select
  (select count(*) from staged) as staged_rows_seen,
  (select count(*) from new_public_users) as public_users_inserted,
  (select count(*) from safe_existing_user_updates) as public_users_updated,
  (select count(*) from inserted_enrollments) as student_enrollments_inserted;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'users'
      and column_name = 'must_change_password'
  ) then
    execute $sql$
      update public.users u
      set
        must_change_password = true,
        updated_at = now()
      from public.stage_students_vv_2024 s
      join public.stage_student_auth_credentials_vv_2024 c
        on lower(c.login) = lower(trim(s.login))
       and c.created_in_auth = true
       and c.auth_user_id is not null
       and c.need_password_change = true
      where u.id = c.auth_user_id
        and lower(u.login::text) = lower(trim(s.login))
        and u.must_change_password is distinct from true
    $sql$;
  end if;
end $$;

commit;
