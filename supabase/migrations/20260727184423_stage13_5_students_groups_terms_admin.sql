-- Stage 13.5 — students / groups / terms admin foundation.
-- LOCAL ONLY. Do not apply remotely from this migration.
-- Auth user provisioning stays out of Web Admin (no service_role client).
begin;

insert into public.admin_permissions(code, description) values
  ('students.read', 'Read students'),
  ('students.write', 'Create/edit student profiles and enrollments'),
  ('students.suspend', 'Block/restore students'),
  ('groups.write', 'Manage academic groups'),
  ('terms.manage', 'Manage academic terms and semester prepare')
on conflict (code) do nothing;

-- Explicit role separation (do not blanket-grant all perms).
insert into public.admin_role_permissions(role_code, permission_code)
select 'super_admin', p.code
from (values
  ('students.read'),('students.write'),('students.suspend'),
  ('groups.write'),('terms.manage')
) as p(code)
on conflict do nothing;
insert into public.admin_role_permissions(role_code, permission_code)
select 'user_manager', p.code
from (values
  ('students.read'),('students.write'),('students.suspend'),
  ('groups.write')
) as p(code)
on conflict do nothing;
insert into public.admin_role_permissions(role_code, permission_code)
select 'academic_editor', p.code
from (values ('groups.write'),('terms.manage')) as p(code)
on conflict do nothing;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.admin_term_ops_batches (
  id uuid primary key default gen_random_uuid(),
  created_by uuid null references public.users(id) on delete set null,
  operation text not null check (operation in ('student_import', 'term_prepare')),
  status text not null check (status in ('dry_run', 'applied', 'cancelled')),
  payload_hash text null,
  summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create unique index if not exists admin_term_ops_batches_actor_payload_uidx
  on public.admin_term_ops_batches (created_by, operation, payload_hash)
  where status = 'applied' and payload_hash is not null and created_by is not null;

create table if not exists public.admin_term_ops_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.admin_term_ops_batches(id) on delete cascade,
  row_number integer not null check (row_number > 0),
  classification text not null,
  payload jsonb not null default '{}'::jsonb,
  error_text text null,
  unique (batch_id, row_number)
);

alter table public.admin_term_ops_batches enable row level security;
alter table public.admin_term_ops_batches force row level security;
alter table public.admin_term_ops_rows enable row level security;
alter table public.admin_term_ops_rows force row level security;
revoke all on table public.admin_term_ops_batches, public.admin_term_ops_rows
  from public, anon, authenticated;

create or replace function private.stage13_5_can(p_perm text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_ok boolean := false;
begin
  if auth.uid() is null then return false; end if;
  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is not null then
    execute 'select private.has_admin_permission($1,$2,$3,$4)'
      into v_ok using auth.uid(), p_perm, 'global', null::uuid;
  end if;
  return coalesce(v_ok, false);
end $$;
revoke all on function private.stage13_5_can(text) from public, anon, authenticated;

create or replace function private.stage13_5_is_student_account(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.users u
    where u.id = p_user_id
      and lower(coalesce(nullif(btrim(u.role), ''), 'student')) = 'student'
  );
$$;
revoke all on function private.stage13_5_is_student_account(uuid) from public, anon, authenticated;

-- Allow trusted admin RPCs to update another student's managed fields.
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
  v_admin_student boolean := false;
begin
  if v_uid is null or v_jwt_role = 'service_role' then
    return new;
  end if;

  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is not null then
    if new.is_active is distinct from old.is_active then
      execute 'select private.has_admin_permission($1,$2,$3,$4)'
        into v_admin_student using v_uid, 'students.suspend', 'global', null::uuid;
    else
      execute 'select private.has_admin_permission($1,$2,$3,$4)'
        into v_admin_student using v_uid, 'students.write', 'global', null::uuid;
    end if;
  end if;

  if coalesce(v_admin_student, false)
     and lower(coalesce(nullif(btrim(old.role), ''), 'student')) = 'student'
     and new.role is not distinct from old.role
     and new.login is not distinct from old.login
     and new.university is not distinct from old.university
     and new.must_change_password is not distinct from old.must_change_password
  then
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
revoke all on function private.guard_users_self_update() from public, anon, authenticated;

create or replace function public.admin_ensure_group_space_for_group(p_group_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_team uuid; v_chat uuid;
begin
  if not (
    private.stage13_5_can('groups.write')
    or private.stage13_5_can('terms.manage')
    or private.stage13_5_can('students.write')
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_group_id is null then raise exception 'group_required' using errcode = '22023'; end if;
  select t.id into v_team from public.teams t
  where t.group_id = p_group_id and t.kind = 'group_space' limit 1;
  if v_team is null then
    insert into public.teams(name, description, teacher, icon, group_id, kind, group_name)
    select 'Пространство группы', '', '', 'groups', p_group_id, 'group_space', g.name
    from public.groups g where g.id = p_group_id
    on conflict do nothing;
    select t.id into v_team from public.teams t
    where t.group_id = p_group_id and t.kind = 'group_space' limit 1;
  end if;
  if v_team is null then raise exception 'group_space_creation_failed' using errcode = 'P0001'; end if;
  perform 1 from public.teams t where t.id = v_team for update;
  select c.id into v_chat from public.chats c where c.team_id = v_team and c.type = 'team_main' limit 1;
  if v_chat is null then
    begin
      insert into public.chats(team_id, type) values (v_team, 'team_main') returning id into v_chat;
    exception when unique_violation then
      select c.id into v_chat from public.chats c where c.team_id = v_team and c.type = 'team_main' limit 1;
    end;
  end if;
  perform public.sync_group_space_members(p_group_id);
  return jsonb_build_object('team_id', v_team, 'chat_id', v_chat, 'group_id', p_group_id);
end $$;

create or replace function public.admin_list_students(
  p_query text default null,
  p_group_id uuid default null,
  p_active boolean default null
) returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not (private.stage13_5_can('students.read') or private.stage13_5_can('students.write'))
      then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'id', u.id,
          'login', u.login,
          'name', u.name,
          'surname', u.surname,
          'is_active', coalesce(u.is_active, true),
          'primary_group_id', u.primary_group_id,
          'group_name', coalesce(g.name, u.group_name),
          'enrollment_id', se.id,
          'enrollment_status', se.status
        ) order by u.surname nulls last, u.name nulls last, u.login)
        from public.users u
        left join lateral (
          select e.* from public.student_enrollments e
          where e.user_id = u.id and e.status = 'active' and e.ended_at is null
          order by e.started_at desc nulls last
          limit 1
        ) se on true
        left join public.groups g on g.id = coalesce(u.primary_group_id, se.group_id)
        where private.stage13_5_is_student_account(u.id)
          and (p_active is null or coalesce(u.is_active, true) = p_active)
          and (p_group_id is null or coalesce(u.primary_group_id, se.group_id) = p_group_id)
          and (
            p_query is null
            or u.login ilike '%' || p_query || '%'
            or coalesce(u.name, '') ilike '%' || p_query || '%'
            or coalesce(u.surname, '') ilike '%' || p_query || '%'
          )
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_upsert_student_profile(
  p_id uuid,
  p_name text default null,
  p_surname text default null,
  p_is_active boolean default null
) returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if not private.stage13_5_is_student_account(p_id) then
    raise exception 'not_a_student' using errcode = '42501';
  end if;
  if p_is_active is not null then
    if not private.stage13_5_can('students.suspend') then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  elsif not private.stage13_5_can('students.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.users set
    name = coalesce(nullif(btrim(p_name), ''), name),
    surname = coalesce(nullif(btrim(p_surname), ''), surname),
    is_active = coalesce(p_is_active, is_active)
  where id = p_id;
  if not found then raise exception 'student_not_found' using errcode = 'P0002'; end if;
  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      case when p_is_active is distinct from null and p_is_active = false then 'student.block'
           when p_is_active is distinct from null and p_is_active = true then 'student.restore'
           else 'student.update' end,
      'student', p_id::text,
      jsonb_build_object('is_active', p_is_active)
    );
  end if;
  return p_id;
end $$;

create or replace function public.admin_assign_student_group(
  p_user_id uuid,
  p_group_id uuid
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_enroll uuid;
begin
  if not private.stage13_5_can('students.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not private.stage13_5_is_student_account(p_user_id) then
    raise exception 'not_a_student' using errcode = '42501';
  end if;
  if not exists (select 1 from public.groups where id = p_group_id) then
    raise exception 'group_not_found' using errcode = 'P0002';
  end if;
  update public.student_enrollments
  set status = 'transferred', ended_at = current_date, updated_at = now()
  where user_id = p_user_id and status = 'active' and ended_at is null
    and group_id is distinct from p_group_id;
  insert into public.student_enrollments(user_id, group_id, status, started_at)
  select p_user_id, p_group_id, 'active', current_date
  where not exists (
    select 1 from public.student_enrollments e
    where e.user_id = p_user_id and e.group_id = p_group_id
      and e.status = 'active' and e.ended_at is null
  )
  returning id into v_enroll;
  if v_enroll is null then
    select e.id into v_enroll from public.student_enrollments e
    where e.user_id = p_user_id and e.group_id = p_group_id
      and e.status = 'active' and e.ended_at is null
    limit 1;
  end if;
  update public.users u
  set primary_group_id = p_group_id,
      group_name = g.name
  from public.groups g
  where u.id = p_user_id and g.id = p_group_id;
  perform public.admin_ensure_group_space_for_group(p_group_id);
  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'student.assign_group', 'student', p_user_id::text,
      jsonb_build_object('group_id', p_group_id, 'enrollment_id', v_enroll)
    );
  end if;
  return p_user_id;
end $$;

create or replace function public.admin_list_groups()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not (
      private.stage13_5_can('groups.write')
      or private.stage13_5_can('students.read')
      or private.stage13_5_can('students.write')
      or private.stage13_5_can('terms.manage')
    ) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'id', g.id,
          'name', g.name,
          'members_count', (
            select count(*) from public.student_enrollments se
            where se.group_id = g.id and se.status = 'active' and se.ended_at is null
          )
        ) order by g.name)
        from public.groups g
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_upsert_group(p_id uuid default null, p_name text default '')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_norm text;
begin
  if not private.stage13_5_can('groups.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if btrim(p_name) = '' then raise exception 'invalid_group' using errcode = '22023'; end if;
  v_norm := lower(regexp_replace(btrim(p_name), '\s+', ' ', 'g'));
  if p_id is null then
    if exists (select 1 from public.groups where lower(regexp_replace(btrim(name), '\s+', ' ', 'g')) = v_norm) then
      raise exception 'duplicate_group_name' using errcode = '23505';
    end if;
    insert into public.groups(name) values (btrim(p_name)) returning id into v_id;
    perform public.admin_ensure_group_space_for_group(v_id);
  else
    update public.groups set name = btrim(p_name) where id = p_id returning id into v_id;
    if v_id is null then raise exception 'group_not_found' using errcode = 'P0002'; end if;
  end if;
  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit('group.upsert', 'group', v_id::text, jsonb_build_object('name', p_name));
  end if;
  return v_id;
end $$;

create or replace function public.admin_list_terms()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not (
      private.stage13_5_can('terms.manage')
      or private.stage13_5_can('academic.read')
      or private.stage13_5_can('students.read')
    ) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'academic_year_id', t.academic_year_id,
          'name', coalesce(t.name, ay.name || ' · ' || t.term_in_year::text),
          'term_in_year', t.term_in_year,
          'is_current', coalesce(t.is_current, false),
          'starts_on', t.starts_on,
          'ends_on', t.ends_on,
          'year_name', ay.name
        ) order by t.term_sequence nulls last, t.starts_on nulls last)
        from public.academic_terms t
        left join public.academic_years ay on ay.id = t.academic_year_id
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_set_current_term(p_term_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if not private.stage13_5_can('terms.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_terms where id = p_term_id) then
    raise exception 'term_not_found' using errcode = 'P0002';
  end if;
  -- Trigger archives previous academic chats; group_space remains.
  update public.academic_terms set is_current = false where is_current is distinct from false;
  update public.academic_terms set is_current = true where id = p_term_id;
  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit('term.set_current', 'academic_term', p_term_id::text, '{}'::jsonb);
  end if;
  return p_term_id;
end $$;

-- Dry-run: count missing offerings/teams for active groups in target term.
create or replace function public.admin_prepare_term_dry_run(p_term_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_year uuid;
  v_semester integer;
  missing_offerings integer := 0;
  missing_teams integer := 0;
  groups_count integer := 0;
  items jsonb := '[]'::jsonb;
begin
  if not private.stage13_5_can('terms.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select academic_year_id, term_in_year into v_year, v_semester
  from public.academic_terms where id = p_term_id;
  if v_year is null then raise exception 'term_not_found' using errcode = 'P0002'; end if;

  select count(*) into groups_count
  from public.groups g
  where exists (
    select 1 from public.student_enrollments se
    where se.group_id = g.id and se.status = 'active' and se.ended_at is null
  );

  if to_regclass('public.curriculum_subjects') is not null
     and to_regclass('public.subject_offerings') is not null then
    select count(*) into missing_offerings
    from public.groups g
    join public.curriculum_subjects cs
      on cs.semester_number = coalesce(
        (
          select gts.semester_number from public.group_term_semesters gts
          where gts.group_id = g.id and gts.academic_term_id = p_term_id
          limit 1
        ),
        v_semester
      )
    where exists (
      select 1 from public.student_enrollments se
      where se.group_id = g.id and se.status = 'active' and se.ended_at is null
    )
      and not exists (
        select 1 from public.subject_offerings so
        where so.group_id = g.id
          and so.subject_id = cs.subject_id
          and so.academic_term_id = p_term_id
      );

    select count(*) into missing_teams
    from public.subject_offerings so
    where so.academic_term_id = p_term_id
      and so.status = 'active'
      and not exists (
        select 1 from public.teams t where t.subject_offering_id = so.id
      );
  end if;

  items := jsonb_build_array(
    jsonb_build_object('kind', 'groups_with_students', 'count', groups_count),
    jsonb_build_object('kind', 'missing_offerings', 'count', missing_offerings),
    jsonb_build_object('kind', 'missing_teams', 'count', missing_teams)
  );
  return jsonb_build_object(
    'term_id', p_term_id,
    'academic_year_id', v_year,
    'items', items,
    'missing_offerings', missing_offerings,
    'missing_teams', missing_teams,
    'groups_count', groups_count
  );
end $$;

create or replace function public.admin_prepare_term_apply(p_term_id uuid, p_set_current boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  dry jsonb;
  v_payload_hash text;
  b uuid;
  created_offerings integer := 0;
  created_teams integer := 0;
  synced_spaces integer := 0;
  v_year uuid;
  v_semester integer;
  g record;
  cs record;
  so_id uuid;
begin
  if not private.stage13_5_can('terms.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  dry := public.admin_prepare_term_dry_run(p_term_id);
  -- Stable intent hash (not dry-run counts, which change after apply).
  v_payload_hash := md5(
    p_term_id::text || ':set_current=' || coalesce(p_set_current, false)::text || ':term_prepare:v1'
  );
  select tb.id into b from public.admin_term_ops_batches tb
  where tb.created_by = auth.uid() and tb.operation = 'term_prepare'
    and tb.status = 'applied' and tb.payload_hash = v_payload_hash
  order by tb.created_at desc limit 1;
  if b is not null then
    return jsonb_build_object('batch_id', b, 'idempotent_replay', true,
      'summary', (select summary from public.admin_term_ops_batches where id = b));
  end if;

  begin
    insert into public.admin_term_ops_batches(created_by, operation, status, payload_hash, summary)
    values (auth.uid(), 'term_prepare', 'applied', v_payload_hash,
            dry || jsonb_build_object('payload_hash', v_payload_hash))
    returning id into b;
  exception when unique_violation then
    select tb.id into b from public.admin_term_ops_batches tb
    where tb.created_by = auth.uid() and tb.operation = 'term_prepare'
      and tb.status = 'applied' and tb.payload_hash = v_payload_hash
    order by tb.created_at desc limit 1;
    return jsonb_build_object('batch_id', b, 'idempotent_replay', true,
      'summary', (select summary from public.admin_term_ops_batches where id = b));
  end;

  select academic_year_id, term_in_year into v_year, v_semester
  from public.academic_terms where id = p_term_id;

  if to_regclass('public.curriculum_subjects') is not null then
    for g in
      select gr.id, gr.name
      from public.groups gr
      where exists (
        select 1 from public.student_enrollments se
        where se.group_id = gr.id and se.status = 'active' and se.ended_at is null
      )
    loop
      for cs in
        select *
        from public.curriculum_subjects csub
        where csub.semester_number = coalesce(
          (
            select gts.semester_number from public.group_term_semesters gts
            where gts.group_id = g.id and gts.academic_term_id = p_term_id
            limit 1
          ),
          v_semester
        )
      loop
        select so.id into so_id
        from public.subject_offerings so
        where so.group_id = g.id and so.subject_id = cs.subject_id
          and so.academic_term_id = p_term_id
        limit 1;
        if so_id is null then
          insert into public.subject_offerings(
            subject_id, curriculum_subject_id, group_id, academic_year_id,
            academic_term_id, semester_number, display_name, status
          ) values (
            cs.subject_id, cs.id, g.id, v_year, p_term_id, cs.semester_number,
            coalesce(cs.display_name, cs.raw_subject_name, 'Предмет'), 'active'
          )
          on conflict do nothing
          returning id into so_id;
          if so_id is not null then created_offerings := created_offerings + 1; end if;
          if so_id is null then
            select so.id into so_id from public.subject_offerings so
            where so.group_id = g.id and so.subject_id = cs.subject_id
              and so.academic_term_id = p_term_id limit 1;
          end if;
        end if;
        if so_id is not null and not exists (
          select 1 from public.teams t where t.subject_offering_id = so_id
        ) then
          insert into public.teams(
            name, description, teacher, icon, group_name, group_id, subject_id,
            subject_offering_id, academic_year_id, academic_term_id, semester_number, kind
          )
          select coalesce(so.display_name, 'Предмет'), '', '', '', null, so.group_id, so.subject_id,
                 so.id, so.academic_year_id, so.academic_term_id, so.semester_number, 'subject'
          from public.subject_offerings so where so.id = so_id;
          created_teams := created_teams + 1;
        end if;
      end loop;
      perform public.admin_ensure_group_space_for_group(g.id);
      synced_spaces := synced_spaces + 1;
    end loop;
  end if;

  if p_set_current then
    perform public.admin_set_current_term(p_term_id);
  end if;

  update public.admin_term_ops_batches
  set summary = dry || jsonb_build_object(
    'payload_hash', v_payload_hash,
    'created_offerings', created_offerings,
    'created_teams', created_teams,
    'synced_group_spaces', synced_spaces,
    'set_current', p_set_current
  )
  where id = b;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'term.prepare_apply', 'academic_term', p_term_id::text,
      jsonb_build_object(
        'batch_id', b,
        'created_offerings', created_offerings,
        'created_teams', created_teams,
        'set_current', p_set_current
      )
    );
  end if;

  return jsonb_build_object(
    'batch_id', b,
    'idempotent_replay', false,
    'created_offerings', created_offerings,
    'created_teams', created_teams,
    'synced_group_spaces', synced_spaces,
    'set_current', p_set_current
  );
end $$;

-- Profile-only student import for existing auth users (by login). No auth.create.
create or replace function public.admin_student_import_dry_run(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r jsonb;
  n integer := 0;
  c text;
  err text;
  match_id uuid;
  out_rows jsonb := '[]'::jsonb;
  login_norm text;
  seen text[] := '{}';
  gcount integer := 0;
begin
  if not private.stage13_5_can('students.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    n := n + 1;
    login_norm := lower(btrim(coalesce(r->>'login', '')));
    match_id := null; c := null; err := null; gcount := 0;
    if login_norm = '' then
      c := 'error'; err := 'login_required';
    elsif login_norm = any(seen) then
      c := 'duplicate'; err := 'duplicate_in_file';
    else
      select u.id into match_id from public.users u
      where lower(u.login) = login_norm
        and private.stage13_5_is_student_account(u.id)
      limit 1;
      if match_id is null then
        if exists (select 1 from public.users u where lower(u.login) = login_norm) then
          c := 'error'; err := 'not_a_student';
        else
          c := 'error'; err := 'auth_user_missing';
        end if;
      elsif nullif(btrim(r->>'group_name'), '') is not null then
        select count(*) into gcount from public.groups g
        where lower(regexp_replace(btrim(g.name), '\s+', ' ', 'g')) =
              lower(regexp_replace(btrim(r->>'group_name'), '\s+', ' ', 'g'));
        if gcount = 0 then
          c := 'error'; err := 'group_not_found';
        elsif gcount > 1 then
          c := 'duplicate'; err := 'ambiguous_group';
        else
          c := 'update';
        end if;
      else
        c := 'update';
      end if;
    end if;
    out_rows := out_rows || jsonb_build_array(jsonb_build_object(
      'row_number', n, 'classification', c, 'matched_user_id', match_id,
      'error_text', err, 'payload', r
    ));
    if login_norm <> '' then seen := array_append(seen, login_norm); end if;
  end loop;
  return jsonb_build_object('rows', n, 'items', out_rows);
end $$;

create or replace function public.admin_student_import_apply(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  dry jsonb; b uuid; item jsonb; updated integer := 0; errors integer := 0; conflicts integer := 0;
  v_payload_hash text := md5(coalesce(p_rows, '[]'::jsonb)::text);
  matched uuid; group_id uuid;
begin
  if not private.stage13_5_can('students.write') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select tb.id into b from public.admin_term_ops_batches tb
  where tb.created_by = auth.uid() and tb.operation = 'student_import'
    and tb.status = 'applied' and tb.payload_hash = v_payload_hash
  order by tb.created_at desc limit 1;
  if b is not null then
    return jsonb_build_object('batch_id', b, 'idempotent_replay', true,
      'summary', (select summary from public.admin_term_ops_batches where id = b));
  end if;
  dry := public.admin_student_import_dry_run(p_rows);
  begin
    insert into public.admin_term_ops_batches(created_by, operation, status, payload_hash, summary)
    values (auth.uid(), 'student_import', 'applied', v_payload_hash,
            dry || jsonb_build_object('payload_hash', v_payload_hash))
    returning id into b;
  exception when unique_violation then
    select tb.id into b from public.admin_term_ops_batches tb
    where tb.created_by = auth.uid() and tb.operation = 'student_import'
      and tb.status = 'applied' and tb.payload_hash = v_payload_hash
    order by tb.created_at desc limit 1;
    return jsonb_build_object('batch_id', b, 'idempotent_replay', true,
      'summary', (select summary from public.admin_term_ops_batches where id = b));
  end;

  for item in select value from jsonb_array_elements(coalesce(dry->'items', '[]'::jsonb)) loop
    insert into public.admin_term_ops_rows(batch_id, row_number, classification, payload, error_text)
    values (b, (item->>'row_number')::integer, item->>'classification',
            coalesce(item->'payload', '{}'::jsonb), item->>'error_text');
    if item->>'classification' = 'update' then
      matched := nullif(item->>'matched_user_id', '')::uuid;
      perform public.admin_upsert_student_profile(
        matched, item->'payload'->>'name', item->'payload'->>'surname', null
      );
      if nullif(btrim(item->'payload'->>'group_name'), '') is not null then
        select g.id into group_id from public.groups g
        where lower(regexp_replace(btrim(g.name), '\s+', ' ', 'g')) =
              lower(regexp_replace(btrim(item->'payload'->>'group_name'), '\s+', ' ', 'g'))
        limit 1;
        if group_id is not null then
          perform public.admin_assign_student_group(matched, group_id);
        end if;
      end if;
      updated := updated + 1;
    elsif item->>'classification' = 'duplicate' then
      conflicts := conflicts + 1;
    else
      errors := errors + 1;
    end if;
  end loop;

  update public.admin_term_ops_batches
  set summary = dry || jsonb_build_object(
    'payload_hash', v_payload_hash, 'updated', updated, 'conflict', conflicts, 'error', errors
  ) where id = b;

  return jsonb_build_object(
    'batch_id', b, 'idempotent_replay', false, 'updated', updated,
    'conflict', conflicts, 'error', errors
  );
end $$;

create or replace function public.admin_list_term_ops_batches(p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not (
      private.stage13_5_can('terms.manage') or private.stage13_5_can('students.write')
    ) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(to_jsonb(b) order by b.created_at desc)
        from (
          select *
          from public.admin_term_ops_batches x
          where (
              x.operation = 'student_import'
              and private.stage13_5_can('students.write')
            )
            or (
              x.operation = 'term_prepare'
              and private.stage13_5_can('terms.manage')
            )
          order by x.created_at desc
          limit greatest(1, least(coalesce(p_limit, 20), 100))
        ) b
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_list_term_ops_rows(p_batch_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not exists (
      select 1 from public.admin_term_ops_batches b
      where b.id = p_batch_id
        and (
          (b.operation = 'student_import' and private.stage13_5_can('students.write'))
          or (b.operation = 'term_prepare' and private.stage13_5_can('terms.manage'))
        )
    ) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(to_jsonb(r) order by r.row_number)
        from public.admin_term_ops_rows r
        where r.batch_id = p_batch_id
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_bulk_set_student_active(
  p_user_ids uuid[],
  p_is_active boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid;
  ok_ids uuid[] := '{}';
  err_ids uuid[] := '{}';
begin
  if not private.stage13_5_can('students.suspend') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  foreach uid in array coalesce(p_user_ids, '{}'::uuid[]) loop
    begin
      perform public.admin_upsert_student_profile(uid, null, null, p_is_active);
      ok_ids := array_append(ok_ids, uid);
    exception when others then
      err_ids := array_append(err_ids, uid);
    end;
  end loop;
  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'student.bulk_set_active', 'student_batch', null,
      jsonb_build_object('is_active', p_is_active, 'ok', ok_ids, 'error', err_ids)
    );
  end if;
  return jsonb_build_object('ok', ok_ids, 'error', err_ids);
end $$;

revoke all on function
  public.admin_ensure_group_space_for_group(uuid),
  public.admin_list_students(text,uuid,boolean),
  public.admin_upsert_student_profile(uuid,text,text,boolean),
  public.admin_assign_student_group(uuid,uuid),
  public.admin_list_groups(),
  public.admin_upsert_group(uuid,text),
  public.admin_list_terms(),
  public.admin_set_current_term(uuid),
  public.admin_prepare_term_dry_run(uuid),
  public.admin_prepare_term_apply(uuid,boolean),
  public.admin_student_import_dry_run(jsonb),
  public.admin_student_import_apply(jsonb),
  public.admin_list_term_ops_batches(integer),
  public.admin_list_term_ops_rows(uuid),
  public.admin_bulk_set_student_active(uuid[], boolean)
from public, anon;
grant execute on function
  public.admin_ensure_group_space_for_group(uuid),
  public.admin_list_students(text,uuid,boolean),
  public.admin_upsert_student_profile(uuid,text,text,boolean),
  public.admin_assign_student_group(uuid,uuid),
  public.admin_list_groups(),
  public.admin_upsert_group(uuid,text),
  public.admin_list_terms(),
  public.admin_set_current_term(uuid),
  public.admin_prepare_term_dry_run(uuid),
  public.admin_prepare_term_apply(uuid,boolean),
  public.admin_student_import_dry_run(jsonb),
  public.admin_student_import_apply(jsonb),
  public.admin_list_term_ops_batches(integer),
  public.admin_list_term_ops_rows(uuid),
  public.admin_bulk_set_student_active(uuid[], boolean)
to authenticated, service_role;

commit;
