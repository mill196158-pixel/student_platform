-- Stage 16.3: reference corrections — «Сообщить об ошибке» (SPEC section 4.3).
--
-- ADDITIVE ONLY. Reference articles themselves reuse the Stage 14 managed
-- content platform (placement `reference`, template `reference_article_v1`);
-- only the missing correction-report flow is added here. Nothing in this file
-- touches the Stage 16.1 subject card model or the subject profile tables.
--
-- Depends on: 20260721202054 (RBAC), 20260722110804 (require_admin_permission),
-- 20260729133000 (content_items, content_item_deliverable_to_user).
--
-- Local only. Not applied to remote in this session.

begin;

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

-- Repeated verbatim from the Stage 16.2 migration so this file is independently
-- re-appliable. See that migration for the moderation.action/write rationale.
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
-- Correction reports
-- ---------------------------------------------------------------------------
create table if not exists public.content_corrections (
  id uuid primary key default gen_random_uuid(),
  content_item_id uuid not null
    references public.content_items (id) on delete cascade,
  reporter_user_id uuid not null
    references public.users (id) on delete cascade,
  note text not null,
  status text not null default 'open'
    check (status in ('open', 'resolved', 'rejected')),
  resolved_by uuid null references public.users (id) on delete set null,
  resolved_at timestamptz null,
  resolution_note text null,
  created_at timestamptz not null default now(),
  constraint content_corrections_note_len check (
    btrim(note) <> '' and char_length(note) <= 1000
  ),
  constraint content_corrections_resolution_len check (
    resolution_note is null or char_length(resolution_note) <= 500
  )
);

comment on table public.content_corrections is
  'Student-reported errors on managed content (reference articles). Moderation entity `content_correction`. No client DML: submit via submit_content_correction.';

-- One open report per (item, reporter): resubmitting updates the note.
create unique index if not exists content_corrections_open_uidx
  on public.content_corrections (content_item_id, reporter_user_id)
  where status = 'open';
create index if not exists content_corrections_status_idx
  on public.content_corrections (status, created_at desc);
create index if not exists content_corrections_item_idx
  on public.content_corrections (content_item_id, created_at desc);

alter table public.content_corrections enable row level security;
alter table public.content_corrections force row level security;
revoke all on table public.content_corrections from public, anon, authenticated;
grant select, insert, update, delete on table public.content_corrections to service_role;

-- ---------------------------------------------------------------------------
-- Student RPC
-- ---------------------------------------------------------------------------
create or replace function public.submit_content_correction(
  p_content_item_id uuid,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if v_note is null then
    raise exception 'note_required' using errcode = '22023';
  end if;
  if char_length(v_note) > 1000 then
    raise exception 'note_too_long' using errcode = '22023';
  end if;

  -- Only content the caller may actually see can be reported. Uses the
  -- deliverable (not visible) gate so a dismissed card can still be reported.
  if not private.content_item_deliverable_to_user(p_content_item_id, v_uid) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.content_corrections c
    where c.reporter_user_id = v_uid
      and c.created_at > now() - interval '60 seconds'
  ) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.content_corrections (
    content_item_id, reporter_user_id, note
  ) values (
    p_content_item_id, v_uid, v_note
  )
  on conflict (content_item_id, reporter_user_id) where (status = 'open')
  do update set note = excluded.note
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_content_corrections(
  p_status text default 'open',
  p_content_item_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  v_uid := private.require_admin_permission('moderation.read');

  if v_status is not null
     and v_status not in ('open', 'resolved', 'rejected', 'all') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  -- Reporter identity is intentionally omitted (Stage 13.6 privacy posture).
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', c.id,
          'content_item_id', c.content_item_id,
          'content_title', ci.title,
          'template_key', ci.template_key,
          'content_status', ci.status,
          'note', c.note,
          'status', c.status,
          'resolution_note', c.resolution_note,
          'resolved_at', c.resolved_at,
          'created_at', c.created_at
        )
        order by c.created_at desc
      )
      from (
        select *
        from public.content_corrections c0
        where (
            coalesce(v_status, 'open') = 'all'
            or c0.status = coalesce(v_status, 'open')
          )
          and (p_content_item_id is null or c0.content_item_id = p_content_item_id)
        order by c0.created_at desc
        limit v_limit
        offset v_offset
      ) c
      join public.content_items ci on ci.id = c.content_item_id
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_resolve_content_correction(
  p_id uuid,
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
  v_row public.content_corrections;
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

  select * into v_row from public.content_corrections where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'open' then
    raise exception 'already_closed' using errcode = '55000';
  end if;

  update public.content_corrections c set
    status = case when v_action = 'resolve' then 'resolved' else 'rejected' end,
    resolved_by = v_uid,
    resolved_at = now(),
    resolution_note = v_reason
  where c.id = p_id
  returning * into v_row;

  perform private.admin_write_audit(
    'content_correction.' || v_action,
    'content_correction',
    p_id::text,
    jsonb_build_object(
      'content_item_id', v_row.content_item_id,
      'status', v_row.status
    )
  );

  return jsonb_build_object('ok', true, 'id', p_id, 'status', v_row.status);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants (RBAC enforced inside each function body)
-- ---------------------------------------------------------------------------
revoke all on function public.submit_content_correction(uuid, text) from public, anon;
grant execute on function public.submit_content_correction(uuid, text)
  to authenticated, service_role;

revoke all on function public.admin_list_content_corrections(text, uuid, integer, integer)
  from public, anon;
grant execute on function public.admin_list_content_corrections(text, uuid, integer, integer)
  to authenticated, service_role;

revoke all on function public.admin_resolve_content_correction(uuid, text, text)
  from public, anon;
grant execute on function public.admin_resolve_content_correction(uuid, text, text)
  to authenticated, service_role;

comment on function public.submit_content_correction(uuid, text) is
  'Student «Сообщить об ошибке» for managed content. Requires the item to be deliverable to the caller; one open report per (item, reporter).';

commit;
