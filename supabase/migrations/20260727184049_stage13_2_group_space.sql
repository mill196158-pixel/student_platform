-- Stage 13.2 — permanent academic group space.
-- LOCAL ONLY. Do not apply to a remote Supabase project from this migration.
-- Assumes the existing teams/chats/team_members/chat_members triggers create
-- team_main chat membership. Verify the legacy stack in a local database first.

begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

alter table public.teams add column if not exists kind text;
update public.teams set kind = 'subject' where kind is null;
alter table public.teams alter column kind set default 'subject';
alter table public.teams alter column kind set not null;
alter table public.teams drop constraint if exists teams_kind_check;
alter table public.teams add constraint teams_kind_check
  check (kind in ('subject', 'group_space'));
create unique index if not exists teams_one_group_space_per_group_idx
  on public.teams (group_id) where kind = 'group_space' and group_id is not null;
alter table public.teams drop constraint if exists teams_group_space_shape_check;
alter table public.teams add constraint teams_group_space_shape_check check (
  kind <> 'group_space' or (
    group_id is not null
    and subject_id is null
    and subject_offering_id is null
    and academic_year_id is null
    and academic_term_id is null
    and semester_number is null
  )
);
-- Team creation is server-controlled; group-space creation happens only in its RPC.
revoke insert on table public.teams from public, anon, authenticated;

-- Safety net for ensure_group_space chat idempotency (may already exist in older stacks).
create unique index if not exists uniq_chats_team_main
  on public.chats (team_id)
  where type = 'team_main';

create table public.group_collections (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete restrict,
  team_id uuid not null references public.teams(id) on delete restrict,
  created_by uuid not null references public.users(id) on delete restrict,
  title text not null check (btrim(title) <> ''),
  description text not null default '',
  purpose text not null default '',
  deadline_at timestamptz null,
  amount_optional numeric null check (amount_optional is null or amount_optional >= 0),
  status text not null default 'open' check (status in ('open', 'closed', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz null,
  constraint group_collections_space_team_unique unique (id, group_id, team_id)
);

create table public.group_collection_contributions (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references public.group_collections(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete restrict,
  participation_status text not null default 'unmarked'
    check (participation_status in ('unmarked', 'joining', 'declined')),
  payment_status text not null default 'unmarked'
    check (payment_status in ('unmarked', 'pending_review', 'confirmed', 'rejected')),
  amount numeric null check (amount is null or amount >= 0),
  comment text not null default '',
  proof_file_id uuid null references public.chat_files(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique (collection_id, user_id)
);

create table public.group_collection_events (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references public.group_collections(id) on delete cascade,
  actor_id uuid null references public.users(id) on delete set null,
  event_type text not null check (btrim(event_type) <> ''),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.group_topic_selections (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete restrict,
  team_id uuid not null references public.teams(id) on delete restrict,
  created_by uuid not null references public.users(id) on delete restrict,
  title text not null check (btrim(title) <> ''),
  description text not null default '',
  deadline_at timestamptz null,
  status text not null default 'open' check (status in ('open', 'closed', 'cancelled')),
  allow_change boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz null
);

create table public.group_topic_options (
  id uuid primary key default gen_random_uuid(),
  selection_id uuid not null references public.group_topic_selections(id) on delete cascade,
  title text not null check (btrim(title) <> ''),
  capacity integer not null check (capacity > 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.group_topic_picks (
  id uuid primary key default gen_random_uuid(),
  selection_id uuid not null references public.group_topic_selections(id) on delete cascade,
  option_id uuid not null references public.group_topic_options(id) on delete restrict,
  user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (selection_id, user_id),
  unique (selection_id, option_id, user_id)
);

create table public.group_topic_events (
  id uuid primary key default gen_random_uuid(),
  selection_id uuid not null references public.group_topic_selections(id) on delete cascade,
  actor_id uuid null references public.users(id) on delete set null,
  event_type text not null check (btrim(event_type) <> ''),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index group_collections_group_status_deadline_idx on public.group_collections(group_id, status, deadline_at);
create index group_collections_team_idx on public.group_collections(team_id);
create index group_collection_contributions_user_idx on public.group_collection_contributions(user_id);
create index group_collection_events_collection_created_idx on public.group_collection_events(collection_id, created_at);
create index group_topic_selections_group_status_deadline_idx on public.group_topic_selections(group_id, status, deadline_at);
create index group_topic_options_selection_sort_idx on public.group_topic_options(selection_id, sort_order, created_at);
create index group_topic_picks_option_idx on public.group_topic_picks(option_id);
create index group_topic_events_selection_created_idx on public.group_topic_events(selection_id, created_at);

alter table public.group_collections enable row level security;
alter table public.group_collections force row level security;
alter table public.group_collection_contributions enable row level security;
alter table public.group_collection_contributions force row level security;
alter table public.group_collection_events enable row level security;
alter table public.group_collection_events force row level security;
alter table public.group_topic_selections enable row level security;
alter table public.group_topic_selections force row level security;
alter table public.group_topic_options enable row level security;
alter table public.group_topic_options force row level security;
alter table public.group_topic_picks enable row level security;
alter table public.group_topic_picks force row level security;
alter table public.group_topic_events enable row level security;
alter table public.group_topic_events force row level security;
revoke all on table public.group_collections, public.group_collection_contributions,
  public.group_collection_events, public.group_topic_selections, public.group_topic_options,
  public.group_topic_picks, public.group_topic_events from public, anon, authenticated;

create or replace function private.current_active_group_id()
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_group_id uuid; v_count integer;
begin
  if auth.uid() is null then return null; end if;
  select count(distinct se.group_id) into v_count from public.student_enrollments se
   where se.user_id = auth.uid() and se.status = 'active' and se.ended_at is null;
  if v_count = 0 then return null; end if;
  select se.group_id into v_group_id from public.student_enrollments se
   join public.users u on u.id = se.user_id
   where se.user_id = auth.uid() and se.status = 'active' and se.ended_at is null
   order by (se.group_id = u.primary_group_id) desc, se.started_at desc nulls last limit 1;
  return v_group_id;
end $$;

create or replace function private.group_space_team_id(p_group_id uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select t.id from public.teams t
  where t.group_id = p_group_id and t.kind = 'group_space' limit 1;
$$;

create or replace function private.is_group_space_member(p_group_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.team_members tm
    join public.teams t on t.id = tm.team_id
    join public.student_enrollments se on se.user_id = tm.user_id and se.group_id = t.group_id
    where t.group_id = p_group_id and t.kind = 'group_space' and tm.user_id = auth.uid()
      and se.status = 'active' and se.ended_at is null
  );
$$;

-- Live audit (2026-07-27, project gwdanmwluhrcfxbnplwd, read-only):
--   users.role: all 'student' (no live starosta values)
--   team_members.role: all 'member' (subject/team starosta unused in data)
--   admin_role_assignments: only super_admin (RBAC ≠ group organizer)
-- Authoritative organizer sources:
--   1) subject-team team_members.role in (starosta, owner) for same group_id
--   2) admin grant via set_group_space_organizer -> source='admin'
-- users.role is NOT used in authorization or ongoing sync (one-time backfill only).
create table if not exists public.group_space_organizer_grants (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  source text not null check (source in ('admin', 'subject_team')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (group_id, user_id, source)
);
create index if not exists group_space_organizer_grants_user_idx
  on public.group_space_organizer_grants (user_id);
alter table public.group_space_organizer_grants enable row level security;
alter table public.group_space_organizer_grants force row level security;
revoke all on table public.group_space_organizer_grants from public, anon, authenticated;

-- Active subject teams only (current/active offerings). Archived/historical
-- semester teams must not keep granting group-space organizer powers.
create or replace function private.is_active_subject_team_for_group(
  p_team_id uuid,
  p_group_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.teams t
    left join public.subject_offerings so on so.id = t.subject_offering_id
    left join public.academic_terms at
      on at.id = coalesce(t.academic_term_id, so.academic_term_id)
    where t.id = p_team_id
      and t.group_id = p_group_id
      and coalesce(t.kind, 'subject') = 'subject'
      and (
        (so.id is not null and so.status = 'active')
        or (so.id is null and coalesce(at.is_current, false))
      )
      and not exists (
        select 1
        from public.chats c
        join public.chat_academic_archives a on a.chat_id = c.id
        where c.team_id = t.id
          and c.type = 'team_main'
      )
  );
$$;
revoke all on function private.is_active_subject_team_for_group(uuid, uuid)
  from public, anon, authenticated;

create or replace function private.refresh_group_space_organizer_grants(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_group_id is null then
    return;
  end if;

  -- Rebuild subject-team source; preserve durable admin grants.
  delete from public.group_space_organizer_grants g
  where g.group_id = p_group_id
    and g.source = 'subject_team';

  insert into public.group_space_organizer_grants(group_id, user_id, source)
  select distinct p_group_id, tm.user_id, 'subject_team'
  from public.team_members tm
  join public.teams t on t.id = tm.team_id
  join public.student_enrollments se
    on se.user_id = tm.user_id
   and se.group_id = p_group_id
   and se.status = 'active'
   and se.ended_at is null
  where t.group_id = p_group_id
    and private.is_active_subject_team_for_group(t.id, p_group_id)
    and tm.role in ('starosta', 'owner')
  on conflict (group_id, user_id, source) do update
    set updated_at = now();
end;
$$;
revoke all on function private.refresh_group_space_organizer_grants(uuid)
  from public, anon, authenticated;

-- Authorization validates current authoritative sources (not a stale cached role).
-- Never users.role and never admin_role_assignments as organizer identity.
create or replace function private.is_group_space_organizer(p_group_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_group_space_member(p_group_id) and (
    exists (
      select 1 from public.group_space_organizer_grants g
      where g.group_id = p_group_id
        and g.user_id = auth.uid()
        and g.source = 'admin'
    )
    or exists (
      select 1 from public.team_members tm
      join public.teams t on t.id = tm.team_id
      where t.group_id = p_group_id
        and private.is_active_subject_team_for_group(t.id, p_group_id)
        and tm.user_id = auth.uid()
        and tm.role in ('starosta', 'owner')
    )
  );
$$;

create or replace function private.is_group_space_admin()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_ok boolean := false;
  v_perm text;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role' then
    return true;
  end if;
  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is null then
    return false;
  end if;
  -- Group-space admin grants are academic membership ops, not content/news RBAC
  -- and not automatic organizer rights for the admin user themselves.
  foreach v_perm in array array['groups.write', 'students.write', 'terms.manage']
  loop
    begin
      execute 'select private.has_admin_permission($1, $2, $3, $4)'
        into v_ok using auth.uid(), v_perm, 'global', null::uuid;
    exception when others then
      v_ok := false;
    end;
    if coalesce(v_ok, false) then
      return true;
    end if;
  end loop;
  return false;
end $$;

revoke all on function private.current_active_group_id(),
  private.group_space_team_id(uuid), private.is_group_space_member(uuid),
  private.is_group_space_organizer(uuid), private.is_group_space_admin()
  from public, anon, authenticated;

create policy group_collections_member_select on public.group_collections for select to authenticated
  using (private.is_group_space_member(group_id));
-- Members see only their own contribution rows; organizers see all in the group.
create policy group_collection_contributions_member_select on public.group_collection_contributions for select to authenticated
  using (
    exists (
      select 1 from public.group_collections c
      where c.id = collection_id
        and private.is_group_space_member(c.group_id)
        and (
          user_id = auth.uid()
          or private.is_group_space_organizer(c.group_id)
        )
    )
  );
create policy group_collection_events_member_select on public.group_collection_events for select to authenticated
  using (exists (select 1 from public.group_collections c where c.id = collection_id and private.is_group_space_member(c.group_id)));
create policy group_topic_selections_member_select on public.group_topic_selections for select to authenticated
  using (private.is_group_space_member(group_id));
create policy group_topic_options_member_select on public.group_topic_options for select to authenticated
  using (exists (select 1 from public.group_topic_selections s where s.id = selection_id and private.is_group_space_member(s.group_id)));
create policy group_topic_picks_member_select on public.group_topic_picks for select to authenticated
  using (exists (select 1 from public.group_topic_selections s where s.id = selection_id and private.is_group_space_member(s.group_id)));
create policy group_topic_events_member_select on public.group_topic_events for select to authenticated
  using (exists (select 1 from public.group_topic_selections s where s.id = selection_id and private.is_group_space_member(s.group_id)));
grant select on public.group_collections, public.group_collection_contributions, public.group_collection_events,
  public.group_topic_selections, public.group_topic_options, public.group_topic_picks, public.group_topic_events to authenticated;

-- Cached group-space team_members.role for UI; auth uses live sources above.
create or replace function private.apply_group_space_cached_roles(p_group_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team uuid;
  v_count integer := 0;
begin
  if p_group_id is null then
    return 0;
  end if;
  v_team := private.group_space_team_id(p_group_id);
  if v_team is null then
    return 0;
  end if;

  insert into public.team_members(team_id, user_id, role)
  select
    v_team,
    se.user_id,
    case
      when exists (
        select 1 from public.group_space_organizer_grants g
        where g.group_id = p_group_id and g.user_id = se.user_id
      )
      or exists (
        select 1 from public.team_members tm
        join public.teams t on t.id = tm.team_id
        where t.group_id = p_group_id
          and private.is_active_subject_team_for_group(t.id, p_group_id)
          and tm.user_id = se.user_id
          and tm.role in ('starosta', 'owner')
      ) then 'starosta'
      else 'member'
    end
  from public.student_enrollments se
  where se.group_id = p_group_id and se.status = 'active' and se.ended_at is null
  on conflict (team_id, user_id) do update
    set role = excluded.role;
  get diagnostics v_count = row_count;

  delete from public.chat_members cm using public.chats c
  where c.id = cm.chat_id and c.team_id = v_team and c.type = 'team_main'
    and not exists (
      select 1 from public.student_enrollments se
      where se.user_id = cm.user_id and se.group_id = p_group_id
        and se.status = 'active' and se.ended_at is null
    );
  delete from public.team_members tm
  where tm.team_id = v_team
    and not exists (
      select 1 from public.student_enrollments se
      where se.user_id = tm.user_id and se.group_id = p_group_id
        and se.status = 'active' and se.ended_at is null
    );
  delete from public.group_space_organizer_grants g
  where g.group_id = p_group_id
    and not exists (
      select 1 from public.student_enrollments se
      where se.user_id = g.user_id and se.group_id = p_group_id
        and se.status = 'active' and se.ended_at is null
    );
  return v_count;
end;
$$;
revoke all on function private.apply_group_space_cached_roles(uuid)
  from public, anon, authenticated;

create or replace function public.sync_group_space_members(p_group_id uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_group uuid := coalesce(p_group_id, private.current_active_group_id());
  v_count integer := 0;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if v_group is null then return 0; end if;
  if v_group <> private.current_active_group_id() and not private.is_group_space_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if private.group_space_team_id(v_group) is null then return 0; end if;

  perform private.refresh_group_space_organizer_grants(v_group);
  v_count := private.apply_group_space_cached_roles(v_group);
  return v_count;
end $$;

-- Keep cached roles fresh when subject-team starosta changes (immediate revoke path).
create or replace function private.trg_subject_team_members_reconcile_group_space()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid := coalesce(new.team_id, old.team_id);
  v_group uuid;
  v_kind text;
begin
  select t.group_id, coalesce(t.kind, 'subject')
    into v_group, v_kind
  from public.teams t
  where t.id = v_team_id;
  if v_group is null or v_kind <> 'subject' then
    return coalesce(new, old);
  end if;
  if private.group_space_team_id(v_group) is null then
    return coalesce(new, old);
  end if;
  perform private.refresh_group_space_organizer_grants(v_group);
  perform private.apply_group_space_cached_roles(v_group);
  return coalesce(new, old);
end;
$$;
revoke all on function private.trg_subject_team_members_reconcile_group_space()
  from public, anon, authenticated;

drop trigger if exists trg_subject_team_members_reconcile_group_space on public.team_members;
create trigger trg_subject_team_members_reconcile_group_space
after insert or update of role, team_id, user_id or delete
on public.team_members
for each row
execute function private.trg_subject_team_members_reconcile_group_space();

create or replace function public.ensure_group_space()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_group uuid := private.current_active_group_id(); v_team uuid; v_chat uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if v_group is null then raise exception 'no_active_group' using errcode = 'P0001'; end if;
  v_team := private.group_space_team_id(v_group);
  if v_team is null then
    insert into public.teams(name, description, teacher, icon, group_id, kind, group_name)
    select 'Пространство группы', '', '', 'groups', v_group, 'group_space', g.name
    from public.groups g
    where g.id = v_group
    on conflict (group_id) where (kind = 'group_space' and group_id is not null) do nothing;
    v_team := private.group_space_team_id(v_group);
  end if;
  if v_team is null then raise exception 'group_space_creation_failed' using errcode = 'P0001'; end if;
  -- Serialize chat creation for this team; unique index uniq_chats_team_main
  -- (created above if missing) is the secondary safety net.
  perform 1 from public.teams t where t.id = v_team for update;
  select c.id into v_chat
  from public.chats c
  where c.team_id = v_team and c.type = 'team_main'
  limit 1;
  if v_chat is null then
    begin
      insert into public.chats(team_id, type)
      values (v_team, 'team_main')
      returning id into v_chat;
    exception
      when unique_violation then
        select c.id into v_chat
        from public.chats c
        where c.team_id = v_team and c.type = 'team_main'
        limit 1;
    end;
  end if;
  perform public.sync_group_space_members(v_group);
  if v_chat is null then
    select c.id into v_chat
    from public.chats c
    where c.team_id = v_team and c.type = 'team_main'
    limit 1;
  end if;
  if v_chat is null then raise exception 'group_space_chat_missing' using errcode = 'P0001'; end if;
  return jsonb_build_object('team_id',v_team,'chat_id',v_chat,'group_id',v_group,'title','Пространство группы','is_organizer',private.is_group_space_organizer(v_group));
end $$;

create or replace function public.get_my_group_space()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_group uuid := private.current_active_group_id(); v_team uuid; v_chat uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  v_team := private.group_space_team_id(v_group);
  if v_group is null or v_team is null then return jsonb_build_object('team_id',null,'chat_id',null,'group_id',v_group,'title',null,'is_organizer',false); end if;
  select id into v_chat from public.chats where team_id=v_team and type='team_main' limit 1;
  return jsonb_build_object('team_id',v_team,'chat_id',v_chat,'group_id',v_group,'title','Пространство группы','is_organizer',private.is_group_space_organizer(v_group));
end $$;

create or replace function public.set_group_space_organizer(p_group_id uuid, p_user_id uuid, p_is_organizer boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_team uuid;
begin
  if not private.is_group_space_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_team := private.group_space_team_id(p_group_id);
  if v_team is null
     or not exists (
       select 1 from public.student_enrollments se
       where se.user_id = p_user_id and se.group_id = p_group_id
         and se.status = 'active' and se.ended_at is null
     )
  then
    raise exception 'invalid_group_member' using errcode = '22023';
  end if;

  if p_is_organizer then
    insert into public.group_space_organizer_grants(group_id, user_id, source)
    values (p_group_id, p_user_id, 'admin')
    on conflict (group_id, user_id, source) do update
      set updated_at = now();
  else
    delete from public.group_space_organizer_grants g
    where g.group_id = p_group_id and g.user_id = p_user_id and g.source = 'admin';
  end if;

  -- Reconcile explicit group-space role from grants (revokes when grant removed
  -- unless another authoritative source remains).
  perform public.sync_group_space_members(p_group_id);
end $$;

create or replace function public.create_group_collection(p_title text, p_description text default '', p_purpose text default '', p_deadline_at timestamptz default null, p_amount_optional numeric default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_group uuid:=private.current_active_group_id(); v_id uuid;
begin if not private.is_group_space_organizer(v_group) then raise exception 'forbidden' using errcode='42501'; end if;
 insert into public.group_collections(group_id,team_id,created_by,title,description,purpose,deadline_at,amount_optional) values(v_group,private.group_space_team_id(v_group),auth.uid(),p_title,coalesce(p_description,''),coalesce(p_purpose,''),p_deadline_at,p_amount_optional) returning id into v_id;
 insert into public.group_collection_events(collection_id,actor_id,event_type,payload) values(v_id,auth.uid(),'created','{}'); return v_id; end $$;

create or replace function public.update_group_collection_status(p_collection_id uuid, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_group uuid; begin select group_id into v_group from public.group_collections where id=p_collection_id for update;
 if not private.is_group_space_organizer(v_group) or p_status not in ('open','closed','cancelled') then raise exception 'forbidden_or_invalid_status' using errcode='42501'; end if;
 update public.group_collections set status=p_status,updated_at=now(),closed_at=case when p_status='open' then null else now() end where id=p_collection_id;
 insert into public.group_collection_events(collection_id,actor_id,event_type,payload) values(p_collection_id,auth.uid(),'status_changed',jsonb_build_object('status',p_status)); end $$;

create or replace function public.upsert_my_collection_contribution(p_collection_id uuid,p_participation_status text default 'unmarked',p_payment_status text default 'unmarked',p_amount numeric default null,p_comment text default '',p_proof_file_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_group uuid; begin select group_id into v_group from public.group_collections where id=p_collection_id and status='open';
 if not private.is_group_space_member(v_group) then raise exception 'forbidden' using errcode='42501'; end if;
 if p_payment_status not in ('unmarked','pending_review') then raise exception 'invalid_payment_status' using errcode='22023'; end if;
 if p_proof_file_id is not null and not exists (
   select 1 from public.chat_files cf join public.chats ch on ch.id=cf.chat_id
   where cf.id=p_proof_file_id and cf.uploaded_by=auth.uid()
     and ch.team_id=private.group_space_team_id(v_group) and ch.type='team_main'
 ) then raise exception 'invalid_proof_file' using errcode='22023'; end if;
 insert into public.group_collection_contributions(collection_id,user_id,participation_status,payment_status,amount,comment,proof_file_id) values(p_collection_id,auth.uid(),p_participation_status,p_payment_status,p_amount,coalesce(p_comment,''),p_proof_file_id)
 on conflict(collection_id,user_id) do update set participation_status=excluded.participation_status,payment_status=excluded.payment_status,amount=excluded.amount,comment=excluded.comment,proof_file_id=excluded.proof_file_id,updated_at=now() returning id into v_id; return v_id; end $$;

create or replace function public.confirm_collection_contribution(p_collection_id uuid,p_user_id uuid,p_payment_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_group uuid;
  v_updated integer;
begin
  select group_id into v_group from public.group_collections where id = p_collection_id for update;
  if not private.is_group_space_organizer(v_group)
     or p_payment_status not in ('confirmed', 'rejected') then
    raise exception 'forbidden_or_invalid_status' using errcode = '42501';
  end if;
  update public.group_collection_contributions
  set payment_status = p_payment_status, updated_at = now()
  where collection_id = p_collection_id and user_id = p_user_id;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'contribution_not_found' using errcode = 'P0002';
  end if;
  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id,
    auth.uid(),
    'payment_reviewed',
    jsonb_build_object('user_id', p_user_id, 'status', p_payment_status)
  );
end $$;

create or replace function public.list_group_collections()
returns setof public.group_collections language sql stable security definer set search_path='' as $$
 select c.* from public.group_collections c where private.is_group_space_member(c.group_id) order by c.status,c.deadline_at nulls last,c.created_at desc;
$$;

create or replace function public.create_topic_selection(p_title text,p_description text default '',p_deadline_at timestamptz default null,p_allow_change boolean default true)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_group uuid:=private.current_active_group_id(); v_id uuid; begin if not private.is_group_space_organizer(v_group) then raise exception 'forbidden' using errcode='42501'; end if;
 insert into public.group_topic_selections(group_id,team_id,created_by,title,description,deadline_at,allow_change) values(v_group,private.group_space_team_id(v_group),auth.uid(),p_title,coalesce(p_description,''),p_deadline_at,p_allow_change) returning id into v_id;
 insert into public.group_topic_events(selection_id,actor_id,event_type,payload) values(v_id,auth.uid(),'created','{}'); return v_id; end $$;

create or replace function public.add_topic_option(p_selection_id uuid,p_title text,p_capacity integer,p_sort_order integer default 0)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_group uuid; begin select group_id into v_group from public.group_topic_selections where id=p_selection_id and status='open' for update;
 if not private.is_group_space_organizer(v_group) then raise exception 'forbidden' using errcode='42501'; end if;
 insert into public.group_topic_options(selection_id,title,capacity,sort_order) values(p_selection_id,p_title,p_capacity,p_sort_order) returning id into v_id; return v_id; end $$;

create or replace function public.pick_topic(p_selection_id uuid,p_option_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_selection public.group_topic_selections%rowtype; v_capacity integer; v_count integer; v_existing uuid;
begin select * into v_selection from public.group_topic_selections where id=p_selection_id for update;
 if not private.is_group_space_member(v_selection.group_id) or v_selection.status<>'open' or (v_selection.deadline_at is not null and v_selection.deadline_at<=now()) then raise exception 'selection_unavailable' using errcode='42501'; end if;
 select capacity into v_capacity from public.group_topic_options where id=p_option_id and selection_id=p_selection_id for update; if v_capacity is null then raise exception 'invalid_option' using errcode='22023'; end if;
 select option_id into v_existing from public.group_topic_picks where selection_id=p_selection_id and user_id=auth.uid() for update;
 if v_existing is not null and (not v_selection.allow_change or v_existing=p_option_id) then if v_existing=p_option_id then return; else raise exception 'pick_change_forbidden' using errcode='42501'; end if; end if;
 select count(*) into v_count from public.group_topic_picks where selection_id=p_selection_id and option_id=p_option_id;
 if v_count>=v_capacity then raise exception 'option_full' using errcode='P0001'; end if;
 if v_existing is not null then delete from public.group_topic_picks where selection_id=p_selection_id and user_id=auth.uid(); end if;
 insert into public.group_topic_picks(selection_id,option_id,user_id) values(p_selection_id,p_option_id,auth.uid());
 insert into public.group_topic_events(selection_id,actor_id,event_type,payload) values(p_selection_id,auth.uid(),'picked',jsonb_build_object('option_id',p_option_id)); end $$;

create or replace function public.cancel_topic_pick(p_selection_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_selection public.group_topic_selections%rowtype;
begin
  select * into v_selection from public.group_topic_selections where id=p_selection_id for update;
  if not private.is_group_space_member(v_selection.group_id)
     or v_selection.status <> 'open'
     or not v_selection.allow_change
     or (v_selection.deadline_at is not null and v_selection.deadline_at <= now()) then
    raise exception 'pick_cancel_forbidden' using errcode = '42501';
  end if;
  delete from public.group_topic_picks
  where selection_id = p_selection_id and user_id = auth.uid();
  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (p_selection_id, auth.uid(), 'cancelled', '{}'::jsonb);
end $$;

create or replace function public.close_topic_selection(p_selection_id uuid,p_status text default 'closed')
returns void language plpgsql security definer set search_path='' as $$
declare v_group uuid; begin select group_id into v_group from public.group_topic_selections where id=p_selection_id for update;
 if not private.is_group_space_organizer(v_group) or p_status not in ('closed','cancelled') then raise exception 'forbidden_or_invalid_status' using errcode='42501'; end if;
 update public.group_topic_selections set status=p_status,closed_at=now(),updated_at=now() where id=p_selection_id;
 insert into public.group_topic_events(selection_id,actor_id,event_type,payload) values(p_selection_id,auth.uid(),'closed',jsonb_build_object('status',p_status)); end $$;

create or replace function public.list_topic_selections()
returns setof public.group_topic_selections language sql stable security definer set search_path='' as $$
 select s.* from public.group_topic_selections s where private.is_group_space_member(s.group_id) order by s.status,s.deadline_at nulls last,s.created_at desc;
$$;

revoke all on function public.sync_group_space_members(uuid), public.ensure_group_space(), public.get_my_group_space(),
 public.set_group_space_organizer(uuid,uuid,boolean), public.create_group_collection(text,text,text,timestamptz,numeric),
 public.update_group_collection_status(uuid,text), public.upsert_my_collection_contribution(uuid,text,text,numeric,text,uuid),
 public.confirm_collection_contribution(uuid,uuid,text), public.list_group_collections(), public.create_topic_selection(text,text,timestamptz,boolean),
 public.add_topic_option(uuid,text,integer,integer), public.pick_topic(uuid,uuid), public.cancel_topic_pick(uuid),
 public.close_topic_selection(uuid,text), public.list_topic_selections() from public, anon;
grant execute on function public.sync_group_space_members(uuid), public.ensure_group_space(), public.get_my_group_space(),
 public.create_group_collection(text,text,text,timestamptz,numeric), public.update_group_collection_status(uuid,text),
 public.upsert_my_collection_contribution(uuid,text,text,numeric,text,uuid), public.confirm_collection_contribution(uuid,uuid,text),
 public.list_group_collections(), public.create_topic_selection(text,text,timestamptz,boolean), public.add_topic_option(uuid,text,integer,integer),
 public.pick_topic(uuid,uuid), public.cancel_topic_pick(uuid), public.close_topic_selection(uuid,text),
 public.list_topic_selections() to authenticated;
grant execute on function public.set_group_space_organizer(uuid,uuid,boolean) to authenticated, service_role;

create or replace function public.archive_academic_chats_for_term(p_academic_term_id uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare v_term public.academic_terms%rowtype; v_now timestamptz:=now(); v_available_until timestamptz; v_count integer:=0;
begin if p_academic_term_id is null then return 0; end if;
 select * into v_term from public.academic_terms at where at.id=p_academic_term_id; if not found or v_term.is_current or v_term.starts_on>(v_now at time zone 'utc')::date then return 0; end if;
 v_available_until:=((v_term.ends_on+interval '12 months')::timestamp at time zone 'utc');
 with candidates as (select c.id chat_id,coalesce(t.subject_offering_id,c.subject_offering_id) subject_offering_id from public.chats c join public.teams t on t.id=c.team_id left join public.subject_offerings so on so.id=coalesce(t.subject_offering_id,c.subject_offering_id) where c.type='team_main' and t.kind<>'group_space' and coalesce(t.academic_term_id,so.academic_term_id)=p_academic_term_id),
 upserted as (insert into public.chat_academic_archives(chat_id,academic_term_id,subject_offering_id,archived_at,available_until) select chat_id,p_academic_term_id,subject_offering_id,v_now,v_available_until from candidates on conflict(chat_id) do update set academic_term_id=excluded.academic_term_id,subject_offering_id=coalesce(public.chat_academic_archives.subject_offering_id,excluded.subject_offering_id),available_until=excluded.available_until,expired_at=null returning 1)
 select count(*)::integer into v_count from upserted; return coalesce(v_count,0); end $$;
revoke all on function public.archive_academic_chats_for_term(uuid) from public, anon, authenticated;
grant execute on function public.archive_academic_chats_for_term(uuid) to service_role;

drop function public.get_my_chat_summaries();
create function public.get_my_chat_summaries()
returns table(chat_id uuid,chat_type text,team_id uuid,team_kind text,team_name text,team_icon text,team_teacher text,team_group_name text,peer_id uuid,title text,avatar_url text,last_message_id uuid,last_message_at timestamptz,last_author_id uuid,last_author_name text,body text,content text,msg_type text,unread_count integer,is_pinned boolean,is_muted boolean,is_archived boolean,hidden_at timestamptz,cleared_at timestamptz,settings_exists boolean)
language plpgsql security definer stable set search_path='' as $$
declare v_me uuid:=auth.uid(); begin if v_me is null then raise exception 'not_authenticated' using errcode='P0001'; end if;
return query with my_teams as (
 select t.id,t.kind,t.name,t.teacher,t.icon,t.group_name from public.teams t join public.team_members tm on tm.team_id=t.id and tm.user_id=v_me
 union select t.id,t.kind,t.name,t.teacher,t.icon,t.group_name from public.teams t join public.users u on u.id=v_me and t.group_name=u.group_name where t.kind='subject'
), accessible as (
 select c.id chat_id,c.type chat_type,c.team_id,null::text team_kind,null::text team_name,null::text team_icon,null::text team_teacher,null::text team_group_name from public.chats c join public.chat_members cm on cm.chat_id=c.id and cm.user_id=v_me where c.type='dm'
 union all select c.id,c.type,c.team_id,mt.kind,mt.name,mt.icon,mt.teacher,mt.group_name from my_teams mt join public.chats c on c.team_id=mt.id and c.type='team_main' where not exists(select 1 from public.chat_academic_archives a where a.chat_id=c.id)
) select a.chat_id,a.chat_type,a.team_id,coalesce(a.team_kind,'subject'),a.team_name,a.team_icon,a.team_teacher,a.team_group_name,peer.peer_id,case when a.chat_type='dm' then coalesce(nullif(trim(peer.title),''),'Пользователь') else coalesce(a.team_name,'') end,case when a.chat_type='dm' then nullif(peer.avatar_url,'') else null end,lm.id,lm.created_at,lm.author_id,case when au.id is null then null else nullif(trim(concat(coalesce(au.name,''),' ',coalesce(au.surname,''))), '') end,lm.body,lm.content,lm.msg_type,coalesce(ur.unread_count,0),coalesce(s.is_pinned,false),coalesce(s.is_muted,false),coalesce(s.is_archived,false),s.hidden_at,s.cleared_at,(s.user_id is not null)
 from accessible a left join lateral(select u.id peer_id,trim(concat(coalesce(u.name,''),' ',coalesce(u.surname,''))) title,coalesce(u.avatar_url,'') avatar_url from public.chat_members cm join public.users u on u.id=cm.user_id where a.chat_type='dm' and cm.chat_id=a.chat_id and cm.user_id<>v_me limit 1) peer on true
 left join lateral(select m.id,m.author_id,m.created_at,m.body,m.content,m.msg_type from public.messages m where m.chat_id=a.chat_id order by m.created_at desc limit 1) lm on true left join public.users au on au.id=lm.author_id
 left join lateral(select count(*)::integer unread_count from public.messages m where m.chat_id=a.chat_id and m.author_id<>v_me and m.created_at>coalesce((select cr.last_read_at from public.chat_reads cr where cr.chat_id=a.chat_id and cr.user_id=v_me limit 1),to_timestamp(0))) ur on true
 left join public.chat_user_settings s on s.user_id=v_me and s.chat_id=a.chat_id order by coalesce(s.is_pinned,false) desc,lm.created_at desc nulls last; end $$;
revoke all on function public.get_my_chat_summaries() from public, anon;
grant execute on function public.get_my_chat_summaries() to authenticated;

do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  alter publication supabase_realtime add table public.group_topic_picks, public.group_collections, public.group_collection_contributions;
 end if;
exception when duplicate_object then null; end $$;

-- One-time migration backfill only: convert legacy users.role='starosta' into durable
-- admin organizer grants. Ongoing refresh/auth never read users.role.
insert into public.group_space_organizer_grants(group_id, user_id, source)
select distinct se.group_id, u.id, 'admin'
from public.users u
join public.student_enrollments se
  on se.user_id = u.id
 and se.status = 'active'
 and se.ended_at is null
where u.role = 'starosta'
on conflict (group_id, user_id, source) do nothing;

commit;
