-- Stage 18 P1 hardening (Codex round 2).
-- Do NOT edit 20260729152000 in place.
--
-- Fixes:
--   * audit-writing list RPCs must be VOLATILE, not STABLE
--   * reviews.moderation_required ON for Stage 18 completed contract
--   * unified moderation queue returns moderator-only author/assignee fields
--   * optional author / assignee / priority / since filters on the queue
--   * get_my_entity_reviews + admin_list_review_moderation_actions for mobile/admin

begin;

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- 1. Enable publish-after-approve for the Stage 18 contract.
-- ---------------------------------------------------------------------------
insert into public.app_feature_flags (key, enabled, description)
values (
  'reviews.moderation_required',
  true,
  'Publish-after-approve for reviews (Stage 18). ON = pending until moderated.'
)
on conflict (key) do update
  set enabled = true,
      description = excluded.description;

-- ---------------------------------------------------------------------------
-- 2. Moderator-only author label helper (never exposed on public read paths).
-- ---------------------------------------------------------------------------
create or replace function private.moderation_author_label(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    nullif(
      btrim(
        coalesce(u.name, '')
        || case
             when coalesce(u.surname, '') <> '' then ' ' || u.surname
             else ''
           end
      ),
      ''
    ),
    nullif(btrim(u.login::text), ''),
    left(p_user_id::text, 8)
  )
  from public.users u
  where u.id = p_user_id;
$$;

revoke all on function private.moderation_author_label(uuid)
  from public, anon, authenticated;
grant execute on function private.moderation_author_label(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 3. admin_list_student_points: VOLATILE (writes audit).
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_student_points(
  p_user_id uuid,
  p_limit integer default 50
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  v_uid := private.require_any_admin_permission(
    array['students.read', 'moderation.read']
  );

  if p_user_id is null then
    raise exception 'invalid_id' using errcode = '22023';
  end if;

  perform private.admin_write_audit(
    'points.list', 'student_points_ledger', p_user_id::text, '{}'::jsonb
  );

  return jsonb_build_object(
    'user_id', p_user_id,
    'balance', private.student_points_balance(p_user_id),
    'entries', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', l.id,
            'review_id', l.review_id,
            'delta', l.delta,
            'reason_code', l.reason_code,
            'meta', l.meta,
            'created_at', l.created_at
          )
          order by l.created_at desc
        )
        from (
          select *
          from public.student_points_ledger l0
          where l0.user_id = p_user_id
          order by l0.created_at desc
          limit v_limit
        ) l
      ),
      '[]'::jsonb
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Unified moderation queue: VOLATILE + moderator-only identity fields.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_unified_moderation_queue(
  text[], text, integer, integer, timestamptz
);

create or replace function public.admin_list_unified_moderation_queue(
  p_domains text[] default null,
  p_status text default 'open',
  p_limit integer default 50,
  p_offset integer default 0,
  p_since timestamptz default null,
  p_author_user_id uuid default null,
  p_assignee_user_id uuid default null,
  p_min_priority integer default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'open');
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_all text[] := array[
    'review', 'review_report', 'vacancy', 'vacancy_report', 'content_correction'
  ];
  v_domains text[];
  v_bad text;
begin
  v_uid := private.require_admin_permission('moderation.read');

  if v_status not in ('open', 'closed', 'all') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct d), '{}'::text[]) into v_domains
  from unnest(coalesce(p_domains, v_all)) as d
  where d is not null;

  if coalesce(array_length(v_domains, 1), 0) = 0 then
    v_domains := v_all;
  end if;

  select string_agg(d, ',' order by d) into v_bad
  from unnest(v_domains) as d
  where not (d = any (v_all));
  if v_bad is not null then
    raise exception 'unknown_domain: %', v_bad using errcode = '22023';
  end if;

  perform private.admin_write_audit(
    'moderation.unified_queue',
    'moderation_queue',
    null,
    jsonb_build_object(
      'domains', to_jsonb(v_domains),
      'status', v_status,
      'author_user_id', p_author_user_id,
      'assignee_user_id', p_assignee_user_id,
      'min_priority', p_min_priority
    )
  );

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'domain', q.domain,
          'entity_id', q.entity_id,
          'parent_id', q.parent_id,
          'title', q.title,
          'detail', q.detail,
          'status', q.status,
          'reason_code', q.reason_code,
          'open_reports', q.open_reports,
          'row_version', q.row_version,
          'created_at', q.created_at,
          'updated_at', q.updated_at,
          'author_user_id', q.author_user_id,
          'author_label', q.author_label,
          'assignee_user_id', q.assignee_user_id,
          'priority', q.priority
        )
        order by q.priority desc nulls last, q.updated_at desc, q.entity_id
      )
      from (
        select *
        from (
          select
            'review'::text as domain,
            r.id as entity_id,
            r.entity_id as parent_id,
            r.entity_type as title,
            left(coalesce(r.body_text, ''), 300) as detail,
            r.moderation_status as status,
            null::text as reason_code,
            (
              select count(*)::integer
              from public.review_reports rr
              where rr.review_id = r.id and rr.status = 'open'
            ) as open_reports,
            null::integer as row_version,
            r.created_at,
            r.updated_at,
            r.author_user_id,
            private.moderation_author_label(r.author_user_id) as author_label,
            r.moderated_by as assignee_user_id,
            (
              select count(*)::integer
              from public.review_reports rr
              where rr.review_id = r.id and rr.status = 'open'
            ) as priority,
            (
              r.moderation_status = 'pending'
              or exists (
                select 1
                from public.review_reports rr
                where rr.review_id = r.id and rr.status = 'open'
              )
            ) as is_open
          from public.entity_reviews r
          where 'review' = any (v_domains)

          union all

          select
            'review_report'::text,
            rr.id,
            rr.review_id,
            'review_report'::text,
            left(coalesce(rr.note, ''), 300),
            rr.status,
            rr.reason_code,
            null::integer,
            null::integer,
            rr.created_at,
            rr.created_at,
            rr.reporter_user_id,
            private.moderation_author_label(rr.reporter_user_id),
            er.moderated_by,
            case rr.reason_code
              when 'abuse' then 30
              when 'privacy' then 20
              else 10
            end,
            (rr.status = 'open')
          from public.review_reports rr
          left join public.entity_reviews er on er.id = rr.review_id
          where 'review_report' = any (v_domains)

          union all

          select
            'vacancy'::text,
            v.id,
            null::uuid,
            left(v.title, 200),
            left(v.summary, 300),
            v.status,
            v.origin,
            (
              select count(*)::integer
              from public.vacancy_reports vr
              where vr.vacancy_id = v.id and vr.status = 'open'
            ),
            v.row_version,
            v.created_at,
            v.updated_at,
            v.submitted_by,
            private.moderation_author_label(v.submitted_by),
            v.moderated_by,
            v.priority,
            (
              v.status in ('submitted', 'in_moderation')
              or exists (
                select 1
                from public.vacancy_reports vr
                where vr.vacancy_id = v.id and vr.status = 'open'
              )
            )
          from public.vacancies v
          where 'vacancy' = any (v_domains)

          union all

          select
            'vacancy_report'::text,
            vr.id,
            vr.vacancy_id,
            'vacancy_report'::text,
            left(coalesce(vr.note, ''), 300),
            vr.status,
            vr.reason_code,
            null::integer,
            null::integer,
            vr.created_at,
            vr.created_at,
            vr.reporter_user_id,
            private.moderation_author_label(vr.reporter_user_id),
            v.moderated_by,
            case vr.reason_code
              when 'abuse' then 30
              when 'privacy' then 20
              else 10
            end,
            (vr.status = 'open')
          from public.vacancy_reports vr
          left join public.vacancies v on v.id = vr.vacancy_id
          where 'vacancy_report' = any (v_domains)

          union all

          select
            'content_correction'::text,
            cc.id,
            cc.content_item_id,
            left(coalesce(ci.title, ''), 200),
            left(cc.note, 300),
            cc.status,
            null::text,
            null::integer,
            null::integer,
            cc.created_at,
            coalesce(cc.resolved_at, cc.created_at),
            cc.reporter_user_id,
            private.moderation_author_label(cc.reporter_user_id),
            cc.resolved_by,
            0,
            (cc.status = 'open')
          from public.content_corrections cc
          join public.content_items ci on ci.id = cc.content_item_id
          where 'content_correction' = any (v_domains)
        ) rows
        where (
            v_status = 'all'
            or (v_status = 'open' and rows.is_open)
            or (v_status = 'closed' and not rows.is_open)
          )
          and (p_since is null or rows.updated_at >= p_since)
          and (p_author_user_id is null or rows.author_user_id = p_author_user_id)
          and (p_assignee_user_id is null or rows.assignee_user_id = p_assignee_user_id)
          and (p_min_priority is null or coalesce(rows.priority, 0) >= p_min_priority)
        order by rows.priority desc nulls last, rows.updated_at desc, rows.entity_id
        limit v_limit
        offset v_offset
      ) q
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.admin_list_unified_moderation_queue(
  text[], text, integer, integer, timestamptz, uuid, uuid, integer
) from public, anon;
grant execute on function public.admin_list_unified_moderation_queue(
  text[], text, integer, integer, timestamptz, uuid, uuid, integer
) to authenticated, service_role;

comment on function public.admin_list_unified_moderation_queue(
  text[], text, integer, integer, timestamptz, uuid, uuid, integer
) is
  'Unified moderation queue. moderation.read only; author_label is moderator-only (never on public reads).';

-- ---------------------------------------------------------------------------
-- 5. Mobile: list the caller''s own reviews (entity ids + moderation state).
-- ---------------------------------------------------------------------------
create or replace function public.get_my_entity_reviews(
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'review_id', x.id,
          'entity_type', x.entity_type,
          'entity_id', x.entity_id,
          'entity_label', x.entity_label,
          'tag_scores', x.tag_scores,
          'body_text', x.body_text,
          'moderation_status', x.moderation_status,
          'status', x.status,
          'updated_at', x.updated_at
        )
        order by x.updated_at desc
      )
      from (
        select
          r.id,
          r.entity_type,
          r.entity_id,
          case
            when r.entity_type = 'teacher' then coalesce(
              nullif(btrim(t.full_name), ''), 'Преподаватель')
            else coalesce(
              nullif(btrim(sc.display_name), ''),
              nullif(btrim(sc.raw_subject_name), ''),
              'Предмет')
          end as entity_label,
          r.tag_scores,
          r.body_text,
          r.moderation_status,
          r.status,
          r.updated_at
        from public.entity_reviews r
        left join public.teachers t
          on r.entity_type = 'teacher' and t.id = r.entity_id
        left join public.subject_catalog sc
          on r.entity_type = 'subject' and sc.id = r.entity_id
        where r.author_user_id = v_uid
          and r.status <> 'removed'
        order by r.updated_at desc
        limit v_limit
      ) x
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.get_my_entity_reviews(integer) from public, anon;
grant execute on function public.get_my_entity_reviews(integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Admin: review moderation journal (parity with vacancy history RPC).
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_review_moderation_actions(
  p_review_id uuid,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  v_uid := private.require_admin_permission('moderation.read');

  if not exists (select 1 from public.entity_reviews where id = p_review_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', a.id,
          'action', a.action,
          'reason_text', a.reason_text,
          'created_at', a.created_at
        )
        order by a.created_at desc
      )
      from (
        select *
        from public.review_moderation_actions ma
        where ma.review_id = p_review_id
        order by ma.created_at desc
        limit v_limit
      ) a
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.admin_list_review_moderation_actions(uuid, integer)
  from public, anon;
grant execute on function public.admin_list_review_moderation_actions(uuid, integer)
  to authenticated, service_role;

commit;
