-- Stage 12.2: news_posts + versions + views + SECURITY DEFINER RPCs.
-- Clients never get table DML. All mutations go through RBAC-gated RPCs.
-- Storage bucket news-media is private; uploads via Edge Function only.

begin;

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'news_post_status') then
    create type public.news_post_status as enum ('draft', 'published', 'archived');
  end if;
  if not exists (select 1 from pg_type where typname = 'news_audience_type') then
    create type public.news_audience_type as enum ('all', 'group');
  end if;
  if not exists (select 1 from pg_type where typname = 'news_card_variant') then
    create type public.news_card_variant as enum (
      'gradientText',
      'imageOnly',
      'imageOverlay',
      'imageWithText'
    );
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.news_posts (
  id uuid primary key default gen_random_uuid(),
  status public.news_post_status not null default 'draft',
  sort_order integer not null default 0,
  priority integer not null default 0,
  starts_at timestamptz null,
  ends_at timestamptz null,
  audience_type public.news_audience_type not null default 'all',
  audience_group_id uuid null references public.groups (id) on delete set null,
  variant public.news_card_variant not null default 'gradientText',
  title text not null default '',
  subtitle text not null default '',
  body text not null default '',
  gradient_colors text[] not null default array['#7367F0', '#B784F7']::text[],
  image_path text null,
  image_focus_x double precision not null default 0,
  image_focus_y double precision not null default 0,
  overlay_opacity double precision not null default 0.42
    check (overlay_opacity >= 0 and overlay_opacity <= 1),
  is_hidden boolean not null default false,
  version_number integer not null default 1,
  created_by uuid null references public.users (id) on delete set null,
  updated_by uuid null references public.users (id) on delete set null,
  published_by uuid null references public.users (id) on delete set null,
  published_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint news_posts_audience_chk check (
    (audience_type = 'all' and audience_group_id is null)
    or (audience_type = 'group' and audience_group_id is not null)
  ),
  constraint news_posts_focus_chk check (
    image_focus_x between -1 and 1
    and image_focus_y between -1 and 1
  )
);

create index if not exists news_posts_status_sort_idx
  on public.news_posts (status, sort_order, priority desc, updated_at desc);
create index if not exists news_posts_audience_group_idx
  on public.news_posts (audience_group_id)
  where audience_type = 'group';
create index if not exists news_posts_schedule_idx
  on public.news_posts (starts_at, ends_at)
  where status = 'published';

create table if not exists public.news_versions (
  id uuid primary key default gen_random_uuid(),
  news_post_id uuid not null references public.news_posts (id) on delete cascade,
  version_number integer not null,
  snapshot jsonb not null,
  created_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint news_versions_unique unique (news_post_id, version_number)
);

create index if not exists news_versions_post_idx
  on public.news_versions (news_post_id, version_number desc);

create table if not exists public.news_views (
  news_post_id uuid not null references public.news_posts (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  seen_at timestamptz not null default now(),
  closed_at timestamptz null,
  primary key (news_post_id, user_id)
);

create index if not exists news_views_user_idx
  on public.news_views (user_id, seen_at desc);

-- ---------------------------------------------------------------------------
-- Lock down tables
-- ---------------------------------------------------------------------------
alter table public.news_posts enable row level security;
alter table public.news_posts force row level security;
alter table public.news_versions enable row level security;
alter table public.news_versions force row level security;
alter table public.news_views enable row level security;
alter table public.news_views force row level security;

revoke all on table public.news_posts from public, anon, authenticated;
revoke all on table public.news_versions from public, anon, authenticated;
revoke all on table public.news_views from public, anon, authenticated;

grant select, insert, update, delete on table public.news_posts to service_role;
grant select, insert, update, delete on table public.news_versions to service_role;
grant select, insert, update, delete on table public.news_views to service_role;

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------
create or replace function private.news_post_to_json(p_row public.news_posts)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_row.id,
    'status', p_row.status,
    'sort_order', p_row.sort_order,
    'priority', p_row.priority,
    'starts_at', p_row.starts_at,
    'ends_at', p_row.ends_at,
    'audience_type', p_row.audience_type,
    'audience_group_id', p_row.audience_group_id,
    'variant', p_row.variant,
    'title', p_row.title,
    'subtitle', p_row.subtitle,
    'body', p_row.body,
    'gradient_colors', to_jsonb(p_row.gradient_colors),
    'image_path', p_row.image_path,
    'image_focus_x', p_row.image_focus_x,
    'image_focus_y', p_row.image_focus_y,
    'overlay_opacity', p_row.overlay_opacity,
    'is_hidden', p_row.is_hidden,
    'version_number', p_row.version_number,
    'created_by', p_row.created_by,
    'updated_by', p_row.updated_by,
    'published_by', p_row.published_by,
    'published_at', p_row.published_at,
    'created_at', p_row.created_at,
    'updated_at', p_row.updated_at
  );
$$;

revoke all on function private.news_post_to_json(public.news_posts)
  from public, anon, authenticated;
grant execute on function private.news_post_to_json(public.news_posts)
  to service_role;

create or replace function private.news_snapshot_version(p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.news_posts;
begin
  select * into v_row from public.news_posts where id = p_post_id;
  if not found then
    return;
  end if;

  insert into public.news_versions (
    news_post_id, version_number, snapshot, created_by
  ) values (
    v_row.id,
    v_row.version_number,
    private.news_post_to_json(v_row),
    auth.uid()
  )
  on conflict (news_post_id, version_number) do update
    set snapshot = excluded.snapshot,
        created_by = excluded.created_by,
        created_at = now();
end;
$$;

revoke all on function private.news_snapshot_version(uuid)
  from public, anon, authenticated;
grant execute on function private.news_snapshot_version(uuid) to service_role;

create or replace function private.current_user_active_group_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    array_agg(distinct se.group_id),
    '{}'::uuid[]
  )
  from public.student_enrollments se
  where se.user_id = auth.uid()
    and se.status = 'active'
    and se.ended_at is null;
$$;

revoke all on function private.current_user_active_group_ids()
  from public, anon, authenticated;
grant execute on function private.current_user_active_group_ids() to service_role;

create or replace function private.require_admin_permission(p_permission text)
returns uuid
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
  if not private.has_admin_permission(v_uid, p_permission, 'global', null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return v_uid;
end;
$$;

revoke all on function private.require_admin_permission(text)
  from public, anon, authenticated;
grant execute on function private.require_admin_permission(text) to service_role;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_news(
  p_status text default null,
  p_include_hidden boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_status public.news_post_status;
begin
  v_uid := private.require_admin_permission('content.read');

  if p_status is not null then
    begin
      v_status := p_status::public.news_post_status;
    exception when others then
      raise exception 'invalid_status' using errcode = '22023';
    end;
  end if;

  perform private.admin_write_audit(
    'news.list',
    'news_post',
    null,
    jsonb_build_object('status', p_status, 'include_hidden', p_include_hidden)
  );

  return coalesce(
    (
      select jsonb_agg(private.news_post_to_json(n) order by n.sort_order, n.priority desc, n.updated_at desc)
      from public.news_posts n
      where (p_status is null or n.status = v_status)
        and (p_include_hidden or not n.is_hidden)
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_get_news(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
begin
  v_uid := private.require_admin_permission('content.read');

  select * into v_row from public.news_posts where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.admin_write_audit(
    'news.get',
    'news_post',
    p_id::text,
    '{}'::jsonb
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_create_news_draft(
  p_title text default '',
  p_subtitle text default '',
  p_body text default '',
  p_variant text default 'gradientText'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
  v_variant public.news_card_variant;
  v_sort integer;
begin
  v_uid := private.require_admin_permission('content.write');

  begin
    v_variant := coalesce(nullif(trim(p_variant), ''), 'gradientText')::public.news_card_variant;
  exception when others then
    raise exception 'invalid_variant' using errcode = '22023';
  end;

  select coalesce(max(sort_order), -1) + 1 into v_sort from public.news_posts;

  insert into public.news_posts (
    title, subtitle, body, variant, sort_order, created_by, updated_by
  ) values (
    coalesce(p_title, ''),
    coalesce(p_subtitle, ''),
    coalesce(p_body, ''),
    v_variant,
    v_sort,
    v_uid,
    v_uid
  )
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.create_draft',
    'news_post',
    v_row.id::text,
    jsonb_build_object('variant', v_row.variant)
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_update_news_draft(
  p_id uuid,
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
  p jsonb := coalesce(p_patch, '{}'::jsonb);
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  -- Snapshot current state before mutation.
  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    title = case when p ? 'title' then coalesce(p->>'title', '') else n.title end,
    subtitle = case when p ? 'subtitle' then coalesce(p->>'subtitle', '') else n.subtitle end,
    body = case when p ? 'body' then coalesce(p->>'body', '') else n.body end,
    variant = case
      when p ? 'variant' then (p->>'variant')::public.news_card_variant
      else n.variant
    end,
    gradient_colors = case
      when p ? 'gradient_colors' then array(
        select jsonb_array_elements_text(p->'gradient_colors')
      )
      else n.gradient_colors
    end,
    image_path = case
      when p ? 'image_path' then nullif(p->>'image_path', '')
      else n.image_path
    end,
    image_focus_x = case
      when p ? 'image_focus_x' then (p->>'image_focus_x')::double precision
      else n.image_focus_x
    end,
    image_focus_y = case
      when p ? 'image_focus_y' then (p->>'image_focus_y')::double precision
      else n.image_focus_y
    end,
    overlay_opacity = case
      when p ? 'overlay_opacity' then (p->>'overlay_opacity')::double precision
      else n.overlay_opacity
    end,
    is_hidden = case
      when p ? 'is_hidden' then (p->>'is_hidden')::boolean
      else n.is_hidden
    end,
    priority = case
      when p ? 'priority' then (p->>'priority')::integer
      else n.priority
    end,
    starts_at = case
      when p ? 'starts_at' then nullif(p->>'starts_at', '')::timestamptz
      else n.starts_at
    end,
    ends_at = case
      when p ? 'ends_at' then nullif(p->>'ends_at', '')::timestamptz
      else n.ends_at
    end,
    audience_type = case
      when p ? 'audience_type' then (p->>'audience_type')::public.news_audience_type
      else n.audience_type
    end,
    audience_group_id = case
      when p ? 'audience_group_id' then nullif(p->>'audience_group_id', '')::uuid
      else n.audience_group_id
    end,
    sort_order = case
      when p ? 'sort_order' then (p->>'sort_order')::integer
      else n.sort_order
    end,
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.update_draft',
    'news_post',
    p_id::text,
    jsonb_build_object('version_number', v_row.version_number)
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_publish_news(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
begin
  v_uid := private.require_admin_permission('content.publish');

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if v_row.status = 'archived' then
    raise exception 'archived_immutable' using errcode = '55000';
  end if;

  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    status = 'published',
    published_by = v_uid,
    published_at = coalesce(n.published_at, now()),
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.publish',
    'news_post',
    p_id::text,
    jsonb_build_object('version_number', v_row.version_number)
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_unpublish_news(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
begin
  v_uid := private.require_admin_permission('content.publish');

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    status = 'draft',
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.unpublish',
    'news_post',
    p_id::text,
    jsonb_build_object('version_number', v_row.version_number)
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_archive_news(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.news_posts;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    status = 'archived',
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.archive',
    'news_post',
    p_id::text,
    jsonb_build_object('version_number', v_row.version_number)
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_duplicate_news(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_src public.news_posts;
  v_row public.news_posts;
  v_sort integer;
begin
  v_uid := private.require_admin_permission('content.write');

  select * into v_src from public.news_posts where id = p_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select coalesce(max(sort_order), -1) + 1 into v_sort from public.news_posts;

  insert into public.news_posts (
    status, sort_order, priority, starts_at, ends_at,
    audience_type, audience_group_id, variant,
    title, subtitle, body, gradient_colors,
    image_path, image_focus_x, image_focus_y, overlay_opacity,
    is_hidden, created_by, updated_by
  ) values (
    'draft', v_sort, v_src.priority, v_src.starts_at, v_src.ends_at,
    v_src.audience_type, v_src.audience_group_id, v_src.variant,
    v_src.title || ' (копия)', v_src.subtitle, v_src.body, v_src.gradient_colors,
    v_src.image_path, v_src.image_focus_x, v_src.image_focus_y, v_src.overlay_opacity,
    v_src.is_hidden, v_uid, v_uid
  )
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.duplicate',
    'news_post',
    v_row.id::text,
    jsonb_build_object('source_id', p_id)
  );

  return private.news_post_to_json(v_row);
end;
$$;

create or replace function public.admin_reorder_news(p_ordered_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_id uuid;
  v_i integer := 0;
begin
  v_uid := private.require_admin_permission('content.write');

  if p_ordered_ids is null then
    raise exception 'invalid_order' using errcode = '22023';
  end if;

  foreach v_id in array p_ordered_ids loop
    update public.news_posts
    set sort_order = v_i,
        updated_by = v_uid,
        updated_at = now()
    where id = v_id;
    v_i := v_i + 1;
  end loop;

  perform private.admin_write_audit(
    'news.reorder',
    'news_post',
    null,
    jsonb_build_object('count', coalesce(array_length(p_ordered_ids, 1), 0))
  );

  return coalesce(
    (
      select jsonb_agg(
        private.news_post_to_json(n)
        order by n.sort_order, n.priority desc, n.updated_at desc
      )
      from public.news_posts n
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_list_news_versions(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  v_uid := private.require_admin_permission('content.read');

  if not exists (select 1 from public.news_posts where id = p_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.admin_write_audit(
    'news.list_versions',
    'news_post',
    p_id::text,
    '{}'::jsonb
  );

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', v.id,
          'news_post_id', v.news_post_id,
          'version_number', v.version_number,
          'created_by', v.created_by,
          'created_at', v.created_at,
          'snapshot', v.snapshot
        )
        order by v.version_number desc
      )
      from public.news_versions v
      where v.news_post_id = p_id
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_restore_news_version(
  p_id uuid,
  p_version_number integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_snap jsonb;
  v_row public.news_posts;
begin
  v_uid := private.require_admin_permission('content.write');

  select snapshot into v_snap
  from public.news_versions
  where news_post_id = p_id and version_number = p_version_number;

  if v_snap is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  select * into v_row from public.news_posts where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform private.news_snapshot_version(v_row.id);

  update public.news_posts n set
    -- restore content fields; keep status unless snapshot had draft/published and not archived force
    title = coalesce(v_snap->>'title', ''),
    subtitle = coalesce(v_snap->>'subtitle', ''),
    body = coalesce(v_snap->>'body', ''),
    variant = coalesce(v_snap->>'variant', 'gradientText')::public.news_card_variant,
    gradient_colors = coalesce(
      array(select jsonb_array_elements_text(v_snap->'gradient_colors')),
      n.gradient_colors
    ),
    image_path = nullif(v_snap->>'image_path', ''),
    image_focus_x = coalesce((v_snap->>'image_focus_x')::double precision, 0),
    image_focus_y = coalesce((v_snap->>'image_focus_y')::double precision, 0),
    overlay_opacity = coalesce((v_snap->>'overlay_opacity')::double precision, 0.42),
    is_hidden = coalesce((v_snap->>'is_hidden')::boolean, false),
    priority = coalesce((v_snap->>'priority')::integer, 0),
    starts_at = nullif(v_snap->>'starts_at', '')::timestamptz,
    ends_at = nullif(v_snap->>'ends_at', '')::timestamptz,
    audience_type = coalesce(v_snap->>'audience_type', 'all')::public.news_audience_type,
    audience_group_id = nullif(v_snap->>'audience_group_id', '')::uuid,
    version_number = n.version_number + 1,
    updated_by = v_uid,
    updated_at = now()
  where n.id = p_id
  returning * into v_row;

  perform private.news_snapshot_version(v_row.id);

  perform private.admin_write_audit(
    'news.restore_version',
    'news_post',
    p_id::text,
    jsonb_build_object(
      'restored_version', p_version_number,
      'new_version', v_row.version_number
    )
  );

  return private.news_post_to_json(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- Student RPCs
-- ---------------------------------------------------------------------------
create or replace function public.get_my_published_news()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_groups uuid[];
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  v_groups := private.current_user_active_group_ids();

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', n.id,
          'status', n.status,
          'sort_order', n.sort_order,
          'priority', n.priority,
          'starts_at', n.starts_at,
          'ends_at', n.ends_at,
          'audience_type', n.audience_type,
          'audience_group_id', n.audience_group_id,
          'variant', n.variant,
          'title', n.title,
          'subtitle', n.subtitle,
          'body', n.body,
          'gradient_colors', to_jsonb(n.gradient_colors),
          'image_path', n.image_path,
          'image_focus_x', n.image_focus_x,
          'image_focus_y', n.image_focus_y,
          'overlay_opacity', n.overlay_opacity,
          'published_at', n.published_at,
          'created_at', n.created_at,
          'updated_at', n.updated_at,
          'seen', (nv.seen_at is not null),
          'closed', (nv.closed_at is not null)
        )
        order by n.sort_order, n.priority desc, n.published_at desc nulls last
      )
      from public.news_posts n
      left join public.news_views nv
        on nv.news_post_id = n.id and nv.user_id = v_uid
      where n.status = 'published'
        and not n.is_hidden
        and (n.starts_at is null or n.starts_at <= now())
        and (n.ends_at is null or n.ends_at >= now())
        and (
          n.audience_type = 'all'
          or (
            n.audience_type = 'group'
            and n.audience_group_id = any (v_groups)
          )
        )
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.mark_news_seen(
  p_news_id uuid,
  p_closed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_visible boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select exists (
    select 1
    from public.news_posts n
    where n.id = p_news_id
      and n.status = 'published'
      and not n.is_hidden
      and (n.starts_at is null or n.starts_at <= now())
      and (n.ends_at is null or n.ends_at >= now())
      and (
        n.audience_type = 'all'
        or (
          n.audience_type = 'group'
          and n.audience_group_id = any (private.current_user_active_group_ids())
        )
      )
  ) into v_visible;

  if not v_visible then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  insert into public.news_views (news_post_id, user_id, seen_at, closed_at)
  values (
    p_news_id,
    v_uid,
    now(),
    case when p_closed then now() else null end
  )
  on conflict (news_post_id, user_id) do update
    set seen_at = public.news_views.seen_at,
        closed_at = case
          when p_closed then coalesce(public.news_views.closed_at, now())
          else public.news_views.closed_at
        end;

  return jsonb_build_object('ok', true, 'news_id', p_news_id, 'closed', p_closed);
end;
$$;

-- Capability probes for Edge Function (no audit spam).
create or replace function public.admin_can_manage_news_media()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return false;
  end if;
  return private.has_admin_permission(v_uid, 'content.write', 'global', null);
end;
$$;

create or replace function public.admin_can_read_news_media()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return false;
  end if;
  return private.has_admin_permission(v_uid, 'content.read', 'global', null)
    or private.has_admin_permission(v_uid, 'content.write', 'global', null);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants for RPCs
-- ---------------------------------------------------------------------------
revoke all on function public.admin_list_news(text, boolean) from public, anon;
grant execute on function public.admin_list_news(text, boolean) to authenticated, service_role;

revoke all on function public.admin_get_news(uuid) from public, anon;
grant execute on function public.admin_get_news(uuid) to authenticated, service_role;

revoke all on function public.admin_create_news_draft(text, text, text, text) from public, anon;
grant execute on function public.admin_create_news_draft(text, text, text, text) to authenticated, service_role;

revoke all on function public.admin_update_news_draft(uuid, jsonb) from public, anon;
grant execute on function public.admin_update_news_draft(uuid, jsonb) to authenticated, service_role;

revoke all on function public.admin_publish_news(uuid) from public, anon;
grant execute on function public.admin_publish_news(uuid) to authenticated, service_role;

revoke all on function public.admin_unpublish_news(uuid) from public, anon;
grant execute on function public.admin_unpublish_news(uuid) to authenticated, service_role;

revoke all on function public.admin_archive_news(uuid) from public, anon;
grant execute on function public.admin_archive_news(uuid) to authenticated, service_role;

revoke all on function public.admin_duplicate_news(uuid) from public, anon;
grant execute on function public.admin_duplicate_news(uuid) to authenticated, service_role;

revoke all on function public.admin_reorder_news(uuid[]) from public, anon;
grant execute on function public.admin_reorder_news(uuid[]) to authenticated, service_role;

revoke all on function public.admin_list_news_versions(uuid) from public, anon;
grant execute on function public.admin_list_news_versions(uuid) to authenticated, service_role;

revoke all on function public.admin_restore_news_version(uuid, integer) from public, anon;
grant execute on function public.admin_restore_news_version(uuid, integer) to authenticated, service_role;

revoke all on function public.get_my_published_news() from public, anon;
grant execute on function public.get_my_published_news() to authenticated, service_role;

revoke all on function public.mark_news_seen(uuid, boolean) from public, anon;
grant execute on function public.mark_news_seen(uuid, boolean) to authenticated, service_role;

revoke all on function public.admin_can_manage_news_media() from public, anon;
grant execute on function public.admin_can_manage_news_media() to authenticated, service_role;

revoke all on function public.admin_can_read_news_media() from public, anon;
grant execute on function public.admin_can_read_news_media() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Private storage bucket (no public/anon object access)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'news-media',
  'news-media',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Deny direct client access; Edge Function uses service_role.
drop policy if exists "news_media_no_anon" on storage.objects;
drop policy if exists "news_media_no_authenticated" on storage.objects;

-- No permissive policies for anon/authenticated on news-media.
-- Explicit deny via absence of policies + RLS enabled on storage.objects.

commit;
