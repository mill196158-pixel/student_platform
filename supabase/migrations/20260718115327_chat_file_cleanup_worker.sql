-- Stage 10b: Yandex Object Storage cleanup worker (queue claim + finalize RPCs).
-- Edge Function deletes objects; SQL never calls Yandex.
-- Cron HTTP invoke uses Vault secret (no plaintext in this file).

-- ---------------------------------------------------------------------------
-- 1) Queue columns for lease / retry / backoff
-- ---------------------------------------------------------------------------
alter table public.chat_file_cleanup_queue
  add column if not exists attempts integer not null default 0;

alter table public.chat_file_cleanup_queue
  add column if not exists available_at timestamptz not null default pg_catalog.now();

alter table public.chat_file_cleanup_queue
  add column if not exists processing_started_at timestamptz null;

create index if not exists chat_file_cleanup_queue_claim_idx
  on public.chat_file_cleanup_queue (available_at, marked_at)
  where status in ('pending', 'processing');

create index if not exists chat_file_cleanup_queue_processing_started_idx
  on public.chat_file_cleanup_queue (processing_started_at)
  where status = 'processing';

comment on column public.chat_file_cleanup_queue.attempts is
  'Claim attempts; incremented on each claim. Max 8 before failed.';
comment on column public.chat_file_cleanup_queue.available_at is
  'Earliest time the row may be claimed (backoff).';
comment on column public.chat_file_cleanup_queue.processing_started_at is
  'Lease start; stale processing is reclaimable after 10 minutes.';

-- ---------------------------------------------------------------------------
-- 2) Error journal (no secrets, no signed URLs, no file_url)
-- ---------------------------------------------------------------------------
create table if not exists public.chat_file_cleanup_errors (
  id uuid primary key default gen_random_uuid(),
  queue_id uuid null references public.chat_file_cleanup_queue (id) on delete set null,
  chat_id uuid null,
  chat_file_id uuid null,
  error_code text not null,
  error_message text not null,
  http_status integer null,
  created_at timestamptz not null default pg_catalog.now()
);

create index if not exists chat_file_cleanup_errors_created_idx
  on public.chat_file_cleanup_errors (created_at desc);

create index if not exists chat_file_cleanup_errors_queue_idx
  on public.chat_file_cleanup_errors (queue_id, created_at desc);

comment on table public.chat_file_cleanup_errors is
  'Cleanup worker error log. Must never store secrets, signed URLs, or file_url.';

alter table public.chat_file_cleanup_errors enable row level security;
alter table public.chat_file_cleanup_errors force row level security;

revoke all privileges on table public.chat_file_cleanup_errors from public;
revoke all privileges on table public.chat_file_cleanup_errors from anon;
revoke all privileges on table public.chat_file_cleanup_errors from authenticated;

-- ---------------------------------------------------------------------------
-- 3) Sanitize helper (strip URL-like substrings from stored errors)
-- ---------------------------------------------------------------------------
create or replace function public.sanitize_cleanup_error_text(p_text text)
returns text
language sql
immutable
security definer
set search_path = ''
as $function$
  select left(
    trim(
      both from
      regexp_replace(
        regexp_replace(
          coalesce(p_text, ''),
          'https?://[^[:space:]]+',
          '[redacted_url]',
          'gi'
        ),
        '(?i)(authorization|secret|password|access[_-]?key|signature)[=:][^[:space:]]+',
        '\1=[redacted]',
        'g'
      )
    ),
    500
  );
$function$;

revoke all on function public.sanitize_cleanup_error_text(text) from public;
revoke all on function public.sanitize_cleanup_error_text(text) from anon;
revoke all on function public.sanitize_cleanup_error_text(text) from authenticated;
grant execute on function public.sanitize_cleanup_error_text(text) to service_role;

-- ---------------------------------------------------------------------------
-- 4) Claim pending / reclaim stuck (service_role only)
-- ---------------------------------------------------------------------------
create or replace function public.claim_pending_chat_file_cleanup(p_limit integer default 25)
returns table (
  id uuid,
  chat_id uuid,
  chat_file_id uuid,
  file_key text,
  attempts integer
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  -- Exhausted stuck processing → failed
  update public.chat_file_cleanup_queue q
  set
    status = 'failed',
    processing_started_at = null,
    processed_at = pg_catalog.now(),
    error_text = 'max_attempts_exceeded'
  where q.status = 'processing'
    and q.attempts >= 8
    and q.processing_started_at is not null
    and q.processing_started_at <= pg_catalog.now() - interval '10 minutes';

  return query
  with picked as (
    select q.id
    from public.chat_file_cleanup_queue q
    where q.attempts < 8
      and (
        (q.status = 'pending' and q.available_at <= pg_catalog.now())
        or (
          q.status = 'processing'
          and q.processing_started_at is not null
          and q.processing_started_at <= pg_catalog.now() - interval '10 minutes'
        )
      )
    order by q.available_at, q.marked_at
    limit v_limit
    for update skip locked
  ),
  claimed as (
    update public.chat_file_cleanup_queue q
    set
      status = 'processing',
      processing_started_at = pg_catalog.now(),
      attempts = q.attempts + 1,
      error_text = null
    from picked
    where q.id = picked.id
    returning
      q.id,
      q.chat_id,
      q.chat_file_id,
      q.file_key,
      q.attempts
  )
  select c.id, c.chat_id, c.chat_file_id, c.file_key, c.attempts
  from claimed c;
end;
$function$;

revoke all on function public.claim_pending_chat_file_cleanup(integer) from public;
revoke all on function public.claim_pending_chat_file_cleanup(integer) from anon;
revoke all on function public.claim_pending_chat_file_cleanup(integer) from authenticated;
grant execute on function public.claim_pending_chat_file_cleanup(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 5) Re-validate eligibility + trusted object key (DB only)
-- ---------------------------------------------------------------------------
create or replace function public.get_chat_file_cleanup_deletion_target(p_queue_id uuid)
returns table (
  queue_id uuid,
  chat_id uuid,
  chat_file_id uuid,
  file_key text,
  eligible boolean,
  skip_reason text
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_q public.chat_file_cleanup_queue%rowtype;
  v_archive public.chat_academic_archives%rowtype;
  v_key text;
  v_now timestamptz := pg_catalog.now();
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if p_queue_id is null then
    return query
    select null::uuid, null::uuid, null::uuid, null::text, false, 'missing_queue_id';
    return;
  end if;

  select * into v_q
  from public.chat_file_cleanup_queue q
  where q.id = p_queue_id;

  if not found then
    return query
    select p_queue_id, null::uuid, null::uuid, null::text, false, 'queue_not_found';
    return;
  end if;

  if v_q.status = 'done' then
    return query
    select v_q.id, v_q.chat_id, v_q.chat_file_id, null::text, false, 'already_done';
    return;
  end if;

  select * into v_archive
  from public.chat_academic_archives a
  where a.chat_id = v_q.chat_id;

  if not found then
    return query
    select v_q.id, v_q.chat_id, v_q.chat_file_id, null::text, false, 'archive_missing';
    return;
  end if;

  if v_archive.expired_at is null then
    return query
    select v_q.id, v_q.chat_id, v_q.chat_file_id, null::text, false, 'not_expired';
    return;
  end if;

  if v_archive.available_until > v_now then
    return query
    select v_q.id, v_q.chat_id, v_q.chat_file_id, null::text, false, 'retention_not_ended';
    return;
  end if;

  -- Queue row must still match this chat/file.
  if not exists (
    select 1
    from public.chat_files cf
    where cf.id = v_q.chat_file_id
      and cf.chat_id = v_q.chat_id
  ) then
    -- File metadata already gone: treat as nothing to delete in storage if key empty.
    v_key := nullif(btrim(v_q.file_key), '');
    if v_key is null then
      return query
      select v_q.id, v_q.chat_id, v_q.chat_file_id, null::text, false, 'file_already_cleared';
      return;
    end if;
    -- Trusted key from queue snapshot taken at expire time (copied from chat_files).
    return query
    select v_q.id, v_q.chat_id, v_q.chat_file_id, v_key, true, null::text;
    return;
  end if;

  select nullif(btrim(cf.file_key::text), '')
  into v_key
  from public.chat_files cf
  where cf.id = v_q.chat_file_id
    and cf.chat_id = v_q.chat_id;

  if v_key is null then
    v_key := nullif(btrim(v_q.file_key), '');
  end if;

  if v_key is null then
    return query
    select v_q.id, v_q.chat_id, v_q.chat_file_id, null::text, false, 'missing_file_key';
    return;
  end if;

  -- Never accept client URLs as object identity.
  if v_key ~* '^https?://' or position('..' in v_key) > 0 or v_key like '/%' then
    return query
    select v_q.id, v_q.chat_id, v_q.chat_file_id, null::text, false, 'invalid_file_key';
    return;
  end if;

  return query
  select v_q.id, v_q.chat_id, v_q.chat_file_id, v_key, true, null::text;
end;
$function$;

revoke all on function public.get_chat_file_cleanup_deletion_target(uuid) from public;
revoke all on function public.get_chat_file_cleanup_deletion_target(uuid) from anon;
revoke all on function public.get_chat_file_cleanup_deletion_target(uuid) from authenticated;
grant execute on function public.get_chat_file_cleanup_deletion_target(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 6) Error journal insert
-- ---------------------------------------------------------------------------
create or replace function public.log_chat_file_cleanup_error(
  p_queue_id uuid,
  p_chat_id uuid,
  p_chat_file_id uuid,
  p_error_code text,
  p_error_message text,
  p_http_status integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_id uuid;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  insert into public.chat_file_cleanup_errors (
    queue_id,
    chat_id,
    chat_file_id,
    error_code,
    error_message,
    http_status
  )
  values (
    p_queue_id,
    p_chat_id,
    p_chat_file_id,
    left(coalesce(nullif(btrim(p_error_code), ''), 'unknown'), 120),
    public.sanitize_cleanup_error_text(p_error_message),
    p_http_status
  )
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.log_chat_file_cleanup_error(uuid, uuid, uuid, text, text, integer) from public;
revoke all on function public.log_chat_file_cleanup_error(uuid, uuid, uuid, text, text, integer) from anon;
revoke all on function public.log_chat_file_cleanup_error(uuid, uuid, uuid, text, text, integer) from authenticated;
grant execute on function public.log_chat_file_cleanup_error(uuid, uuid, uuid, text, text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 7) Purge chat messages after all files for that chat are terminal
-- ---------------------------------------------------------------------------
create or replace function public.maybe_purge_expired_chat_content(p_chat_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_archive public.chat_academic_archives%rowtype;
  v_pending integer;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if p_chat_id is null then
    return false;
  end if;

  select * into v_archive
  from public.chat_academic_archives a
  where a.chat_id = p_chat_id;

  if not found then
    return false;
  end if;

  if v_archive.expired_at is null or v_archive.available_until > pg_catalog.now() then
    return false;
  end if;

  select count(*)::integer into v_pending
  from public.chat_file_cleanup_queue q
  where q.chat_id = p_chat_id
    and q.status in ('pending', 'processing');

  if coalesce(v_pending, 0) > 0 then
    return false;
  end if;

  -- Still have undeleted external objects pending metadata?
  if exists (
    select 1
    from public.chat_files cf
    where cf.chat_id = p_chat_id
      and cf.is_deleted = false
      and nullif(btrim(cf.file_key::text), '') is not null
  ) then
    return false;
  end if;

  -- Preserve chat_academic_archives tombstone; clear messages + related metadata.
  delete from public.message_reactions mr
  using public.messages m
  where mr.message_id = m.id
    and m.chat_id = p_chat_id;

  delete from public.chat_reads cr
  where cr.chat_id = p_chat_id;

  update public.messages m
  set file_id = null
  where m.chat_id = p_chat_id
    and m.file_id is not null;

  update public.chat_files cf
  set message_id = null
  where cf.chat_id = p_chat_id
    and cf.message_id is not null;

  delete from public.messages m
  where m.chat_id = p_chat_id;

  delete from public.chat_files cf
  where cf.chat_id = p_chat_id;

  -- Keep chats / chat_members / chat_academic_archives / chat_user_settings.
  return true;
end;
$function$;

revoke all on function public.maybe_purge_expired_chat_content(uuid) from public;
revoke all on function public.maybe_purge_expired_chat_content(uuid) from anon;
revoke all on function public.maybe_purge_expired_chat_content(uuid) from authenticated;
grant execute on function public.maybe_purge_expired_chat_content(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 8) Complete after successful object delete (or skip/fail/retry)
-- ---------------------------------------------------------------------------
create or replace function public.complete_chat_file_cleanup(
  p_queue_id uuid,
  p_outcome text,
  p_error_code text default null,
  p_error_message text default null,
  p_http_status integer default null,
  p_retry_seconds integer default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_q public.chat_file_cleanup_queue%rowtype;
  v_safe_error text;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if p_outcome not in ('done', 'skipped', 'failed', 'retry') then
    raise exception using errcode = 'P0001', message = 'invalid_outcome';
  end if;

  select * into v_q
  from public.chat_file_cleanup_queue q
  where q.id = p_queue_id
  for update;

  if not found then
    return;
  end if;

  if v_q.status = 'done' then
    return;
  end if;

  v_safe_error := public.sanitize_cleanup_error_text(p_error_message);

  if p_outcome in ('failed', 'retry', 'skipped')
     and coalesce(nullif(btrim(p_error_code), ''), v_safe_error) is not null then
    perform public.log_chat_file_cleanup_error(
      p_queue_id,
      v_q.chat_id,
      v_q.chat_file_id,
      coalesce(nullif(btrim(p_error_code), ''), p_outcome),
      coalesce(v_safe_error, p_outcome),
      p_http_status
    );
  end if;

  if p_outcome = 'retry' then
    update public.chat_file_cleanup_queue q
    set
      status = 'pending',
      processing_started_at = null,
      error_text = v_safe_error,
      available_at = pg_catalog.now()
        + make_interval(secs => greatest(coalesce(p_retry_seconds, 30), 5))
    where q.id = p_queue_id;
    return;
  end if;

  if p_outcome = 'failed' then
    update public.chat_file_cleanup_queue q
    set
      status = 'failed',
      processing_started_at = null,
      processed_at = pg_catalog.now(),
      error_text = coalesce(v_safe_error, 'failed')
    where q.id = p_queue_id;
    perform public.maybe_purge_expired_chat_content(v_q.chat_id);
    return;
  end if;

  -- done / skipped: object gone or nothing to delete; clear metadata then mark done.
  update public.messages m
  set file_id = null
  where m.file_id = v_q.chat_file_id;

  update public.chat_files cf
  set
    is_deleted = true,
    file_url = '',
    file_key = '',
    file_size = 0
  where cf.id = v_q.chat_file_id
    and cf.chat_id = v_q.chat_id;

  update public.chat_file_cleanup_queue q
  set
    status = 'done',
    processing_started_at = null,
    processed_at = pg_catalog.now(),
    error_text = case when p_outcome = 'skipped' then coalesce(v_safe_error, p_error_code) else null end
  where q.id = p_queue_id;

  perform public.maybe_purge_expired_chat_content(v_q.chat_id);
end;
$function$;

revoke all on function public.complete_chat_file_cleanup(uuid, text, text, text, integer, integer) from public;
revoke all on function public.complete_chat_file_cleanup(uuid, text, text, text, integer, integer) from anon;
revoke all on function public.complete_chat_file_cleanup(uuid, text, text, text, integer, integer) from authenticated;
grant execute on function public.complete_chat_file_cleanup(uuid, text, text, text, integer, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 9) Cron: invoke Edge Function exactly once (Vault bearer; no secret in git)
-- ---------------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

do $cron$
declare
  v_has_secret boolean := false;
begin
  select exists (
    select 1
    from vault.decrypted_secrets s
    where s.name = 'chat_file_cleanup_secret'
  ) into v_has_secret;

  if exists (
    select 1 from cron.job j where j.jobname = 'cleanup-chat-files'
  ) then
    perform cron.unschedule('cleanup-chat-files');
  end if;

  if not v_has_secret then
    raise notice 'Skipping cleanup-chat-files cron: vault secret chat_file_cleanup_secret missing';
    return;
  end if;

  perform cron.schedule(
    'cleanup-chat-files',
    '*/15 * * * *',
    $cmd$
    select net.http_post(
      url := 'https://gwdanmwluhrcfxbnplwd.supabase.co/functions/v1/cleanup-chat-files',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'chat_file_cleanup_secret'
          limit 1
        )
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 30000
    );
    $cmd$
  );
end;
$cron$;
