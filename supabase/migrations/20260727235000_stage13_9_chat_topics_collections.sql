-- Stage 13.9 — Chat-scoped topic selection + collection foundation hardening
-- Local migration only. Do not apply to remote until owner-authorized.
-- Extends Stage 13.2 group_topic_* / group_collection_* without duplicating tables.

begin;

-- ---------------------------------------------------------------------------
-- 1) Schema extensions
-- ---------------------------------------------------------------------------
alter table public.group_topic_selections
  drop constraint if exists group_topic_selections_status_check;

alter table public.group_topic_selections
  add column if not exists completion_deadline_at timestamptz null,
  add column if not exists source_file_id uuid null references public.chat_files(id) on delete set null,
  add column if not exists show_results_to_all boolean not null default true,
  add column if not exists card_message_id uuid null references public.messages(id) on delete set null;

alter table public.group_topic_selections
  add constraint group_topic_selections_status_check
  check (status in ('draft', 'open', 'closed', 'cancelled'));

alter table public.group_collections
  add column if not exists instructions text not null default '',
  add column if not exists payment_details text not null default '',
  add column if not exists card_message_id uuid null references public.messages(id) on delete set null;

-- Private payment requisites: never readable via authenticated table SELECT.
create table if not exists public.group_collection_secrets (
  collection_id uuid primary key references public.group_collections(id) on delete cascade,
  payment_details text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.group_collection_secrets enable row level security;
alter table public.group_collection_secrets force row level security;
revoke all on table public.group_collection_secrets from public, anon, authenticated;
-- No SELECT/INSERT/UPDATE/DELETE policies for authenticated: SECURITY DEFINER only.

-- Move any inline requisites into the private table, then drop the public column.
insert into public.group_collection_secrets(collection_id, payment_details)
select c.id, coalesce(c.payment_details, '')
from public.group_collections c
where coalesce(c.payment_details, '') <> ''
on conflict (collection_id) do update
set payment_details = excluded.payment_details, updated_at = now();

alter table public.group_collections
  drop column if exists payment_details;

-- ---------------------------------------------------------------------------
-- 2) Scope helpers (team_id is the single source of truth)
-- ---------------------------------------------------------------------------
create or replace function private.team_main_chat_id(p_team_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id
  from public.chats c
  where c.team_id = p_team_id and c.type = 'team_main'
  limit 1;
$$;

revoke all on function private.team_main_chat_id(uuid) from public, anon, authenticated;

create or replace function private.is_active_team_member(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.teams t
      where t.id = p_team_id
        and (
          (
            t.kind = 'group_space'
            and private.is_group_space_member(t.group_id)
          )
          or (
            coalesce(t.kind, 'subject') = 'subject'
            and t.group_id is not null
            and private.is_active_subject_team_for_group(t.id, t.group_id)
            and exists (
              select 1
              from public.team_members tm
              join public.student_enrollments se
                on se.user_id = tm.user_id
               and se.group_id = t.group_id
               and se.status = 'active'
               and se.ended_at is null
              where tm.team_id = t.id
                and tm.user_id = auth.uid()
            )
          )
        )
        and not exists (
          select 1
          from public.chats c
          join public.chat_academic_archives a on a.chat_id = c.id
          where c.team_id = t.id and c.type = 'team_main'
        )
    );
$$;

revoke all on function private.is_active_team_member(uuid) from public, anon, authenticated;

create or replace function private.can_manage_team_topics(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- Manager rights require active (non-archived) membership in the same team.
  select private.is_active_team_member(p_team_id)
    and exists (
      select 1
      from public.teams t
      where t.id = p_team_id
        and (
          (
            t.kind = 'group_space'
            and private.is_group_space_organizer(t.group_id)
          )
          or (
            coalesce(t.kind, 'subject') = 'subject'
            and exists (
              select 1
              from public.team_members tm
              where tm.team_id = t.id
                and tm.user_id = auth.uid()
                -- team_members.role allows owner/starosta/member only (no teacher role).
                and lower(coalesce(tm.role, '')) in ('starosta', 'owner')
            )
          )
        )
    );
$$;

revoke all on function private.can_manage_team_topics(uuid) from public, anon, authenticated;

create or replace function private.can_manage_team_collections(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- Collections remain group-space only unless product expands later.
  select private.is_active_team_member(p_team_id)
    and exists (
      select 1
      from public.teams t
      where t.id = p_team_id
        and t.kind = 'group_space'
        and private.is_group_space_organizer(t.group_id)
    );
$$;

revoke all on function private.can_manage_team_collections(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3) RLS: team-scoped access; private picks when show_results_to_all=false
-- ---------------------------------------------------------------------------
drop policy if exists group_topic_selections_member_select on public.group_topic_selections;
create policy group_topic_selections_member_select
on public.group_topic_selections
for select to authenticated
using (
  status <> 'draft'
  and private.is_active_team_member(team_id)
);

drop policy if exists group_topic_options_member_select on public.group_topic_options;
create policy group_topic_options_member_select
on public.group_topic_options
for select to authenticated
using (
  exists (
    select 1
    from public.group_topic_selections s
    where s.id = selection_id
      and s.status <> 'draft'
      and private.is_active_team_member(s.team_id)
  )
);

drop policy if exists group_topic_picks_member_select on public.group_topic_picks;
create policy group_topic_picks_member_select
on public.group_topic_picks
for select to authenticated
using (
  exists (
    select 1
    from public.group_topic_selections s
    where s.id = selection_id
      and s.status <> 'draft'
      and private.is_active_team_member(s.team_id)
      and (
        s.show_results_to_all
        or user_id = auth.uid()
        or private.can_manage_team_topics(s.team_id)
      )
  )
);

-- ---------------------------------------------------------------------------
-- 4) Publish topic selection for a chat (atomic)
-- ---------------------------------------------------------------------------
create or replace function public.publish_topic_selection_for_chat(
  p_chat_id uuid,
  p_title text,
  p_description text default '',
  p_deadline_at timestamptz default null,
  p_completion_deadline_at timestamptz default null,
  p_allow_change boolean default true,
  p_show_results_to_all boolean default true,
  p_source_file_id uuid default null,
  p_options jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team public.teams%rowtype;
  v_chat public.chats%rowtype;
  v_selection_id uuid;
  v_message_id uuid;
  v_option jsonb;
  v_sort integer := 0;
  v_option_count integer := 0;
  v_title text := btrim(coalesce(p_title, ''));
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if v_title = '' then
    raise exception 'title_required' using errcode = '22023';
  end if;

  select * into v_chat from public.chats where id = p_chat_id for update;
  if not found or v_chat.type <> 'team_main' or v_chat.team_id is null then
    raise exception 'invalid_chat' using errcode = '22023';
  end if;

  select * into v_team from public.teams where id = v_chat.team_id for update;
  if not found or coalesce(v_team.kind, 'subject') = 'dm' then
    raise exception 'invalid_team' using errcode = '22023';
  end if;
  if not private.can_manage_team_topics(v_team.id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.chat_academic_archives a where a.chat_id = p_chat_id
  ) then
    raise exception 'chat_archived' using errcode = '42501';
  end if;

  if jsonb_typeof(coalesce(p_options, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(p_options) < 1
     or jsonb_array_length(p_options) > 200 then
    raise exception 'invalid_options' using errcode = '22023';
  end if;

  if p_source_file_id is not null and not exists (
    select 1
    from public.chat_files f
    where f.id = p_source_file_id
      and f.chat_id = p_chat_id
      and coalesce(f.is_sensitive, false) = false
  ) then
    raise exception 'invalid_source_file' using errcode = '22023';
  end if;

  insert into public.group_topic_selections(
    group_id, team_id, created_by, title, description, deadline_at,
    completion_deadline_at, allow_change, show_results_to_all, source_file_id, status
  ) values (
    v_team.group_id, v_team.id, auth.uid(), v_title, coalesce(p_description, ''),
    p_deadline_at, p_completion_deadline_at, coalesce(p_allow_change, true),
    coalesce(p_show_results_to_all, true), p_source_file_id, 'open'
  ) returning id into v_selection_id;

  for v_option in
    select value from jsonb_array_elements(p_options)
  loop
    v_sort := v_sort + 1;
    if btrim(coalesce(v_option->>'title', '')) = '' then
      continue;
    end if;
    insert into public.group_topic_options(selection_id, title, capacity, sort_order)
    values (
      v_selection_id,
      btrim(v_option->>'title'),
      greatest(1, coalesce((v_option->>'capacity')::integer, 1)),
      coalesce((v_option->>'sort_order')::integer, v_sort)
    );
    v_option_count := v_option_count + 1;
  end loop;

  if v_option_count < 1 then
    raise exception 'options_required' using errcode = '22023';
  end if;

  insert into public.messages(chat_id, author_id, body, content, msg_type)
  values (
    p_chat_id,
    auth.uid(),
    'Выбор темы: ' || v_title,
    jsonb_build_object(
      'card', 'topic_selection',
      'selection_id', v_selection_id
    ),
    'text'
  ) returning id into v_message_id;

  update public.group_topic_selections
  set card_message_id = v_message_id, updated_at = now()
  where id = v_selection_id;

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    v_selection_id,
    auth.uid(),
    'published',
    jsonb_build_object('option_count', v_option_count, 'message_id', v_message_id)
  );

  return jsonb_build_object(
    'selection_id', v_selection_id,
    'message_id', v_message_id,
    'option_count', v_option_count
  );
end;
$$;

-- Legacy group-space API: create selection shell; options added via add_topic_option.
create or replace function public.create_topic_selection(
  p_title text,
  p_description text default '',
  p_deadline_at timestamptz default null,
  p_allow_change boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid := private.current_active_group_id();
  v_id uuid;
begin
  if not private.is_group_space_organizer(v_group) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.group_topic_selections(
    group_id, team_id, created_by, title, description, deadline_at, allow_change, status
  ) values (
    v_group,
    private.group_space_team_id(v_group),
    auth.uid(),
    p_title,
    coalesce(p_description, ''),
    p_deadline_at,
    p_allow_change,
    'open'
  ) returning id into v_id;
  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (v_id, auth.uid(), 'created', '{}'::jsonb);
  return v_id;
end;
$$;

create or replace function public.reassign_topic_pick(
  p_selection_id uuid,
  p_user_id uuid,
  p_option_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
  v_capacity integer;
  v_count integer;
  v_prev uuid;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_topics(v_selection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_selection.status <> 'open'
     or (v_selection.deadline_at is not null and v_selection.deadline_at <= now()) then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;
  if not private.is_active_team_member(v_selection.team_id)
     or not exists (
       select 1 from public.team_members tm
       where tm.team_id = v_selection.team_id and tm.user_id = p_user_id
     ) then
    -- For group_space, membership is enrollment-based.
    if not (
      exists (
        select 1 from public.teams t
        where t.id = v_selection.team_id and t.kind = 'group_space'
      )
      and exists (
        select 1 from public.student_enrollments se
        where se.user_id = p_user_id
          and se.group_id = v_selection.group_id
          and se.status = 'active'
          and se.ended_at is null
      )
    ) then
      raise exception 'target_not_member' using errcode = '42501';
    end if;
  end if;

  select capacity into v_capacity
  from public.group_topic_options
  where id = p_option_id and selection_id = p_selection_id
  for update;
  if v_capacity is null then
    raise exception 'invalid_option' using errcode = '22023';
  end if;

  select option_id into v_prev
  from public.group_topic_picks
  where selection_id = p_selection_id and user_id = p_user_id
  for update;

  select count(*) into v_count
  from public.group_topic_picks
  where selection_id = p_selection_id
    and option_id = p_option_id
    and user_id is distinct from p_user_id;
  if v_count >= v_capacity then
    raise exception 'option_full' using errcode = 'P0001';
  end if;

  delete from public.group_topic_picks
  where selection_id = p_selection_id and user_id = p_user_id;

  insert into public.group_topic_picks(selection_id, option_id, user_id)
  values (p_selection_id, p_option_id, p_user_id);

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id,
    auth.uid(),
    'reassigned',
    jsonb_build_object(
      'user_id', p_user_id,
      'previous_option_id', v_prev,
      'option_id', p_option_id
    )
  );
end;
$$;

create or replace function public.list_topic_selections_for_chat(p_chat_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
begin
  select team_id into v_team_id
  from public.chats
  where id = p_chat_id and type = 'team_main';
  if v_team_id is null or not private.is_active_team_member(v_team_id) then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', s.id,
          'title', s.title,
          'description', s.description,
          'status', s.status,
          'deadline_at', s.deadline_at,
          'completion_deadline_at', s.completion_deadline_at,
          'allow_change', s.allow_change,
          'show_results_to_all', s.show_results_to_all,
          'source_file_id', s.source_file_id,
          'card_message_id', s.card_message_id,
          'free_slots', (
            select coalesce(sum(greatest(o.capacity - (
              select count(*) from public.group_topic_picks p
              where p.option_id = o.id
            ), 0)), 0)
            from public.group_topic_options o
            where o.selection_id = s.id
          ),
          'taken_slots', (
            select count(*) from public.group_topic_picks p where p.selection_id = s.id
          ),
          'total_capacity', (
            select coalesce(sum(o.capacity), 0)
            from public.group_topic_options o where o.selection_id = s.id
          )
        )
        order by s.status, s.deadline_at nulls last, s.created_at desc
      )
      from public.group_topic_selections s
      where s.team_id = v_team_id and s.status <> 'draft'
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.list_topic_options_for_selection(p_selection_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
  v_can_manage boolean;
begin
  select * into v_selection from public.group_topic_selections where id = p_selection_id;
  if not found or v_selection.status = 'draft' then
    return '[]'::jsonb;
  end if;
  if not private.is_active_team_member(v_selection.team_id) then
    return '[]'::jsonb;
  end if;
  v_can_manage := private.can_manage_team_topics(v_selection.team_id);

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'selection_id', o.selection_id,
          'title', o.title,
          'capacity', o.capacity,
          'sort_order', o.sort_order,
          'taken', (
            select count(*) from public.group_topic_picks p where p.option_id = o.id
          ),
          'my_pick', exists (
            select 1 from public.group_topic_picks p
            where p.option_id = o.id and p.user_id = auth.uid()
          ),
          'picker_names', case
            when v_selection.show_results_to_all or v_can_manage then (
              select coalesce(jsonb_agg(
                nullif(trim(concat(coalesce(u.name, ''), ' ', coalesce(u.surname, ''))), '')
              ), '[]'::jsonb)
              from public.group_topic_picks p
              join public.users u on u.id = p.user_id
              where p.option_id = o.id
            )
            else '[]'::jsonb
          end
        )
        order by o.sort_order, o.created_at
      )
      from public.group_topic_options o
      where o.selection_id = p_selection_id
    ),
    '[]'::jsonb
  );
end;
$$;

-- Harden pick_topic membership to team scope (not whole group for subject teams).
create or replace function public.pick_topic(p_selection_id uuid, p_option_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
  v_capacity integer;
  v_count integer;
  v_existing uuid;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not private.is_active_team_member(v_selection.team_id)
     or v_selection.status <> 'open'
     or (v_selection.deadline_at is not null and v_selection.deadline_at <= now()) then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;

  select capacity into v_capacity
  from public.group_topic_options
  where id = p_option_id and selection_id = p_selection_id
  for update;
  if v_capacity is null then
    raise exception 'invalid_option' using errcode = '22023';
  end if;

  select option_id into v_existing
  from public.group_topic_picks
  where selection_id = p_selection_id and user_id = auth.uid()
  for update;

  if v_existing is not null
     and (not v_selection.allow_change or v_existing = p_option_id) then
    if v_existing = p_option_id then
      return;
    end if;
    raise exception 'pick_change_forbidden' using errcode = '42501';
  end if;

  -- Exclude self so a topic change does not falsely count as full.
  select count(*) into v_count
  from public.group_topic_picks
  where selection_id = p_selection_id
    and option_id = p_option_id
    and user_id is distinct from auth.uid();
  if v_count >= v_capacity then
    raise exception 'option_full' using errcode = 'P0001';
  end if;

  if v_existing is not null then
    delete from public.group_topic_picks
    where selection_id = p_selection_id and user_id = auth.uid();
  end if;

  insert into public.group_topic_picks(selection_id, option_id, user_id)
  values (p_selection_id, p_option_id, auth.uid());

  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id,
    auth.uid(),
    'picked',
    jsonb_build_object('option_id', p_option_id)
  );
end;
$$;

-- Calendar/home feed for topic/collection deadlines (not subject assignments).
create or replace function public.list_my_group_action_deadlines(
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with bounds as (
    select
      coalesce(p_from, now() - interval '30 days') as d_from,
      coalesce(p_to, now() + interval '180 days') as d_to
  ),
  topic_items as (
    select
      'topic_deadline'::text as event_type,
      s.id as entity_id,
      s.title,
      s.deadline_at as occurs_at,
      private.team_main_chat_id(s.team_id) as chat_id,
      s.team_id,
      s.group_id,
      t.name as team_name,
      s.status as action_status,
      (
        select o.title
        from public.group_topic_picks p
        join public.group_topic_options o on o.id = p.option_id
        where p.selection_id = s.id and p.user_id = auth.uid()
        limit 1
      ) as my_pick_text,
      jsonb_build_object('selection_id', s.id, 'card_message_id', s.card_message_id) as payload
    from public.group_topic_selections s
    join public.teams t on t.id = s.team_id
    cross join bounds b
    where s.status = 'open'
      and s.deadline_at is not null
      and s.deadline_at between b.d_from and b.d_to
      and private.is_active_team_member(s.team_id)
  ),
  collection_items as (
    select
      'collection_deadline'::text as event_type,
      c.id as entity_id,
      c.title,
      c.deadline_at as occurs_at,
      private.team_main_chat_id(c.team_id) as chat_id,
      c.team_id,
      c.group_id,
      t.name as team_name,
      c.status as action_status,
      case
        when cc.participation_status = 'joining'
             and cc.payment_status = 'confirmed' then 'Участвую · оплачено'
        when cc.participation_status = 'joining' then 'Участвую'
        when cc.participation_status = 'declined' then 'Не участвую'
        else null
      end as my_pick_text,
      jsonb_build_object('collection_id', c.id, 'card_message_id', c.card_message_id) as payload
    from public.group_collections c
    join public.teams t on t.id = c.team_id
    left join public.group_collection_contributions cc
      on cc.collection_id = c.id and cc.user_id = auth.uid()
    cross join bounds b
    where c.status = 'open'
      and c.deadline_at is not null
      and c.deadline_at between b.d_from and b.d_to
      and private.is_active_team_member(c.team_id)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'event_type', x.event_type,
        'entity_id', x.entity_id,
        'title', x.title,
        'occurs_at', x.occurs_at,
        'chat_id', x.chat_id,
        'team_id', x.team_id,
        'group_id', x.group_id,
        'team_name', x.team_name,
        'status', x.action_status,
        'my_pick_text', x.my_pick_text,
        'payload', x.payload
      )
      order by x.occurs_at nulls last
    ),
    '[]'::jsonb
  )
  from (
    select * from topic_items
    union all
    select * from collection_items
  ) x;
$$;

-- Collection create: keep group-space only; add instructions/payment_details.
-- Drop legacy 5-arg overload so defaulted 7-arg covers old callers.
drop function if exists public.create_group_collection(text, text, text, timestamptz, numeric);
create or replace function public.create_group_collection(
  p_title text,
  p_description text default '',
  p_purpose text default '',
  p_deadline_at timestamptz default null,
  p_amount_optional numeric default null,
  p_instructions text default '',
  p_payment_details text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid := private.current_active_group_id();
  v_team uuid;
  v_chat uuid;
  v_id uuid;
  v_message_id uuid;
begin
  v_team := private.group_space_team_id(v_group);
  if not private.can_manage_team_collections(v_team) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_chat := private.team_main_chat_id(v_team);

  insert into public.group_collections(
    group_id, team_id, created_by, title, description, purpose, deadline_at,
    amount_optional, instructions, status
  ) values (
    v_group, v_team, auth.uid(), btrim(p_title), coalesce(p_description, ''),
    coalesce(p_purpose, ''), p_deadline_at, p_amount_optional,
    left(coalesce(p_instructions, ''), 4000),
    'open'
  ) returning id into v_id;

  if btrim(coalesce(p_payment_details, '')) <> '' then
    insert into public.group_collection_secrets(collection_id, payment_details)
    values (v_id, left(btrim(p_payment_details), 2000));
  end if;

  if v_chat is not null then
    insert into public.messages(chat_id, author_id, body, content, msg_type)
    values (
      v_chat,
      auth.uid(),
      'Сбор: ' || btrim(p_title),
      jsonb_build_object('card', 'collection', 'collection_id', v_id),
      'text'
    ) returning id into v_message_id;

    update public.group_collections
    set card_message_id = v_message_id, updated_at = now()
    where id = v_id;
  end if;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    v_id,
    auth.uid(),
    'created',
    jsonb_build_object('has_payment_details', btrim(coalesce(p_payment_details, '')) <> '')
  );
  -- Never put requisites into events/audit/push.
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) Collection proof privacy + contribution listing
-- ---------------------------------------------------------------------------
-- chat_files has no SELECT grant for authenticated today; still mark sensitive
-- proofs and expose them only via SECURITY DEFINER RPC to owner/organizer.
alter table public.chat_files
  add column if not exists is_sensitive boolean not null default false;

create or replace function public.mark_chat_file_sensitive(p_file_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  update public.chat_files
  set is_sensitive = true
  where id = p_file_id and uploaded_by = auth.uid();
  if not found then
    raise exception 'forbidden' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.get_collection_proof_file(p_collection_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_proof uuid;
  v_file public.chat_files%rowtype;
begin
  select * into v_collection from public.group_collections where id = p_collection_id;
  if not found then
    return null;
  end if;
  if auth.uid() is distinct from p_user_id
     and not private.can_manage_team_collections(v_collection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not private.is_active_team_member(v_collection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select proof_file_id into v_proof
  from public.group_collection_contributions
  where collection_id = p_collection_id and user_id = p_user_id;
  if v_proof is null then
    return null;
  end if;

  select * into v_file from public.chat_files where id = v_proof;
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'id', v_file.id,
    'file_name', v_file.file_name,
    'file_url', v_file.file_url,
    'file_type', v_file.file_type
  );
end;
$$;

-- Progress without proof URLs / payment details for non-privileged readers.
create or replace function public.list_collection_contribution_progress(p_collection_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_manage boolean;
begin
  select * into v_collection from public.group_collections where id = p_collection_id;
  if not found or not private.is_active_team_member(v_collection.team_id) then
    return '[]'::jsonb;
  end if;
  v_manage := private.can_manage_team_collections(v_collection.team_id);

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'user_id', c.user_id,
          'participation_status', c.participation_status,
          'payment_status', c.payment_status,
          'amount', c.amount,
          'has_proof', c.proof_file_id is not null,
          -- Never return payment proof URL here; use get_collection_proof_file.
          'proof_file_id', case
            when v_manage or c.user_id = auth.uid() then c.proof_file_id
            else null
          end,
          'comment', case
            when v_manage or c.user_id = auth.uid() then c.comment
            else null
          end
        )
        order by c.updated_at desc
      )
      from public.group_collection_contributions c
      where c.collection_id = p_collection_id
    ),
    '[]'::jsonb
  );
end;
$$;

-- Redact payment_details for non-organizers (return type changes from setof).
drop function if exists public.list_group_collections();
create function public.list_group_collections()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_group uuid := private.current_active_group_id();
  v_manage boolean;
begin
  if v_group is null or not private.is_group_space_member(v_group) then
    return '[]'::jsonb;
  end if;
  v_manage := private.is_group_space_organizer(v_group);
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', c.id,
          'title', c.title,
          'description', c.description,
          'purpose', c.purpose,
          'status', c.status,
          'deadline_at', c.deadline_at,
          'amount_optional', c.amount_optional,
          'instructions', c.instructions,
          'payment_details', case
            when v_manage then coalesce((
              select s.payment_details
              from public.group_collection_secrets s
              where s.collection_id = c.id
            ), '')
            else ''
          end,
          'card_message_id', c.card_message_id,
          'joined_count', (
            select count(*) from public.group_collection_contributions x
            where x.collection_id = c.id and x.participation_status = 'joining'
          ),
          'confirmed_count', (
            select count(*) from public.group_collection_contributions x
            where x.collection_id = c.id and x.payment_status = 'confirmed'
          )
        )
        order by c.created_at desc
      )
      from public.group_collections c
      where c.group_id = v_group and c.status <> 'cancelled'
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.release_topic_pick(
  p_selection_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_topics(v_selection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.group_topic_picks
  where selection_id = p_selection_id and user_id = p_user_id;
  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id,
    auth.uid(),
    'released',
    jsonb_build_object('user_id', p_user_id)
  );
end;
$$;

-- Subject-team managers can add options / close selections (not only group organizers).
create or replace function public.add_topic_option(
  p_selection_id uuid,
  p_title text,
  p_capacity integer,
  p_sort_order integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_selection public.group_topic_selections%rowtype;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id and status = 'open'
  for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_topics(v_selection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.group_topic_options(selection_id, title, capacity, sort_order)
  values (p_selection_id, p_title, greatest(1, p_capacity), p_sort_order)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.close_topic_selection(
  p_selection_id uuid,
  p_status text default 'closed'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not found then
    raise exception 'selection_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_team_topics(v_selection.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status not in ('closed', 'cancelled') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  update public.group_topic_selections
  set status = p_status, updated_at = now()
  where id = p_selection_id;
  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (
    p_selection_id,
    auth.uid(),
    'status_changed',
    jsonb_build_object('status', p_status)
  );
end;
$$;

-- Harden cancel_topic_pick to team membership + deadline rules.
create or replace function public.cancel_topic_pick(p_selection_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection public.group_topic_selections%rowtype;
begin
  select * into v_selection
  from public.group_topic_selections
  where id = p_selection_id
  for update;
  if not found or not private.is_active_team_member(v_selection.team_id) then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;
  if v_selection.status <> 'open'
     or (v_selection.deadline_at is not null and v_selection.deadline_at <= now()) then
    raise exception 'selection_unavailable' using errcode = '42501';
  end if;
  if not v_selection.allow_change then
    raise exception 'pick_change_forbidden' using errcode = '42501';
  end if;
  delete from public.group_topic_picks
  where selection_id = p_selection_id and user_id = auth.uid();
  insert into public.group_topic_events(selection_id, actor_id, event_type, payload)
  values (p_selection_id, auth.uid(), 'cancelled_pick', '{}'::jsonb);
end;
$$;

-- Mark proof sensitive when contribution attaches a file.
create or replace function public.upsert_my_collection_contribution(
  p_collection_id uuid,
  p_participation_status text default 'unmarked',
  p_payment_status text default 'unmarked',
  p_amount numeric default null,
  p_comment text default '',
  p_proof_file_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_collection public.group_collections%rowtype;
  v_id uuid;
begin
  select * into v_collection from public.group_collections where id = p_collection_id for update;
  if not found or v_collection.status <> 'open'
     or not private.is_active_team_member(v_collection.team_id) then
    raise exception 'collection_unavailable' using errcode = '42501';
  end if;
  if p_payment_status not in ('unmarked', 'pending_review') then
    raise exception 'invalid_payment_status' using errcode = '22023';
  end if;
  if p_proof_file_id is not null and not exists (
    select 1
    from public.chat_files cf
    join public.chats ch on ch.id = cf.chat_id
    where cf.id = p_proof_file_id
      and cf.uploaded_by = auth.uid()
      and ch.team_id = v_collection.team_id
      and ch.type = 'team_main'
  ) then
    raise exception 'invalid_proof_file' using errcode = '22023';
  end if;
  if p_proof_file_id is not null then
    update public.chat_files set is_sensitive = true where id = p_proof_file_id;
  end if;

  insert into public.group_collection_contributions(
    collection_id, user_id, participation_status, payment_status, amount, comment, proof_file_id
  ) values (
    p_collection_id, auth.uid(), p_participation_status, p_payment_status, p_amount,
    coalesce(p_comment, ''), p_proof_file_id
  )
  on conflict (collection_id, user_id) do update
  set participation_status = excluded.participation_status,
      payment_status = excluded.payment_status,
      amount = excluded.amount,
      comment = excluded.comment,
      proof_file_id = excluded.proof_file_id,
      updated_at = now()
  returning id into v_id;

  insert into public.group_collection_events(collection_id, actor_id, event_type, payload)
  values (
    p_collection_id,
    auth.uid(),
    'contribution_upserted',
    jsonb_build_object(
      'participation_status', p_participation_status,
      'payment_status', p_payment_status,
      'has_proof', p_proof_file_id is not null
    )
  );
  -- Never log requisites or proof URLs.
  return v_id;
end;
$$;

-- Realtime publication (guarded).
do $$
begin
  begin
    alter publication supabase_realtime add table public.group_topic_selections;
  exception when duplicate_object then null; when undefined_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.group_topic_options;
  exception when duplicate_object then null; when undefined_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.group_topic_picks;
  exception when duplicate_object then null; when undefined_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.group_collections;
  exception when duplicate_object then null; when undefined_object then null;
  end;
end $$;

revoke all on function
  public.publish_topic_selection_for_chat(uuid, text, text, timestamptz, timestamptz, boolean, boolean, uuid, jsonb),
  public.reassign_topic_pick(uuid, uuid, uuid),
  public.release_topic_pick(uuid, uuid),
  public.list_topic_selections_for_chat(uuid),
  public.list_topic_options_for_selection(uuid),
  public.list_my_group_action_deadlines(timestamptz, timestamptz),
  public.create_group_collection(text, text, text, timestamptz, numeric, text, text),
  public.create_topic_selection(text, text, timestamptz, boolean),
  public.pick_topic(uuid, uuid),
  public.cancel_topic_pick(uuid),
  public.mark_chat_file_sensitive(uuid),
  public.get_collection_proof_file(uuid, uuid),
  public.list_collection_contribution_progress(uuid),
  public.list_group_collections(),
  public.upsert_my_collection_contribution(uuid, text, text, numeric, text, uuid)
from public, anon;

grant execute on function
  public.publish_topic_selection_for_chat(uuid, text, text, timestamptz, timestamptz, boolean, boolean, uuid, jsonb),
  public.reassign_topic_pick(uuid, uuid, uuid),
  public.release_topic_pick(uuid, uuid),
  public.list_topic_selections_for_chat(uuid),
  public.list_topic_options_for_selection(uuid),
  public.list_my_group_action_deadlines(timestamptz, timestamptz),
  public.create_group_collection(text, text, text, timestamptz, numeric, text, text),
  public.create_topic_selection(text, text, timestamptz, boolean),
  public.pick_topic(uuid, uuid),
  public.cancel_topic_pick(uuid),
  public.mark_chat_file_sensitive(uuid),
  public.get_collection_proof_file(uuid, uuid),
  public.list_collection_contribution_progress(uuid),
  public.list_group_collections(),
  public.upsert_my_collection_contribution(uuid, text, text, numeric, text, uuid)
to authenticated, service_role;

-- Restrictive chat_files SELECT: members see non-sensitive only; proofs are private.
alter table public.chat_files enable row level security;
alter table public.chat_files force row level security;
grant select, insert, update on public.chat_files to authenticated;

-- Ensure write policies exist (remote already has them; local stripped DBs may not).
do $$
begin
  if not exists (
    select 1 from pg_policy
    where polrelid = 'public.chat_files'::regclass
      and polname = 'chat_files_insert_member'
  ) then
    create policy chat_files_insert_member
    on public.chat_files
    for insert to authenticated
    with check (
      uploaded_by = auth.uid()
      and (
        exists (
          select 1 from public.chat_members cm
          where cm.chat_id = chat_files.chat_id and cm.user_id = auth.uid()
        )
        or exists (
          select 1
          from public.team_members tm
          join public.chats c on c.id = chat_files.chat_id
          where c.team_id is not null
            and tm.team_id = c.team_id
            and tm.user_id = auth.uid()
        )
      )
    );
  end if;

  if not exists (
    select 1 from pg_policy
    where polrelid = 'public.chat_files'::regclass
      and polname = 'chat_files_update_owner'
  ) then
    create policy chat_files_update_owner
    on public.chat_files
    for update to authenticated
    using (uploaded_by = auth.uid())
    with check (uploaded_by = auth.uid());
  end if;
end $$;

drop policy if exists chat_files_select_member on public.chat_files;
create policy chat_files_select_member
on public.chat_files
for select to authenticated
using (
  exists (
    select 1
    from public.chat_members cm
    where cm.chat_id = chat_files.chat_id and cm.user_id = auth.uid()
  )
  or exists (
    select 1
    from public.team_members tm
    join public.chats c on c.id = chat_files.chat_id
    where c.team_id is not null
      and tm.team_id = c.team_id
      and tm.user_id = auth.uid()
  )
);

drop policy if exists chat_files_select_sensitive_proof on public.chat_files;

-- RESTRICTIVE gate: sensitive proofs never leak through other permissive SELECT policies.
drop policy if exists chat_files_restrict_sensitive_proof on public.chat_files;
create policy chat_files_restrict_sensitive_proof
on public.chat_files
as restrictive
for select to authenticated
using (
  coalesce(is_sensitive, false) = false
  or uploaded_by = auth.uid()
  or exists (
    select 1
    from public.group_collection_contributions cc
    join public.group_collections gc on gc.id = cc.collection_id
    where cc.proof_file_id = chat_files.id
      and private.can_manage_team_collections(gc.team_id)
  )
);

-- Clients cannot clear the sensitive flag after a proof was marked.
create or replace function private.chat_files_protect_sensitive_flag()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and old.is_sensitive is true
     and coalesce(new.is_sensitive, false) is distinct from true then
    if coalesce(current_setting('private.allow_sensitive_clear', true), '') <> '1' then
      raise exception 'sensitive_flag_immutable' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_chat_files_protect_sensitive_flag on public.chat_files;
create trigger trg_chat_files_protect_sensitive_flag
before update on public.chat_files
for each row
execute function private.chat_files_protect_sensitive_flag();

-- Exclude sensitive proof files from chat message attachment payloads when RPC exists.
do $$
declare
  v_oid oid;
  v_src text;
  v_patched text;
begin
  select p.oid into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_chat_messages_page'
  limit 1;
  if v_oid is null then
    -- Local stripped DBs may omit this RPC; remote apply must have it.
    if current_setting('app.stage13_9_require_messages_page', true) = '1' then
      raise exception 'get_chat_messages_page missing; cannot harden sensitive attachments';
    end if;
    raise notice 'get_chat_messages_page missing; sensitive attachment RPC patch skipped';
    return;
  end if;
  select pg_get_functiondef(v_oid) into v_src;
  if v_src ilike '%is_sensitive%' then
    return;
  end if;
  if v_src not ilike '%from public.chat_files cf%'
     or v_src not ilike '%and coalesce(cf.is_deleted, false) = false%' then
    raise exception 'get_chat_messages_page body unexpected; refusing unsafe apply';
  end if;
  v_patched := replace(
    v_src,
    'and coalesce(cf.is_deleted, false) = false',
    'and coalesce(cf.is_deleted, false) = false and coalesce(cf.is_sensitive, false) = false'
  );
  if v_patched = v_src or v_patched not ilike '%is_sensitive%' then
    raise exception 'failed to patch get_chat_messages_page for sensitive files';
  end if;
  execute v_patched;
end $$;

commit;
