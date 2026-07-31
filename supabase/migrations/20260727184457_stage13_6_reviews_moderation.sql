-- Stage 13.6 — structured reviews + moderation foundation.
-- LOCAL ONLY. Text reviews gated by feature flag (default OFF).
-- Does not alter existing difficulty vote tables/RPCs.
begin;

insert into public.admin_permissions(code, description) values
  ('moderation.read', 'Read moderation queue'),
  ('moderation.write', 'Moderate reviews')
on conflict (code) do nothing;
insert into public.admin_role_permissions(role_code, permission_code)
select r.code, p.code
from public.admin_roles r
cross join (values ('moderation.read'), ('moderation.write')) as p(code)
where r.code in ('super_admin', 'moderator')
on conflict do nothing;

create table if not exists public.app_feature_flags (
  key text primary key,
  enabled boolean not null default false,
  description text not null default '',
  updated_at timestamptz not null default now()
);
insert into public.app_feature_flags(key, enabled, description) values
  ('reviews.text_enabled', false, 'Optional free-text reviews (legal/product gate)'),
  ('reviews.structured_enabled', true, 'Structured tag ratings')
on conflict (key) do nothing;

create table if not exists public.review_tags (
  code text primary key,
  label text not null,
  entity_type text not null check (entity_type in ('teacher', 'subject')),
  sort_order integer not null default 0,
  is_active boolean not null default true
);
insert into public.review_tags(code, label, entity_type, sort_order) values
  ('clarity', 'Понятность', 'teacher', 10),
  ('fairness', 'Справедливость', 'teacher', 20),
  ('availability', 'Доступность', 'teacher', 30),
  ('usefulness', 'Полезность', 'subject', 10),
  ('workload', 'Нагрузка', 'subject', 20),
  ('organization', 'Организация', 'subject', 30)
on conflict (code) do nothing;

create table if not exists public.entity_reviews (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('teacher', 'subject')),
  entity_id uuid not null,
  author_user_id uuid not null references public.users(id) on delete cascade,
  tag_scores jsonb not null default '{}'::jsonb,
  body_text text null,
  status text not null default 'active'
    check (status in ('active', 'hidden', 'removed')),
  is_anonymous boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  hidden_at timestamptz null,
  hidden_reason text null,
  constraint entity_reviews_body_len check (body_text is null or char_length(body_text) <= 1000)
);
-- One active review per user per entity.
create unique index if not exists entity_reviews_one_active_uidx
  on public.entity_reviews (author_user_id, entity_type, entity_id)
  where status = 'active';
create index if not exists entity_reviews_entity_idx
  on public.entity_reviews (entity_type, entity_id, status);

create table if not exists public.review_reports (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null references public.entity_reviews(id) on delete cascade,
  reporter_user_id uuid not null references public.users(id) on delete cascade,
  reason_code text not null check (reason_code in ('spam', 'abuse', 'privacy', 'other')),
  note text null,
  status text not null default 'open' check (status in ('open', 'resolved', 'rejected')),
  created_at timestamptz not null default now(),
  unique (review_id, reporter_user_id)
);

create table if not exists public.review_moderation_actions (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null references public.entity_reviews(id) on delete cascade,
  actor_user_id uuid null references public.users(id) on delete set null,
  action text not null check (action in ('hide', 'restore', 'resolve_report', 'reject_report')),
  reason_text text not null default '',
  created_at timestamptz not null default now()
);

alter table public.app_feature_flags enable row level security;
alter table public.app_feature_flags force row level security;
alter table public.review_tags enable row level security;
alter table public.review_tags force row level security;
alter table public.entity_reviews enable row level security;
alter table public.entity_reviews force row level security;
alter table public.review_reports enable row level security;
alter table public.review_reports force row level security;
alter table public.review_moderation_actions enable row level security;
alter table public.review_moderation_actions force row level security;

revoke all on table public.app_feature_flags, public.review_tags, public.entity_reviews,
  public.review_reports, public.review_moderation_actions
from public, anon, authenticated;
grant select on public.app_feature_flags, public.review_tags to authenticated;

drop policy if exists app_feature_flags_read on public.app_feature_flags;
create policy app_feature_flags_read on public.app_feature_flags
  for select to authenticated using (true);
drop policy if exists review_tags_read on public.review_tags;
create policy review_tags_read on public.review_tags
  for select to authenticated using (is_active);

create or replace function private.stage13_6_can_moderate()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_ok boolean := false;
begin
  if auth.uid() is null then return false; end if;
  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is not null then
    execute 'select private.has_admin_permission($1,$2,$3,$4)'
      into v_ok using auth.uid(), 'moderation.write', 'global', null::uuid;
  end if;
  return coalesce(v_ok, false);
end $$;

create or replace function private.stage13_6_feature_enabled(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select enabled from public.app_feature_flags where key = p_key), false);
$$;

create or replace function public.get_review_feature_flags()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(key, enabled), '{}'::jsonb)
  from public.app_feature_flags
  where key like 'reviews.%';
$$;

create or replace function public.list_review_tags(p_entity_type text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order),
    '[]'::jsonb
  )
  from public.review_tags
  where is_active and entity_type = p_entity_type;
$$;

-- Public aggregate without author disclosure.
create or replace function public.get_entity_review_summary(
  p_entity_type text,
  p_entity_id uuid
) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'entity_type', p_entity_type,
    'entity_id', p_entity_id,
    'active_count', count(*) filter (where status = 'active'),
    'tag_averages', coalesce((
      select jsonb_object_agg(tag, avg_score)
      from (
        select key as tag, round(avg((value)::numeric), 2) as avg_score
        from public.entity_reviews r,
             lateral jsonb_each_text(r.tag_scores)
        where r.entity_type = p_entity_type
          and r.entity_id = p_entity_id
          and r.status = 'active'
        group by key
      ) s
    ), '{}'::jsonb),
    'text_enabled', private.stage13_6_feature_enabled('reviews.text_enabled'),
    'structured_enabled', private.stage13_6_feature_enabled('reviews.structured_enabled')
  )
  from public.entity_reviews
  where entity_type = p_entity_type and entity_id = p_entity_id;
$$;

create or replace function public.upsert_my_entity_review(
  p_entity_type text,
  p_entity_id uuid,
  p_tag_scores jsonb default '{}'::jsonb,
  p_body_text text default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_body text := nullif(btrim(coalesce(p_body_text, '')), '');
  v_recent integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_entity_type not in ('teacher', 'subject') then
    raise exception 'invalid_entity' using errcode = '22023';
  end if;
  if not private.stage13_6_feature_enabled('reviews.structured_enabled') then
    raise exception 'structured_reviews_disabled' using errcode = 'P0001';
  end if;
  if v_body is not null and not private.stage13_6_feature_enabled('reviews.text_enabled') then
    raise exception 'text_reviews_disabled' using errcode = 'P0001';
  end if;
  if v_body is not null and char_length(v_body) > 1000 then
    raise exception 'body_too_long' using errcode = '22023';
  end if;
  if p_entity_type = 'teacher' then
    if not exists (
      select 1 from public.teachers t
      where t.id = p_entity_id and t.status = 'published'
    ) then
      raise exception 'entity_not_found' using errcode = 'P0002';
    end if;
  elsif p_entity_type = 'subject' then
    if not exists (
      select 1 from public.subject_catalog sc
      where sc.id = p_entity_id and sc.status = 'published'
    ) then
      raise exception 'entity_not_found' using errcode = 'P0002';
    end if;
  end if;
  if jsonb_typeof(coalesce(p_tag_scores, '{}'::jsonb)) <> 'object' then
    raise exception 'invalid_tags' using errcode = '22023';
  end if;
  if exists (
    select 1
    from jsonb_each(coalesce(p_tag_scores, '{}'::jsonb)) kv
    where not exists (
      select 1 from public.review_tags t
      where t.code = kv.key and t.entity_type = p_entity_type and t.is_active
    )
    or jsonb_typeof(kv.value) <> 'number'
    or (kv.value)::numeric < 1
    or (kv.value)::numeric > 5
  ) then
    raise exception 'invalid_tag_scores' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_tag_scores, '{}'::jsonb)) = 'object'
     and (select count(*) from jsonb_object_keys(coalesce(p_tag_scores, '{}'::jsonb))) = 0
     and v_body is null then
    raise exception 'empty_review' using errcode = '22023';
  end if;

  select count(*) into v_recent
  from public.entity_reviews
  where author_user_id = auth.uid()
    and updated_at > now() - interval '30 seconds';
  if v_recent > 0 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.entity_reviews(
    entity_type, entity_id, author_user_id, tag_scores, body_text, status, is_anonymous, updated_at
  ) values (
    p_entity_type, p_entity_id, auth.uid(), coalesce(p_tag_scores, '{}'::jsonb), v_body,
    'active', true, now()
  )
  on conflict (author_user_id, entity_type, entity_id) where (status = 'active')
  do update set
    tag_scores = excluded.tag_scores,
    body_text = excluded.body_text,
    updated_at = now()
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.report_entity_review(
  p_review_id uuid,
  p_reason_code text,
  p_note text default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_reason_code not in ('spam', 'abuse', 'privacy', 'other') then
    raise exception 'invalid_reason' using errcode = '22023';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'note_too_long' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.entity_reviews r
    where r.id = p_review_id and r.author_user_id = auth.uid()
  ) then
    raise exception 'cannot_report_own' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.review_reports rr
    where rr.reporter_user_id = auth.uid()
      and rr.created_at > now() - interval '60 seconds'
  ) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.review_reports(review_id, reporter_user_id, reason_code, note)
  values (p_review_id, auth.uid(), p_reason_code, nullif(btrim(coalesce(p_note, '')), ''))
  on conflict (review_id, reporter_user_id) do update
    set note = excluded.note, status = 'open'
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.admin_list_moderation_queue(
  p_limit integer default 50,
  p_status text default 'queue'
) returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_6_can_moderate() then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'review_id', r.id,
          'entity_type', r.entity_type,
          'entity_id', r.entity_id,
          'status', r.status,
          'has_text', r.body_text is not null,
          'body_text', r.body_text,
          'tag_scores', r.tag_scores,
          'hidden_reason', r.hidden_reason,
          'reports', coalesce((
            select jsonb_agg(jsonb_build_object(
              'reason_code', rr.reason_code,
              'note', rr.note,
              'created_at', rr.created_at
            ) order by rr.created_at desc)
            from public.review_reports rr
            where rr.review_id = r.id and rr.status = 'open'
          ), '[]'::jsonb),
          'open_reports', (
            select count(*) from public.review_reports rr
            where rr.review_id = r.id and rr.status = 'open'
          ),
          'updated_at', r.updated_at
          -- author intentionally omitted
        ) order by r.updated_at desc)
        from (
          select * from public.entity_reviews er
          where case
            when coalesce(p_status, 'queue') = 'hidden' then er.status = 'hidden'
            when coalesce(p_status, 'queue') = 'all' then true
            else er.status = 'active'
              and exists (
                select 1 from public.review_reports rr
                where rr.review_id = er.id and rr.status = 'open'
              )
          end
          order by updated_at desc
          limit greatest(1, least(coalesce(p_limit, 50), 200))
        ) r
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_moderate_review(
  p_review_id uuid,
  p_action text,
  p_reason_text text default ''
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_row public.entity_reviews%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason_text, '')), '');
begin
  if not private.stage13_6_can_moderate() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action not in ('hide', 'restore') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) > 500 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  select * into v_row from public.entity_reviews where id = p_review_id for update;
  if not found then raise exception 'review_not_found' using errcode = 'P0002'; end if;
  if p_action = 'restore' and exists (
    select 1 from public.entity_reviews other
    where other.author_user_id = v_row.author_user_id
      and other.entity_type = v_row.entity_type
      and other.entity_id = v_row.entity_id
      and other.status = 'active'
      and other.id <> v_row.id
  ) then
    -- Deterministic: keep newer active review, leave this one hidden.
    raise exception 'restore_conflicts_with_active_review' using errcode = '23505';
  end if;
  update public.entity_reviews set
    status = case when p_action = 'hide' then 'hidden' else 'active' end,
    hidden_at = case when p_action = 'hide' then now() else null end,
    hidden_reason = case when p_action = 'hide' then v_reason else null end,
    updated_at = now()
  where id = p_review_id;
  insert into public.review_moderation_actions(review_id, actor_user_id, action, reason_text)
  values (p_review_id, auth.uid(), p_action, v_reason);
  update public.review_reports
  set status = 'resolved'
  where review_id = p_review_id and status = 'open';
  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'review.' || p_action, 'entity_review', p_review_id::text,
      jsonb_build_object('reason', v_reason)
    );
  end if;
  return p_review_id;
end $$;

create or replace function public.admin_list_moderation_actions(
  p_review_id uuid default null,
  p_limit integer default 50
) returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_6_can_moderate() then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'id', a.id,
          'review_id', a.review_id,
          'action', a.action,
          'reason_text', a.reason_text,
          'created_at', a.created_at
          -- actor intentionally omitted from default payload
        ) order by a.created_at desc)
        from (
          select * from public.review_moderation_actions
          where p_review_id is null or review_id = p_review_id
          order by created_at desc
          limit greatest(1, least(coalesce(p_limit, 50), 200))
        ) a
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function
  public.get_review_feature_flags(),
  public.list_review_tags(text),
  public.get_entity_review_summary(text,uuid),
  public.upsert_my_entity_review(text,uuid,jsonb,text),
  public.report_entity_review(uuid,text,text),
  public.admin_list_moderation_queue(integer,text),
  public.admin_moderate_review(uuid,text,text),
  public.admin_list_moderation_actions(uuid,integer)
from public, anon;
grant execute on function
  public.get_review_feature_flags(),
  public.list_review_tags(text),
  public.get_entity_review_summary(text,uuid),
  public.upsert_my_entity_review(text,uuid,jsonb,text),
  public.report_entity_review(uuid,text,text),
  public.admin_list_moderation_queue(integer,text),
  public.admin_moderate_review(uuid,text,text),
  public.admin_list_moderation_actions(uuid,integer)
to authenticated, service_role;
drop function if exists public.admin_list_moderation_queue(integer);

commit;
