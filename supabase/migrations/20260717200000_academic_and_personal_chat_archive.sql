-- Stage 10: unified chat archive (academic term archive + personal DM archive).
-- Chain: subject_offering → team → chat(team_main) → academic_term.
-- Do not apply from this agent session; file is for review / later apply.

-- ---------------------------------------------------------------------------
-- 1) Academic archive metadata (server-owned; not per-user)
-- ---------------------------------------------------------------------------
create table if not exists public.chat_academic_archives (
  chat_id uuid primary key references public.chats(id) on delete cascade,
  academic_term_id uuid not null references public.academic_terms(id) on delete restrict,
  subject_offering_id uuid null references public.subject_offerings(id) on delete set null,
  archived_at timestamptz not null default pg_catalog.now(),
  available_until timestamptz not null,
  expired_at timestamptz null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint chat_academic_archives_available_after_archived
    check (available_until >= archived_at)
);

create index if not exists chat_academic_archives_term_idx
  on public.chat_academic_archives (academic_term_id);

create index if not exists chat_academic_archives_available_until_idx
  on public.chat_academic_archives (available_until)
  where expired_at is null;

comment on table public.chat_academic_archives is
  'Server archive of completed-semester team_main chats. Retention = academic_term.ends_on + 12 months.';

alter table public.chat_academic_archives enable row level security;

revoke all privileges on table public.chat_academic_archives from public;
revoke all privileges on table public.chat_academic_archives from anon;
revoke all privileges on table public.chat_academic_archives from authenticated;
-- Authenticated reads only via SECURITY DEFINER RPCs (no direct SELECT grant).

-- ---------------------------------------------------------------------------
-- 2) External file cleanup queue (Yandex Object Storage — worker is next substage)
-- ---------------------------------------------------------------------------
create table if not exists public.chat_file_cleanup_queue (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  chat_file_id uuid not null references public.chat_files(id) on delete cascade,
  file_key text not null,
  file_url text null,
  file_name text null,
  status text not null default 'pending',
  marked_at timestamptz not null default pg_catalog.now(),
  processed_at timestamptz null,
  error_text text null,
  constraint chat_file_cleanup_queue_status_check
    check (status in ('pending', 'processing', 'done', 'failed')),
  constraint chat_file_cleanup_queue_file_unique unique (chat_file_id)
);

create index if not exists chat_file_cleanup_queue_status_idx
  on public.chat_file_cleanup_queue (status, marked_at);

comment on table public.chat_file_cleanup_queue is
  'Marks chat_files for external object deletion. SQL never deletes Yandex objects; worker/Edge Function does.';

alter table public.chat_file_cleanup_queue enable row level security;

revoke all privileges on table public.chat_file_cleanup_queue from public;
revoke all privileges on table public.chat_file_cleanup_queue from anon;
revoke all privileges on table public.chat_file_cleanup_queue from authenticated;

-- ---------------------------------------------------------------------------
-- 3) Helpers: resolve term for team_main chat; read-only / writable checks
-- ---------------------------------------------------------------------------
create or replace function public.academic_term_id_for_chat(p_chat_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    t.academic_term_id,
    so_team.academic_term_id,
    so_chat.academic_term_id
  )
  from public.chats c
  left join public.teams t on t.id = c.team_id
  left join public.subject_offerings so_team on so_team.id = t.subject_offering_id
  left join public.subject_offerings so_chat on so_chat.id = c.subject_offering_id
  where c.id = p_chat_id
    and c.type = 'team_main'
  limit 1;
$function$;

revoke all on function public.academic_term_id_for_chat(uuid) from public;
revoke all on function public.academic_term_id_for_chat(uuid) from anon;
revoke all on function public.academic_term_id_for_chat(uuid) from authenticated;

create or replace function public.is_academic_chat_read_only(p_chat_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  -- Any archive row (including expired) stays permanently read-only.
  select exists (
    select 1
    from public.chat_academic_archives a
    where a.chat_id = p_chat_id
  );
$function$;

revoke all on function public.is_academic_chat_read_only(uuid) from public;
revoke all on function public.is_academic_chat_read_only(uuid) from anon;
revoke all on function public.is_academic_chat_read_only(uuid) from authenticated;

create or replace function public.assert_academic_chat_writable(p_chat_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  -- service_role may perform system maintenance
  if coalesce((select auth.jwt() ->> 'role'), '') = 'service_role' then
    return;
  end if;

  if public.is_academic_chat_read_only(p_chat_id) then
    raise exception using
      errcode = 'P0001',
      message = 'academic_chat_archived';
  end if;
end;
$function$;

revoke all on function public.assert_academic_chat_writable(uuid) from public;
revoke all on function public.assert_academic_chat_writable(uuid) from anon;
revoke all on function public.assert_academic_chat_writable(uuid) from authenticated;

-- ---------------------------------------------------------------------------
-- 4) Idempotent archive of team_main chats for a completed academic_term
-- ---------------------------------------------------------------------------
create or replace function public.archive_academic_chats_for_term(p_academic_term_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_term public.academic_terms%rowtype;
  v_now timestamptz := pg_catalog.now();
  v_available_until timestamptz;
  v_count integer := 0;
begin
  if p_academic_term_id is null then
    return 0;
  end if;

  select * into v_term
  from public.academic_terms at
  where at.id = p_academic_term_id;

  if not found then
    return 0;
  end if;

  -- Never archive current or future terms.
  if v_term.is_current then
    return 0;
  end if;
  if v_term.starts_on > (v_now at time zone 'utc')::date then
    return 0;
  end if;

  v_available_until := ((v_term.ends_on + interval '12 months')::timestamp
    at time zone 'utc');

  with candidates as (
    select
      c.id as chat_id,
      coalesce(t.subject_offering_id, c.subject_offering_id) as subject_offering_id
    from public.chats c
    join public.teams t on t.id = c.team_id
    left join public.subject_offerings so on so.id = coalesce(
      t.subject_offering_id,
      c.subject_offering_id
    )
    where c.type = 'team_main'
      and coalesce(t.academic_term_id, so.academic_term_id) = p_academic_term_id
  ),
  upserted as (
    insert into public.chat_academic_archives (
      chat_id,
      academic_term_id,
      subject_offering_id,
      archived_at,
      available_until
    )
    select
      cand.chat_id,
      p_academic_term_id,
      cand.subject_offering_id,
      v_now,
      v_available_until
    from candidates cand
    on conflict (chat_id) do update
      set
        academic_term_id = excluded.academic_term_id,
        subject_offering_id = coalesce(
          public.chat_academic_archives.subject_offering_id,
          excluded.subject_offering_id
        ),
        -- Keep first archived_at; refresh available_until from term ends_on.
        available_until = excluded.available_until,
        expired_at = null
    returning 1
  )
  select count(*)::integer into v_count from upserted;

  return coalesce(v_count, 0);
end;
$function$;

revoke all on function public.archive_academic_chats_for_term(uuid) from public;
revoke all on function public.archive_academic_chats_for_term(uuid) from anon;
revoke all on function public.archive_academic_chats_for_term(uuid) from authenticated;
grant execute on function public.archive_academic_chats_for_term(uuid) to service_role;

create or replace function public.archive_completed_academic_chats()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_term_id uuid;
  v_total integer := 0;
  v_n integer;
  v_now_date date := (pg_catalog.now() at time zone 'utc')::date;
begin
  for v_term_id in
    select at.id
    from public.academic_terms at
    where at.is_current = false
      and at.starts_on <= v_now_date
      and (
        exists (
          select 1 from public.academic_terms cur
          where cur.is_current = true
            and cur.term_sequence > at.term_sequence
        )
        or at.ends_on < v_now_date
      )
  loop
    v_n := public.archive_academic_chats_for_term(v_term_id);
    v_total := v_total + coalesce(v_n, 0);
  end loop;

  return v_total;
end;
$function$;

revoke all on function public.archive_completed_academic_chats() from public;
revoke all on function public.archive_completed_academic_chats() from anon;
revoke all on function public.archive_completed_academic_chats() from authenticated;
grant execute on function public.archive_completed_academic_chats() to service_role;

-- Expire user-visible archive rows and enqueue file cleanup metadata.
-- Does NOT delete external Yandex objects.
create or replace function public.expire_academic_chat_archives()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := pg_catalog.now();
  v_expired integer := 0;
begin
  with due as (
    select a.chat_id
    from public.chat_academic_archives a
    join public.academic_terms at on at.id = a.academic_term_id
    where a.expired_at is null
      and a.available_until <= v_now
      -- Never expire current/future terms even if dates were wrong.
      and at.is_current = false
      and at.starts_on <= (v_now at time zone 'utc')::date
  ),
  marked as (
    update public.chat_academic_archives a
    set expired_at = v_now
    from due
    where a.chat_id = due.chat_id
    returning a.chat_id
  ),
  enqueued as (
    insert into public.chat_file_cleanup_queue (
      chat_id,
      chat_file_id,
      file_key,
      file_url,
      file_name,
      status,
      marked_at
    )
    select
      cf.chat_id,
      cf.id,
      cf.file_key::text,
      cf.file_url::text,
      cf.file_name::text,
      'pending',
      v_now
    from public.chat_files cf
    join marked m on m.chat_id = cf.chat_id
    on conflict (chat_file_id) do nothing
    returning 1
  )
  select count(*)::integer into v_expired from marked;

  -- Enqueue only; worker deletes the Yandex object, then clears chat_files metadata.
  perform (select count(*) from enqueued);

  return coalesce(v_expired, 0);
end;
$function$;

revoke all on function public.expire_academic_chat_archives() from public;
revoke all on function public.expire_academic_chat_archives() from anon;
revoke all on function public.expire_academic_chat_archives() from authenticated;
grant execute on function public.expire_academic_chat_archives() to service_role;

-- Trigger: when a term becomes current, archive previous completed terms.
create or replace function public.trg_fn_academic_terms_archive_previous()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if tg_op = 'UPDATE'
     and new.is_current = true
     and coalesce(old.is_current, false) = false then
    perform public.archive_completed_academic_chats();
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_academic_terms_archive_previous on public.academic_terms;
create trigger trg_academic_terms_archive_previous
after update of is_current on public.academic_terms
for each row
execute function public.trg_fn_academic_terms_archive_previous();

-- ---------------------------------------------------------------------------
-- 5) Server-wide write guard (cannot bypass via other RPCs that INSERT/UPDATE/DELETE)
-- ---------------------------------------------------------------------------
create or replace function public.trg_fn_block_archived_academic_message_writes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_chat_id uuid;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') = 'service_role' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    v_chat_id := old.chat_id;
  else
    v_chat_id := new.chat_id;
  end if;

  perform public.assert_academic_chat_writable(v_chat_id);

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_messages_block_archived_academic on public.messages;
create trigger trg_messages_block_archived_academic
before insert or update or delete on public.messages
for each row
execute function public.trg_fn_block_archived_academic_message_writes();

create or replace function public.trg_fn_block_archived_academic_reaction_writes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_chat_id uuid;
  v_message_id uuid;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') = 'service_role' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    v_message_id := old.message_id;
  else
    v_message_id := new.message_id;
  end if;

  select m.chat_id into v_chat_id
  from public.messages m
  where m.id = v_message_id
  limit 1;

  if v_chat_id is not null then
    perform public.assert_academic_chat_writable(v_chat_id);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_message_reactions_block_archived_academic
  on public.message_reactions;
create trigger trg_message_reactions_block_archived_academic
before insert or update or delete on public.message_reactions
for each row
execute function public.trg_fn_block_archived_academic_reaction_writes();

-- Block any authenticated write to chat_files of an archived academic chat.
create or replace function public.trg_fn_block_archived_academic_chat_file_writes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_chat_id uuid;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') = 'service_role' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    v_chat_id := old.chat_id;
  else
    v_chat_id := new.chat_id;
  end if;

  perform public.assert_academic_chat_writable(v_chat_id);

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_chat_files_block_archived_academic on public.chat_files;
create trigger trg_chat_files_block_archived_academic
before insert or update or delete on public.chat_files
for each row
execute function public.trg_fn_block_archived_academic_chat_file_writes();

-- ---------------------------------------------------------------------------
-- 6) Personal DM archive / hide RPCs (use existing chat_user_settings)
-- ---------------------------------------------------------------------------
create or replace function public.set_personal_chat_archived(
  p_chat_id uuid,
  p_archived boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  if p_chat_id is null then
    raise exception using errcode = 'P0001', message = 'chat_not_found';
  end if;

  if not exists (
    select 1
    from public.chats c
    join public.chat_members cm
      on cm.chat_id = c.id
     and cm.user_id = v_me
    where c.id = p_chat_id
      and c.type = 'dm'
  ) then
    raise exception using errcode = 'P0001', message = 'forbidden';
  end if;

  insert into public.chat_user_settings as s (
    user_id, chat_id, is_archived, updated_at
  ) values (
    v_me, p_chat_id, coalesce(p_archived, false), pg_catalog.now()
  )
  on conflict (user_id, chat_id) do update
    set
      is_archived = coalesce(p_archived, false),
      updated_at = pg_catalog.now()
    where s.is_archived is distinct from coalesce(p_archived, false);
end;
$function$;

revoke all on function public.set_personal_chat_archived(uuid, boolean) from public;
revoke all on function public.set_personal_chat_archived(uuid, boolean) from anon;
grant execute on function public.set_personal_chat_archived(uuid, boolean) to authenticated;

create or replace function public.hide_personal_chat_for_me(p_chat_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_me uuid := (select auth.uid());
  v_now timestamptz := pg_catalog.now();
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  if p_chat_id is null then
    raise exception using errcode = 'P0001', message = 'chat_not_found';
  end if;

  if not exists (
    select 1
    from public.chats c
    join public.chat_members cm
      on cm.chat_id = c.id
     and cm.user_id = v_me
    where c.id = p_chat_id
      and c.type = 'dm'
  ) then
    raise exception using errcode = 'P0001', message = 'forbidden';
  end if;

  insert into public.chat_user_settings as s (
    user_id, chat_id, hidden_at, cleared_at, is_archived, updated_at
  ) values (
    v_me, p_chat_id, v_now, v_now, false, v_now
  )
  on conflict (user_id, chat_id) do update
    set
      hidden_at = v_now,
      cleared_at = v_now,
      is_archived = false,
      updated_at = v_now;
end;
$function$;

revoke all on function public.hide_personal_chat_for_me(uuid) from public;
revoke all on function public.hide_personal_chat_for_me(uuid) from anon;
grant execute on function public.hide_personal_chat_for_me(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7) Active list: get_my_chat_summaries (exclude personal archive + academic archive)
-- ---------------------------------------------------------------------------
create or replace function public.get_my_chat_summaries()
returns table (
  chat_id uuid,
  chat_type text,
  team_id uuid,
  team_name text,
  team_icon text,
  team_teacher text,
  team_group_name text,
  peer_id uuid,
  title text,
  avatar_url text,
  last_message_id uuid,
  last_message_at timestamptz,
  last_author_id uuid,
  last_author_name text,
  body text,
  content text,
  msg_type text,
  unread_count integer,
  is_pinned boolean,
  is_muted boolean,
  is_archived boolean,
  hidden_at timestamptz,
  cleared_at timestamptz,
  settings_exists boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  return query
  with me as (
    select u.id, u.group_name
    from public.users u
    where u.id = v_me
    limit 1
  ),
  my_teams as (
    select t.id, t.name, t.teacher, t.icon, t.group_name
    from public.teams t
    join public.team_members tm on tm.team_id = t.id
    join me on tm.user_id = me.id
    union
    select t.id, t.name, t.teacher, t.icon, t.group_name
    from public.teams t
    join me on t.group_name = me.group_name
  ),
  accessible as (
    select
      c.id as chat_id,
      c.type as chat_type,
      c.team_id,
      null::text as team_name,
      null::text as team_icon,
      null::text as team_teacher,
      null::text as team_group_name
    from public.chats c
    join public.chat_members cm
      on cm.chat_id = c.id
     and cm.user_id = v_me
    where c.type = 'dm'

    union all

    select
      c.id as chat_id,
      c.type as chat_type,
      c.team_id,
      mt.name as team_name,
      mt.icon as team_icon,
      mt.teacher as team_teacher,
      mt.group_name as team_group_name
    from my_teams mt
    join public.chats c
      on c.team_id = mt.id
     and c.type = 'team_main'
    where not exists (
      select 1
      from public.chat_academic_archives a
      where a.chat_id = c.id
    )
  ),
  base as (
    select
      a.chat_id,
      a.chat_type,
      a.team_id,
      a.team_name,
      a.team_icon,
      a.team_teacher,
      a.team_group_name,
      peer.peer_id,
      case
        when a.chat_type = 'dm' then
          coalesce(nullif(trim(peer.title), ''), 'Личный чат')
        else
          coalesce(a.team_name, '')
      end as title,
      case
        when a.chat_type = 'dm' then nullif(peer.avatar_url, '')
        else null
      end as avatar_url,
      s.is_pinned,
      s.is_muted,
      s.is_archived,
      s.hidden_at,
      s.cleared_at,
      (s.user_id is not null) as settings_exists,
      coalesce(s.cleared_at, to_timestamp(0)) as cleared_floor
    from accessible a
    left join lateral (
      select
        u.id as peer_id,
        trim(concat(coalesce(u.name, ''), ' ', coalesce(u.surname, ''))) as title,
        coalesce(u.avatar_url, '') as avatar_url
      from public.chat_members cm_peer
      join public.users u on u.id = cm_peer.user_id
      where a.chat_type = 'dm'
        and cm_peer.chat_id = a.chat_id
        and cm_peer.user_id <> v_me
      limit 1
    ) peer on true
    left join public.chat_user_settings s
      on s.user_id = v_me
     and s.chat_id = a.chat_id
    where
      -- Personal archive: hide from active list
      not (a.chat_type = 'dm' and coalesce(s.is_archived, false))
      -- Hide-for-me: stay hidden until a newer message arrives
      and not (
        a.chat_type = 'dm'
        and s.hidden_at is not null
        and not exists (
          select 1
          from public.messages m_new
          where m_new.chat_id = a.chat_id
            and m_new.created_at > s.hidden_at
        )
      )
  )
  select
    b.chat_id,
    b.chat_type,
    b.team_id,
    b.team_name,
    b.team_icon,
    b.team_teacher,
    b.team_group_name,
    b.peer_id,
    b.title,
    b.avatar_url,
    lm.id as last_message_id,
    lm.created_at as last_message_at,
    lm.author_id as last_author_id,
    case
      when au.id is null then null
      else nullif(
        trim(concat(coalesce(au.name, ''), ' ', coalesce(au.surname, ''))),
        ''
      )
    end as last_author_name,
    lm.body,
    lm.content,
    lm.msg_type,
    coalesce(ur.unread_count, 0) as unread_count,
    coalesce(b.is_pinned, false) as is_pinned,
    coalesce(b.is_muted, false) as is_muted,
    coalesce(b.is_archived, false) as is_archived,
    b.hidden_at,
    b.cleared_at,
    b.settings_exists
  from base b
  left join lateral (
    select
      m.id,
      m.author_id,
      m.created_at,
      m.body,
      m.content,
      m.msg_type
    from public.messages m
    where m.chat_id = b.chat_id
      and m.created_at > b.cleared_floor
    order by m.created_at desc
    limit 1
  ) lm on true
  left join public.users au on au.id = lm.author_id
  left join lateral (
    select count(*)::integer as unread_count
    from public.messages m
    where m.chat_id = b.chat_id
      and m.author_id <> v_me
      and m.created_at > b.cleared_floor
      and m.created_at > coalesce(
        (
          select cr.last_read_at
          from public.chat_reads cr
          where cr.chat_id = b.chat_id
            and cr.user_id = v_me
          limit 1
        ),
        to_timestamp(0)
      )
  ) ur on true
  order by
    coalesce(b.is_pinned, false) desc,
    lm.created_at desc nulls last;
end;
$function$;

revoke execute on function public.get_my_chat_summaries() from PUBLIC, anon;
grant execute on function public.get_my_chat_summaries() to authenticated;

-- ---------------------------------------------------------------------------
-- 8) Bulk archive list (academic + personal) — single query, no N+1
-- ---------------------------------------------------------------------------
create or replace function public.get_my_archived_chat_summaries()
returns table (
  chat_id uuid,
  chat_type text,
  archive_type text,
  team_id uuid,
  team_name text,
  team_icon text,
  team_teacher text,
  team_group_name text,
  peer_id uuid,
  title text,
  avatar_url text,
  last_message_id uuid,
  last_message_at timestamptz,
  last_author_id uuid,
  last_author_name text,
  body text,
  content text,
  msg_type text,
  unread_count integer,
  is_pinned boolean,
  is_muted boolean,
  is_archived boolean,
  hidden_at timestamptz,
  cleared_at timestamptz,
  settings_exists boolean,
  semester_label text,
  archived_at timestamptz,
  available_until timestamptz,
  read_only boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := auth.uid();
  v_now timestamptz := pg_catalog.now();
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  return query
  with me as (
    select u.id, u.group_name
    from public.users u
    where u.id = v_me
    limit 1
  ),
  my_teams as (
    select t.id, t.name, t.teacher, t.icon, t.group_name
    from public.teams t
    join public.team_members tm on tm.team_id = t.id
    join me on tm.user_id = me.id
    union
    select t.id, t.name, t.teacher, t.icon, t.group_name
    from public.teams t
    join me on t.group_name = me.group_name
  ),
  academic_rows as (
    select
      c.id as chat_id,
      c.type as chat_type,
      'academic'::text as archive_type,
      c.team_id,
      mt.name as team_name,
      mt.icon as team_icon,
      mt.teacher as team_teacher,
      mt.group_name as team_group_name,
      null::uuid as peer_id,
      coalesce(mt.name, '') as title,
      null::text as avatar_url,
      a.archived_at,
      a.available_until,
      true as read_only,
      case
        when gts.semester_number is not null then
          'Семестр ' || gts.semester_number::text
          || coalesce(' · ' || nullif(trim(at.name), ''), '')
        else
          coalesce(nullif(trim(at.name), ''), 'Завершённый семестр')
      end as semester_label
    from public.chat_academic_archives a
    join public.chats c on c.id = a.chat_id and c.type = 'team_main'
    join my_teams mt on mt.id = c.team_id
    join public.academic_terms at on at.id = a.academic_term_id
    left join public.teams t on t.id = c.team_id
    left join lateral (
      select g.id
      from public.groups g
      where (t.group_id is not null and g.id = t.group_id)
         or (t.group_id is null and t.group_name is not null and g.name = t.group_name)
      limit 1
    ) g on true
    left join public.group_term_semesters gts
      on gts.group_id = coalesce(t.group_id, g.id)
     and gts.academic_term_id = a.academic_term_id
    where a.expired_at is null
      and a.available_until > v_now
  ),
  personal_rows as (
    select
      c.id as chat_id,
      c.type as chat_type,
      'personal'::text as archive_type,
      c.team_id,
      null::text as team_name,
      null::text as team_icon,
      null::text as team_teacher,
      null::text as team_group_name,
      peer.peer_id,
      coalesce(nullif(trim(peer.title), ''), 'Личный чат') as title,
      nullif(peer.avatar_url, '') as avatar_url,
      s.updated_at as archived_at,
      null::timestamptz as available_until,
      false as read_only,
      null::text as semester_label
    from public.chats c
    join public.chat_members cm
      on cm.chat_id = c.id
     and cm.user_id = v_me
    join public.chat_user_settings s
      on s.user_id = v_me
     and s.chat_id = c.id
     and s.is_archived = true
    left join lateral (
      select
        u.id as peer_id,
        trim(concat(coalesce(u.name, ''), ' ', coalesce(u.surname, ''))) as title,
        coalesce(u.avatar_url, '') as avatar_url
      from public.chat_members cm_peer
      join public.users u on u.id = cm_peer.user_id
      where cm_peer.chat_id = c.id
        and cm_peer.user_id <> v_me
      limit 1
    ) peer on true
    where c.type = 'dm'
      and not (
        s.hidden_at is not null
        and not exists (
          select 1
          from public.messages m_new
          where m_new.chat_id = c.id
            and m_new.created_at > s.hidden_at
        )
      )
  ),
  archived as (
    select * from academic_rows
    union all
    select * from personal_rows
  )
  select
    ar.chat_id,
    ar.chat_type,
    ar.archive_type,
    ar.team_id,
    ar.team_name,
    ar.team_icon,
    ar.team_teacher,
    ar.team_group_name,
    ar.peer_id,
    ar.title,
    ar.avatar_url,
    lm.id as last_message_id,
    lm.created_at as last_message_at,
    lm.author_id as last_author_id,
    case
      when au.id is null then null
      else nullif(
        trim(concat(coalesce(au.name, ''), ' ', coalesce(au.surname, ''))),
        ''
      )
    end as last_author_name,
    lm.body,
    lm.content,
    lm.msg_type,
    case
      when ar.archive_type = 'academic' then 0
      else coalesce(ur.unread_count, 0)
    end as unread_count,
    coalesce(s.is_pinned, false) as is_pinned,
    coalesce(s.is_muted, false) as is_muted,
    coalesce(s.is_archived, false) as is_archived,
    s.hidden_at,
    s.cleared_at,
    (s.user_id is not null) as settings_exists,
    ar.semester_label,
    ar.archived_at,
    ar.available_until,
    ar.read_only
  from archived ar
  left join public.chat_user_settings s
    on s.user_id = v_me
   and s.chat_id = ar.chat_id
  left join lateral (
    select
      m.id,
      m.author_id,
      m.created_at,
      m.body,
      m.content,
      m.msg_type
    from public.messages m
    where m.chat_id = ar.chat_id
      and m.created_at > coalesce(s.cleared_at, to_timestamp(0))
    order by m.created_at desc
    limit 1
  ) lm on true
  left join public.users au on au.id = lm.author_id
  left join lateral (
    select count(*)::integer as unread_count
    from public.messages m
    where m.chat_id = ar.chat_id
      and m.author_id <> v_me
      and m.created_at > coalesce(s.cleared_at, to_timestamp(0))
      and m.created_at > coalesce(
        (
          select cr.last_read_at
          from public.chat_reads cr
          where cr.chat_id = ar.chat_id
            and cr.user_id = v_me
          limit 1
        ),
        to_timestamp(0)
      )
  ) ur on true
  order by
    ar.archived_at desc nulls last,
    lm.created_at desc nulls last;
end;
$function$;

revoke all on function public.get_my_archived_chat_summaries() from public;
revoke all on function public.get_my_archived_chat_summaries() from anon;
grant execute on function public.get_my_archived_chat_summaries() to authenticated;

-- Internal helpers / trigger functions: no client EXECUTE.
revoke all on function public.trg_fn_academic_terms_archive_previous() from public;
revoke all on function public.trg_fn_academic_terms_archive_previous() from anon;
revoke all on function public.trg_fn_academic_terms_archive_previous() from authenticated;

revoke all on function public.trg_fn_block_archived_academic_message_writes() from public;
revoke all on function public.trg_fn_block_archived_academic_message_writes() from anon;
revoke all on function public.trg_fn_block_archived_academic_message_writes() from authenticated;

revoke all on function public.trg_fn_block_archived_academic_reaction_writes() from public;
revoke all on function public.trg_fn_block_archived_academic_reaction_writes() from anon;
revoke all on function public.trg_fn_block_archived_academic_reaction_writes() from authenticated;

revoke all on function public.trg_fn_block_archived_academic_chat_file_writes() from public;
revoke all on function public.trg_fn_block_archived_academic_chat_file_writes() from anon;
revoke all on function public.trg_fn_block_archived_academic_chat_file_writes() from authenticated;

-- ---------------------------------------------------------------------------
-- 9) get_chat_messages_for_team: block expired academic history
-- ---------------------------------------------------------------------------
create or replace function public.get_chat_messages_for_team(
  p_team_id uuid,
  p_limit integer default 400,
  p_since timestamp with time zone default '1970-01-01 00:00:00+00'::timestamptz
)
returns table (
  id uuid,
  chat_id uuid,
  author_id uuid,
  author_login text,
  author_name text,
  author_avatar_url text,
  text text,
  type text,
  msg_type text,
  at timestamptz,
  created_at timestamptz,
  edited_at timestamptz,
  reply_to_id uuid,
  assignment_id uuid,
  file_id uuid,
  attachments jsonb,
  reactions jsonb,
  user_reactions text[],
  is_pinned boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_me uuid := (select auth.uid());
  v_chat_id uuid;
begin
  if v_me is null then
    raise exception using
      errcode = 'P0001',
      message = 'not_authenticated';
  end if;

  -- Same visibility as public.get_my_teams(): membership ∪ teams of my group.
  if not exists (
    select 1
    from public.team_members tm
    where tm.team_id = p_team_id
      and tm.user_id = v_me
  ) and not exists (
    select 1
    from public.teams t
    join public.users u on u.id = v_me
    where t.id = p_team_id
      and t.group_name is not null
      and t.group_name = u.group_name
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'forbidden';
  end if;

  select c.id into v_chat_id
  from public.chats c
  where c.team_id = p_team_id
    and c.type = 'team_main'
  limit 1;

  if v_chat_id is not null and exists (
    select 1
    from public.chat_academic_archives a
    where a.chat_id = v_chat_id
      and a.expired_at is not null
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'academic_chat_expired';
  end if;

  return query
  with main_chat as (
    select c.id
    from public.chats c
    where c.team_id = p_team_id
      and c.type = 'team_main'
    limit 1
  )
  select
    m.id,
    m.chat_id,
    m.author_id,
    u.login,
    trim(coalesce(u.name, '') || ' ' || coalesce(u.surname, '')),
    u.avatar_url,
    coalesce(m.content, m.body, ''),
    coalesce(m.msg_type, m.type, 'text'),
    coalesce(m.msg_type, m.type, 'text'),
    m.created_at,
    m.created_at,
    m.edited_at,
    m.reply_to_id,
    m.assignment_id,
    m.file_id,
    coalesce(m.attachments, '[]'::jsonb),
    (
      select coalesce(jsonb_object_agg(t.emoji, t.cnt), '{}'::jsonb)
      from (
        select mr.emoji, count(*)::bigint as cnt
        from public.message_reactions mr
        where mr.message_id = m.id
        group by mr.emoji
      ) t
    ),
    (
      select array_agg(mr.emoji)
      from public.message_reactions mr
      where mr.message_id = m.id
        and mr.user_id = v_me
    ),
    m.is_pinned
  from public.messages m
  join main_chat c on c.id = m.chat_id
  left join public.users u on u.id = m.author_id
  where m.created_at >= p_since
  order by m.created_at asc
  limit coalesce(p_limit, 400);
end;
$function$;

revoke all on function public.get_chat_messages_for_team(uuid, integer, timestamptz) from public;
revoke all on function public.get_chat_messages_for_team(uuid, integer, timestamptz) from anon;
grant execute on function public.get_chat_messages_for_team(uuid, integer, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 10) Daily maintenance via pg_cron (idempotent named job)
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;

do $cron$
begin
  -- Named schedule is upserted; unschedule first so re-apply never duplicates.
  if exists (
    select 1
    from cron.job j
    where j.jobname = 'chat-archive-maintenance'
  ) then
    perform cron.unschedule('chat-archive-maintenance');
  end if;

  perform cron.schedule(
    'chat-archive-maintenance',
    '15 3 * * *',
    $cmd$
      select public.archive_completed_academic_chats();
      select public.expire_academic_chat_archives();
    $cmd$
  );
end;
$cron$;

-- Backfill once at migrate time (owner / service path; not via authenticated RPC).
select public.archive_completed_academic_chats();
