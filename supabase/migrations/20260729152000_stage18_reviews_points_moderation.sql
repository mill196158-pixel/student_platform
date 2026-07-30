-- Stage 18: reviews moderation, points ledger, unified moderation queue.
-- SPEC section 6.
--
-- EXTENDS the Stage 13.6 reviews system (`entity_reviews`). There is no second
-- reviews system here.
--
-- Publish-after-approve is introduced behind the feature flag
-- `reviews.moderation_required` (default FALSE = current live behaviour). With
-- the flag OFF the Stage 13.6 RPCs behave exactly as today. With the flag ON a
-- new review is stored as moderation_status='pending' + status='hidden', so the
-- existing Stage 13.6 read path (`get_entity_review_summary`, which filters
-- status='active') hides it until a moderator approves. That keeps the Stage
-- 13.6 functions untouched instead of rewriting them.
--
-- Points: a +1 credit is outstanding exactly while a review is approved AND
-- active; leaving that state writes a compensating -1; a later re-approval opens
-- a new credit cycle. All of it is enforced by one trigger, so no moderation
-- path can bypass it. Points are NOT money.
--
-- Depends on: 20260721202054 (RBAC), 20260727184457 (reviews),
-- 20260729133000 (content audit helper), 20260729150700 (content_corrections),
-- 20260729151000 (vacancies). The unified queue reads all of those domains, so
-- this migration must run after Stage 16.3 and Stage 17.
--
-- Local only. Not applied to remote in this session.

begin;

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

-- Repeated verbatim from the Stage 16 migration so this file is independently
-- re-appliable.
create or replace function private.require_any_admin_permission(p_permissions text[])
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_perm text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_permissions is null or coalesce(array_length(p_permissions, 1), 0) = 0 then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  foreach v_perm in array p_permissions loop
    if private.has_admin_permission(v_uid, v_perm, 'global', null) then
      return v_uid;
    end if;
  end loop;

  raise exception 'forbidden' using errcode = '42501';
end;
$$;

revoke all on function private.require_any_admin_permission(text[])
  from public, anon, authenticated;
grant execute on function private.require_any_admin_permission(text[]) to service_role;

-- ---------------------------------------------------------------------------
-- 1. Extend entity_reviews with moderation state.
--
-- Backfill order matters: existing rows are classified BEFORE the column
-- becomes NOT NULL, and the 'pending' default only applies to NEW rows.
-- Currently active rows are already live, so they are treated as approved.
-- ---------------------------------------------------------------------------
alter table public.entity_reviews add column if not exists moderation_status text;
alter table public.entity_reviews add column if not exists moderation_reason text;
alter table public.entity_reviews
  add column if not exists moderated_by uuid null references public.users (id) on delete set null;
alter table public.entity_reviews add column if not exists moderated_at timestamptz null;

update public.entity_reviews
set moderation_status = case when status = 'active' then 'approved' else 'rejected' end
where moderation_status is null;

alter table public.entity_reviews alter column moderation_status set default 'pending';
alter table public.entity_reviews alter column moderation_status set not null;

alter table public.entity_reviews
  drop constraint if exists entity_reviews_moderation_status_check;
alter table public.entity_reviews
  add constraint entity_reviews_moderation_status_check
    check (moderation_status in ('draft', 'pending', 'approved', 'rejected'));

alter table public.entity_reviews
  drop constraint if exists entity_reviews_moderation_reason_len;
alter table public.entity_reviews
  add constraint entity_reviews_moderation_reason_len
    check (moderation_reason is null or char_length(moderation_reason) <= 500);

comment on column public.entity_reviews.moderation_status is
  'Stage 18 moderation state. Default pending; forced to approved on insert while the reviews.moderation_required flag is OFF (legacy behaviour).';

create index if not exists entity_reviews_moderation_status_idx
  on public.entity_reviews (moderation_status, updated_at desc);

-- The Stage 13.6 trail vocabulary was hide | restore | resolve_report |
-- reject_report. Stage 18 introduces real approval decisions, and an approval
-- must be recorded as `approve` — never disguised as `restore`.
alter table public.review_moderation_actions
  drop constraint if exists review_moderation_actions_action_check;
alter table public.review_moderation_actions
  add constraint review_moderation_actions_action_check
    check (action in (
      'hide', 'restore', 'approve', 'reject', 'remove_violation',
      'resolve_report', 'reject_report'
    ));

-- One pending review per (author, entity) so the moderation queue cannot be
-- flooded while the gate is enabled.
create unique index if not exists entity_reviews_one_pending_uidx
  on public.entity_reviews (author_user_id, entity_type, entity_id)
  where moderation_status = 'pending';

insert into public.app_feature_flags (key, enabled, description)
values (
  'reviews.moderation_required',
  false,
  'Publish-after-approve for reviews (Stage 18). OFF keeps Stage 13.6 behaviour.'
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Publish-after-approve gate.
--
-- Flag OFF  -> inserts are forced to 'approved' and nothing else changes.
-- Flag ON   -> new / edited content becomes pending and is hidden from the
--              Stage 13.6 read path until a moderator approves it.
-- ---------------------------------------------------------------------------
create or replace function private.entity_reviews_moderation_gate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_required boolean := coalesce(
    (
      select f.enabled
      from public.app_feature_flags f
      where f.key = 'reviews.moderation_required'
    ),
    false
  );
begin
  if tg_op = 'INSERT' then
    if not v_required then
      new.moderation_status := 'approved';
      return new;
    end if;

    if new.moderation_status is null or new.moderation_status = 'approved' then
      new.moderation_status := 'pending';
    end if;
    if new.moderation_status <> 'approved' then
      new.status := 'hidden';
    end if;
    return new;
  end if;

  -- Re-editing approved OR rejected content sends it back through moderation,
  -- which is what completes the rejected -> resubmit -> pending lifecycle even
  -- for writers that do not set moderation_status themselves.
  if v_required
     and old.moderation_status in ('approved', 'rejected')
     and new.moderation_status = old.moderation_status
     and (
       new.tag_scores is distinct from old.tag_scores
       or new.body_text is distinct from old.body_text
     ) then
    new.moderation_status := 'pending';
    new.status := 'hidden';
    new.moderation_reason := null;
  end if;

  return new;
end;
$$;

revoke all on function private.entity_reviews_moderation_gate()
  from public, anon, authenticated;

drop trigger if exists trg_entity_reviews_moderation_gate on public.entity_reviews;
create trigger trg_entity_reviews_moderation_gate
before insert or update on public.entity_reviews
for each row execute function private.entity_reviews_moderation_gate();

-- ---------------------------------------------------------------------------
-- 3. Points ledger.
--
-- A review can legitimately be credited, revoked and credited AGAIN (approved →
-- removed as a violation → restored after appeal), so uniqueness cannot be
-- (review_id, reason_code): that would permanently block the second credit.
--
-- The model is credit CYCLES. cycle_number 1 is the first +1; the compensating
-- -1 carries the same cycle_number as the credit it cancels; a later re-credit
-- opens cycle 2. Uniqueness is (review_id, reason_code, cycle_number), which
-- still makes a double credit or a double debit inside one cycle impossible
-- while allowing the review to be re-credited.
-- ---------------------------------------------------------------------------
create table if not exists public.student_points_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  review_id uuid null references public.entity_reviews (id) on delete set null,
  delta integer not null,
  reason_code text not null check (
    reason_code in (
      'review_approved', 'review_credit_revoked', 'manual_adjustment'
    )
  ),
  cycle_number integer not null default 1 check (cycle_number >= 1),
  meta jsonb not null default '{}'::jsonb,
  created_by uuid null references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint student_points_ledger_delta_nonzero check (delta <> 0),
  constraint student_points_ledger_delta_range check (delta between -100 and 100),
  constraint student_points_ledger_meta_object check (jsonb_typeof(meta) = 'object'),
  -- Automatic review reasons must always reference their review.
  constraint student_points_ledger_review_required check (
    reason_code = 'manual_adjustment' or review_id is not null
  ),
  constraint student_points_ledger_review_sign check (
    (reason_code = 'review_approved' and delta = 1)
    or (reason_code = 'review_credit_revoked' and delta = -1)
    or reason_code = 'manual_adjustment'
  )
);

-- Re-appliability: the earlier draft of this file had no cycle_number and a
-- unique index on (review_id, reason_code).
alter table public.student_points_ledger
  add column if not exists cycle_number integer not null default 1;
alter table public.student_points_ledger
  drop constraint if exists student_points_ledger_cycle_positive;
alter table public.student_points_ledger
  add constraint student_points_ledger_cycle_positive check (cycle_number >= 1);
drop index if exists public.student_points_ledger_review_reason_uidx;

comment on table public.student_points_ledger is
  'Append-only student points. +1 while a review is approved and active, compensating -1 when it stops being either. Credit cycles allow a re-credit after compensation. NOT money; never a payment balance.';
comment on column public.student_points_ledger.cycle_number is
  'Credit cycle for this review. The -1 shares the cycle of the +1 it cancels; a later re-credit opens the next cycle.';

create unique index if not exists student_points_ledger_review_cycle_uidx
  on public.student_points_ledger (review_id, reason_code, cycle_number)
  where review_id is not null;
create index if not exists student_points_ledger_user_idx
  on public.student_points_ledger (user_id, created_at desc);

alter table public.student_points_ledger enable row level security;
alter table public.student_points_ledger force row level security;
revoke all on table public.student_points_ledger from public, anon, authenticated;
grant select, insert, update, delete on table public.student_points_ledger to service_role;

create or replace function private.student_points_balance(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(l.delta), 0)::integer
  from public.student_points_ledger l
  where l.user_id = p_user_id;
$$;

revoke all on function private.student_points_balance(uuid)
  from public, anon, authenticated;
grant execute on function private.student_points_balance(uuid) to service_role;

-- The earlier draft of this file had no cycle argument.
drop function if exists private.student_points_record(uuid, uuid, integer, text, jsonb);

-- Idempotent: returns true only when a NEW ledger row was written.
create or replace function private.student_points_record(
  p_user_id uuid,
  p_review_id uuid,
  p_delta integer,
  p_reason_code text,
  p_cycle_number integer default 1,
  p_meta jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted integer := 0;
begin
  if p_user_id is null then
    return false;
  end if;

  insert into public.student_points_ledger (
    user_id, review_id, delta, reason_code, cycle_number, meta, created_by
  ) values (
    p_user_id, p_review_id, p_delta, p_reason_code,
    greatest(coalesce(p_cycle_number, 1), 1),
    coalesce(p_meta, '{}'::jsonb), auth.uid()
  )
  on conflict (review_id, reason_code, cycle_number) where (review_id is not null)
  do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted > 0;
end;
$$;

revoke all on function private.student_points_record(uuid, uuid, integer, text, integer, jsonb)
  from public, anon, authenticated;
grant execute on function private.student_points_record(uuid, uuid, integer, text, integer, jsonb)
  to service_role;

-- Credit state for one review: how many credits, how many revocations and
-- whether a credit is currently outstanding.
create or replace function private.review_points_state(p_review_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'credits', coalesce(count(*) filter (where l.reason_code = 'review_approved'), 0),
    'revocations', coalesce(count(*) filter (where l.reason_code = 'review_credit_revoked'), 0),
    'outstanding', coalesce(sum(
      case
        when l.reason_code = 'review_approved' then 1
        when l.reason_code = 'review_credit_revoked' then -1
        else 0
      end
    ), 0)
  )
  from public.student_points_ledger l
  where l.review_id = p_review_id;
$$;

revoke all on function private.review_points_state(uuid)
  from public, anon, authenticated;
grant execute on function private.review_points_state(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- SINGLE point of truth for review points.
--
-- Invariant: a credit is outstanding exactly while the review is
-- moderation_status = 'approved' AND status = 'active'. Any write that leaves
-- that state writes the compensating -1, so no moderation path — Stage 18,
-- legacy Stage 13.6, or a future one — can bypass compensation.
-- ---------------------------------------------------------------------------
create or replace function private.review_points_sync_one(p_review_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.entity_reviews;
  v_state jsonb;
  v_credits integer;
  v_outstanding integer;
  v_should_be_credited boolean;
begin
  select * into v_row from public.entity_reviews where id = p_review_id;
  if not found or v_row.author_user_id is null then
    return 'noop';
  end if;

  v_state := private.review_points_state(p_review_id);
  v_credits := coalesce((v_state ->> 'credits')::integer, 0);
  v_outstanding := coalesce((v_state ->> 'outstanding')::integer, 0);
  v_should_be_credited :=
    (v_row.moderation_status = 'approved' and v_row.status = 'active');

  if v_should_be_credited and v_outstanding <= 0 then
    if private.student_points_record(
      v_row.author_user_id,
      p_review_id,
      1,
      'review_approved',
      v_credits + 1,
      jsonb_build_object('entity_type', v_row.entity_type, 'entity_id', v_row.entity_id)
    ) then
      return 'credited';
    end if;
    return 'noop';
  end if;

  if not v_should_be_credited and v_outstanding > 0 then
    if private.student_points_record(
      v_row.author_user_id,
      p_review_id,
      -1,
      'review_credit_revoked',
      v_credits,
      jsonb_build_object(
        'entity_type', v_row.entity_type,
        'moderation_status', v_row.moderation_status,
        'status', v_row.status
      )
    ) then
      return 'revoked';
    end if;
    return 'noop';
  end if;

  return 'noop';
end;
$$;

revoke all on function private.review_points_sync_one(uuid)
  from public, anon, authenticated;
grant execute on function private.review_points_sync_one(uuid) to service_role;

create or replace function private.entity_reviews_points_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.review_points_sync_one(new.id);
  return null;
end;
$$;

revoke all on function private.entity_reviews_points_sync()
  from public, anon, authenticated;

-- AFTER, so an auto-approved insert (flag OFF) is credited too and no path can
-- write an approved+active review without the +1.
drop trigger if exists trg_entity_reviews_points_sync on public.entity_reviews;
create trigger trg_entity_reviews_points_sync
after insert or update on public.entity_reviews
for each row execute function private.entity_reviews_points_sync();

-- One-time (and repeatable) backfill for reviews that were auto-approved before
-- this migration existed. Idempotent: the cycle guard makes a second run a
-- no-op, and it never credits a review that is not approved+active.
create or replace function public.admin_backfill_review_points(
  p_limit integer default 1000
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_limit integer := greatest(1, least(coalesce(p_limit, 1000), 10000));
  v_id uuid;
  v_result text;
  v_credited integer := 0;
  v_scanned integer := 0;
begin
  v_uid := private.require_any_admin_permission(
    array['moderation.action', 'moderation.write']
  );

  for v_id in
    select r.id
    from public.entity_reviews r
    where r.moderation_status = 'approved'
      and r.status = 'active'
      and r.author_user_id is not null
      and coalesce(
        (private.review_points_state(r.id) ->> 'outstanding')::integer, 0
      ) <= 0
    order by r.created_at
    limit v_limit
  loop
    v_scanned := v_scanned + 1;
    v_result := private.review_points_sync_one(v_id);
    if v_result = 'credited' then
      v_credited := v_credited + 1;
    end if;
  end loop;

  perform private.admin_write_audit(
    'points.backfill_review_credits',
    'student_points_ledger',
    null,
    jsonb_build_object('scanned', v_scanned, 'credited', v_credited)
  );

  return jsonb_build_object(
    'ok', true,
    'scanned', v_scanned,
    'credited', v_credited,
    'remaining_possible', (v_scanned >= v_limit)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Review moderation (Stage 18 canonical path).
-- ---------------------------------------------------------------------------
create or replace function private.entity_review_assert_not_own(p_review_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_author uuid;
  v_uid uuid := auth.uid();
begin
  select r.author_user_id into v_author
  from public.entity_reviews r
  where r.id = p_review_id;
  if not found then
    raise exception 'review_not_found' using errcode = 'P0002';
  end if;
  if v_uid is not null and v_author = v_uid then
    raise exception 'cannot_moderate_own_review' using errcode = '42501';
  end if;
  return v_author;
end;
$$;

revoke all on function private.entity_review_assert_not_own(uuid)
  from public, anon, authenticated;
grant execute on function private.entity_review_assert_not_own(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Shared moderation core. BOTH the Stage 18 RPC and the legacy Stage 13.6 RPC
-- go through this function, so the legacy path cannot diverge from the
-- points-aware path and compensation cannot be bypassed by choosing the older
-- entry point. RBAC is the CALLER's responsibility (each entry point keeps its
-- own gate); this function only enforces the domain rules.
--
-- p_trail_action keeps each entry point's historical review_moderation_actions
-- vocabulary intact: Stage 18 records approve / reject / remove_violation, the
-- legacy RPC keeps hide / restore. An approval is never recorded as `restore`.
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
     or v_action not in ('approve', 'reject', 'remove_violation', 'restore') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;
  if v_action in ('reject', 'remove_violation') and v_reason is null then
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
    else 'removed'
  end;

  -- Deterministic conflict rule inherited from Stage 13.6: never end up with
  -- two active reviews by the same author for the same entity.
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

  -- Points are written by trg_entity_reviews_points_sync, not here, so every
  -- writer gets the same treatment. Only the outcome is reported back.
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

revoke all on function private.review_moderate_apply(uuid, text, text, uuid, text)
  from public, anon, authenticated;
grant execute on function private.review_moderate_apply(uuid, text, text, uuid, text)
  to service_role;

create or replace function public.admin_moderate_review_v2(
  p_review_id uuid,
  p_action text,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  v_uid := private.require_any_admin_permission(
    array['moderation.action', 'moderation.write']
  );

  return private.review_moderate_apply(
    p_review_id, p_action, p_reason, v_uid, null
  );
end;
$$;

-- Legacy Stage 13.6 entry point, kept for existing Admin callers. It now
-- REDIRECTS into the shared core (hide -> reject, restore -> restore) so the
-- points ledger, the moderation trail and the report resolution behave
-- identically no matter which RPC is called. Its own permission gate is
-- preserved so no existing moderator loses access.
create or replace function public.admin_moderate_review(
  p_review_id uuid,
  p_action text,
  p_reason_text text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
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

  perform private.review_moderate_apply(
    p_review_id,
    case when p_action = 'hide' then 'reject' else 'restore' end,
    v_reason,
    auth.uid(),
    p_action
  );

  return p_review_id;
end;
$$;

-- Stage 18 authoring path. Required when reviews.moderation_required is ON,
-- because the Stage 13.6 upsert infers ON CONFLICT from the active-only index.
create or replace function public.submit_my_entity_review(
  p_entity_type text,
  p_entity_id uuid,
  p_tag_scores jsonb default '{}'::jsonb,
  p_body_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := nullif(btrim(coalesce(p_body_text, '')), '');
  v_scores jsonb := coalesce(p_tag_scores, '{}'::jsonb);
  v_row public.entity_reviews;
  v_recent integer;
  v_required boolean := private.stage13_6_feature_enabled('reviews.moderation_required');
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_entity_type not in ('teacher', 'subject') then
    raise exception 'invalid_entity' using errcode = '22023';
  end if;
  if not private.stage13_6_feature_enabled('reviews.structured_enabled') then
    raise exception 'structured_reviews_disabled' using errcode = 'P0001';
  end if;
  if v_body is not null
     and not private.stage13_6_feature_enabled('reviews.text_enabled') then
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
  else
    if not exists (
      select 1 from public.subject_catalog sc
      where sc.id = p_entity_id and sc.status = 'published'
    ) then
      raise exception 'entity_not_found' using errcode = 'P0002';
    end if;
  end if;

  if jsonb_typeof(v_scores) <> 'object' then
    raise exception 'invalid_tags' using errcode = '22023';
  end if;
  if exists (
    select 1
    from jsonb_each(v_scores) kv
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
  if (select count(*) from jsonb_object_keys(v_scores)) = 0 and v_body is null then
    raise exception 'empty_review' using errcode = '22023';
  end if;

  select count(*)::integer into v_recent
  from public.entity_reviews r
  where r.author_user_id = v_uid
    and r.updated_at > now() - interval '30 seconds';
  if v_recent > 0 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  -- One row per (author, entity) regardless of moderation state. A review
  -- REMOVED as a violation is excluded: it is terminal, and a fresh submission
  -- starts a new row (and a new points cycle) instead of resurrecting it.
  select * into v_row
  from public.entity_reviews r
  where r.author_user_id = v_uid
    and r.entity_type = p_entity_type
    and r.entity_id = p_entity_id
    and r.status <> 'removed'
  order by r.updated_at desc
  limit 1
  for update;

  if found then
    -- rejected -> resubmit -> pending is an explicit lifecycle step, not a
    -- side effect of the trigger: a resubmission always re-enters the queue
    -- when the moderation gate is on, and carries no stale rejection reason.
    update public.entity_reviews r set
      tag_scores = v_scores,
      body_text = v_body,
      moderation_status = case when v_required then 'pending' else 'approved' end,
      status = case when v_required then 'hidden' else 'active' end,
      moderation_reason = null,
      moderated_by = null,
      moderated_at = null,
      hidden_at = case when v_required then now() else null end,
      hidden_reason = null,
      updated_at = now()
    where r.id = v_row.id
    returning * into v_row;
  else
    insert into public.entity_reviews (
      entity_type, entity_id, author_user_id, tag_scores, body_text,
      status, is_anonymous, updated_at
    ) values (
      p_entity_type, p_entity_id, v_uid, v_scores, v_body, 'active', true, now()
    )
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'ok', true,
    'review_id', v_row.id,
    'status', v_row.status,
    'moderation_status', v_row.moderation_status
  );
end;
$$;

create or replace function public.admin_resolve_review_report(
  p_report_id uuid,
  p_action text,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.review_reports;
  v_action text := nullif(btrim(coalesce(p_action, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  v_uid := private.require_any_admin_permission(
    array['moderation.action', 'moderation.write']
  );

  if v_action is null or v_action not in ('resolve', 'reject') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;

  select * into v_row from public.review_reports where id = p_report_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'open' then
    raise exception 'already_closed' using errcode = '55000';
  end if;

  -- A moderator must not close a report on their own review.
  perform private.entity_review_assert_not_own(v_row.review_id);

  update public.review_reports r set
    status = case when v_action = 'resolve' then 'resolved' else 'rejected' end
  where r.id = p_report_id
  returning * into v_row;

  insert into public.review_moderation_actions (
    review_id, actor_user_id, action, reason_text
  ) values (
    v_row.review_id,
    v_uid,
    case when v_action = 'resolve' then 'resolve_report' else 'reject_report' end,
    coalesce(v_reason, '')
  );

  perform private.admin_write_audit(
    'review_report.' || v_action,
    'review_report',
    p_report_id::text,
    jsonb_build_object('status', v_row.status)
  );

  return jsonb_build_object('ok', true, 'id', p_report_id, 'status', v_row.status);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Points RPCs
-- ---------------------------------------------------------------------------
create or replace function public.get_my_points_summary(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 100));
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  return jsonb_build_object(
    'user_id', v_uid,
    'balance', private.student_points_balance(v_uid),
    'entries', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'delta', l.delta,
            'reason_code', l.reason_code,
            'created_at', l.created_at
          )
          order by l.created_at desc
        )
        from (
          select *
          from public.student_points_ledger l0
          where l0.user_id = v_uid
          order by l0.created_at desc
          limit v_limit
        ) l
      ),
      '[]'::jsonb
    )
  );
end;
$$;

create or replace function public.admin_list_student_points(
  p_user_id uuid,
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
-- 6. Unified moderation queue across reviews, vacancies, reports and
--    content corrections. Read-only, counts + ids only, no author identities.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_unified_moderation_queue(
  p_domains text[] default null,
  p_status text default 'open',
  p_limit integer default 50,
  p_offset integer default 0,
  p_since timestamptz default null
)
returns jsonb
language plpgsql
stable
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
    jsonb_build_object('domains', to_jsonb(v_domains), 'status', v_status)
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
          'updated_at', q.updated_at
        )
        order by q.updated_at desc, q.entity_id
      )
      from (
        select *
        from (
          -- Reviews awaiting moderation or carrying open reports.
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
            (rr.status = 'open')
          from public.review_reports rr
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
            (vr.status = 'open')
          from public.vacancy_reports vr
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
        order by rows.updated_at desc, rows.entity_id
        limit v_limit
        offset v_offset
      ) q
    ),
    '[]'::jsonb
  );
end;
$$;

-- Single entry point so the Admin queue does not need per-domain wiring.
-- Each delegate re-checks RBAC on its own.
create or replace function public.admin_moderation_action(
  p_domain text,
  p_entity_id uuid,
  p_action text,
  p_reason text default '',
  p_expected_row_version integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_domain text := nullif(btrim(coalesce(p_domain, '')), '');
begin
  if v_domain is null
     or v_domain not in (
       'review', 'review_report', 'vacancy', 'vacancy_report', 'content_correction'
     ) then
    raise exception 'unknown_domain' using errcode = '22023';
  end if;
  if p_entity_id is null then
    raise exception 'invalid_id' using errcode = '22023';
  end if;

  if v_domain = 'review' then
    return public.admin_moderate_review_v2(p_entity_id, p_action, p_reason);
  elsif v_domain = 'review_report' then
    return public.admin_resolve_review_report(p_entity_id, p_action, p_reason);
  elsif v_domain = 'vacancy' then
    if p_expected_row_version is null then
      raise exception 'row_version_required' using errcode = '22023';
    end if;
    return public.admin_moderate_vacancy(
      p_entity_id, p_action, p_expected_row_version, p_reason
    );
  elsif v_domain = 'vacancy_report' then
    return public.admin_resolve_vacancy_report(p_entity_id, p_action, p_reason);
  else
    return public.admin_resolve_content_correction(p_entity_id, p_action, p_reason);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants (RBAC enforced inside each function body)
-- ---------------------------------------------------------------------------
revoke all on function public.admin_moderate_review_v2(uuid, text, text) from public, anon;
grant execute on function public.admin_moderate_review_v2(uuid, text, text)
  to authenticated, service_role;

revoke all on function public.admin_moderate_review(uuid, text, text) from public, anon;
grant execute on function public.admin_moderate_review(uuid, text, text)
  to authenticated, service_role;

revoke all on function public.submit_my_entity_review(text, uuid, jsonb, text)
  from public, anon;
grant execute on function public.submit_my_entity_review(text, uuid, jsonb, text)
  to authenticated, service_role;

revoke all on function public.admin_resolve_review_report(uuid, text, text)
  from public, anon;
grant execute on function public.admin_resolve_review_report(uuid, text, text)
  to authenticated, service_role;

revoke all on function public.get_my_points_summary(integer) from public, anon;
grant execute on function public.get_my_points_summary(integer)
  to authenticated, service_role;

revoke all on function public.admin_list_student_points(uuid, integer) from public, anon;
grant execute on function public.admin_list_student_points(uuid, integer)
  to authenticated, service_role;

revoke all on function public.admin_backfill_review_points(integer) from public, anon;
grant execute on function public.admin_backfill_review_points(integer)
  to authenticated, service_role;

revoke all on function public.admin_list_unified_moderation_queue(
  text[], text, integer, integer, timestamptz
) from public, anon;
grant execute on function public.admin_list_unified_moderation_queue(
  text[], text, integer, integer, timestamptz
) to authenticated, service_role;

revoke all on function public.admin_moderation_action(text, uuid, text, text, integer)
  from public, anon;
grant execute on function public.admin_moderation_action(text, uuid, text, text, integer)
  to authenticated, service_role;

comment on function public.admin_moderate_review_v2(uuid, text, text) is
  'Stage 18 review moderation. Cannot moderate own review. Records approve/reject/remove_violation verbatim in the trail and delegates points to the ledger trigger.';
comment on function public.admin_moderate_review(uuid, text, text) is
  'Legacy Stage 13.6 entry point. Redirects into private.review_moderate_apply (hide -> reject, restore -> restore) so points compensation cannot be bypassed.';
comment on function public.admin_backfill_review_points(integer) is
  'Idempotent backfill of the +1 credit for reviews that were auto-approved before Stage 18. Never credits a review that is not approved+active.';
comment on function public.admin_list_unified_moderation_queue(
  text[], text, integer, integer, timestamptz
) is
  'Unified moderation queue over reviews, review reports, vacancies, vacancy reports and content corrections. moderation.read only; no author identities.';
comment on function public.submit_my_entity_review(text, uuid, jsonb, text) is
  'Stage 18 review authoring. Required when reviews.moderation_required is ON; the Stage 13.6 upsert only conflicts on the active-only index.';

commit;
