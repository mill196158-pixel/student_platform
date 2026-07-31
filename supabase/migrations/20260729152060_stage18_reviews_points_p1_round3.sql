-- Stage 18 P1 hardening round 3 (Codex).
-- Do NOT edit 20260729152000 in place.
--
-- Fixes:
--   * request_clarification in review + vacancy moderation lifecycles
--   * vacancy approve only from in_moderation (match Stage 17 editor UX)
--   * trail vocabulary extended for audit parity

begin;

-- ---------------------------------------------------------------------------
-- 1. Vacancy status machine: clarification returns to draft for re-edit.
-- ---------------------------------------------------------------------------
create or replace function private.vacancy_assert_transition(
  p_from text,
  p_to text
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_from is null or p_to is null then
    raise exception 'invalid_status_transition' using errcode = '22023';
  end if;
  if p_from = p_to then
    return;
  end if;

  if not (
    (p_from = 'draft' and p_to in ('submitted', 'in_moderation', 'archived'))
    or (p_from = 'submitted' and p_to in ('in_moderation', 'rejected', 'archived', 'draft'))
    or (p_from = 'in_moderation' and p_to in ('approved', 'rejected', 'archived', 'draft'))
    or (p_from = 'approved' and p_to in ('published', 'rejected', 'draft', 'archived'))
    or (p_from = 'published' and p_to in ('expired', 'approved', 'archived'))
    or (p_from = 'expired' and p_to in ('published', 'archived'))
    or (p_from = 'rejected' and p_to in ('draft', 'archived'))
  ) then
    raise exception 'invalid_status_transition_%_to_%', p_from, p_to
      using errcode = '55000';
  end if;
end;
$$;

alter table public.vacancy_moderation_actions
  drop constraint if exists vacancy_moderation_actions_action_check;
alter table public.vacancy_moderation_actions
  add constraint vacancy_moderation_actions_action_check
    check (action in (
      'create_draft', 'submit', 'take_in_moderation', 'approve', 'reject',
      'request_clarification',
      'publish', 'unpublish', 'expire', 'auto_expire', 'archive',
      'resolve_report', 'reject_report'
    ));

alter table public.review_moderation_actions
  drop constraint if exists review_moderation_actions_action_check;
alter table public.review_moderation_actions
  add constraint review_moderation_actions_action_check
    check (action in (
      'hide', 'restore', 'approve', 'reject', 'remove_violation',
      'request_clarification',
      'resolve_report', 'reject_report'
    ));

-- ---------------------------------------------------------------------------
-- 2. Review moderation: request_clarification (resubmit path, distinct trail).
-- ---------------------------------------------------------------------------
create or replace function private.review_moderate_apply(
  p_review_id uuid,
  p_action text,
  p_reason text,
  p_actor uuid,
  p_trail_action text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.entity_reviews;
  v_action text := nullif(btrim(coalesce(p_action, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_trail text := coalesce(nullif(btrim(coalesce(p_trail_action, '')), ''), v_action);
  v_new_moderation text;
  v_new_status text;
  v_before jsonb;
  v_after jsonb;
begin
  if v_action is null
     or v_action not in (
       'approve', 'reject', 'remove_violation', 'restore', 'request_clarification'
     ) then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;
  if v_action in ('reject', 'remove_violation', 'request_clarification')
     and v_reason is null then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  perform private.entity_review_assert_not_own(p_review_id);

  select * into v_row from public.entity_reviews where id = p_review_id for update;
  if not found then
    raise exception 'review_not_found' using errcode = 'P0002';
  end if;

  v_new_moderation := case v_action
    when 'approve' then 'approved'
    when 'restore' then 'approved'
    else 'rejected'
  end;
  v_new_status := case v_action
    when 'approve' then 'active'
    when 'restore' then 'active'
    when 'reject' then 'hidden'
    when 'request_clarification' then 'hidden'
    else 'removed'
  end;

  if v_new_status = 'active' and exists (
    select 1
    from public.entity_reviews other
    where other.author_user_id = v_row.author_user_id
      and other.entity_type = v_row.entity_type
      and other.entity_id = v_row.entity_id
      and other.status = 'active'
      and other.id <> v_row.id
  ) then
    raise exception 'restore_conflicts_with_active_review' using errcode = '23505';
  end if;

  v_before := private.review_points_state(p_review_id);

  update public.entity_reviews r set
    moderation_status = v_new_moderation,
    status = v_new_status,
    moderation_reason = v_reason,
    moderated_by = p_actor,
    moderated_at = now(),
    hidden_at = case when v_new_status = 'active' then null else now() end,
    hidden_reason = case when v_new_status = 'active' then null else v_reason end,
    updated_at = now()
  where r.id = p_review_id
  returning * into v_row;

  v_after := private.review_points_state(p_review_id);

  insert into public.review_moderation_actions (
    review_id, actor_user_id, action, reason_text
  ) values (
    p_review_id, p_actor, v_trail, coalesce(v_reason, '')
  );

  update public.review_reports
  set status = 'resolved'
  where review_id = p_review_id and status = 'open';

  perform private.admin_write_audit(
    'review.' || v_action,
    'entity_review',
    p_review_id::text,
    jsonb_build_object(
      'moderation_status', v_row.moderation_status,
      'status', v_row.status,
      'trail_action', v_trail,
      'points_before', v_before,
      'points_after', v_after
    )
  );

  return jsonb_build_object(
    'ok', true,
    'review_id', p_review_id,
    'action', v_action,
    'moderation_status', v_row.moderation_status,
    'status', v_row.status,
    'points_credited', (
      coalesce((v_after ->> 'credits')::integer, 0)
      > coalesce((v_before ->> 'credits')::integer, 0)
    ),
    'points_debited', (
      coalesce((v_after ->> 'revocations')::integer, 0)
      > coalesce((v_before ->> 'revocations')::integer, 0)
    ),
    'points_outstanding', coalesce((v_after ->> 'outstanding')::integer, 0)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Vacancy moderation: request_clarification + approve guard.
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
    rejection_reason = case when v_to = 'rejected' then v_reason else null end,
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

commit;
