-- Stage 14.1.2 follow-up (Codex P1):
--   * Align structured-action legacy route projection with Mobile CTA routes
--   * Tombstone reference categories by legacy_key (bootstrap identity)
-- Does not edit applied migration 20260730190415.

-- ---------------------------------------------------------------------------
-- 1. Legacy route projection used by action conflict checks
-- ---------------------------------------------------------------------------
create or replace function private.content_legacy_route_for_screen(p_screen text)
returns text
language sql
immutable
as $$
  select case p_screen
    when 'home' then '/home'
    when 'diary' then '/my-diary'
    when 'schedule' then '/schedule'
    when 'info' then '/help'
    when 'help' then '/help'
    when 'profile' then '/profile'
    when 'learning' then '/learning'
    else null
  end;
$$;

revoke all on function private.content_legacy_route_for_screen(text)
  from public, anon, authenticated;
grant execute on function private.content_legacy_route_for_screen(text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 2. CTA allowlist: accept Mobile diary route alias
-- ---------------------------------------------------------------------------
create or replace function private.content_assert_cta(
  p_route text,
  p_url text
)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_prefixes text[] := array[
    '/diary', '/my-diary', '/info', '/profile', '/schedule', '/home',
    '/learning', '/chat', '/help'
  ];
  v_prefix text;
  v_ok boolean := false;
begin
  if p_route is not null and p_url is not null then
    raise exception 'invalid_cta_route_and_url' using errcode = '22023';
  end if;

  if p_route is not null then
    foreach v_prefix in array v_prefixes loop
      if p_route = v_prefix or p_route like v_prefix || '/%' then
        v_ok := true;
      end if;
    end loop;
    if not v_ok then
      raise exception 'invalid_cta_route' using errcode = '22023';
    end if;
    if p_route ~ '[[:space:]]' or length(p_route) > 300 then
      raise exception 'invalid_cta_route' using errcode = '22023';
    end if;
  end if;

  if p_url is not null then
    if length(p_url) > 500
       or p_url !~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9](:[0-9]{1,5})?(/[^[:space:]]*)?$' then
      raise exception 'invalid_cta_url' using errcode = '22023';
    end if;
  end if;
end;
$$;

revoke all on function private.content_assert_cta(text, text)
  from public, anon, authenticated;
grant execute on function private.content_assert_cta(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Category safe-delete: tombstone by legacy_key (bootstrap identity)
-- ---------------------------------------------------------------------------
create or replace function public.admin_safe_delete_reference_category(
  p_id uuid,
  p_expected_row_version integer,
  p_mode text,
  p_reassign_to uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.reference_categories;
  v_mode text := nullif(btrim(coalesce(p_mode, '')), '');
  v_published integer := 0;
  v_total integer := 0;
  v_moved integer := 0;
  v_tombstone_key text;
begin
  v_uid := private.require_admin_permission('content.publish');

  if v_mode is null or v_mode not in ('reassign', 'archive_articles', 'cancel') then
    raise exception 'invalid_delete_mode' using errcode = '22023';
  end if;
  if v_mode = 'cancel' then
    raise exception 'delete_cancelled' using errcode = 'P0001';
  end if;

  select * into v_row from public.reference_categories
  where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_expected_row_version is null then
    raise exception 'row_version_required' using errcode = '22023';
  end if;
  if v_row.row_version <> p_expected_row_version then
    raise exception 'row_version_conflict' using errcode = 'P0001';
  end if;

  select count(*)::integer into v_total
  from public.content_item_reference_categories l
  where l.reference_category_id = p_id;

  select count(*)::integer into v_published
  from public.content_item_reference_categories l
  join public.content_items c on c.id = l.content_item_id
  where l.reference_category_id = p_id
    and c.status = 'published';

  if v_mode = 'reassign' then
    if p_reassign_to is null or p_reassign_to = p_id then
      raise exception 'reassign_target_required' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.reference_categories c where c.id = p_reassign_to
    ) then
      raise exception 'reassign_target_not_found' using errcode = 'P0002';
    end if;
    update public.content_item_reference_categories l
    set reference_category_id = p_reassign_to
    where l.reference_category_id = p_id;
    get diagnostics v_moved = row_count;
  elsif v_mode = 'archive_articles' then
    if v_published > 0 then
      update public.content_items c set
        status = 'archived',
        row_version = c.row_version + 1,
        version_number = c.version_number + 1,
        updated_by = v_uid,
        updated_at = now()
      where c.id in (
        select l.content_item_id
        from public.content_item_reference_categories l
        where l.reference_category_id = p_id
      ) and c.status <> 'archived';
      get diagnostics v_moved = row_count;
    end if;
    delete from public.content_item_reference_categories
    where reference_category_id = p_id;
  end if;

  -- Bootstrap identity lives on legacy_key (e.g. content:reference_category:...).
  v_tombstone_key := nullif(btrim(coalesce(v_row.legacy_key, '')), '');
  if v_tombstone_key is not null then
    insert into public.content_legacy_tombstones (
      resource_kind, legacy_key, deleted_by, meta
    ) values (
      'reference_category', v_tombstone_key, v_uid,
      jsonb_build_object(
        'title', v_row.title,
        'key', v_row.key
      )
    )
    on conflict (resource_kind, legacy_key) do update
      set deleted_at = now(),
          deleted_by = excluded.deleted_by,
          meta = excluded.meta;
  end if;

  delete from public.reference_categories where id = p_id;

  perform private.content_write_domain_audit(
    'reference.safe_delete_category',
    'reference_category',
    p_id,
    jsonb_build_object(
      'mode', v_mode,
      'article_total', v_total,
      'published_before', v_published,
      'moved_or_archived', v_moved,
      'reassign_to', p_reassign_to,
      'legacy_key', v_tombstone_key,
      'tombstone', v_tombstone_key is not null
    )
  );

  return jsonb_build_object(
    'deleted', true,
    'id', p_id,
    'mode', v_mode,
    'article_total', v_total,
    'moved_or_archived', v_moved,
    'legacy_key', v_tombstone_key,
    'tombstone', v_tombstone_key is not null
  );
end;
$$;

revoke all on function public.admin_safe_delete_reference_category(
  uuid, integer, text, uuid
) from public, anon;
grant execute on function public.admin_safe_delete_reference_category(
  uuid, integer, text, uuid
) to authenticated, service_role;
