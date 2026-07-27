-- Stage 13.3 — teachers management foundation.
-- LOCAL ONLY. Do not apply to a remote Supabase project from this migration.
begin;

insert into public.admin_permissions(code, description)
values ('teachers.write', 'Create and edit teachers')
on conflict (code) do nothing;
insert into public.admin_role_permissions(role_code, permission_code)
select r.code, 'teachers.write'
from public.admin_roles r
where r.code in ('super_admin', 'academic_editor')
on conflict do nothing;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.normalize_person_name(p_value text)
returns text language sql immutable set search_path = '' as $$
  select lower(regexp_replace(btrim(coalesce(p_value, '')), '\s+', ' ', 'g'));
$$;
revoke all on function private.normalize_person_name(text) from public, anon, authenticated;

alter table public.teachers add column if not exists status text;
update public.teachers set status = 'published' where status is null;
alter table public.teachers alter column status set default 'draft';
alter table public.teachers alter column status set not null;
alter table public.teachers add column if not exists about_text text not null default '';
alter table public.teachers add column if not exists photo_path text null;
alter table public.teachers add column if not exists position text null;
alter table public.teachers add column if not exists academic_degree text null;
alter table public.teachers add column if not exists contacts_public jsonb not null default '{}'::jsonb;
alter table public.teachers add column if not exists updated_at timestamptz not null default now();
alter table public.teachers add column if not exists published_at timestamptz null;
alter table public.teachers add column if not exists archived_at timestamptz null;
update public.teachers
set published_at = coalesce(published_at, created_at, now())
where status = 'published' and published_at is null;
alter table public.teachers drop constraint if exists teachers_status_check;
alter table public.teachers add constraint teachers_status_check
  check (status in ('draft', 'published', 'archived'));
create index if not exists teachers_published_normalized_name_idx
  on public.teachers (lower(normalized_name)) where status = 'published';
create index if not exists teachers_full_name_idx on public.teachers (full_name);

create table if not exists public.teacher_versions (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.teachers(id) on delete restrict,
  version_number integer not null,
  snapshot jsonb not null,
  created_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (teacher_id, version_number)
);
create table if not exists public.teacher_import_batches (
  id uuid primary key default gen_random_uuid(),
  created_by uuid null references public.users(id) on delete set null,
  file_name text not null default '',
  status text not null check (status in ('dry_run', 'applied', 'cancelled')),
  payload_hash text null,
  summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.teacher_import_batches add column if not exists payload_hash text null;
create unique index if not exists teacher_import_batches_actor_payload_uidx
  on public.teacher_import_batches (created_by, payload_hash)
  where status = 'applied' and payload_hash is not null and created_by is not null;

create table if not exists public.teacher_import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.teacher_import_batches(id) on delete cascade,
  row_number integer not null check (row_number > 0),
  classification text not null check (classification in ('new', 'update', 'duplicate', 'error')),
  payload jsonb not null default '{}'::jsonb,
  error_text text null,
  matched_teacher_id uuid null references public.teachers(id) on delete set null,
  unique (batch_id, row_number)
);

alter table public.teacher_difficulty_targets
  add column if not exists canonical_teacher_id uuid null references public.teachers(id) on delete set null;
create index if not exists teacher_difficulty_targets_canonical_teacher_id_idx
  on public.teacher_difficulty_targets(canonical_teacher_id);

insert into public.teachers (full_name, normalized_name, status, about_text, created_at, updated_at, published_at)
select t.display_name, private.normalize_person_name(t.display_name), 'published',
  coalesce(t.about_text, ''), now(), now(), now()
from public.teacher_difficulty_targets t
where t.canonical_teacher_id is null
  and not exists (
    select 1 from public.teachers p
    where lower(p.normalized_name) = private.normalize_person_name(t.display_name)
  );

update public.teacher_difficulty_targets t
set canonical_teacher_id = p.id
from public.teachers p
where t.canonical_teacher_id is null
  and lower(p.normalized_name) = private.normalize_person_name(t.display_name)
  and (
    select count(*) from public.teachers x
    where lower(x.normalized_name) = private.normalize_person_name(t.display_name)
  ) = 1;

alter table public.teachers enable row level security;
alter table public.teachers force row level security;
alter table public.teacher_versions enable row level security;
alter table public.teacher_versions force row level security;
alter table public.teacher_import_batches enable row level security;
alter table public.teacher_import_batches force row level security;
alter table public.teacher_import_rows enable row level security;
alter table public.teacher_import_rows force row level security;
revoke all on table public.teachers, public.teacher_versions, public.teacher_import_batches,
  public.teacher_import_rows from public, anon, authenticated;
grant select on public.teachers to authenticated;
drop policy if exists teachers_published_authenticated_read on public.teachers;
create policy teachers_published_authenticated_read on public.teachers for select to authenticated
  using (status = 'published');

create or replace function private.stage13_3_can_write_teachers()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_ok boolean := false;
begin
  if auth.uid() is null then return false; end if;
  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is not null then
    execute 'select private.has_admin_permission($1,$2,$3,$4)'
      into v_ok using auth.uid(), 'teachers.write', 'global', null::uuid;
  end if;
  return coalesce(v_ok, false);
end $$;
revoke all on function private.stage13_3_can_write_teachers() from public, anon, authenticated;

create or replace function private.stage13_3_can_read_teachers()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_ok boolean := false;
begin
  if auth.uid() is null then return false; end if;
  if private.stage13_3_can_write_teachers() then return true; end if;
  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is not null then
    execute 'select private.has_admin_permission($1,$2,$3,$4)'
      into v_ok using auth.uid(), 'academic.read', 'global', null::uuid;
  end if;
  return coalesce(v_ok, false);
end $$;
revoke all on function private.stage13_3_can_read_teachers() from public, anon, authenticated;

create or replace function private.stage13_3_sanitize_contacts(p_contacts jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(
    (
      select jsonb_object_agg(k, p_contacts -> k)
      from unnest(array['website', 'public_email', 'office', 'telegram']) as k
      where coalesce(p_contacts, '{}'::jsonb) ? k
        and nullif(btrim(p_contacts ->> k), '') is not null
    ),
    '{}'::jsonb
  );
$$;

create or replace function private.stage13_3_related_subjects(p_teacher_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_out jsonb := '[]'::jsonb;
begin
  if to_regclass('public.offering_teachers') is null
     or to_regclass('public.subject_offerings') is null
     or to_regclass('public.subject_catalog') is null then
    return '[]'::jsonb;
  end if;
  execute $q$
    select coalesce(
      (
        select jsonb_agg(
          jsonb_build_object('subject_id', x.id, 'canonical_name', x.canonical_name)
          order by x.canonical_name
        )
        from (
          select distinct sc.id, sc.canonical_name
          from public.offering_teachers ot
          join public.subject_offerings so on so.id = ot.subject_offering_id
          join public.subject_catalog sc on sc.id = so.subject_id
          where ot.teacher_id = $1
        ) x
      ),
      '[]'::jsonb
    )
  $q$ into v_out using p_teacher_id;
  return coalesce(v_out, '[]'::jsonb);
exception when others then
  return '[]'::jsonb;
end $$;
revoke all on function private.stage13_3_related_subjects(uuid) from public, anon, authenticated;

create or replace function public.admin_list_teachers(
  p_query text default null,
  p_status text default null,
  p_sort text default 'name_asc'
)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_3_can_read_teachers() then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
          to_jsonb(t) || jsonb_build_object(
            'related_subjects', private.stage13_3_related_subjects(t.id),
            'photo_placeholder', (t.photo_path is null)
          )
          order by
            case when p_sort = 'name_desc' then t.full_name end desc,
            case when p_sort = 'updated_desc' then t.updated_at end desc nulls last,
            t.full_name asc
        )
        from public.teachers t
        where (p_status is null or t.status = p_status)
          and (
            p_query is null
            or t.full_name ilike '%' || p_query || '%'
            or coalesce(t.department, '') ilike '%' || p_query || '%'
          )
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_upsert_teacher(
  p_id uuid default null,
  p_full_name text default '',
  p_department text default null,
  p_position text default null,
  p_academic_degree text default null,
  p_about_text text default '',
  p_status text default 'draft',
  p_contacts_public jsonb default '{}'::jsonb,
  p_photo_path text default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_version integer;
  v_prev_status text;
  v_action text;
begin
  if not private.stage13_3_can_write_teachers() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if btrim(p_full_name) = '' or p_status not in ('draft', 'published', 'archived') then
    raise exception 'invalid_teacher' using errcode = '22023';
  end if;
  p_contacts_public := private.stage13_3_sanitize_contacts(p_contacts_public);

  if p_id is null then
    insert into public.teachers(
      full_name, normalized_name, department, position, academic_degree,
      about_text, status, contacts_public, photo_path, updated_at, published_at, archived_at
    ) values (
      btrim(p_full_name), private.normalize_person_name(p_full_name), p_department, p_position,
      p_academic_degree, coalesce(p_about_text, ''), p_status, p_contacts_public, p_photo_path,
      now(),
      case when p_status = 'published' then now() end,
      case when p_status = 'archived' then now() end
    )
    returning id into v_id;
    v_action := 'teacher.create';
  else
    select status into v_prev_status
    from public.teachers
    where id = p_id
    for update;
    if v_prev_status is null then
      raise exception 'teacher_not_found' using errcode = 'P0002';
    end if;
    update public.teachers set
      full_name = btrim(p_full_name),
      normalized_name = private.normalize_person_name(p_full_name),
      department = p_department,
      position = p_position,
      academic_degree = p_academic_degree,
      about_text = coalesce(p_about_text, ''),
      status = p_status,
      contacts_public = p_contacts_public,
      photo_path = coalesce(p_photo_path, photo_path),
      updated_at = now(),
      published_at = case when p_status = 'published' then coalesce(published_at, now()) else published_at end,
      archived_at = case when p_status = 'archived' then now() else null end
    where id = p_id
    returning id into v_id;
    v_action := case
      when v_prev_status is distinct from p_status and p_status = 'archived' then 'teacher.archive'
      when v_prev_status is distinct from p_status and p_status = 'published' then 'teacher.publish'
      when v_prev_status = 'archived' and p_status <> 'archived' then 'teacher.restore'
      else 'teacher.update'
    end;
  end if;

  select coalesce(max(version_number), 0) + 1 into v_version
  from public.teacher_versions
  where teacher_id = v_id;
  insert into public.teacher_versions(teacher_id, version_number, snapshot, created_by)
  select v_id, v_version, to_jsonb(t), auth.uid()
  from public.teachers t
  where t.id = v_id;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      v_action,
      'teacher',
      v_id::text,
      jsonb_build_object(
        'status', p_status,
        'prev_status', v_prev_status,
        'version_number', v_version
      )
    );
  end if;
  return v_id;
end $$;

create or replace function public.admin_set_teacher_status(p_id uuid, p_status text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_row public.teachers%rowtype;
begin
  select * into v_row from public.teachers where id = p_id for update;
  if not found then
    raise exception 'teacher_not_found' using errcode = 'P0002';
  end if;
  return public.admin_upsert_teacher(
    v_row.id, v_row.full_name, v_row.department, v_row.position, v_row.academic_degree,
    v_row.about_text, p_status, v_row.contacts_public, v_row.photo_path
  );
end $$;

create or replace function public.admin_list_teacher_versions(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_3_can_write_teachers() then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(to_jsonb(v) order by v.version_number desc)
        from public.teacher_versions v
        where v.teacher_id = p_id
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_restore_teacher_version(p_id uuid, p_version_number integer)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  s jsonb;
  restored uuid;
begin
  if not private.stage13_3_can_write_teachers() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select snapshot into s
  from public.teacher_versions
  where teacher_id = p_id and version_number = p_version_number;
  if s is null then
    raise exception 'version_not_found' using errcode = 'P0002';
  end if;
  restored := public.admin_upsert_teacher(
    p_id,
    s->>'full_name',
    s->>'department',
    s->>'position',
    s->>'academic_degree',
    s->>'about_text',
    coalesce(s->>'status', 'draft'),
    coalesce(s->'contacts_public', '{}'::jsonb),
    s->>'photo_path'
  );
  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'teacher.version_restore',
      'teacher',
      restored::text,
      jsonb_build_object(
        'teacher_id', p_id,
        'version_number', p_version_number
      )
    );
  end if;
  return restored;
end $$;

create or replace function public.get_published_teacher(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (
      select jsonb_build_object(
        'id', t.id,
        'full_name', t.full_name,
        'department', t.department,
        'position', t.position,
        'academic_degree', t.academic_degree,
        'about_text', t.about_text,
        'photo_path', t.photo_path,
        'contacts_public', t.contacts_public,
        'related_subjects', private.stage13_3_related_subjects(t.id)
      )
      from public.teachers t
      where t.id = p_id and t.status = 'published'
    ),
    'null'::jsonb
  );
$$;

create or replace function public.admin_list_teacher_import_batches(p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_3_can_write_teachers() then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(to_jsonb(b) order by b.created_at desc)
        from (
          select *
          from public.teacher_import_batches
          order by created_at desc
          limit greatest(1, least(coalesce(p_limit, 20), 100))
        ) b
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_list_teacher_import_rows(p_batch_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_3_can_write_teachers() then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(to_jsonb(r) order by r.row_number)
        from public.teacher_import_rows r
        where r.batch_id = p_batch_id
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_teacher_import_dry_run(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r jsonb;
  n integer := 0;
  c text;
  err text;
  normalized text;
  match_id uuid;
  match_count integer;
  seen text[] := '{}';
  out_rows jsonb := '[]'::jsonb;
  tid text;
begin
  if not private.stage13_3_can_write_teachers() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    n := n + 1;
    normalized := private.normalize_person_name(r->>'full_name');
    match_id := null;
    match_count := 0;
    c := null;
    err := null;
    tid := nullif(btrim(r->>'teacher_id'), '');

    if tid is not null then
      begin
        select t.id into match_id from public.teachers t where t.id = tid::uuid;
        if match_id is null then
          c := 'error';
          err := 'teacher_id_not_found';
        else
          c := 'update';
        end if;
      exception when invalid_text_representation then
        c := 'error';
        err := 'invalid_teacher_id';
      end;
    elsif coalesce(nullif(btrim(r->>'public_email'), ''), '') <> '' then
      select count(*) into match_count
      from public.teachers t
      where lower(coalesce(t.contacts_public->>'public_email', '')) =
            lower(btrim(r->>'public_email'));
      if match_count = 1 then
        select t.id into match_id
        from public.teachers t
        where lower(coalesce(t.contacts_public->>'public_email', '')) =
              lower(btrim(r->>'public_email'))
        limit 1;
        c := 'update';
      elsif match_count > 1 then
        c := 'duplicate';
        err := 'ambiguous_email';
      end if;
    end if;

    if c is null then
      select count(*) into match_count
      from public.teachers t
      where lower(t.normalized_name) = normalized;
      if match_count = 1 then
        select t.id into match_id
        from public.teachers t
        where lower(t.normalized_name) = normalized
        limit 1;
      end if;
      c := case
        when normalized = '' then 'error'
        when normalized = any(seen) then 'duplicate'
        when match_count > 1 then 'duplicate'
        when match_id is null then 'new'
        else 'update'
      end;
      err := case
        when c = 'error' then 'full_name_required'
        when c = 'duplicate' and match_count > 1 then 'ambiguous_name'
        when c = 'duplicate' and normalized = any(seen) then 'duplicate_in_file'
        else null
      end;
    end if;

    out_rows := out_rows || jsonb_build_array(
      jsonb_build_object(
        'row_number', n,
        'classification', c,
        'matched_teacher_id', match_id,
        'error_text', err,
        'payload', r
      )
    );
    if normalized <> '' then
      seen := array_append(seen, normalized);
    end if;
  end loop;
  return jsonb_build_object('rows', n, 'items', out_rows);
end $$;

create or replace function public.admin_teacher_import_apply(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b uuid;
  item jsonb;
  created integer := 0;
  updated integer := 0;
  skipped integer := 0;
  conflicts integer := 0;
  errors integer := 0;
  dry jsonb;
  classification text;
  matched uuid;
  new_id uuid;
  v_payload_hash text := md5(coalesce(p_rows, '[]'::jsonb)::text);
  contacts jsonb;
begin
  if not private.stage13_3_can_write_teachers() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select tb.id into b
  from public.teacher_import_batches tb
  where tb.created_by = auth.uid()
    and tb.status = 'applied'
    and tb.payload_hash = v_payload_hash
  order by tb.created_at desc
  limit 1;
  if b is not null then
    return jsonb_build_object(
      'batch_id', b,
      'idempotent_replay', true,
      'summary', (select summary from public.teacher_import_batches where id = b)
    );
  end if;

  dry := public.admin_teacher_import_dry_run(p_rows);

  begin
    insert into public.teacher_import_batches(created_by, status, payload_hash, summary)
    values (
      auth.uid(),
      'applied',
      v_payload_hash,
      dry || jsonb_build_object('payload_hash', v_payload_hash)
    )
    returning id into b;
  exception when unique_violation then
    select tb.id into b
    from public.teacher_import_batches tb
    where tb.created_by = auth.uid()
      and tb.status = 'applied'
      and tb.payload_hash = v_payload_hash
    order by tb.created_at desc
    limit 1;
    return jsonb_build_object(
      'batch_id', b,
      'idempotent_replay', true,
      'summary', (select summary from public.teacher_import_batches where id = b)
    );
  end;

  for item in select value from jsonb_array_elements(coalesce(dry->'items', '[]'::jsonb)) loop
    classification := item->>'classification';
    matched := nullif(item->>'matched_teacher_id', '')::uuid;
    insert into public.teacher_import_rows(
      batch_id, row_number, classification, payload, error_text, matched_teacher_id
    ) values (
      b,
      (item->>'row_number')::integer,
      classification,
      coalesce(item->'payload', '{}'::jsonb),
      item->>'error_text',
      matched
    );

    contacts := case
      when jsonb_typeof(item->'payload'->'contacts_public') = 'object'
        then item->'payload'->'contacts_public'
      else jsonb_strip_nulls(jsonb_build_object(
        'public_email', nullif(btrim(item->'payload'->>'public_email'), ''),
        'website', nullif(btrim(item->'payload'->>'website'), ''),
        'office', nullif(btrim(item->'payload'->>'office'), ''),
        'telegram', nullif(btrim(item->'payload'->>'telegram'), '')
      ))
    end;

    if classification = 'new' then
      new_id := public.admin_upsert_teacher(
        null,
        item->'payload'->>'full_name',
        item->'payload'->>'department',
        item->'payload'->>'position',
        item->'payload'->>'academic_degree',
        coalesce(item->'payload'->>'about_text', ''),
        'draft',
        contacts,
        null
      );
      created := created + 1;
    elsif classification = 'update' and matched is not null then
      perform public.admin_upsert_teacher(
        matched,
        item->'payload'->>'full_name',
        item->'payload'->>'department',
        item->'payload'->>'position',
        item->'payload'->>'academic_degree',
        coalesce(item->'payload'->>'about_text', ''),
        (select status from public.teachers where id = matched),
        contacts,
        null
      );
      updated := updated + 1;
    elsif classification = 'duplicate' then
      conflicts := conflicts + 1;
    elsif classification = 'error' then
      errors := errors + 1;
    else
      skipped := skipped + 1;
    end if;
  end loop;

  update public.teacher_import_batches
  set summary = dry || jsonb_build_object(
    'payload_hash', v_payload_hash,
    'created', created,
    'updated', updated,
    'skipped', skipped,
    'conflict', conflicts,
    'error', errors
  )
  where id = b;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'teacher.import_apply',
      'teacher_import_batch',
      b::text,
      jsonb_build_object(
        'created', created,
        'updated', updated,
        'conflict', conflicts,
        'error', errors,
        'payload_hash', v_payload_hash
      )
    );
  end if;

  return jsonb_build_object(
    'batch_id', b,
    'idempotent_replay', false,
    'payload_hash', v_payload_hash,
    'created', created,
    'updated', updated,
    'skipped', skipped,
    'conflict', conflicts,
    'error', errors
  );
end $$;

revoke all on function public.admin_list_teachers(text,text,text),
  public.admin_upsert_teacher(uuid,text,text,text,text,text,text,jsonb,text),
  public.admin_set_teacher_status(uuid,text),
  public.admin_list_teacher_versions(uuid),
  public.admin_restore_teacher_version(uuid,integer),
  public.get_published_teacher(uuid),
  public.admin_list_teacher_import_batches(integer),
  public.admin_list_teacher_import_rows(uuid),
  public.admin_teacher_import_dry_run(jsonb),
  public.admin_teacher_import_apply(jsonb)
  from public, anon;
grant execute on function public.admin_list_teachers(text,text,text),
  public.admin_upsert_teacher(uuid,text,text,text,text,text,text,jsonb,text),
  public.admin_set_teacher_status(uuid,text),
  public.admin_list_teacher_versions(uuid),
  public.admin_restore_teacher_version(uuid,integer),
  public.get_published_teacher(uuid),
  public.admin_list_teacher_import_batches(integer),
  public.admin_list_teacher_import_rows(uuid),
  public.admin_teacher_import_dry_run(jsonb),
  public.admin_teacher_import_apply(jsonb)
  to authenticated, service_role;

-- Drop older overloads if present from earlier drafts.
drop function if exists public.admin_list_teachers(text, text);
drop function if exists public.admin_upsert_teacher(uuid,text,text,text,text,text,text,jsonb);

commit;
