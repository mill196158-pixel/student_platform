-- Stage 19 Import Studio — completion (Codex APPROVE gate).
--
-- Additive only. Does NOT rewrite 20260729153000 / 20260729153050 in place;
-- every function below is CREATE OR REPLACE of an existing definition, which
-- is the same technique 20260729153050 used on top of 20260729153000.
--
-- Promotes groups / terms / curriculum / offerings / teacher_links /
-- enrollments from validate_only / not_implemented to apply, with:
--   * Stage-19-owned apply helpers (private.import_studio_apply_*) for the
--     six domains that have no Stage 13 apply RPC to delegate to;
--   * upsert-by-id-first matching (an explicit *_id column always wins over
--     name/natural-key matching, never silently duplicated);
--   * real, dependency-checked rollback for the domains where undoing a
--     CREATE cannot destroy unrelated data (terms, curriculum, offerings,
--     teacher_links) — see private.import_studio_rollback_* below;
--   * fail-closed apply via the same nested-subtransaction pattern as
--     20260729153050, extended to cover every domain uniformly.
--
-- Domain matrix after this migration:
--   apply           teachers, subjects, students (unchanged)
--                    groups, terms, curriculum, offerings, teacher_links,
--                    enrollments (NEW)
--   validate_only    (none)
--   not_implemented  (none)
--
-- rollback_safe (set at apply time, per batch):
--   true   terms, curriculum, offerings, teacher_links
--   false  teachers, subjects, students, groups, enrollments
--          (groups also provisions group_space teams/chats; enrollments can
--          change team membership; teachers/subjects/students may have been
--          hand-edited after apply; students provisions auth users)
--
-- rollback_safe = true is a necessary, not sufficient, condition: rollback
-- of a rollback_safe batch is still refused wholesale (error_code
-- rollback_refused_has_updates) if ANY row in it matched/updated a
-- pre-existing record instead of being freshly created by that apply call.
-- Per-row apply_created (set atomically at apply time, never derived from
-- the dry-run classification) is what rollback actually deletes by.
--
-- Local only. Not applied to remote in this session.

begin;

-- ---------------------------------------------------------------------------
-- 0) New typed match columns for the six new domains. matched_group_id,
--    matched_teacher_id, matched_subject_id, matched_user_id already exist
--    and are reused (extended to more domains below).
-- ---------------------------------------------------------------------------
alter table public.import_studio_rows
  add column if not exists matched_curriculum_subject_id uuid null
    references public.curriculum_subjects (id) on delete set null,
  add column if not exists matched_term_id uuid null
    references public.academic_terms (id) on delete set null,
  add column if not exists matched_offering_id uuid null
    references public.subject_offerings (id) on delete set null,
  add column if not exists matched_teacher_link_id uuid null
    references public.offering_teachers (id) on delete set null,
  add column if not exists matched_enrollment_id uuid null
    references public.student_enrollments (id) on delete set null,
  add column if not exists apply_created boolean null,
  add column if not exists apply_row_fingerprint text null;

comment on column public.import_studio_rows.matched_curriculum_subject_id is
  'curriculum_subjects.id created/updated by this row (curriculum domain apply).';
comment on column public.import_studio_rows.matched_term_id is
  'academic_terms.id created/updated by this row (terms domain), or resolved term for offerings/teacher_links.';
comment on column public.import_studio_rows.matched_offering_id is
  'subject_offerings.id created/updated by this row (offerings domain), or resolved offering for teacher_links.';
comment on column public.import_studio_rows.matched_teacher_link_id is
  'offering_teachers.id created by this row (teacher_links domain).';
comment on column public.import_studio_rows.matched_enrollment_id is
  'student_enrollments.id created/matched by this row (enrollments domain).';
comment on column public.import_studio_rows.apply_created is
  'Set at apply time (not dry-run time): true only if this row''s target row was actually INSERTed by THIS apply call; false if it matched/updated a pre-existing row; null if never applied. Rollback deletes only apply_created = true rows, never a pre-existing row that merely got updated — the apply-time outcome is authoritative, not the dry-run classification, so a race between dry-run and apply can never cause rollback to destroy data it did not create.';
comment on column public.import_studio_rows.apply_row_fingerprint is
  'md5 fingerprint of the target row''s content, captured at the instant apply_created was set to true (terms/curriculum/offerings/teacher_links only). Rollback recomputes the live fingerprint just before deleting and refuses with rollback_refused_row_drift if it no longer matches, so a row hand-edited (or further changed by other admin actions) after apply is never silently destroyed by an undo that assumes it is still exactly what apply created.';

-- Batches now also carry a structured rollback plan so
-- admin_import_studio_rollback_batch never has to re-derive "what did apply
-- create" from scratch; it just re-reads the rows.
alter table public.import_studio_batches
  drop constraint if exists import_studio_batches_status_check;
alter table public.import_studio_batches
  add constraint import_studio_batches_status_check
  check (status in ('dry_run', 'applied', 'cancelled', 'failed', 'rolled_back'));

comment on column public.import_studio_batches.rollback_safe is
  'True only for batches whose domain has a reviewed, reversible undo: terms, curriculum, offerings, teacher_links. Set at successful apply time; never true for teachers, subjects, students, groups, enrollments.';

-- ---------------------------------------------------------------------------
-- 1) Domain-column allow list. Extended for the new domains:
--      matched_teacher_id     teachers, teacher_links
--      matched_subject_id     subjects, curriculum, offerings, teacher_links
--      matched_user_id        students, enrollments
--      matched_group_id       groups, students, curriculum, offerings,
--                              teacher_links, enrollments
--      matched_curriculum_subject_id  curriculum
--      matched_term_id         terms, offerings, teacher_links
--      matched_offering_id     offerings, teacher_links
--      matched_teacher_link_id teacher_links
--      matched_enrollment_id   enrollments
--    The XOR "single primary match" check (import_studio_rows_single_match)
--    only ever counted {teacher, subject, user}; none of the new domains put
--    more than one of those three on the same row, so it is untouched.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_rows_assert_domain()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_domain text;
begin
  select b.domain into v_domain
  from public.import_studio_batches b
  where b.id = new.batch_id;
  if not found then
    raise exception 'batch_not_found' using errcode = 'P0002';
  end if;

  if new.matched_teacher_id is not null
     and v_domain not in ('teachers', 'teacher_links') then
    raise exception 'match_domain_mismatch_teacher' using errcode = '22023';
  end if;
  if new.matched_subject_id is not null
     and v_domain not in ('subjects', 'curriculum', 'offerings', 'teacher_links') then
    raise exception 'match_domain_mismatch_subject' using errcode = '22023';
  end if;
  if new.matched_user_id is not null
     and v_domain not in ('students', 'enrollments') then
    raise exception 'match_domain_mismatch_user' using errcode = '22023';
  end if;
  if new.matched_group_id is not null
     and v_domain not in (
       'groups', 'students', 'curriculum', 'offerings', 'teacher_links', 'enrollments'
     ) then
    raise exception 'match_domain_mismatch_group' using errcode = '22023';
  end if;
  if new.matched_curriculum_subject_id is not null and v_domain <> 'curriculum' then
    raise exception 'match_domain_mismatch_curriculum_subject' using errcode = '22023';
  end if;
  if new.matched_term_id is not null
     and v_domain not in ('terms', 'offerings', 'teacher_links') then
    raise exception 'match_domain_mismatch_term' using errcode = '22023';
  end if;
  if new.matched_offering_id is not null
     and v_domain not in ('offerings', 'teacher_links') then
    raise exception 'match_domain_mismatch_offering' using errcode = '22023';
  end if;
  if new.matched_teacher_link_id is not null and v_domain <> 'teacher_links' then
    raise exception 'match_domain_mismatch_teacher_link' using errcode = '22023';
  end if;
  if new.matched_enrollment_id is not null and v_domain <> 'enrollments' then
    raise exception 'match_domain_mismatch_enrollment' using errcode = '22023';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) Honest domain matrix — every domain now supports apply.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_domain_state(p_domain text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_domain
    when 'teachers' then 'apply'
    when 'subjects' then 'apply'
    when 'students' then 'apply'
    when 'groups' then 'apply'
    when 'curriculum' then 'apply'
    when 'terms' then 'apply'
    when 'offerings' then 'apply'
    when 'teacher_links' then 'apply'
    when 'enrollments' then 'apply'
    else null
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2b) Hub notes + catalogue: every domain is now `apply`, so the foundation's
--     per-domain "validate-only" / "not implemented" messaging (keyed off
--     d.domain rather than domain_state) would otherwise go stale and lie
--     about groups/curriculum/terms specifically. Re-derive it from
--     domain_state so it can never disagree with reality again.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_domain_notes(p_domain text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when private.import_studio_domain_state(p_domain) = 'not_implemented' then
      'NOT IMPLEMENTED. Declared for a stable vocabulary only; every call raises not_implemented_domain_*.'
    when private.import_studio_domain_state(p_domain) = 'validate_only' then
      'Validate-only: dry run + diff only, apply is refused.'
    when p_domain = 'terms' then
      'Apply включён. Текущий семестр не переключается и не создаётся Осень 2026. Откат безопасен только если batch целиком состоит из новых, ещё не используемых семестров — при наличии хотя бы одного обновления откат отклоняется целиком (rollback_refused_has_updates).'
    when p_domain = 'groups' then
      'Apply включён. Для каждой новой группы автоматически создаётся group_space team + chat — откат недоступен (см. предупреждение перед apply).'
    when p_domain = 'curriculum' then
      'Apply включён. group_name используется только для проверки; запись идёт в curriculum_subjects по (предмет, семестр). Откат безопасен только если batch целиком состоит из новых записей — при наличии хотя бы одного обновления откат отклоняется целиком (rollback_refused_has_updates).'
    when p_domain = 'offerings' then
      'Apply включён. Дедупликация по (группа, предмет, семестр). Откат безопасен только для batch без обновлений и без связанных команд/чатов/оценок — при наличии обновлений откат отклоняется целиком (rollback_refused_has_updates).'
    when p_domain = 'teacher_links' then
      'Apply включён. offering_teachers — чистая связь без зависимостей, но откат безопасен только если batch целиком состоит из новых связей — при наличии хотя бы одного обновления откат отклоняется целиком (rollback_refused_has_updates).'
    when p_domain = 'enrollments' then
      'Apply включён, но только для новых зачислений или точного повтора существующего — переводы между группами не поддерживаются. Откат недоступен (может затронуть состав team).'
    else
      'Apply делегируется существующему domain import RPC (teachers/subjects/students).'
  end;
$$;

revoke all on function private.import_studio_domain_notes(text)
  from public, anon, authenticated;
grant execute on function private.import_studio_domain_notes(text) to service_role;

create or replace function public.admin_import_studio_list_domains()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  v_uid := private.require_any_admin_permission(array[
    'academic.read', 'teachers.write', 'subjects.write', 'students.write',
    'groups.write', 'terms.manage'
  ]);

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'domain', d.domain,
          'domain_state', private.import_studio_domain_state(d.domain),
          'apply_permission', private.import_studio_domain_permission(d.domain),
          'supports_apply', private.import_studio_supports_apply(d.domain),
          'template_columns', to_jsonb(private.import_studio_template(d.domain)),
          'can_dry_run',
            private.import_studio_domain_state(d.domain) <> 'not_implemented'
            and private.has_admin_permission(
              v_uid, private.import_studio_domain_permission(d.domain), 'global', null
            ),
          'can_apply', private.import_studio_supports_apply(d.domain)
            and private.has_admin_permission(
              v_uid, private.import_studio_domain_permission(d.domain), 'global', null
            ),
          'notes', private.import_studio_domain_notes(d.domain)
        )
        order by d.domain
      )
      from (
        values ('teachers'), ('subjects'), ('students'),
               ('groups'), ('curriculum'), ('terms'),
               ('offerings'), ('teacher_links'), ('enrollments')
      ) as d(domain)
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) Templates for the six newly-enabled domains. *_id columns always win
--    over natural-key matching in the validator below (never a silent
--    duplicate when the caller already knows the row's id).
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_template(p_domain text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_domain
    when 'teachers' then array[
      'teacher_id', 'full_name', 'email', 'public_email', 'department',
      'position', 'academic_degree', 'about_text', 'website', 'office',
      'telegram'
    ]
    when 'subjects' then array[
      'subject_id', 'canonical_name', 'description', 'department', 'control_form',
      'difficulty_label', 'requirements', 'learning_outcomes', 'short_description',
      'what_to_expect', 'how_to_pass', 'useful_materials_note', 'useful_links',
      'common_pitfalls'
    ]
    when 'students' then array['login', 'name', 'surname', 'group_name']
    when 'groups' then array['group_id', 'name']
    when 'curriculum' then array[
      'curriculum_subject_id', 'group_name', 'subject_name', 'semester_number',
      'credits', 'hours_total', 'control_form', 'block_name', 'subject_index'
    ]
    when 'terms' then array[
      'term_id', 'academic_year_name', 'name', 'term_in_year', 'starts_on', 'ends_on'
    ]
    when 'offerings' then array[
      'offering_id', 'group_name', 'subject_name', 'academic_year_name',
      'term_name', 'semester_number', 'display_name', 'status'
    ]
    when 'teacher_links' then array[
      'teacher_link_id', 'offering_id', 'group_name', 'subject_name',
      'academic_year_name', 'term_name', 'teacher_id', 'teacher_full_name', 'role'
    ]
    when 'enrollments' then array[
      'enrollment_id', 'login', 'group_name', 'started_at'
    ]
    else array[]::text[]
  end;
$$;

-- ---------------------------------------------------------------------------
-- 4) Row validator — extended with the six new domains. teachers / subjects /
--    students / groups / curriculum / terms keep their existing shape;
--    groups / curriculum / terms gain optional id-based matching.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_validate_row(
  p_domain text,
  p_row jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row jsonb := coalesce(p_row, '{}'::jsonb);
  v_allowed text[] := private.import_studio_template(p_domain);
  v_errors text[] := '{}'::text[];
  v_mapped jsonb := '{}'::jsonb;
  v_key text;
  v_bad text;
  v_class text := 'new';
  v_teacher uuid;
  v_subject uuid;
  v_user uuid;
  v_group uuid;
  v_num numeric;
  v_start date;
  v_end date;
  v_term integer;
  v_email text;
  v_contacts jsonb := '{}'::jsonb;
  v_links jsonb;
  -- New-domain locals.
  v_curriculum_subject uuid;
  v_term_row uuid;
  v_offering uuid;
  v_teacher_link uuid;
  v_enrollment uuid;
  v_year_id uuid;
  v_semester numeric;
  v_display text;
  v_status text;
  v_role text;
  v_login text;
  v_started date;
begin
  perform private.import_studio_assert_implemented(p_domain);

  if jsonb_typeof(v_row) <> 'object' then
    return jsonb_build_object(
      'classification', 'error',
      'mapped', '{}'::jsonb,
      'errors', to_jsonb(array['row_not_object']),
      'dedupe_key', null
    );
  end if;

  select string_agg(t.key, ',' order by t.key)
  into v_bad
  from jsonb_object_keys(v_row) as t(key)
  where not (t.key = any (v_allowed))
    and t.key <> 'contacts_public';
  if v_bad is not null then
    v_errors := array_append(v_errors, 'unknown_columns:' || v_bad);
  end if;

  if p_domain = 'teachers' then
    if nullif(btrim(coalesce(v_row ->> 'teacher_id', '')), '') is not null then
      begin
        select t.id into v_teacher
        from public.teachers t
        where t.id = (btrim(v_row ->> 'teacher_id'))::uuid;
        if v_teacher is null then
          v_errors := array_append(v_errors, 'teacher_id_not_found');
        else
          v_class := 'update';
          v_key := v_teacher::text;
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_teacher_id');
      end;
    else
      v_key := private.import_studio_norm(v_row ->> 'full_name');
      if v_key is null then
        v_errors := array_append(v_errors, 'full_name_required');
      else
        v_key := private.normalize_person_name(v_row ->> 'full_name');
        select t.id into v_teacher
        from public.teachers t
        where t.normalized_name = v_key
        limit 1;
        if v_teacher is not null then
          v_class := 'update';
        end if;
      end if;
    end if;

    if jsonb_typeof(v_row -> 'contacts_public') = 'object' then
      v_contacts := v_row -> 'contacts_public';
    else
      v_contacts := jsonb_strip_nulls(jsonb_build_object(
        'public_email', coalesce(
          nullif(btrim(v_row ->> 'public_email'), ''),
          nullif(btrim(v_row ->> 'email'), '')
        ),
        'website', nullif(btrim(v_row ->> 'website'), ''),
        'office', nullif(btrim(v_row ->> 'office'), ''),
        'telegram', nullif(btrim(v_row ->> 'telegram'), '')
      ));
    end if;

    v_email := nullif(btrim(v_contacts ->> 'public_email'), '');
    if v_email is not null
       and v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' then
      v_errors := array_append(v_errors, 'invalid_public_email');
    end if;

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'teacher_id', nullif(btrim(coalesce(v_row ->> 'teacher_id', '')), ''),
      'full_name', nullif(btrim(coalesce(v_row ->> 'full_name', '')), ''),
      'department', nullif(btrim(coalesce(v_row ->> 'department', '')), ''),
      'position', nullif(btrim(coalesce(v_row ->> 'position', '')), ''),
      'academic_degree', nullif(btrim(coalesce(v_row ->> 'academic_degree', '')), ''),
      'about_text', nullif(btrim(coalesce(v_row ->> 'about_text', '')), ''),
      'public_email', v_email,
      'contacts_public', case
        when v_contacts = '{}'::jsonb then null
        else v_contacts
      end
    ));

  elsif p_domain = 'subjects' then
    v_key := private.import_studio_norm(v_row ->> 'canonical_name');
    if v_key is null then
      v_errors := array_append(v_errors, 'canonical_name_required');
    else
      select sc.id into v_subject
      from public.subject_catalog sc
      where private.import_studio_norm(sc.normalized_name) = v_key
         or private.import_studio_norm(sc.canonical_name) = v_key
      limit 1;
      if v_subject is not null then
        v_class := 'update';
      end if;
    end if;

    v_links := case
      when jsonb_typeof(v_row -> 'useful_links') = 'array' then v_row -> 'useful_links'
      else '[]'::jsonb
    end;

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'subject_id', nullif(btrim(coalesce(v_row ->> 'subject_id', '')), ''),
      'canonical_name', nullif(btrim(coalesce(v_row ->> 'canonical_name', '')), ''),
      'description', nullif(btrim(coalesce(v_row ->> 'description', '')), ''),
      'department', nullif(btrim(coalesce(v_row ->> 'department', '')), ''),
      'control_form', nullif(btrim(coalesce(v_row ->> 'control_form', '')), ''),
      'difficulty_label', nullif(btrim(coalesce(v_row ->> 'difficulty_label', '')), ''),
      'requirements', nullif(btrim(coalesce(v_row ->> 'requirements', '')), ''),
      'learning_outcomes', nullif(btrim(coalesce(v_row ->> 'learning_outcomes', '')), ''),
      'short_description', nullif(btrim(coalesce(v_row ->> 'short_description', '')), ''),
      'what_to_expect', nullif(btrim(coalesce(v_row ->> 'what_to_expect', '')), ''),
      'how_to_pass', nullif(btrim(coalesce(v_row ->> 'how_to_pass', '')), ''),
      'useful_materials_note', nullif(btrim(coalesce(v_row ->> 'useful_materials_note', '')), ''),
      'common_pitfalls', nullif(btrim(coalesce(v_row ->> 'common_pitfalls', '')), ''),
      'useful_links', v_links
    ));

  elsif p_domain = 'students' then
    v_key := lower(btrim(coalesce(v_row ->> 'login', '')));
    if v_key = '' then
      v_key := null;
      v_errors := array_append(v_errors, 'login_required');
    else
      select u.id into v_user
      from public.users u
      where lower(u.login) = v_key
      limit 1;
      if v_user is null then
        v_errors := array_append(v_errors, 'user_not_found');
      else
        v_class := 'update';
      end if;
    end if;
    if nullif(btrim(coalesce(v_row ->> 'group_name', '')), '') is not null then
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
      limit 1;
      if v_group is null then
        v_errors := array_append(v_errors, 'group_not_found');
      end if;
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'login', v_key,
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), ''),
      'surname', nullif(btrim(coalesce(v_row ->> 'surname', '')), ''),
      'group_name', nullif(btrim(coalesce(v_row ->> 'group_name', '')), '')
    ));

  elsif p_domain = 'groups' then
    if nullif(btrim(coalesce(v_row ->> 'group_id', '')), '') is not null then
      begin
        select g.id into v_group
        from public.groups g
        where g.id = (btrim(v_row ->> 'group_id'))::uuid;
        if v_group is null then
          v_errors := array_append(v_errors, 'group_id_not_found');
        else
          v_class := 'update';
          v_key := v_group::text;
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_group_id');
      end;
    else
      v_key := private.import_studio_norm(v_row ->> 'name');
      if v_key is null then
        v_errors := array_append(v_errors, 'name_required');
      else
        select g.id into v_group
        from public.groups g
        where private.import_studio_norm(g.name) = v_key
        limit 1;
        if v_group is not null then
          v_class := 'update';
        end if;
      end if;
    end if;
    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'group_id', nullif(btrim(coalesce(v_row ->> 'group_id', '')), ''),
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), '')
    ));

  elsif p_domain = 'curriculum' then
    if nullif(btrim(coalesce(v_row ->> 'curriculum_subject_id', '')), '') is not null then
      begin
        select cs.id, cs.subject_id into v_curriculum_subject, v_subject
        from public.curriculum_subjects cs
        where cs.id = (btrim(v_row ->> 'curriculum_subject_id'))::uuid;
        if v_curriculum_subject is null then
          v_errors := array_append(v_errors, 'curriculum_subject_id_not_found');
        else
          v_class := 'update';
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_curriculum_subject_id');
      end;
    end if;

    -- group_name is context/validation only: curriculum_subjects has no
    -- group_id column (it is shared across every group on that semester),
    -- so it never becomes a write target, only a sanity check + warning.
    if private.import_studio_norm(v_row ->> 'group_name') is null then
      v_errors := array_append(v_errors, 'group_name_required');
    else
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
      limit 1;
      if v_group is null then
        v_errors := array_append(v_errors, 'group_not_found');
      end if;
    end if;

    if v_subject is null then
      if private.import_studio_norm(v_row ->> 'subject_name') is null then
        v_errors := array_append(v_errors, 'subject_name_required');
      else
        select sc.id into v_subject
        from public.subject_catalog sc
        where private.import_studio_norm(sc.normalized_name)
                = private.import_studio_norm(v_row ->> 'subject_name')
           or private.import_studio_norm(sc.canonical_name)
                = private.import_studio_norm(v_row ->> 'subject_name')
        limit 1;
        if v_subject is null then
          v_errors := array_append(v_errors, 'subject_not_found');
        end if;
      end if;
    end if;

    begin
      v_num := nullif(btrim(coalesce(v_row ->> 'semester_number', '')), '')::numeric;
    exception when others then
      v_num := null;
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end;
    if v_num is null then
      v_errors := array_append(v_errors, 'semester_number_required');
    elsif v_num <> trunc(v_num) or v_num < 1 or v_num > 12 then
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end if;

    -- Natural-key match (subject_id, semester_number) when no explicit id
    -- was given: this MUST classify as 'update' whenever an existing
    -- curriculum_subjects row already matches, exactly like
    -- private.import_studio_apply_curriculum's own dedupe lookup below —
    -- otherwise dry-run always says 'new' while apply silently updates the
    -- pre-existing row, and rollback would then delete that pre-existing
    -- row (P0: rollback deletes pre-existing rows).
    if v_curriculum_subject is null
       and v_subject is not null
       and v_num is not null
       and v_num = trunc(v_num) then
      select cs.id into v_curriculum_subject
      from public.curriculum_subjects cs
      where cs.subject_id = v_subject
        and cs.semester_number = v_num::integer
      limit 1;
      if v_curriculum_subject is not null then
        v_class := 'update';
      end if;
    end if;

    if v_curriculum_subject is null then
      v_key := private.import_studio_norm(
        coalesce(v_row ->> 'subject_name', '') || '|' ||
        coalesce(v_row ->> 'semester_number', '')
      );
    else
      v_key := v_curriculum_subject::text;
    end if;

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'curriculum_subject_id', v_curriculum_subject,
      'group_id', v_group,
      'subject_id', v_subject,
      'semester_number', v_num,
      'credits', nullif(btrim(coalesce(v_row ->> 'credits', '')), ''),
      'hours_total', nullif(btrim(coalesce(v_row ->> 'hours_total', '')), ''),
      'control_form', nullif(btrim(coalesce(v_row ->> 'control_form', '')), ''),
      'block_name', nullif(btrim(coalesce(v_row ->> 'block_name', '')), ''),
      'subject_index', nullif(btrim(coalesce(v_row ->> 'subject_index', '')), '')
    ));

  elsif p_domain = 'terms' then
    if v_row ? 'is_current' then
      v_errors := array_append(v_errors, 'current_term_flip_forbidden');
    end if;

    if nullif(btrim(coalesce(v_row ->> 'term_id', '')), '') is not null then
      begin
        select t.id into v_term_row
        from public.academic_terms t
        where t.id = (btrim(v_row ->> 'term_id'))::uuid;
        if v_term_row is null then
          v_errors := array_append(v_errors, 'term_id_not_found');
        else
          v_class := 'update';
          v_key := v_term_row::text;
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_term_id');
      end;
    else
      v_key := private.import_studio_norm(
        coalesce(v_row ->> 'academic_year_name', '') || '|' || coalesce(v_row ->> 'name', '')
      );
      select t.id into v_term_row
      from public.academic_terms t
      join public.academic_years ay on ay.id = t.academic_year_id
      where private.import_studio_norm(ay.name) = private.import_studio_norm(v_row ->> 'academic_year_name')
        and private.import_studio_norm(t.name) = private.import_studio_norm(v_row ->> 'name')
      limit 1;
      if v_term_row is not null then
        v_class := 'update';
      end if;
    end if;

    if private.import_studio_norm(v_row ->> 'name') is null then
      v_errors := array_append(v_errors, 'name_required');
    end if;
    if private.import_studio_norm(v_row ->> 'academic_year_name') is null then
      v_errors := array_append(v_errors, 'academic_year_name_required');
    end if;

    begin
      v_term := nullif(btrim(coalesce(v_row ->> 'term_in_year', '')), '')::integer;
    exception when others then
      v_term := null;
    end;
    if v_term is null or v_term not in (1, 2) then
      v_errors := array_append(v_errors, 'invalid_term_in_year');
    end if;

    begin
      v_start := nullif(btrim(coalesce(v_row ->> 'starts_on', '')), '')::date;
      v_end := nullif(btrim(coalesce(v_row ->> 'ends_on', '')), '')::date;
    exception when others then
      v_start := null;
      v_end := null;
      v_errors := array_append(v_errors, 'invalid_dates');
    end;
    if v_start is null or v_end is null then
      v_errors := array_append(v_errors, 'dates_required');
    elsif v_end < v_start then
      v_errors := array_append(v_errors, 'ends_before_starts');
    end if;

    if (v_start is not null
        and v_start between date '2026-08-01' and date '2026-12-31')
       or (
         coalesce(v_row ->> 'name', '') ilike '%2026%'
         and (
           coalesce(v_row ->> 'name', '') ilike '%осен%'
           or coalesce(v_row ->> 'name', '') ilike '%autumn%'
           or coalesce(v_row ->> 'name', '') ilike '%fall%'
         )
       ) then
      v_errors := array_append(v_errors, 'autumn_2026_forbidden');
    end if;

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'term_id', v_term_row,
      'academic_year_name', nullif(btrim(coalesce(v_row ->> 'academic_year_name', '')), ''),
      'name', nullif(btrim(coalesce(v_row ->> 'name', '')), ''),
      'term_in_year', v_term,
      'starts_on', v_start,
      'ends_on', v_end
    ));

  elsif p_domain = 'offerings' then
    if nullif(btrim(coalesce(v_row ->> 'offering_id', '')), '') is not null then
      begin
        select so.id into v_offering
        from public.subject_offerings so
        where so.id = (btrim(v_row ->> 'offering_id'))::uuid;
        if v_offering is null then
          v_errors := array_append(v_errors, 'offering_id_not_found');
        else
          v_class := 'update';
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_offering_id');
      end;
    end if;

    if private.import_studio_norm(v_row ->> 'group_name') is null then
      v_errors := array_append(v_errors, 'group_name_required');
    else
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
      limit 1;
      if v_group is null then
        v_errors := array_append(v_errors, 'group_not_found');
      end if;
    end if;

    if private.import_studio_norm(v_row ->> 'subject_name') is null then
      v_errors := array_append(v_errors, 'subject_name_required');
    else
      select sc.id into v_subject
      from public.subject_catalog sc
      where private.import_studio_norm(sc.normalized_name)
              = private.import_studio_norm(v_row ->> 'subject_name')
         or private.import_studio_norm(sc.canonical_name)
              = private.import_studio_norm(v_row ->> 'subject_name')
      limit 1;
      if v_subject is null then
        v_errors := array_append(v_errors, 'subject_not_found');
      end if;
    end if;

    if private.import_studio_norm(v_row ->> 'academic_year_name') is null then
      v_errors := array_append(v_errors, 'academic_year_name_required');
    end if;
    if private.import_studio_norm(v_row ->> 'term_name') is null then
      v_errors := array_append(v_errors, 'term_name_required');
    end if;
    if private.import_studio_norm(v_row ->> 'academic_year_name') is not null
       and private.import_studio_norm(v_row ->> 'term_name') is not null then
      select t.id into v_term_row
      from public.academic_terms t
      join public.academic_years ay on ay.id = t.academic_year_id
      where private.import_studio_norm(ay.name) = private.import_studio_norm(v_row ->> 'academic_year_name')
        and private.import_studio_norm(t.name) = private.import_studio_norm(v_row ->> 'term_name')
      limit 1;
      if v_term_row is null then
        v_errors := array_append(v_errors, 'term_not_found');
      end if;
    end if;

    begin
      v_semester := nullif(btrim(coalesce(v_row ->> 'semester_number', '')), '')::numeric;
    exception when others then
      v_semester := null;
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end;
    if v_semester is null then
      v_errors := array_append(v_errors, 'semester_number_required');
    elsif v_semester <> trunc(v_semester) or v_semester < 1 then
      v_errors := array_append(v_errors, 'invalid_semester_number');
    end if;

    v_status := coalesce(nullif(btrim(v_row ->> 'status'), ''), 'active');
    if v_status not in ('active', 'archived', 'cancelled') then
      v_errors := array_append(v_errors, 'invalid_status');
    end if;

    v_display := nullif(btrim(coalesce(v_row ->> 'display_name', '')), '');

    -- Natural-key match (group_id, subject_id, academic_term_id) when no
    -- explicit id was given: MUST classify as 'update' whenever an existing
    -- subject_offerings row already matches, exactly like
    -- private.import_studio_apply_offerings's own dedupe lookup below —
    -- otherwise dry-run always says 'new' while apply silently updates the
    -- pre-existing row, and rollback would then delete that pre-existing
    -- row (P0: rollback deletes pre-existing rows).
    if v_offering is null
       and v_group is not null
       and v_subject is not null
       and v_term_row is not null then
      select so.id into v_offering
      from public.subject_offerings so
      where so.group_id = v_group
        and so.subject_id = v_subject
        and so.academic_term_id = v_term_row
      limit 1;
      if v_offering is not null then
        v_class := 'update';
      end if;
    end if;

    v_key := coalesce(
      v_offering::text,
      private.import_studio_norm(
        coalesce(v_row ->> 'group_name', '') || '|' ||
        coalesce(v_row ->> 'subject_name', '') || '|' ||
        coalesce(v_row ->> 'academic_year_name', '') || '|' ||
        coalesce(v_row ->> 'term_name', '')
      )
    );

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'offering_id', v_offering,
      'group_id', v_group,
      'subject_id', v_subject,
      'term_id', v_term_row,
      'semester_number', v_semester,
      'display_name', v_display,
      'status', v_status
    ));

  elsif p_domain = 'teacher_links' then
    if nullif(btrim(coalesce(v_row ->> 'teacher_link_id', '')), '') is not null then
      begin
        select ot.id into v_teacher_link
        from public.offering_teachers ot
        where ot.id = (btrim(v_row ->> 'teacher_link_id'))::uuid;
        if v_teacher_link is null then
          v_errors := array_append(v_errors, 'teacher_link_id_not_found');
        else
          v_class := 'update';
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_teacher_link_id');
      end;
    end if;

    if nullif(btrim(coalesce(v_row ->> 'offering_id', '')), '') is not null then
      begin
        select so.id into v_offering
        from public.subject_offerings so
        where so.id = (btrim(v_row ->> 'offering_id'))::uuid;
        if v_offering is null then
          v_errors := array_append(v_errors, 'offering_id_not_found');
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_offering_id');
      end;
    else
      if private.import_studio_norm(v_row ->> 'group_name') is null then
        v_errors := array_append(v_errors, 'group_name_required');
      else
        select g.id into v_group
        from public.groups g
        where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
        limit 1;
        if v_group is null then
          v_errors := array_append(v_errors, 'group_not_found');
        end if;
      end if;
      if private.import_studio_norm(v_row ->> 'subject_name') is null then
        v_errors := array_append(v_errors, 'subject_name_required');
      else
        select sc.id into v_subject
        from public.subject_catalog sc
        where private.import_studio_norm(sc.normalized_name)
                = private.import_studio_norm(v_row ->> 'subject_name')
           or private.import_studio_norm(sc.canonical_name)
                = private.import_studio_norm(v_row ->> 'subject_name')
        limit 1;
        if v_subject is null then
          v_errors := array_append(v_errors, 'subject_not_found');
        end if;
      end if;
      if private.import_studio_norm(v_row ->> 'academic_year_name') is null
         or private.import_studio_norm(v_row ->> 'term_name') is null then
        v_errors := array_append(v_errors, 'academic_year_name_and_term_name_required');
      else
        select t.id into v_term_row
        from public.academic_terms t
        join public.academic_years ay on ay.id = t.academic_year_id
        where private.import_studio_norm(ay.name) = private.import_studio_norm(v_row ->> 'academic_year_name')
          and private.import_studio_norm(t.name) = private.import_studio_norm(v_row ->> 'term_name')
        limit 1;
        if v_term_row is null then
          v_errors := array_append(v_errors, 'term_not_found');
        end if;
      end if;
      if v_group is not null and v_subject is not null and v_term_row is not null then
        select so.id into v_offering
        from public.subject_offerings so
        where so.group_id = v_group
          and so.subject_id = v_subject
          and so.academic_term_id = v_term_row
        limit 1;
        if v_offering is null then
          v_errors := array_append(v_errors, 'offering_not_found');
        end if;
      end if;
    end if;

    if nullif(btrim(coalesce(v_row ->> 'teacher_id', '')), '') is not null then
      begin
        select t.id into v_teacher
        from public.teachers t
        where t.id = (btrim(v_row ->> 'teacher_id'))::uuid;
        if v_teacher is null then
          v_errors := array_append(v_errors, 'teacher_id_not_found');
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_teacher_id');
      end;
    elsif private.import_studio_norm(v_row ->> 'teacher_full_name') is null then
      v_errors := array_append(v_errors, 'teacher_id_or_teacher_full_name_required');
    else
      select t.id into v_teacher
      from public.teachers t
      where t.normalized_name = private.normalize_person_name(v_row ->> 'teacher_full_name')
      limit 1;
      if v_teacher is null then
        v_errors := array_append(v_errors, 'teacher_not_found');
      end if;
    end if;

    v_role := coalesce(nullif(btrim(v_row ->> 'role'), ''), '');

    -- Natural-key match (subject_offering_id, teacher_id, role) when no
    -- explicit id was given: MUST classify as 'update' whenever an existing
    -- offering_teachers row already matches, exactly like
    -- private.import_studio_apply_teacher_links's own dedupe lookup below —
    -- otherwise dry-run always says 'new' while apply silently updates the
    -- pre-existing row, and rollback would then delete that pre-existing
    -- row (P0: rollback deletes pre-existing rows).
    if v_teacher_link is null and v_offering is not null and v_teacher is not null then
      select ot.id into v_teacher_link
      from public.offering_teachers ot
      where ot.subject_offering_id = v_offering
        and ot.teacher_id = v_teacher
        and coalesce(ot.role, '') = v_role
      limit 1;
      if v_teacher_link is not null then
        v_class := 'update';
      end if;
    end if;

    v_key := coalesce(
      v_teacher_link::text,
      case
        when v_offering is not null and v_teacher is not null then
          v_offering::text || '|' || v_teacher::text || '|' || v_role
        else null
      end
    );

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'teacher_link_id', v_teacher_link,
      'offering_id', v_offering,
      'teacher_id', v_teacher,
      'role', nullif(v_role, '')
    ));

  else
    -- enrollments
    if nullif(btrim(coalesce(v_row ->> 'enrollment_id', '')), '') is not null then
      begin
        select se.id into v_enrollment
        from public.student_enrollments se
        where se.id = (btrim(v_row ->> 'enrollment_id'))::uuid;
        if v_enrollment is null then
          v_errors := array_append(v_errors, 'enrollment_id_not_found');
        else
          v_class := 'update';
        end if;
      exception when invalid_text_representation then
        v_errors := array_append(v_errors, 'invalid_enrollment_id');
      end;
    end if;

    v_login := lower(btrim(coalesce(v_row ->> 'login', '')));
    if v_login = '' then
      v_login := null;
      v_errors := array_append(v_errors, 'login_required');
    else
      select u.id into v_user
      from public.users u
      where lower(u.login) = v_login
      limit 1;
      if v_user is null then
        v_errors := array_append(v_errors, 'user_not_found');
      end if;
    end if;

    if private.import_studio_norm(v_row ->> 'group_name') is null then
      v_errors := array_append(v_errors, 'group_name_required');
    else
      select g.id into v_group
      from public.groups g
      where private.import_studio_norm(g.name) = private.import_studio_norm(v_row ->> 'group_name')
      limit 1;
      if v_group is null then
        v_errors := array_append(v_errors, 'group_not_found');
      end if;
    end if;

    begin
      v_started := nullif(btrim(coalesce(v_row ->> 'started_at', '')), '')::date;
    exception when others then
      v_started := null;
      v_errors := array_append(v_errors, 'invalid_started_at');
    end;

    -- Conservative by design: an active enrollment for this user in a
    -- DIFFERENT group is a transfer, which Import Studio does not attempt
    -- (it would touch team membership). Only a brand new enrollment or an
    -- exact idempotent replay of an existing one is supported.
    if v_user is not null and v_group is not null then
      if exists (
        select 1
        from public.student_enrollments se
        where se.user_id = v_user
          and se.status = 'active'
          and se.ended_at is null
          and se.group_id is distinct from v_group
      ) then
        v_errors := array_append(v_errors, 'user_already_enrolled_in_other_group');
      end if;
    end if;

    v_key := coalesce(v_enrollment::text, v_login || '|' || coalesce(v_group::text, ''));

    v_mapped := jsonb_strip_nulls(jsonb_build_object(
      'enrollment_id', v_enrollment,
      'user_id', v_user,
      'group_id', v_group,
      'started_at', v_started
    ));
  end if;

  if coalesce(array_length(v_errors, 1), 0) > 0 then
    v_class := 'error';
  end if;

  return jsonb_build_object(
    'classification', v_class,
    'mapped', v_mapped,
    'errors', to_jsonb(v_errors),
    'dedupe_key', v_key,
    'matched_teacher_id', v_teacher,
    'matched_subject_id', v_subject,
    'matched_user_id', v_user,
    'matched_group_id', v_group,
    'matched_curriculum_subject_id', v_curriculum_subject,
    'matched_term_id', v_term_row,
    'matched_offering_id', v_offering,
    'matched_teacher_link_id', v_teacher_link,
    'matched_enrollment_id', v_enrollment
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) Dry run: persist the five new matched_* columns too.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_start_dry_run(
  p_domain text,
  p_rows jsonb,
  p_file_name text default '',
  p_batch_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_domain text := private.import_studio_assert_domain(
    nullif(btrim(coalesce(p_domain, '')), '')
  );
  v_rows jsonb := coalesce(p_rows, '[]'::jsonb);
  v_hash text;
  v_key text;
  v_batch public.import_studio_batches;
  v_row jsonb;
  v_result jsonb;
  v_n integer := 0;
  v_errors integer := 0;
  v_new integer := 0;
  v_update integer := 0;
  v_duplicate integer := 0;
  v_seen text[] := '{}'::text[];
  v_dedupe text;
  v_class text;
begin
  v_uid := private.import_studio_require_read(v_domain);

  if jsonb_typeof(v_rows) <> 'array' then
    raise exception 'invalid_rows' using errcode = '22023';
  end if;
  if jsonb_array_length(v_rows) = 0 then
    raise exception 'empty_rows' using errcode = '22023';
  end if;
  if jsonb_array_length(v_rows) > 5000 then
    raise exception 'too_many_rows' using errcode = '22023';
  end if;

  v_hash := md5(v_domain || ':' || v_rows::text);
  v_key := coalesce(nullif(btrim(coalesce(p_batch_key, '')), ''), v_hash);
  if char_length(v_key) > 120 then
    raise exception 'invalid_batch_key' using errcode = '22023';
  end if;

  select * into v_batch
  from public.import_studio_batches b
  where b.created_by = v_uid
    and b.domain = v_domain
    and b.batch_key = v_key
  for update;

  if found then
    if v_batch.status = 'applied' then
      if v_batch.payload_hash is distinct from v_hash then
        raise exception 'batch_key_payload_mismatch' using errcode = '22023';
      end if;
      return private.import_studio_batch_json(v_batch.id)
        || jsonb_build_object('already_applied', true);
    end if;
    delete from public.import_studio_rows where batch_id = v_batch.id;
    update public.import_studio_batches b set
      status = 'dry_run',
      file_name = left(coalesce(p_file_name, ''), 260),
      payload_hash = v_hash,
      created_by = v_uid,
      created_at = now(),
      applied_by = null,
      applied_at = null,
      delegated_result = '{}'::jsonb,
      rollback_safe = false
    where b.id = v_batch.id
    returning * into v_batch;
  else
    insert into public.import_studio_batches (
      domain, status, batch_key, file_name, payload_hash, created_by
    ) values (
      v_domain, 'dry_run', v_key, left(coalesce(p_file_name, ''), 260), v_hash, v_uid
    )
    returning * into v_batch;
  end if;

  for v_row in select value from jsonb_array_elements(v_rows) loop
    v_n := v_n + 1;
    v_result := private.import_studio_validate_row(v_domain, v_row);
    v_class := v_result ->> 'classification';
    v_dedupe := v_result ->> 'dedupe_key';

    if v_dedupe is not null and v_dedupe = any (v_seen) then
      v_class := 'duplicate';
    elsif v_dedupe is not null then
      v_seen := array_append(v_seen, v_dedupe);
    end if;

    insert into public.import_studio_rows (
      batch_id, row_number, classification, source_payload, mapped_payload,
      validation, error_text, dedupe_key, matched_teacher_id, matched_subject_id,
      matched_user_id, matched_group_id, matched_curriculum_subject_id,
      matched_term_id, matched_offering_id, matched_teacher_link_id,
      matched_enrollment_id
    ) values (
      v_batch.id,
      v_n,
      v_class,
      v_row,
      coalesce(v_result -> 'mapped', '{}'::jsonb),
      jsonb_build_object('errors', coalesce(v_result -> 'errors', '[]'::jsonb)),
      left(
        nullif(
          (
            select string_agg(e.value #>> '{}', ',')
            from jsonb_array_elements(coalesce(v_result -> 'errors', '[]'::jsonb)) as e(value)
          ),
          ''
        ),
        500
      ),
      v_dedupe,
      nullif(v_result ->> 'matched_teacher_id', '')::uuid,
      nullif(v_result ->> 'matched_subject_id', '')::uuid,
      nullif(v_result ->> 'matched_user_id', '')::uuid,
      nullif(v_result ->> 'matched_group_id', '')::uuid,
      nullif(v_result ->> 'matched_curriculum_subject_id', '')::uuid,
      nullif(v_result ->> 'matched_term_id', '')::uuid,
      nullif(v_result ->> 'matched_offering_id', '')::uuid,
      nullif(v_result ->> 'matched_teacher_link_id', '')::uuid,
      nullif(v_result ->> 'matched_enrollment_id', '')::uuid
    );

    if v_class = 'error' then
      v_errors := v_errors + 1;
    elsif v_class = 'duplicate' then
      v_duplicate := v_duplicate + 1;
    elsif v_class = 'update' then
      v_update := v_update + 1;
    else
      v_new := v_new + 1;
    end if;
  end loop;

  update public.import_studio_batches b set
    row_count = v_n,
    error_count = v_errors,
    summary = jsonb_build_object(
      'total', v_n,
      'new', v_new,
      'update', v_update,
      'duplicate', v_duplicate,
      'error', v_errors,
      'payload_hash', v_hash,
      'warnings', private.import_studio_batch_warnings(v_domain, v_new)
    )
  where b.id = v_batch.id
  returning * into v_batch;

  perform private.admin_write_audit(
    'import_studio.dry_run',
    'import_studio_batch',
    v_batch.id::text,
    jsonb_build_object(
      'domain', v_domain,
      'batch_key', v_key,
      'row_count', v_n,
      'error_count', v_errors,
      'file_name', left(coalesce(p_file_name, ''), 260)
    )
  );

  return private.import_studio_batch_json(v_batch.id)
    || jsonb_build_object('already_applied', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5b) Warning summary shown before confirm apply (SPEC: warn about side
--     effects a dry-run predicts, e.g. new group_space teams/chats).
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_batch_warnings(
  p_domain text,
  p_new_count integer
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_domain = 'groups' and p_new_count > 0 then
      to_jsonb(array[format(
        'Будет создано %s новых групп(ы). Для каждой автоматически создаётся group_space team + chat.',
        p_new_count
      )])
    when p_domain = 'students' and p_new_count > 0 then
      to_jsonb(array[format(
        'Будет создано %s новых аккаунтов студентов (auth-провижининг). Откат недоступен.',
        p_new_count
      )])
    when p_domain = 'offerings' and p_new_count > 0 then
      to_jsonb(array[format(
        'Будет создано %s новых subject_offerings. Предметные команды/чаты создаются отдельно через term backfill, не этим импортом.',
        p_new_count
      )])
    when p_domain = 'enrollments' and p_new_count > 0 then
      to_jsonb(array[format(
        'Будет создано %s новых зачислений. Перевод между группами этим импортом не поддерживается — только новые зачисления.',
        p_new_count
      )])
    when p_domain = 'terms' and p_new_count > 0 then
      to_jsonb(array[format(
        'Будет создано %s новых семестров. Текущий семестр не переключается этим импортом.',
        p_new_count
      )])
    else '[]'::jsonb
  end;
$$;

revoke all on function private.import_studio_batch_warnings(text, integer)
  from public, anon, authenticated;
grant execute on function private.import_studio_batch_warnings(text, integer)
  to service_role;

-- ---------------------------------------------------------------------------
-- 6) Stage-19-owned apply helpers for the six domains with no Stage 13 apply
--    RPC. Each takes the batch id, loops its own (new, update) rows, upserts
--    by id first (never name-only when an id was supplied), backfills the
--    row's matched_* column with what it wrote (so rollback can target
--    exactly those rows), and returns {error, conflict, applied, created,
--    updated} — the same shape admin_import_studio_apply already inspects
--    for the delegated Stage 13 path.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_apply_groups(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_group_id uuid;
  v_created integer := 0;
  v_updated integer := 0;
begin
  for r in
    select ir.id as row_id, ir.mapped_payload
    from public.import_studio_rows ir
    where ir.batch_id = p_batch_id
      and ir.classification in ('new', 'update')
    order by ir.row_number
  loop
    v_group_id := public.admin_upsert_group(
      nullif(r.mapped_payload ->> 'group_id', '')::uuid,
      coalesce(r.mapped_payload ->> 'name', '')
    );
    if nullif(r.mapped_payload ->> 'group_id', '') is not null then
      v_updated := v_updated + 1;
    else
      v_created := v_created + 1;
    end if;
    update public.import_studio_rows
    set matched_group_id = v_group_id
    where id = r.row_id;
  end loop;

  return jsonb_build_object(
    'error', 0, 'conflict', 0, 'created', v_created, 'updated', v_updated
  );
end;
$$;

revoke all on function private.import_studio_apply_groups(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_apply_groups(uuid) to service_role;

-- Terms: forward-only creation of new academic_terms (and, if needed, a new
-- academic_years row). term_sequence is derived deterministically
-- (start_year * 10 + term_in_year) so imported terms sort correctly with the
-- hand-seeded ones. Never touches is_current — the guard trigger on
-- academic_terms would reject that anyway.
create or replace function private.import_studio_apply_terms(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_year_id uuid;
  v_start_year integer;
  v_term_id uuid;
  v_row_created boolean;
  v_fingerprint text;
  v_created integer := 0;
  v_updated integer := 0;
begin
  for r in
    select ir.id as row_id, ir.mapped_payload
    from public.import_studio_rows ir
    where ir.batch_id = p_batch_id
      and ir.classification in ('new', 'update')
    order by ir.row_number
  loop
    v_row_created := false;
    v_fingerprint := null;

    if nullif(r.mapped_payload ->> 'term_id', '') is not null then
      update public.academic_terms
      set name = coalesce(r.mapped_payload ->> 'name', name),
          starts_on = coalesce((r.mapped_payload ->> 'starts_on')::date, starts_on),
          ends_on = coalesce((r.mapped_payload ->> 'ends_on')::date, ends_on)
      where id = (r.mapped_payload ->> 'term_id')::uuid
      returning id into v_term_id;
      v_updated := v_updated + 1;
    else
      -- start_year: the January-anchored calendar year the academic year
      -- STARTS in, matching the seed convention (e.g. "2025/2026" -> 2025).
      v_start_year := split_part(coalesce(r.mapped_payload ->> 'academic_year_name', ''), '/', 1)::integer;

      select ay.id into v_year_id
      from public.academic_years ay
      where private.import_studio_norm(ay.name)
              = private.import_studio_norm(r.mapped_payload ->> 'academic_year_name')
      limit 1;

      if v_year_id is null then
        insert into public.academic_years (name, start_year, starts_on, ends_on, is_current)
        values (
          r.mapped_payload ->> 'academic_year_name',
          v_start_year,
          (r.mapped_payload ->> 'starts_on')::date,
          (r.mapped_payload ->> 'starts_on')::date + interval '1 year' - interval '1 day',
          false
        )
        on conflict (name) do update set name = excluded.name
        returning id into v_year_id;
      end if;

      -- Explicit check-then-write (not ON CONFLICT ... DO UPDATE): apply-time
      -- creation provenance must be atomic and unambiguous — we need to know
      -- for certain whether THIS call inserted the row or matched an
      -- existing one, so rollback never deletes a pre-existing row that
      -- merely got updated (P0: rollback deletes pre-existing rows).
      select t.id into v_term_id
      from public.academic_terms t
      where t.academic_year_id = v_year_id
        and t.term_in_year = (r.mapped_payload ->> 'term_in_year')::integer
      limit 1;

      if v_term_id is not null then
        update public.academic_terms set
          name = coalesce(r.mapped_payload ->> 'name', name),
          starts_on = coalesce((r.mapped_payload ->> 'starts_on')::date, starts_on),
          ends_on = coalesce((r.mapped_payload ->> 'ends_on')::date, ends_on)
        where id = v_term_id;
        v_updated := v_updated + 1;
      else
        insert into public.academic_terms (
          academic_year_id, term_in_year, term_sequence, name, starts_on, ends_on, is_current
        ) values (
          v_year_id,
          (r.mapped_payload ->> 'term_in_year')::integer,
          v_start_year * 10 + (r.mapped_payload ->> 'term_in_year')::integer,
          r.mapped_payload ->> 'name',
          (r.mapped_payload ->> 'starts_on')::date,
          (r.mapped_payload ->> 'ends_on')::date,
          false
        )
        returning id into v_term_id;
        v_created := v_created + 1;
        v_row_created := true;
      end if;
    end if;

    -- Fingerprint captured the instant apply_created is set, so rollback can
    -- later prove nothing else touched this row before deleting it.
    if v_row_created then
      select md5((name, starts_on, ends_on, term_in_year, term_sequence,
                  academic_year_id, is_current)::text)
      into v_fingerprint
      from public.academic_terms
      where id = v_term_id;
    end if;

    update public.import_studio_rows
    set matched_term_id = v_term_id,
        apply_created = v_row_created,
        apply_row_fingerprint = v_fingerprint
    where id = r.row_id;
  end loop;

  return jsonb_build_object(
    'error', 0, 'conflict', 0, 'created', v_created, 'updated', v_updated
  );
end;
$$;

revoke all on function private.import_studio_apply_terms(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_apply_terms(uuid) to service_role;

-- Curriculum: curriculum_subjects is shared across groups on the same
-- semester (no group_id column), so the natural key is (subject_id,
-- semester_number); group_name is validated but never written.
create or replace function private.import_studio_apply_curriculum(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_id uuid;
  v_display text;
  v_row_created boolean;
  v_lock_key bigint;
  v_fingerprint text;
  v_created integer := 0;
  v_updated integer := 0;
begin
  for r in
    select ir.id as row_id, ir.mapped_payload
    from public.import_studio_rows ir
    where ir.batch_id = p_batch_id
      and ir.classification in ('new', 'update')
    order by ir.row_number
  loop
    v_row_created := false;
    v_fingerprint := null;

    select coalesce(sc.canonical_name, 'Предмет') into v_display
    from public.subject_catalog sc
    where sc.id = (r.mapped_payload ->> 'subject_id')::uuid;

    if nullif(r.mapped_payload ->> 'curriculum_subject_id', '') is not null then
      update public.curriculum_subjects set
        credits = coalesce((r.mapped_payload ->> 'credits')::numeric, credits),
        hours_total = coalesce((r.mapped_payload ->> 'hours_total')::integer, hours_total),
        control_form = coalesce(r.mapped_payload ->> 'control_form', control_form),
        block_name = coalesce(r.mapped_payload ->> 'block_name', block_name),
        subject_index = coalesce(r.mapped_payload ->> 'subject_index', subject_index)
      where id = (r.mapped_payload ->> 'curriculum_subject_id')::uuid
      returning id into v_id;
      v_updated := v_updated + 1;
    else
      -- Deterministic locking on the natural key (subject_id,
      -- semester_number) before the check-then-insert below: two concurrent
      -- apply calls targeting the same (subject, semester) now fully
      -- serialize on this xact-scoped advisory lock, so the second one
      -- always observes the first one's insert in its own SELECT and takes
      -- the update/match branch — apply_created can never be wrongly set to
      -- true for both. Session-independent hash, not table-dependent, so it
      -- does not require (and does not assume) a matching unique index.
      v_lock_key := hashtextextended(
        'import_studio_apply_curriculum:'
          || coalesce(r.mapped_payload ->> 'subject_id', '')
          || ':' || coalesce(r.mapped_payload ->> 'semester_number', ''),
        0
      );
      perform pg_advisory_xact_lock(v_lock_key);

      select cs.id into v_id
      from public.curriculum_subjects cs
      where cs.subject_id = (r.mapped_payload ->> 'subject_id')::uuid
        and cs.semester_number = (r.mapped_payload ->> 'semester_number')::integer
      limit 1;

      if v_id is not null then
        update public.curriculum_subjects set
          credits = coalesce((r.mapped_payload ->> 'credits')::numeric, credits),
          hours_total = coalesce((r.mapped_payload ->> 'hours_total')::integer, hours_total),
          control_form = coalesce(r.mapped_payload ->> 'control_form', control_form),
          block_name = coalesce(r.mapped_payload ->> 'block_name', block_name),
          subject_index = coalesce(r.mapped_payload ->> 'subject_index', subject_index)
        where id = v_id;
        v_updated := v_updated + 1;
      else
        -- Conflict-safe insert: the advisory lock above already makes this
        -- unreachable for two callers of THIS function, but if the target
        -- schema ever gains (or already has, undocumented) a unique
        -- constraint on (subject_id, semester_number), a unique_violation
        -- here is still treated as "matched", never as this call's create.
        begin
          insert into public.curriculum_subjects (
            subject_id, raw_subject_name, display_name, semester_number,
            credits, hours_total, control_form, block_name, subject_index
          ) values (
            (r.mapped_payload ->> 'subject_id')::uuid,
            v_display,
            v_display,
            (r.mapped_payload ->> 'semester_number')::integer,
            (r.mapped_payload ->> 'credits')::numeric,
            (r.mapped_payload ->> 'hours_total')::integer,
            r.mapped_payload ->> 'control_form',
            r.mapped_payload ->> 'block_name',
            r.mapped_payload ->> 'subject_index'
          )
          returning id into v_id;
          v_created := v_created + 1;
          v_row_created := true;
        exception
          when unique_violation then
            select cs.id into v_id
            from public.curriculum_subjects cs
            where cs.subject_id = (r.mapped_payload ->> 'subject_id')::uuid
              and cs.semester_number = (r.mapped_payload ->> 'semester_number')::integer
            limit 1;
            v_updated := v_updated + 1;
            v_row_created := false;
        end;
      end if;
    end if;

    -- apply_created reflects THIS apply call's atomic outcome (insert vs
    -- match), not the dry-run classification — see comment on the column.
    if v_row_created then
      -- Fingerprint every mutable business column so a post-apply enrich
      -- (elective flags, type/kind, raw name, etc.) blocks destructive rollback.
      select md5((
        subject_id, raw_subject_name, display_name, semester_number,
        credits, hours_total, control_form, block_name, subject_index,
        department, subject_type, subject_kind, is_elective, elective_module_code
      )::text)
      into v_fingerprint
      from public.curriculum_subjects
      where id = v_id;
    end if;

    update public.import_studio_rows
    set matched_curriculum_subject_id = v_id,
        apply_created = v_row_created,
        apply_row_fingerprint = v_fingerprint
    where id = r.row_id;
  end loop;

  return jsonb_build_object(
    'error', 0, 'conflict', 0, 'created', v_created, 'updated', v_updated
  );
end;
$$;

revoke all on function private.import_studio_apply_curriculum(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_apply_curriculum(uuid) to service_role;

-- Offerings: dedupe by (group_id, subject_id, academic_term_id) when no
-- offering_id was supplied. Best-effort curriculum_subject_id link (only
-- when exactly one curriculum_subjects row matches subject+semester).
create or replace function private.import_studio_apply_offerings(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_id uuid;
  v_curriculum_subject_id uuid;
  v_year_id uuid;
  v_display text;
  v_row_created boolean;
  v_lock_key bigint;
  v_fingerprint text;
  v_created integer := 0;
  v_updated integer := 0;
begin
  for r in
    select ir.id as row_id, ir.mapped_payload
    from public.import_studio_rows ir
    where ir.batch_id = p_batch_id
      and ir.classification in ('new', 'update')
    order by ir.row_number
  loop
    v_row_created := false;
    v_fingerprint := null;

    select sc.canonical_name into v_display
    from public.subject_catalog sc
    where sc.id = (r.mapped_payload ->> 'subject_id')::uuid;
    v_display := coalesce(
      nullif(btrim(r.mapped_payload ->> 'display_name'), ''), v_display, 'Предмет'
    );

    select t.academic_year_id into v_year_id
    from public.academic_terms t
    where t.id = (r.mapped_payload ->> 'term_id')::uuid;

    select cs.id into v_curriculum_subject_id
    from public.curriculum_subjects cs
    where cs.subject_id = (r.mapped_payload ->> 'subject_id')::uuid
      and cs.semester_number = (r.mapped_payload ->> 'semester_number')::integer
    limit 2;
    -- Ambiguous (>1) or missing match: leave curriculum_subject_id null.
    if (select count(*) from public.curriculum_subjects cs
        where cs.subject_id = (r.mapped_payload ->> 'subject_id')::uuid
          and cs.semester_number = (r.mapped_payload ->> 'semester_number')::integer) <> 1 then
      v_curriculum_subject_id := null;
    end if;

    if nullif(r.mapped_payload ->> 'offering_id', '') is not null then
      update public.subject_offerings set
        display_name = v_display,
        semester_number = coalesce((r.mapped_payload ->> 'semester_number')::integer, semester_number),
        status = coalesce(r.mapped_payload ->> 'status', status)
      where id = (r.mapped_payload ->> 'offering_id')::uuid
      returning id into v_id;
      v_updated := v_updated + 1;
    else
      -- Deterministic locking on the natural key (group_id, subject_id,
      -- term_id) before the check-then-insert below — see the matching
      -- comment in import_studio_apply_curriculum for why this makes
      -- concurrent apply calls serialize instead of racing.
      v_lock_key := hashtextextended(
        'import_studio_apply_offerings:'
          || coalesce(r.mapped_payload ->> 'group_id', '')
          || ':' || coalesce(r.mapped_payload ->> 'subject_id', '')
          || ':' || coalesce(r.mapped_payload ->> 'term_id', ''),
        0
      );
      perform pg_advisory_xact_lock(v_lock_key);

      select so.id into v_id
      from public.subject_offerings so
      where so.group_id = (r.mapped_payload ->> 'group_id')::uuid
        and so.subject_id = (r.mapped_payload ->> 'subject_id')::uuid
        and so.academic_term_id = (r.mapped_payload ->> 'term_id')::uuid
      limit 1;

      if v_id is not null then
        update public.subject_offerings set
          display_name = v_display,
          semester_number = coalesce((r.mapped_payload ->> 'semester_number')::integer, semester_number),
          status = coalesce(r.mapped_payload ->> 'status', status)
        where id = v_id;
        v_updated := v_updated + 1;
      else
        -- Conflict-safe insert: the advisory lock above already makes this
        -- unreachable for two callers of THIS function; a unique_violation
        -- (e.g. an undocumented constraint on the target schema) is still
        -- treated as "matched", never as this call's create.
        begin
          insert into public.subject_offerings (
            subject_id, curriculum_subject_id, group_id, academic_year_id,
            academic_term_id, semester_number, display_name, status
          ) values (
            (r.mapped_payload ->> 'subject_id')::uuid,
            v_curriculum_subject_id,
            (r.mapped_payload ->> 'group_id')::uuid,
            v_year_id,
            (r.mapped_payload ->> 'term_id')::uuid,
            (r.mapped_payload ->> 'semester_number')::integer,
            v_display,
            coalesce(r.mapped_payload ->> 'status', 'active')
          )
          returning id into v_id;
          v_created := v_created + 1;
          v_row_created := true;
        exception
          when unique_violation then
            select so.id into v_id
            from public.subject_offerings so
            where so.group_id = (r.mapped_payload ->> 'group_id')::uuid
              and so.subject_id = (r.mapped_payload ->> 'subject_id')::uuid
              and so.academic_term_id = (r.mapped_payload ->> 'term_id')::uuid
            limit 1;
            v_updated := v_updated + 1;
            v_row_created := false;
        end;
      end if;
    end if;

    -- apply_created reflects THIS apply call's atomic outcome (insert vs
    -- match), not the dry-run classification — see comment on the column.
    if v_row_created then
      select md5((subject_id, curriculum_subject_id, group_id, academic_year_id,
                  academic_term_id, semester_number, display_name, status)::text)
      into v_fingerprint
      from public.subject_offerings
      where id = v_id;
    end if;

    update public.import_studio_rows
    set matched_offering_id = v_id,
        apply_created = v_row_created,
        apply_row_fingerprint = v_fingerprint
    where id = r.row_id;
  end loop;

  return jsonb_build_object(
    'error', 0, 'conflict', 0, 'created', v_created, 'updated', v_updated
  );
end;
$$;

revoke all on function private.import_studio_apply_offerings(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_apply_offerings(uuid) to service_role;

-- Teacher links: offering_teachers has a real unique(subject_offering_id,
-- teacher_id, role) constraint, so on conflict do nothing is sufficient —
-- role is coalesced to '' first so NULL never defeats that uniqueness.
create or replace function private.import_studio_apply_teacher_links(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_id uuid;
  v_role text;
  v_row_created boolean;
  v_lock_key bigint;
  v_fingerprint text;
  v_created integer := 0;
  v_updated integer := 0;
begin
  for r in
    select ir.id as row_id, ir.mapped_payload
    from public.import_studio_rows ir
    where ir.batch_id = p_batch_id
      and ir.classification in ('new', 'update')
    order by ir.row_number
  loop
    v_row_created := false;
    v_fingerprint := null;
    v_role := coalesce(r.mapped_payload ->> 'role', '');

    if nullif(r.mapped_payload ->> 'teacher_link_id', '') is not null then
      update public.offering_teachers
      set role = v_role
      where id = (r.mapped_payload ->> 'teacher_link_id')::uuid
      returning id into v_id;
      v_updated := v_updated + 1;
    else
      -- Deterministic locking on the natural key (offering_id, teacher_id,
      -- role) before the check-then-write below — see the matching comment
      -- in import_studio_apply_curriculum. offering_teachers carries a real
      -- unique(subject_offering_id, teacher_id, role) constraint on the
      -- target schema, but the lock removes the race even if that
      -- assumption is ever wrong, and the exception handler below keeps
      -- provenance correct if the constraint does fire.
      v_lock_key := hashtextextended(
        'import_studio_apply_teacher_links:'
          || coalesce(r.mapped_payload ->> 'offering_id', '')
          || ':' || coalesce(r.mapped_payload ->> 'teacher_id', '')
          || ':' || v_role,
        0
      );
      perform pg_advisory_xact_lock(v_lock_key);

      select ot.id into v_id
      from public.offering_teachers ot
      where ot.subject_offering_id = (r.mapped_payload ->> 'offering_id')::uuid
        and ot.teacher_id = (r.mapped_payload ->> 'teacher_id')::uuid
        and coalesce(ot.role, '') = v_role
      limit 1;

      if v_id is not null then
        v_updated := v_updated + 1;
      else
        begin
          insert into public.offering_teachers (subject_offering_id, teacher_id, role)
          values (
            (r.mapped_payload ->> 'offering_id')::uuid,
            (r.mapped_payload ->> 'teacher_id')::uuid,
            v_role
          )
          returning id into v_id;
          v_created := v_created + 1;
          v_row_created := true;
        exception
          when unique_violation then
            select ot.id into v_id
            from public.offering_teachers ot
            where ot.subject_offering_id = (r.mapped_payload ->> 'offering_id')::uuid
              and ot.teacher_id = (r.mapped_payload ->> 'teacher_id')::uuid
              and coalesce(ot.role, '') = v_role
            limit 1;
            v_updated := v_updated + 1;
            v_row_created := false;
        end;
      end if;
    end if;

    -- apply_created reflects THIS apply call's atomic outcome (insert vs
    -- match), not the dry-run classification — see comment on the column.
    if v_row_created then
      select md5((subject_offering_id, teacher_id, role)::text)
      into v_fingerprint
      from public.offering_teachers
      where id = v_id;
    end if;

    update public.import_studio_rows
    set matched_teacher_link_id = v_id,
        apply_created = v_row_created,
        apply_row_fingerprint = v_fingerprint
    where id = r.row_id;
  end loop;

  return jsonb_build_object(
    'error', 0, 'conflict', 0, 'created', v_created, 'updated', v_updated
  );
end;
$$;

revoke all on function private.import_studio_apply_teacher_links(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_apply_teacher_links(uuid)
  to service_role;

-- Enrollments: conservative by design (see validator) — only ever creates a
-- brand new active enrollment, or replays an existing exact match as an
-- idempotent no-op. Cross-group transfers are refused at validation time.
create or replace function private.import_studio_apply_enrollments(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_id uuid;
  v_created integer := 0;
  v_updated integer := 0;
begin
  for r in
    select ir.id as row_id, ir.mapped_payload
    from public.import_studio_rows ir
    where ir.batch_id = p_batch_id
      and ir.classification in ('new', 'update')
    order by ir.row_number
  loop
    select se.id into v_id
    from public.student_enrollments se
    where se.user_id = (r.mapped_payload ->> 'user_id')::uuid
      and se.group_id = (r.mapped_payload ->> 'group_id')::uuid
      and se.status = 'active'
      and se.ended_at is null
    limit 1;

    if v_id is not null then
      v_updated := v_updated + 1;
    else
      insert into public.student_enrollments (user_id, group_id, started_at, status)
      values (
        (r.mapped_payload ->> 'user_id')::uuid,
        (r.mapped_payload ->> 'group_id')::uuid,
        coalesce((r.mapped_payload ->> 'started_at')::date, current_date),
        'active'
      )
      returning id into v_id;
      v_created := v_created + 1;
    end if;

    update public.import_studio_rows
    set matched_enrollment_id = v_id
    where id = r.row_id;
  end loop;

  return jsonb_build_object(
    'error', 0, 'conflict', 0, 'created', v_created, 'updated', v_updated
  );
end;
$$;

revoke all on function private.import_studio_apply_enrollments(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_apply_enrollments(uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- 7) Confirm apply — now dispatches to either the existing Stage 13
--    delegated RPC (teachers/subjects/students) or a Stage-19-owned helper
--    (the six new domains), inside the same nested-subtransaction fail-closed
--    pattern. Sets rollback_safe on the batch for domains with a reviewed
--    reversible undo.
-- ---------------------------------------------------------------------------
create or replace function public.admin_import_studio_apply(
  p_batch_id uuid,
  p_confirm_batch_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_batch public.import_studio_batches;
  v_before jsonb;
  v_rows jsonb;
  v_fn text;
  v_signature text;
  v_result jsonb := '{}'::jsonb;
  v_errors integer := 0;
  v_conflicts integer := 0;
  v_failed boolean := false;
  v_fail_detail text := '';
  v_delegated boolean;
  v_rollback_safe boolean;
begin
  select * into v_batch
  from public.import_studio_batches
  where id = p_batch_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_uid := private.import_studio_require_apply(v_batch.domain);
  perform private.import_studio_assert_owner(v_batch, v_uid);

  if nullif(btrim(coalesce(p_confirm_batch_key, '')), '') is distinct from v_batch.batch_key then
    raise exception 'batch_key_confirmation_mismatch' using errcode = '22023';
  end if;

  if v_batch.status = 'applied' then
    return private.import_studio_batch_json(p_batch_id)
      || jsonb_build_object('already_applied', true, 'idempotent_replay', true);
  end if;
  if v_batch.status <> 'dry_run' then
    raise exception 'batch_not_appliable' using errcode = '55000';
  end if;
  if not private.import_studio_supports_apply(v_batch.domain) then
    raise exception 'apply_not_supported_for_domain_%', v_batch.domain
      using errcode = '0A000';
  end if;
  if v_batch.error_count > 0 then
    raise exception 'batch_has_errors' using errcode = 'P0001';
  end if;
  if v_batch.row_count = 0 then
    raise exception 'empty_batch' using errcode = '22023';
  end if;

  v_delegated := v_batch.domain in ('teachers', 'subjects', 'students');
  v_rollback_safe := v_batch.domain in ('terms', 'curriculum', 'offerings', 'teacher_links');

  v_before := private.import_studio_term_fingerprint();

  if v_delegated then
    select coalesce(jsonb_agg(r.mapped_payload order by r.row_number), '[]'::jsonb)
    into v_rows
    from public.import_studio_rows r
    where r.batch_id = p_batch_id
      and r.classification in ('new', 'update');

    if jsonb_array_length(v_rows) = 0 then
      raise exception 'nothing_to_apply' using errcode = '22023';
    end if;

    v_fn := case v_batch.domain
      when 'teachers' then 'public.admin_teacher_import_apply'
      when 'subjects' then 'public.admin_subject_import_apply'
      else 'public.admin_student_import_apply'
    end;
    v_signature := v_fn || '(jsonb)';

    if to_regprocedure(v_signature) is null then
      raise exception 'domain_apply_rpc_missing_%', v_fn using errcode = '55000';
    end if;
  else
    if not exists (
      select 1 from public.import_studio_rows r
      where r.batch_id = p_batch_id and r.classification in ('new', 'update')
    ) then
      raise exception 'nothing_to_apply' using errcode = '22023';
    end if;
    v_fn := case v_batch.domain
      when 'groups' then 'private.import_studio_apply_groups'
      when 'terms' then 'private.import_studio_apply_terms'
      when 'curriculum' then 'private.import_studio_apply_curriculum'
      when 'offerings' then 'private.import_studio_apply_offerings'
      when 'teacher_links' then 'private.import_studio_apply_teacher_links'
      else 'private.import_studio_apply_enrollments'
    end;
  end if;

  -- Nested subtransaction: roll back delegated/owned domain mutations on
  -- failure, then persist failed status + audit outside the nested block.
  begin
    if v_delegated then
      execute format('select %s($1)', v_fn) into v_result using v_rows;
    else
      execute format('select %s($1)', v_fn) into v_result using p_batch_id;
    end if;

    v_errors := coalesce((v_result ->> 'error')::integer, 0);
    v_conflicts := coalesce((v_result ->> 'conflict')::integer, 0);

    if v_errors > 0 or v_conflicts > 0 then
      raise exception 'delegated_apply_failed_inner'
        using errcode = 'P0001',
              detail = format('errors=%s conflicts=%s', v_errors, v_conflicts);
    end if;

    perform private.import_studio_assert_term_safety(v_before);
  exception
    when others then
      v_failed := true;
      v_fail_detail := coalesce(nullif(SQLERRM, ''), 'delegated_apply_failed');
      if v_result is null or v_result = '{}'::jsonb then
        v_result := jsonb_build_object(
          'error', greatest(v_errors, 1),
          'conflict', v_conflicts,
          'exception', v_fail_detail
        );
      else
        v_result := v_result || jsonb_build_object('exception', v_fail_detail);
      end if;
  end;

  if v_failed then
    update public.import_studio_batches b set
      status = 'failed',
      delegated_result = coalesce(v_result, '{}'::jsonb)
    where b.id = p_batch_id;

    perform private.admin_write_audit(
      'import_studio.apply_refused',
      'import_studio_batch',
      p_batch_id::text,
      jsonb_build_object(
        'domain', v_batch.domain,
        'delegated_to', v_fn,
        'error', coalesce((v_result ->> 'error')::integer, v_errors),
        'conflict', coalesce((v_result ->> 'conflict')::integer, v_conflicts),
        'delegated_result', coalesce(v_result, '{}'::jsonb)
      )
    );

    return private.import_studio_batch_json(p_batch_id)
      || jsonb_build_object(
        'ok', false,
        'already_applied', false,
        'delegated_apply_failed', true,
        'detail', v_fail_detail
      );
  end if;

  update public.import_studio_batches b set
    status = 'applied',
    applied_by = v_uid,
    applied_at = now(),
    delegated_result = coalesce(v_result, '{}'::jsonb),
    rollback_safe = v_rollback_safe
  where b.id = p_batch_id
  returning * into v_batch;

  perform private.admin_write_audit(
    'import_studio.apply',
    'import_studio_batch',
    p_batch_id::text,
    jsonb_build_object(
      'domain', v_batch.domain,
      'row_count', v_batch.row_count,
      'delegated_to', v_fn,
      'rollback_safe', v_rollback_safe
    )
  );

  return private.import_studio_batch_json(p_batch_id)
    || jsonb_build_object('ok', true, 'already_applied', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8) Rollback — real implementation for the four rollback_safe domains.
--
-- Dependency checks are EXPLICIT existence checks, not "try the delete and
-- catch a foreign-key violation": several of the relevant FKs are
-- ON DELETE SET NULL or ON DELETE CASCADE (subject_offerings.curriculum_
-- subject_id, offering_teachers.subject_offering_id, subject_ratings.*,
-- group_term_semesters.academic_term_id, ...), which would silently orphan
-- or cascade-delete unrelated rows instead of raising. A blocked rollback
-- refuses instead of half-applying: the whole delete loop runs inside one
-- nested subtransaction, and any blocker aborts it before anything commits.
--
-- Only rows with apply_created = true are ever deleted — the atomic,
-- apply-time-recorded outcome of THIS apply call, not the dry-run
-- classification (which can go stale under a dry-run/apply race, and used
-- to always say 'new' for curriculum/offerings/teacher_links even when a
-- natural-key match existed, causing rollback to delete a pre-existing
-- row). If ANY row in the batch matched/updated a pre-existing record
-- (apply_created = false) instead of being freshly created, the whole
-- rollback is refused (rollback_refused_has_updates) rather than partially
-- undone — there is no "before" snapshot to restore an updated row to.
-- ---------------------------------------------------------------------------
create or replace function private.import_studio_term_blockers(p_term_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_blockers text[] := '{}'::text[];
  v_found boolean;
begin
  if exists (select 1 from public.academic_terms where id = p_term_id and is_current) then
    v_blockers := array_append(v_blockers, 'is_current_term');
  end if;

  if exists (select 1 from public.subject_offerings where academic_term_id = p_term_id) then
    v_blockers := array_append(v_blockers, 'subject_offerings');
  end if;

  -- Optional tables (may not exist in every environment): guarded with
  -- to_regclass, same convention as private.stage13_8_group_semester.
  if to_regclass('public.group_term_semesters') is not null then
    execute 'select exists (select 1 from public.group_term_semesters where academic_term_id = $1)'
      into v_found using p_term_id;
    if v_found then
      v_blockers := array_append(v_blockers, 'group_term_semesters');
    end if;
  end if;
  if to_regclass('public.teams') is not null then
    execute 'select exists (select 1 from public.teams where academic_term_id = $1)'
      into v_found using p_term_id;
    if v_found then
      v_blockers := array_append(v_blockers, 'teams');
    end if;
  end if;
  if to_regclass('public.assignments') is not null then
    execute 'select exists (select 1 from public.assignments where academic_term_id = $1)'
      into v_found using p_term_id;
    if v_found then
      v_blockers := array_append(v_blockers, 'assignments');
    end if;
  end if;
  if to_regclass('public.chat_files') is not null then
    execute 'select exists (select 1 from public.chat_files where academic_term_id = $1)'
      into v_found using p_term_id;
    if v_found then
      v_blockers := array_append(v_blockers, 'chat_files');
    end if;
  end if;
  if to_regclass('public.lessons') is not null then
    execute 'select exists (select 1 from public.lessons where academic_term_id = $1)'
      into v_found using p_term_id;
    if v_found then
      v_blockers := array_append(v_blockers, 'lessons');
    end if;
  end if;
  if to_regclass('public.subject_diary_entries') is not null then
    execute 'select exists (select 1 from public.subject_diary_entries where academic_term_id = $1)'
      into v_found using p_term_id;
    if v_found then
      v_blockers := array_append(v_blockers, 'subject_diary_entries');
    end if;
  end if;
  if to_regclass('public.chat_academic_archives') is not null then
    execute 'select exists (select 1 from public.chat_academic_archives where academic_term_id = $1)'
      into v_found using p_term_id;
    if v_found then
      v_blockers := array_append(v_blockers, 'chat_academic_archives');
    end if;
  end if;

  return v_blockers;
end;
$$;

revoke all on function private.import_studio_term_blockers(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_term_blockers(uuid) to service_role;

create or replace function private.import_studio_curriculum_blockers(p_curriculum_subject_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_blockers text[] := '{}'::text[];
  v_found boolean;
begin
  if exists (
    select 1 from public.subject_offerings where curriculum_subject_id = p_curriculum_subject_id
  ) then
    v_blockers := array_append(v_blockers, 'subject_offerings');
  end if;

  if to_regclass('public.subject_ratings') is not null then
    execute 'select exists (select 1 from public.subject_ratings where curriculum_subject_id = $1)'
      into v_found using p_curriculum_subject_id;
    if v_found then
      v_blockers := array_append(v_blockers, 'subject_ratings');
    end if;
  end if;

  return v_blockers;
end;
$$;

revoke all on function private.import_studio_curriculum_blockers(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_curriculum_blockers(uuid)
  to service_role;

create or replace function private.import_studio_offering_blockers(p_offering_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_blockers text[] := '{}'::text[];
  v_found boolean;
  v_tbl text;
begin
  if exists (
    select 1 from public.offering_teachers where subject_offering_id = p_offering_id
  ) then
    v_blockers := array_append(v_blockers, 'offering_teachers');
  end if;
  if exists (
    select 1 from public.subject_offering_student_profiles where subject_offering_id = p_offering_id
  ) then
    v_blockers := array_append(v_blockers, 'subject_offering_student_profiles');
  end if;
  if exists (
    select 1 from public.subject_difficulty_votes where subject_offering_id = p_offering_id
  ) then
    v_blockers := array_append(v_blockers, 'subject_difficulty_votes');
  end if;

  -- Optional tables: guarded with to_regclass, same convention as
  -- private.stage13_8_group_semester.
  foreach v_tbl in array array[
    'subject_ratings', 'teacher_subject_ratings', 'personal_diary_tasks',
    'chat_academic_archives', 'teams', 'chats', 'assignments', 'chat_files',
    'lessons', 'subject_diary_entries'
  ]
  loop
    if to_regclass('public.' || v_tbl) is not null then
      execute format(
        'select exists (select 1 from public.%I where subject_offering_id = $1)', v_tbl
      ) into v_found using p_offering_id;
      if v_found then
        v_blockers := array_append(v_blockers, v_tbl);
      end if;
    end if;
  end loop;

  return v_blockers;
end;
$$;

revoke all on function private.import_studio_offering_blockers(uuid)
  from public, anon, authenticated;
grant execute on function private.import_studio_offering_blockers(uuid)
  to service_role;

create or replace function public.admin_import_studio_rollback_batch(
  p_batch_id uuid,
  p_confirm_batch_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_batch public.import_studio_batches;
  v_rolled_back boolean := false;
  v_block_reason text := '';
  v_deleted integer := 0;
  v_updates_not_reverted integer := 0;
  v_update_count integer := 0;
  v_error_code text := 'rollback_blocked_by_dependency';
  v_live_fingerprint text;
  r record;
  v_blockers text[];
begin
  select * into v_batch
  from public.import_studio_batches
  where id = p_batch_id
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_uid := private.import_studio_require_apply(v_batch.domain);
  perform private.import_studio_assert_owner(v_batch, v_uid);

  if nullif(btrim(coalesce(p_confirm_batch_key, '')), '') is distinct from v_batch.batch_key then
    raise exception 'batch_key_confirmation_mismatch' using errcode = '22023';
  end if;

  if v_batch.status <> 'applied' then
    raise exception 'batch_not_applied' using errcode = '55000';
  end if;

  if not v_batch.rollback_safe then
    perform private.admin_write_audit(
      'import_studio.rollback_refused',
      'import_studio_batch',
      p_batch_id::text,
      jsonb_build_object(
        'domain', v_batch.domain, 'rollback_safe', false, 'reason', 'domain_not_rollback_safe'
      )
    );
    return jsonb_build_object(
      'ok', false,
      'refused', true,
      'batch_id', p_batch_id,
      'domain', v_batch.domain,
      'rollback_safe', false,
      'error_code', 'rollback_not_supported_for_batch',
      'message', format(
        'Откат batch для домена %s не поддерживается: изменения могут быть связаны с другими данными (team/chat, зачисления, ручные правки после импорта).',
        v_batch.domain
      )
    );
  end if;

  -- P1: a batch that touched ANY pre-existing row (matched/updated rather
  -- than inserted by THIS apply call) is refused wholesale rather than
  -- partially rolled back. There is no before-snapshot to restore an
  -- updated row to, so "rollback the new rows and leave the updates" would
  -- silently understate what actually happened; refusing is the honest
  -- option (see finding: "batches with updates marked rollback-safe").
  -- apply_created (set atomically at apply time) is authoritative here, not
  -- the dry-run classification, which can go stale under a dry-run/apply
  -- race.
  select count(*) into v_update_count
  from public.import_studio_rows
  where batch_id = p_batch_id
    and classification in ('new', 'update')
    and coalesce(apply_created, false) = false;

  if v_update_count > 0 then
    perform private.admin_write_audit(
      'import_studio.rollback_refused',
      'import_studio_batch',
      p_batch_id::text,
      jsonb_build_object(
        'domain', v_batch.domain, 'rollback_safe', true,
        'reason', 'rollback_refused_has_updates', 'update_count', v_update_count
      )
    );
    return jsonb_build_object(
      'ok', false,
      'refused', true,
      'batch_id', p_batch_id,
      'domain', v_batch.domain,
      'rollback_safe', true,
      'error_code', 'rollback_refused_has_updates',
      'message', format(
        'Откат отклонён: этот batch обновил %s уже существующих записей — снимок «до» не хранится, поэтому откат мог бы исказить данные, которые batch не создавал.',
        v_update_count
      )
    );
  end if;

  -- Nested subtransaction: any blocker or error aborts every delete in this
  -- batch's rollback together — never a partial undo.
  begin
    if v_batch.domain = 'terms' then
      for r in
        select id, matched_term_id, apply_row_fingerprint
        from public.import_studio_rows
        where batch_id = p_batch_id
          and apply_created = true
          and matched_term_id is not null
        order by row_number desc
      loop
        v_blockers := private.import_studio_term_blockers(r.matched_term_id);
        if coalesce(array_length(v_blockers, 1), 0) > 0 then
          raise exception 'rollback_blocked_by_dependency:%', array_to_string(v_blockers, ',')
            using errcode = '55000';
        end if;

        -- P1: refuse (never silently delete) if the row drifted from what
        -- apply actually created — e.g. a later admin edit or the
        -- is_current flip flow. apply_row_fingerprint was captured at the
        -- instant apply set apply_created = true; a null fingerprint (a
        -- batch applied before this column existed) is also treated as
        -- drift, since there is nothing to prove it did NOT drift.
        -- FOR UPDATE closes the TOCTOU window between fingerprint check
        -- and delete under concurrent editors.
        select md5((name, starts_on, ends_on, term_in_year, term_sequence,
                    academic_year_id, is_current)::text)
        into v_live_fingerprint
        from public.academic_terms
        where id = r.matched_term_id
        for update;
        if r.apply_row_fingerprint is null
           or v_live_fingerprint is distinct from r.apply_row_fingerprint then
          raise exception 'rollback_refused_row_drift:academic_terms:%', r.matched_term_id
            using errcode = '55000';
        end if;

        delete from public.academic_terms where id = r.matched_term_id;
        v_deleted := v_deleted + 1;
      end loop;

    elsif v_batch.domain = 'curriculum' then
      for r in
        select id, matched_curriculum_subject_id, apply_row_fingerprint
        from public.import_studio_rows
        where batch_id = p_batch_id
          and apply_created = true
          and matched_curriculum_subject_id is not null
        order by row_number desc
      loop
        v_blockers := private.import_studio_curriculum_blockers(r.matched_curriculum_subject_id);
        if coalesce(array_length(v_blockers, 1), 0) > 0 then
          raise exception 'rollback_blocked_by_dependency:%', array_to_string(v_blockers, ',')
            using errcode = '55000';
        end if;

        select md5((
          subject_id, raw_subject_name, display_name, semester_number,
          credits, hours_total, control_form, block_name, subject_index,
          department, subject_type, subject_kind, is_elective, elective_module_code
        )::text)
        into v_live_fingerprint
        from public.curriculum_subjects
        where id = r.matched_curriculum_subject_id
        for update;
        if r.apply_row_fingerprint is null
           or v_live_fingerprint is distinct from r.apply_row_fingerprint then
          raise exception 'rollback_refused_row_drift:curriculum_subjects:%',
            r.matched_curriculum_subject_id
            using errcode = '55000';
        end if;

        delete from public.curriculum_subjects where id = r.matched_curriculum_subject_id;
        v_deleted := v_deleted + 1;
      end loop;

    elsif v_batch.domain = 'offerings' then
      for r in
        select id, matched_offering_id, apply_row_fingerprint
        from public.import_studio_rows
        where batch_id = p_batch_id
          and apply_created = true
          and matched_offering_id is not null
        order by row_number desc
      loop
        v_blockers := private.import_studio_offering_blockers(r.matched_offering_id);
        if coalesce(array_length(v_blockers, 1), 0) > 0 then
          raise exception 'rollback_blocked_by_dependency:%', array_to_string(v_blockers, ',')
            using errcode = '55000';
        end if;

        select md5((subject_id, curriculum_subject_id, group_id, academic_year_id,
                    academic_term_id, semester_number, display_name, status)::text)
        into v_live_fingerprint
        from public.subject_offerings
        where id = r.matched_offering_id
        for update;
        if r.apply_row_fingerprint is null
           or v_live_fingerprint is distinct from r.apply_row_fingerprint then
          raise exception 'rollback_refused_row_drift:subject_offerings:%', r.matched_offering_id
            using errcode = '55000';
        end if;

        delete from public.subject_offerings where id = r.matched_offering_id;
        v_deleted := v_deleted + 1;
      end loop;

    else
      -- teacher_links: offering_teachers is a pure junction row with no
      -- other table referencing it, so it is always safe to delete —
      -- still drift-checked, since (subject_offering_id, teacher_id, role)
      -- could in principle have been hand-edited after apply.
      for r in
        select id, matched_teacher_link_id, apply_row_fingerprint
        from public.import_studio_rows
        where batch_id = p_batch_id
          and apply_created = true
          and matched_teacher_link_id is not null
        order by row_number desc
      loop
        select md5((subject_offering_id, teacher_id, role)::text)
        into v_live_fingerprint
        from public.offering_teachers
        where id = r.matched_teacher_link_id
        for update;
        if r.apply_row_fingerprint is null
           or v_live_fingerprint is distinct from r.apply_row_fingerprint then
          raise exception 'rollback_refused_row_drift:offering_teachers:%', r.matched_teacher_link_id
            using errcode = '55000';
        end if;

        delete from public.offering_teachers where id = r.matched_teacher_link_id;
        v_deleted := v_deleted + 1;
      end loop;
    end if;

    -- Always 0 here: the v_update_count check above already refused the
    -- whole rollback if any row in this batch matched/updated a
    -- pre-existing row instead of being created by this apply call.
    -- Recomputed (rather than hardcoded) so this stays honest if that
    -- invariant is ever loosened.
    select count(*) into v_updates_not_reverted
    from public.import_studio_rows
    where batch_id = p_batch_id
      and classification in ('new', 'update')
      and coalesce(apply_created, false) = false;

    v_rolled_back := true;
  exception
    when others then
      v_rolled_back := false;
      v_block_reason := coalesce(nullif(SQLERRM, ''), 'rollback_failed');
      -- Distinguish drift refusals from dependency-blocker refusals in the
      -- returned error_code (both share the same nested-subtransaction
      -- catch-all so neither ever partially deletes this batch's rows).
      if v_block_reason like 'rollback_refused_row_drift:%' then
        v_error_code := 'rollback_refused_row_drift';
      else
        v_error_code := 'rollback_blocked_by_dependency';
      end if;
  end;

  if not v_rolled_back then
    perform private.admin_write_audit(
      'import_studio.rollback_refused',
      'import_studio_batch',
      p_batch_id::text,
      jsonb_build_object(
        'domain', v_batch.domain, 'rollback_safe', true,
        'reason', v_block_reason, 'error_code', v_error_code
      )
    );
    return jsonb_build_object(
      'ok', false,
      'refused', true,
      'batch_id', p_batch_id,
      'domain', v_batch.domain,
      'rollback_safe', true,
      'error_code', v_error_code,
      'message', case
        when v_error_code = 'rollback_refused_row_drift' then format(
          'Откат отклонён: запись изменилась после применения импорта — снимок «после apply» больше не совпадает, откат мог бы уничтожить данные, которые batch не создавал. (%s)',
          v_block_reason
        )
        else format('Откат отклонён: %s', v_block_reason)
      end
    );
  end if;

  update public.import_studio_batches set status = 'rolled_back' where id = p_batch_id;

  perform private.admin_write_audit(
    'import_studio.rollback',
    'import_studio_batch',
    p_batch_id::text,
    jsonb_build_object(
      'domain', v_batch.domain,
      'deleted_count', v_deleted,
      'updates_not_reverted', v_updates_not_reverted
    )
  );

  return jsonb_build_object(
    'ok', true,
    'refused', false,
    'batch_id', p_batch_id,
    'domain', v_batch.domain,
    'rollback_safe', true,
    'deleted_count', v_deleted,
    'updates_not_reverted', v_updates_not_reverted,
    'message', format(
      'Откат выполнен: удалено %s записей, созданных этим batch. Обновлений существующих записей в этом batch не было (%s).',
      v_deleted, v_updates_not_reverted
    )
  );
end;
$$;

comment on function public.admin_import_studio_rollback_batch(uuid, text) is
  'Rolls back only a rollback_safe applied batch (terms, curriculum, offerings, teacher_links), deleting rows this batch actually INSERTed (apply_created=true, set atomically at apply time — never the dry-run classification, which can go stale) after an explicit dependency check AND a drift check per row. Refuses (ok=false, error_code=rollback_refused_has_updates) wholesale if the batch matched/updated ANY pre-existing row, since there is no before-snapshot to restore it to; refuses (error_code=rollback_refused_row_drift) per-row if the live row no longer matches the apply_row_fingerprint captured at apply time (hand-edited, or otherwise changed, after apply); also refuses for non-rollback_safe domains or when a dependency blocks the undo. Never partially rolls back.';

commit;
