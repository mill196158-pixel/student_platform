-- Stage 13.4 — subjects admin foundation.
-- LOCAL ONLY. Do not apply to a remote Supabase project from this migration.
begin;

insert into public.admin_permissions(code, description)
values ('subjects.write', 'Create and edit subjects')
on conflict (code) do nothing;
insert into public.admin_role_permissions(role_code, permission_code)
select r.code, 'subjects.write'
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

-- Catalog admin fields (do not touch difficulty votes).
alter table public.subject_catalog add column if not exists department text null;
alter table public.subject_catalog add column if not exists control_form text null;
alter table public.subject_catalog add column if not exists difficulty_label text null;
alter table public.subject_catalog add column if not exists requirements text null;
alter table public.subject_catalog add column if not exists learning_outcomes text null;
alter table public.subject_catalog add column if not exists useful_links jsonb not null default '[]'::jsonb;
alter table public.subject_catalog add column if not exists status text;
update public.subject_catalog set status = 'published' where status is null;
alter table public.subject_catalog alter column status set default 'draft';
alter table public.subject_catalog alter column status set not null;
alter table public.subject_catalog drop constraint if exists subject_catalog_status_check;
alter table public.subject_catalog add constraint subject_catalog_status_check
  check (status in ('draft', 'published', 'archived'));
alter table public.subject_catalog add column if not exists published_at timestamptz null;
alter table public.subject_catalog add column if not exists archived_at timestamptz null;
update public.subject_catalog
set published_at = coalesce(published_at, created_at, now())
where status = 'published' and published_at is null;
-- Enforce uniqueness only when the catalog has no preexisting collisions.
-- Do not rewrite normalized_name for legacy duplicates; they remain visible as
-- ambiguous matches in import dry-run until an admin merges them manually.
do $uniq$
begin
  if not exists (
    select 1
    from public.subject_catalog
    group by normalized_name
    having count(*) > 1
  ) then
    create unique index if not exists subject_catalog_normalized_name_uidx
      on public.subject_catalog (normalized_name);
  end if;
end
$uniq$;
create index if not exists subject_catalog_status_name_idx
  on public.subject_catalog (status, canonical_name);

-- Ensure every catalog row can have a student profile shell.
insert into public.subject_student_profiles(subject_id, short_description, moderation_status, updated_at)
select sc.id, coalesce(sc.description, ''),
  case when sc.status = 'published' then 'published'
       when sc.status = 'archived' then 'hidden'
       else 'draft' end,
  now()
from public.subject_catalog sc
where not exists (
  select 1 from public.subject_student_profiles p where p.subject_id = sc.id
);

create table if not exists public.subject_versions (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references public.subject_catalog(id) on delete restrict,
  version_number integer not null,
  snapshot jsonb not null,
  created_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (subject_id, version_number)
);

create table if not exists public.subject_import_batches (
  id uuid primary key default gen_random_uuid(),
  created_by uuid null references public.users(id) on delete set null,
  file_name text not null default '',
  status text not null check (status in ('dry_run', 'applied', 'cancelled')),
  payload_hash text null,
  summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create unique index if not exists subject_import_batches_actor_payload_uidx
  on public.subject_import_batches (created_by, payload_hash)
  where status = 'applied' and payload_hash is not null and created_by is not null;

create table if not exists public.subject_import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.subject_import_batches(id) on delete cascade,
  row_number integer not null check (row_number > 0),
  classification text not null check (classification in ('new', 'update', 'duplicate', 'error')),
  payload jsonb not null default '{}'::jsonb,
  error_text text null,
  matched_subject_id uuid null references public.subject_catalog(id) on delete set null,
  unique (batch_id, row_number)
);

alter table public.subject_catalog enable row level security;
alter table public.subject_catalog force row level security;
alter table public.subject_versions enable row level security;
alter table public.subject_versions force row level security;
alter table public.subject_import_batches enable row level security;
alter table public.subject_import_batches force row level security;
alter table public.subject_import_rows enable row level security;
alter table public.subject_import_rows force row level security;
alter table public.subject_student_profiles enable row level security;
alter table public.subject_student_profiles force row level security;

revoke all on table public.subject_catalog, public.subject_versions,
  public.subject_import_batches, public.subject_import_rows,
  public.subject_student_profiles
  from public, anon, authenticated;
grant select on public.subject_catalog to authenticated;
grant select on public.subject_student_profiles to authenticated;

-- Drop legacy permissive SELECT policies (OR-combined with new ones).
drop policy if exists subject_catalog_read_authenticated on public.subject_catalog;
drop policy if exists subject_catalog_published_authenticated_read on public.subject_catalog;
create policy subject_catalog_published_authenticated_read on public.subject_catalog
  for select to authenticated using (status = 'published');
drop policy if exists subject_student_profiles_read_published_authenticated on public.subject_student_profiles;
drop policy if exists subject_student_profiles_admin_manage on public.subject_student_profiles;
create policy subject_student_profiles_read_published_authenticated on public.subject_student_profiles
  for select to authenticated using (moderation_status = 'published');

create or replace function private.stage13_4_can_write_subjects()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_ok boolean := false;
begin
  if auth.uid() is null then return false; end if;
  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is not null then
    execute 'select private.has_admin_permission($1,$2,$3,$4)'
      into v_ok using auth.uid(), 'subjects.write', 'global', null::uuid;
  end if;
  return coalesce(v_ok, false);
end $$;
revoke all on function private.stage13_4_can_write_subjects() from public, anon, authenticated;

create or replace function private.stage13_4_can_read_subjects()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_ok boolean := false;
begin
  if auth.uid() is null then return false; end if;
  if private.stage13_4_can_write_subjects() then return true; end if;
  if to_regprocedure('private.has_admin_permission(uuid,text,text,uuid)') is not null then
    execute 'select private.has_admin_permission($1,$2,$3,$4)'
      into v_ok using auth.uid(), 'academic.read', 'global', null::uuid;
  end if;
  return coalesce(v_ok, false);
end $$;
revoke all on function private.stage13_4_can_read_subjects() from public, anon, authenticated;

create or replace function private.stage13_4_related_teachers(p_subject_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_out jsonb := '[]'::jsonb;
begin
  if to_regclass('public.offering_teachers') is null
     or to_regclass('public.subject_offerings') is null
     or to_regclass('public.teachers') is null then
    return '[]'::jsonb;
  end if;
  execute $q$
    select coalesce(
      (
        select jsonb_agg(
          jsonb_build_object('teacher_id', x.id, 'full_name', x.full_name)
          order by x.full_name
        )
        from (
          select distinct t.id, t.full_name
          from public.offering_teachers ot
          join public.subject_offerings so on so.id = ot.subject_offering_id
          join public.teachers t on t.id = ot.teacher_id
          where so.subject_id = $1
        ) x
      ),
      '[]'::jsonb
    )
  $q$ into v_out using p_subject_id;
  return coalesce(v_out, '[]'::jsonb);
exception when others then
  return '[]'::jsonb;
end $$;
revoke all on function private.stage13_4_related_teachers(uuid) from public, anon, authenticated;

create or replace function private.stage13_4_subject_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(sc)
    || jsonb_build_object(
      'short_description', p.short_description,
      'what_to_expect', p.what_to_expect,
      'how_to_pass', p.how_to_pass,
      'useful_materials_note', p.useful_materials_note,
      'common_pitfalls', p.common_pitfalls,
      'tags', coalesce(p.tags, '{}'::text[]),
      'profile_id', p.id,
      'related_teachers', private.stage13_4_related_teachers(sc.id)
    )
  from public.subject_catalog sc
  left join public.subject_student_profiles p on p.subject_id = sc.id
  where sc.id = p_id;
$$;

create or replace function public.admin_list_subjects(
  p_query text default null,
  p_status text default null,
  p_sort text default 'name_asc'
)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_4_can_read_subjects() then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
          private.stage13_4_subject_json(sc.id)
          order by
            case when p_sort = 'name_desc' then sc.canonical_name end desc,
            case when p_sort = 'updated_desc' then sc.updated_at end desc nulls last,
            sc.canonical_name asc
        )
        from public.subject_catalog sc
        where (p_status is null or sc.status = p_status)
          and (
            p_query is null
            or sc.canonical_name ilike '%' || p_query || '%'
            or coalesce(sc.department, '') ilike '%' || p_query || '%'
          )
      ),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_upsert_subject(
  p_id uuid default null,
  p_canonical_name text default '',
  p_description text default null,
  p_department text default null,
  p_control_form text default null,
  p_difficulty_label text default null,
  p_requirements text default null,
  p_learning_outcomes text default null,
  p_useful_links jsonb default '[]'::jsonb,
  p_status text default 'draft',
  p_short_description text default null,
  p_what_to_expect text default null,
  p_how_to_pass text default null,
  p_useful_materials_note text default null,
  p_common_pitfalls text default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_version integer;
  v_prev text;
  v_action text;
  v_norm text;
  v_profile_status text;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if btrim(p_canonical_name) = '' or p_status not in ('draft', 'published', 'archived') then
    raise exception 'invalid_subject' using errcode = '22023';
  end if;
  v_norm := private.normalize_person_name(p_canonical_name);
  v_profile_status := case
    when p_status = 'published' then 'published'
    when p_status = 'archived' then 'hidden'
    else 'draft'
  end;
  if jsonb_typeof(coalesce(p_useful_links, '[]'::jsonb)) <> 'array' then
    p_useful_links := '[]'::jsonb;
  else
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'title', coalesce(nullif(btrim(elem->>'title'), ''), elem->>'url'),
          'url', nullif(btrim(elem->>'url'), '')
        )
      ),
      '[]'::jsonb
    )
    into p_useful_links
    from jsonb_array_elements(p_useful_links) elem
    where nullif(btrim(elem->>'url'), '') is not null;
  end if;

  perform pg_advisory_xact_lock(('x' || substr(md5(v_norm), 1, 16))::bit(64)::bigint);
  if exists (
    select 1 from public.subject_catalog sc
    where sc.normalized_name = v_norm
      and (p_id is null or sc.id <> p_id)
  ) then
    raise exception 'duplicate_subject_name' using errcode = '23505';
  end if;
  begin
    if p_id is null then
      insert into public.subject_catalog(
        canonical_name, normalized_name, description, department, control_form,
        difficulty_label, requirements, learning_outcomes, useful_links, status,
        updated_at, published_at, archived_at
      ) values (
        btrim(p_canonical_name), v_norm, p_description, p_department, p_control_form,
        p_difficulty_label, p_requirements, p_learning_outcomes, p_useful_links, p_status,
        now(),
        case when p_status = 'published' then now() end,
        case when p_status = 'archived' then now() end
      ) returning id into v_id;
      v_action := 'subject.create';
    else
      select status into v_prev from public.subject_catalog where id = p_id for update;
      if v_prev is null then
        raise exception 'subject_not_found' using errcode = 'P0002';
      end if;
      update public.subject_catalog set
        canonical_name = btrim(p_canonical_name),
        normalized_name = v_norm,
        description = p_description,
        department = p_department,
        control_form = p_control_form,
        difficulty_label = p_difficulty_label,
        requirements = p_requirements,
        learning_outcomes = p_learning_outcomes,
        useful_links = p_useful_links,
        status = p_status,
        updated_at = now(),
        published_at = case when p_status = 'published' then coalesce(published_at, now()) else published_at end,
        archived_at = case when p_status = 'archived' then now() else null end
      where id = p_id
      returning id into v_id;
      v_action := case
        when v_prev is distinct from p_status and p_status = 'archived' then 'subject.archive'
        when v_prev is distinct from p_status and p_status = 'published' then 'subject.publish'
        when v_prev = 'archived' and p_status <> 'archived' then 'subject.restore'
        else 'subject.update'
      end;
    end if;
  exception when unique_violation then
    raise exception 'duplicate_subject_name' using errcode = '23505';
  end;

  insert into public.subject_student_profiles(
    subject_id, short_description, what_to_expect, how_to_pass,
    useful_materials_note, common_pitfalls, moderation_status, updated_by, updated_at
  ) values (
    v_id,
    coalesce(p_short_description, p_description, ''),
    p_what_to_expect, p_how_to_pass, p_useful_materials_note, p_common_pitfalls,
    v_profile_status, auth.uid(), now()
  )
  on conflict (subject_id) do update set
    short_description = excluded.short_description,
    what_to_expect = excluded.what_to_expect,
    how_to_pass = excluded.how_to_pass,
    useful_materials_note = excluded.useful_materials_note,
    common_pitfalls = excluded.common_pitfalls,
    moderation_status = excluded.moderation_status,
    updated_by = auth.uid(),
    updated_at = now();

  select coalesce(max(version_number), 0) + 1 into v_version
  from public.subject_versions where subject_id = v_id;
  insert into public.subject_versions(subject_id, version_number, snapshot, created_by)
  values (v_id, v_version, private.stage13_4_subject_json(v_id), auth.uid());

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      v_action, 'subject', v_id::text,
      jsonb_build_object('status', p_status, 'prev_status', v_prev, 'version_number', v_version)
    );
  end if;
  return v_id;
end $$;

create or replace function public.admin_set_subject_status(p_id uuid, p_status text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r public.subject_catalog%rowtype;
  p public.subject_student_profiles%rowtype;
begin
  select * into r from public.subject_catalog where id = p_id for update;
  if not found then raise exception 'subject_not_found' using errcode = 'P0002'; end if;
  select * into p from public.subject_student_profiles where subject_id = p_id;
  return public.admin_upsert_subject(
    r.id, r.canonical_name, r.description, r.department, r.control_form, r.difficulty_label,
    r.requirements, r.learning_outcomes, r.useful_links, p_status,
    p.short_description, p.what_to_expect, p.how_to_pass, p.useful_materials_note, p.common_pitfalls
  );
end $$;

create or replace function public.admin_list_subject_versions(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_4_can_write_subjects() then '[]'::jsonb
    else coalesce(
      (select jsonb_agg(to_jsonb(v) order by v.version_number desc)
       from public.subject_versions v where v.subject_id = p_id),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_restore_subject_version(p_id uuid, p_version_number integer)
returns uuid language plpgsql security definer set search_path = '' as $$
declare s jsonb; restored uuid;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select snapshot into s from public.subject_versions
  where subject_id = p_id and version_number = p_version_number;
  if s is null then raise exception 'version_not_found' using errcode = 'P0002'; end if;
  restored := public.admin_upsert_subject(
    p_id, s->>'canonical_name', s->>'description', s->>'department', s->>'control_form',
    s->>'difficulty_label', s->>'requirements', s->>'learning_outcomes',
    coalesce(s->'useful_links', '[]'::jsonb), coalesce(s->>'status', 'draft'),
    s->>'short_description', s->>'what_to_expect', s->>'how_to_pass',
    s->>'useful_materials_note', s->>'common_pitfalls'
  );
  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'subject.version_restore', 'subject', restored::text,
      jsonb_build_object('subject_id', p_id, 'version_number', p_version_number)
    );
  end if;
  return restored;
end $$;

create or replace function public.get_published_subject(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when exists (select 1 from public.subject_catalog sc where sc.id = p_id and sc.status = 'published')
      then private.stage13_4_subject_json(p_id)
    else 'null'::jsonb
  end;
$$;

create or replace function public.admin_list_subject_import_batches(p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_4_can_write_subjects() then '[]'::jsonb
    else coalesce(
      (select jsonb_agg(to_jsonb(b) order by b.created_at desc)
       from (
         select * from public.subject_import_batches
         order by created_at desc
         limit greatest(1, least(coalesce(p_limit, 20), 100))
       ) b),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_list_subject_import_rows(p_batch_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when not private.stage13_4_can_write_subjects() then '[]'::jsonb
    else coalesce(
      (select jsonb_agg(to_jsonb(r) order by r.row_number)
       from public.subject_import_rows r where r.batch_id = p_batch_id),
      '[]'::jsonb
    )
  end;
$$;

create or replace function public.admin_subject_import_dry_run(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r jsonb; n integer := 0; c text; err text; normalized text;
  match_id uuid; match_count integer; seen text[] := '{}'; out_rows jsonb := '[]'::jsonb;
  sid text;
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    n := n + 1; normalized := private.normalize_person_name(r->>'canonical_name');
    match_id := null; match_count := 0; c := null; err := null;
    sid := nullif(btrim(r->>'subject_id'), '');
    if sid is not null then
      begin
        select sc.id into match_id from public.subject_catalog sc where sc.id = sid::uuid;
        if match_id is null then c := 'error'; err := 'subject_id_not_found';
        else c := 'update'; end if;
      exception when invalid_text_representation then
        c := 'error'; err := 'invalid_subject_id';
      end;
    end if;
    if c is null then
      select count(*) into match_count from public.subject_catalog sc
      where sc.normalized_name = normalized;
      if match_count = 1 then
        select sc.id into match_id from public.subject_catalog sc
        where sc.normalized_name = normalized limit 1;
      end if;
      c := case
        when normalized = '' then 'error'
        when normalized = any(seen) then 'duplicate'
        when match_count > 1 then 'duplicate'
        when match_id is null then 'new'
        else 'update'
      end;
      err := case
        when c = 'error' then 'canonical_name_required'
        when c = 'duplicate' and match_count > 1 then 'ambiguous_name'
        when c = 'duplicate' then 'duplicate_in_file'
        else null
      end;
    end if;
    out_rows := out_rows || jsonb_build_array(jsonb_build_object(
      'row_number', n, 'classification', c, 'matched_subject_id', match_id,
      'error_text', err, 'payload', r
    ));
    if normalized <> '' then seen := array_append(seen, normalized); end if;
  end loop;
  return jsonb_build_object('rows', n, 'items', out_rows);
end $$;

create or replace function public.admin_subject_import_apply(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b uuid; item jsonb; created integer := 0; updated integer := 0;
  skipped integer := 0; conflicts integer := 0; errors integer := 0;
  dry jsonb; classification text; matched uuid;
  v_payload_hash text := md5(coalesce(p_rows, '[]'::jsonb)::text);
begin
  if not private.stage13_4_can_write_subjects() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select tb.id into b from public.subject_import_batches tb
  where tb.created_by = auth.uid() and tb.status = 'applied'
    and tb.payload_hash = v_payload_hash
  order by tb.created_at desc limit 1;
  if b is not null then
    return jsonb_build_object('batch_id', b, 'idempotent_replay', true,
      'summary', (select summary from public.subject_import_batches where id = b));
  end if;
  dry := public.admin_subject_import_dry_run(p_rows);
  begin
    insert into public.subject_import_batches(created_by, status, payload_hash, summary)
    values (auth.uid(), 'applied', v_payload_hash, dry || jsonb_build_object('payload_hash', v_payload_hash))
    returning id into b;
  exception when unique_violation then
    select tb.id into b from public.subject_import_batches tb
    where tb.created_by = auth.uid() and tb.status = 'applied'
      and tb.payload_hash = v_payload_hash
    order by tb.created_at desc limit 1;
    return jsonb_build_object('batch_id', b, 'idempotent_replay', true,
      'summary', (select summary from public.subject_import_batches where id = b));
  end;

  for item in select value from jsonb_array_elements(coalesce(dry->'items', '[]'::jsonb)) loop
    classification := item->>'classification';
    matched := nullif(item->>'matched_subject_id', '')::uuid;
    insert into public.subject_import_rows(batch_id, row_number, classification, payload, error_text, matched_subject_id)
    values (b, (item->>'row_number')::integer, classification, coalesce(item->'payload', '{}'::jsonb),
            item->>'error_text', matched);
    if classification = 'new' then
      perform public.admin_upsert_subject(
        null, item->'payload'->>'canonical_name', item->'payload'->>'description',
        item->'payload'->>'department', item->'payload'->>'control_form',
        item->'payload'->>'difficulty_label', item->'payload'->>'requirements',
        item->'payload'->>'learning_outcomes',
        case when jsonb_typeof(item->'payload'->'useful_links') = 'array'
          then item->'payload'->'useful_links' else '[]'::jsonb end,
        'draft',
        item->'payload'->>'short_description', item->'payload'->>'what_to_expect',
        item->'payload'->>'how_to_pass', item->'payload'->>'useful_materials_note',
        item->'payload'->>'common_pitfalls'
      );
      created := created + 1;
    elsif classification = 'update' and matched is not null then
      perform public.admin_upsert_subject(
        matched, item->'payload'->>'canonical_name', item->'payload'->>'description',
        item->'payload'->>'department', item->'payload'->>'control_form',
        item->'payload'->>'difficulty_label', item->'payload'->>'requirements',
        item->'payload'->>'learning_outcomes',
        case when jsonb_typeof(item->'payload'->'useful_links') = 'array'
          then item->'payload'->'useful_links'
          else coalesce((select useful_links from public.subject_catalog where id = matched), '[]'::jsonb)
        end,
        (select status from public.subject_catalog where id = matched),
        item->'payload'->>'short_description', item->'payload'->>'what_to_expect',
        item->'payload'->>'how_to_pass', item->'payload'->>'useful_materials_note',
        item->'payload'->>'common_pitfalls'
      );
      updated := updated + 1;
    elsif classification = 'duplicate' then conflicts := conflicts + 1;
    elsif classification = 'error' then errors := errors + 1;
    else skipped := skipped + 1;
    end if;
  end loop;

  update public.subject_import_batches
  set summary = dry || jsonb_build_object(
    'payload_hash', v_payload_hash, 'created', created, 'updated', updated,
    'skipped', skipped, 'conflict', conflicts, 'error', errors
  ) where id = b;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'subject.import_apply', 'subject_import_batch', b::text,
      jsonb_build_object('created', created, 'updated', updated, 'conflict', conflicts,
                         'error', errors, 'payload_hash', v_payload_hash)
    );
  end if;
  return jsonb_build_object(
    'batch_id', b, 'idempotent_replay', false, 'payload_hash', v_payload_hash,
    'created', created, 'updated', updated, 'skipped', skipped,
    'conflict', conflicts, 'error', errors
  );
end $$;

revoke all on function
  public.admin_list_subjects(text,text,text),
  public.admin_upsert_subject(uuid,text,text,text,text,text,text,text,jsonb,text,text,text,text,text,text),
  public.admin_set_subject_status(uuid,text),
  public.admin_list_subject_versions(uuid),
  public.admin_restore_subject_version(uuid,integer),
  public.get_published_subject(uuid),
  public.admin_list_subject_import_batches(integer),
  public.admin_list_subject_import_rows(uuid),
  public.admin_subject_import_dry_run(jsonb),
  public.admin_subject_import_apply(jsonb)
from public, anon;
grant execute on function
  public.admin_list_subjects(text,text,text),
  public.admin_upsert_subject(uuid,text,text,text,text,text,text,text,jsonb,text,text,text,text,text,text),
  public.admin_set_subject_status(uuid,text),
  public.admin_list_subject_versions(uuid),
  public.admin_restore_subject_version(uuid,integer),
  public.get_published_subject(uuid),
  public.admin_list_subject_import_batches(integer),
  public.admin_list_subject_import_rows(uuid),
  public.admin_subject_import_dry_run(jsonb),
  public.admin_subject_import_apply(jsonb)
to authenticated, service_role;

commit;
