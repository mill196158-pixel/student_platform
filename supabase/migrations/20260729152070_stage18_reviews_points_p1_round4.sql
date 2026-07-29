-- Stage 18 P1 hardening round 4 (Codex).
-- Do NOT edit earlier Stage 18 migrations in place.
--
-- Fixes:
--   * vacancy request_clarification preserves rejection_reason
--   * author-scoped get / update-draft / resubmit for clarified vacancies
--   * get_my_entity_reviews returns moderation_reason to the author

begin;

-- ---------------------------------------------------------------------------
-- 1. Vacancy moderation: keep clarification reason on draft return.
-- ---------------------------------------------------------------------------
create or replace function public.admin_moderate_vacancy(
  p_id uuid,
  p_action text,
  p_expected_row_version integer,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_action text := nullif(btrim(coalesce(p_action, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_from text;
  v_to text;
begin
  v_uid := private.require_any_admin_permission(
    array['moderation.action', 'moderation.write']
  );

  if v_action is null
     or v_action not in (
       'take_in_moderation', 'approve', 'reject', 'request_clarification'
     ) then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;
  if v_action in ('reject', 'request_clarification') and v_reason is null then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  v_row := private.vacancy_lock(p_id, p_expected_row_version);
  v_from := v_row.status;

  if v_row.submitted_by is not null and v_row.submitted_by = v_uid then
    raise exception 'cannot_moderate_own_submission' using errcode = '42501';
  end if;

  if v_action = 'approve' and v_from <> 'in_moderation' then
    raise exception 'approve_requires_in_moderation' using errcode = '22023';
  end if;

  v_to := case v_action
    when 'take_in_moderation' then 'in_moderation'
    when 'approve' then 'approved'
    when 'request_clarification' then 'draft'
    else 'rejected'
  end;

  perform private.vacancy_assert_transition(v_from, v_to);

  update public.vacancies v set
    status = v_to,
    moderated_by = v_uid,
    moderated_at = now(),
    -- Reject and clarification both expose a reason to the author.
    -- Approve / take_in_moderation clear stale reasons.
    rejection_reason = case
      when v_action in ('reject', 'request_clarification') then v_reason
      else null
    end,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(p_id, v_action, v_from, v_to, coalesce(v_reason, ''));

  return private.vacancy_to_admin_json(p_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Author: list own vacancy submissions (incl. draft + clarification reason).
-- ---------------------------------------------------------------------------
create or replace function public.get_my_vacancy_submissions(
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
          'id', x.id,
          'title', x.title,
          'company_name', x.company_name,
          'summary', x.summary,
          'description', x.description,
          'employment_type', x.employment_type,
          'work_format', x.work_format,
          'location', x.location,
          'salary_text', x.salary_text,
          'external_url', x.external_url,
          'contacts', x.contacts,
          'status', x.status,
          'origin', x.origin,
          'rejection_reason', x.rejection_reason,
          'row_version', x.row_version,
          'submitted_at', x.submitted_at,
          'updated_at', x.updated_at
        )
        order by x.updated_at desc
      )
      from (
        select
          v.id,
          v.title,
          v.company_name,
          v.summary,
          v.description,
          v.employment_type,
          v.work_format,
          v.location,
          v.salary_text,
          v.external_url,
          v.contacts,
          v.status,
          v.origin,
          v.rejection_reason,
          v.row_version,
          v.submitted_at,
          v.updated_at
        from public.vacancies v
        where v.submitted_by = v_uid
          and v.origin = 'user_submission'
          and v.status in (
            'draft', 'submitted', 'in_moderation', 'rejected', 'approved', 'published'
          )
        order by v.updated_at desc
        limit v_limit
      ) x
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.get_my_vacancy_submissions(integer)
  from public, anon;
grant execute on function public.get_my_vacancy_submissions(integer)
  to authenticated, service_role;

comment on function public.get_my_vacancy_submissions(integer) is
  'Author-scoped vacancy submissions. Includes rejection_reason for reject/clarification.';

-- ---------------------------------------------------------------------------
-- 3. Author: update own draft (after clarification) and resubmit.
-- ---------------------------------------------------------------------------
create or replace function public.update_my_vacancy_draft(
  p_id uuid,
  p_patch jsonb,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_row public.vacancies;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_expected_row_version is null then
    raise exception 'expected_version_required' using errcode = '22023';
  end if;

  perform private.vacancy_assert_patch(v_patch, array[
    'title', 'company_name', 'summary', 'description', 'employment_type',
    'work_format', 'location', 'salary_text', 'external_url', 'contacts'
  ]);

  select * into v_row
  from public.vacancies v
  where v.id = p_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.submitted_by is distinct from v_uid
     or v_row.origin <> 'user_submission' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'not_editable_in_status_%', v_row.status using errcode = '55000';
  end if;
  if v_row.row_version is distinct from p_expected_row_version then
    raise exception 'row_version_conflict' using errcode = '40001';
  end if;

  if v_patch ? 'title' and nullif(btrim(coalesce(v_patch ->> 'title', '')), '') is null then
    raise exception 'invalid_title' using errcode = '22023';
  end if;

  update public.vacancies v set
    title = case when v_patch ? 'title' then btrim(v_patch ->> 'title') else v.title end,
    company_name = case when v_patch ? 'company_name'
      then coalesce(v_patch ->> 'company_name', '') else v.company_name end,
    summary = case when v_patch ? 'summary'
      then coalesce(v_patch ->> 'summary', '') else v.summary end,
    description = case when v_patch ? 'description'
      then coalesce(v_patch ->> 'description', '') else v.description end,
    employment_type = case when v_patch ? 'employment_type'
      then nullif(btrim(coalesce(v_patch ->> 'employment_type', '')), '')
      else v.employment_type end,
    work_format = case when v_patch ? 'work_format'
      then nullif(btrim(coalesce(v_patch ->> 'work_format', '')), '')
      else v.work_format end,
    location = case when v_patch ? 'location'
      then nullif(btrim(coalesce(v_patch ->> 'location', '')), '') else v.location end,
    salary_text = case when v_patch ? 'salary_text'
      then nullif(btrim(coalesce(v_patch ->> 'salary_text', '')), '')
      else v.salary_text end,
    external_url = case when v_patch ? 'external_url'
      then nullif(btrim(coalesce(v_patch ->> 'external_url', '')), '')
      else v.external_url end,
    contacts = case when v_patch ? 'contacts'
      then coalesce(v_patch -> 'contacts', '{}'::jsonb) else v.contacts end,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);

  return jsonb_build_object(
    'ok', true,
    'id', v_row.id,
    'status', v_row.status,
    'row_version', v_row.row_version,
    'rejection_reason', v_row.rejection_reason
  );
end;
$$;

revoke all on function public.update_my_vacancy_draft(uuid, jsonb, integer)
  from public, anon;
grant execute on function public.update_my_vacancy_draft(uuid, jsonb, integer)
  to authenticated, service_role;

create or replace function public.resubmit_my_vacancy(
  p_id uuid,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.vacancies;
  v_from text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_expected_row_version is null then
    raise exception 'expected_version_required' using errcode = '22023';
  end if;
  if not exists (
    select 1
    from public.users u
    join public.student_enrollments se
      on se.user_id = u.id and se.status = 'active' and se.ended_at is null
    where u.id = v_uid and u.is_active
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_row
  from public.vacancies v
  where v.id = p_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.submitted_by is distinct from v_uid
     or v_row.origin <> 'user_submission' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'not_resubmittable_in_status_%', v_row.status
      using errcode = '55000';
  end if;
  if v_row.row_version is distinct from p_expected_row_version then
    raise exception 'row_version_conflict' using errcode = '40001';
  end if;
  if nullif(btrim(coalesce(v_row.title, '')), '') is null then
    raise exception 'invalid_title' using errcode = '22023';
  end if;

  v_from := v_row.status;
  perform private.vacancy_assert_transition(v_from, 'submitted');

  update public.vacancies v set
    status = 'submitted',
    submitted_at = now(),
    -- Fresh queue entry: clear clarification/reject reason after author fix.
    rejection_reason = null,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;

  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(
    p_id, 'submit', v_from, 'submitted', 'author resubmit after clarification'
  );

  return jsonb_build_object(
    'ok', true,
    'id', v_row.id,
    'status', v_row.status,
    'row_version', v_row.row_version
  );
end;
$$;

revoke all on function public.resubmit_my_vacancy(uuid, integer)
  from public, anon;
grant execute on function public.resubmit_my_vacancy(uuid, integer)
  to authenticated, service_role;

comment on function public.update_my_vacancy_draft(uuid, jsonb, integer) is
  'Author edits own draft vacancy after moderator request_clarification.';
comment on function public.resubmit_my_vacancy(uuid, integer) is
  'Author resubmits draft vacancy into submitted queue; clears rejection_reason.';

-- ---------------------------------------------------------------------------
-- 4. Mobile: expose moderation_reason on get_my_entity_reviews.
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
          'moderation_reason', x.moderation_reason,
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
          r.moderation_reason,
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

commit;
