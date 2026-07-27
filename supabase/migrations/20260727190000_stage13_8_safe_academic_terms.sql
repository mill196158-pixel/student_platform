-- Stage 13.8 — Safe academic terms lifecycle
-- Local migration only. Do not apply to remote until owner-authorized.
-- Splits safe backfill from forward-only term activation.

begin;

-- ---------------------------------------------------------------------------
-- 0) Preconditions + single-current guarantee
-- ---------------------------------------------------------------------------
do $$
declare
  v_current_count integer;
begin
  alter table public.academic_terms
    alter column is_current set default false;

  update public.academic_terms
  set is_current = false
  where is_current is null;

  alter table public.academic_terms
    alter column is_current set not null;

  select count(*)::integer into v_current_count
  from public.academic_terms
  where is_current = true;

  if v_current_count <> 1 then
    raise exception
      'stage13_8_requires_exactly_one_current_term (found %)', v_current_count
      using errcode = 'P0001';
  end if;
end $$;

create unique index if not exists academic_terms_one_current_uidx
  on public.academic_terms (is_current)
  where is_current = true;

-- Feature flag for future automation only. No job reads this yet.
alter table public.academic_terms
  add column if not exists auto_activation_enabled boolean not null default false;

comment on column public.academic_terms.auto_activation_enabled is
  'Reserved feature flag. Auto activation must remain disabled unless an explicit future job is enabled.';

-- Drop broad archive-on-any-current-flip trigger. Transition archives previous term explicitly.
drop trigger if exists trg_academic_terms_archive_previous on public.academic_terms;

-- Allow Stage 13.8 ops journal values.
alter table public.admin_term_ops_batches
  drop constraint if exists admin_term_ops_batches_operation_check;
alter table public.admin_term_ops_batches
  add constraint admin_term_ops_batches_operation_check
  check (operation = any (array[
    'student_import'::text,
    'term_prepare'::text,
    'term_backfill'::text,
    'term_start_next'::text
  ]));

-- Close direct table writes: lifecycle changes only through SECURITY DEFINER RPCs.
alter table public.academic_terms enable row level security;
alter table public.academic_terms force row level security;
drop policy if exists "academic_terms_admin_manage" on public.academic_terms;
drop policy if exists "academic_terms_read_authenticated" on public.academic_terms;
drop policy if exists academic_terms_select_authenticated on public.academic_terms;
create policy academic_terms_select_authenticated
  on public.academic_terms
  for select
  to authenticated
  using (auth.uid() is not null);
revoke insert, update, delete, truncate on table public.academic_terms from anon, authenticated;
grant select on table public.academic_terms to authenticated;

-- ---------------------------------------------------------------------------
-- 1) Internal helpers
-- ---------------------------------------------------------------------------
create or replace function private.stage13_8_require_terms_manage()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.stage13_5_can('terms.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
end;
$$;

revoke all on function private.stage13_8_require_terms_manage() from public, anon, authenticated;

create or replace function private.stage13_8_acquire_lifecycle_lock()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not pg_try_advisory_xact_lock(hashtext('stage13_8_term_lifecycle')) then
    raise exception 'term_lifecycle_in_progress' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on function private.stage13_8_acquire_lifecycle_lock()
  from public, anon, authenticated;

create or replace function private.trg_fn_stage13_8_guard_is_current()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and new.is_current is distinct from old.is_current
     and current_setting('private.allow_term_current_flip', true) is distinct from '1'
  then
    raise exception 'direct_is_current_update_forbidden'
      using errcode = '42501',
            hint = 'Use admin_start_next_term';
  end if;
  return new;
end;
$$;

revoke all on function private.trg_fn_stage13_8_guard_is_current()
  from public, anon, authenticated;

drop trigger if exists trg_stage13_8_guard_is_current on public.academic_terms;
create trigger trg_stage13_8_guard_is_current
before update of is_current on public.academic_terms
for each row
execute function private.trg_fn_stage13_8_guard_is_current();

create or replace function private.stage13_8_current_term()
returns public.academic_terms
language sql
stable
security definer
set search_path = ''
as $$
  select t.*
  from public.academic_terms t
  where t.is_current = true
  order by t.term_sequence
  limit 1;
$$;

revoke all on function private.stage13_8_current_term() from public, anon, authenticated;

create or replace function private.stage13_8_nearest_next_term(p_current_sequence integer)
returns public.academic_terms
language sql
stable
security definer
set search_path = ''
as $$
  select t.*
  from public.academic_terms t
  where t.term_sequence > p_current_sequence
  order by t.term_sequence
  limit 1;
$$;

revoke all on function private.stage13_8_nearest_next_term(integer) from public, anon, authenticated;

create or replace function private.stage13_8_group_semester(
  p_group_id uuid,
  p_term_id uuid,
  p_fallback integer
)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_semester integer;
begin
  if to_regclass('public.group_term_semesters') is null then
    return p_fallback;
  end if;

  execute $q$
    select gts.semester_number
    from public.group_term_semesters gts
    where gts.group_id = $1 and gts.academic_term_id = $2
    limit 1
  $q$ into v_semester using p_group_id, p_term_id;

  return coalesce(v_semester, p_fallback);
end;
$$;

revoke all on function private.stage13_8_group_semester(uuid, uuid, integer)
  from public, anon, authenticated;

create or replace function private.stage13_8_lifecycle(
  p_is_current boolean,
  p_term_sequence integer,
  p_current_sequence integer
)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_is_current, false) then 'active'
    when p_current_sequence is not null and p_term_sequence > p_current_sequence then 'planned'
    else 'completed'
  end;
$$;

revoke all on function private.stage13_8_lifecycle(boolean, integer, integer)
  from public, anon, authenticated;

create or replace function private.stage13_8_ensure_subject_chat_and_members(p_team_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chat uuid;
  v_group_id uuid;
  v_created_chat boolean := false;
begin
  if p_team_id is null then
    return false;
  end if;

  perform 1 from public.teams t where t.id = p_team_id for update;

  select c.id into v_chat
  from public.chats c
  where c.team_id = p_team_id and c.type = 'team_main'
  limit 1;

  if v_chat is null then
    begin
      insert into public.chats(team_id, type)
      values (p_team_id, 'team_main')
      returning id into v_chat;
      v_created_chat := true;
    exception when unique_violation then
      select c.id into v_chat
      from public.chats c
      where c.team_id = p_team_id and c.type = 'team_main'
      limit 1;
    end;
  end if;

  select t.group_id into v_group_id
  from public.teams t
  where t.id = p_team_id;

  if v_group_id is not null then
    -- Drop stale student memberships (member/starosta/etc.) without active enrollment.
    -- Keep only non-student accounts (e.g. teachers) that are not student-linked.
    if v_chat is not null then
      delete from public.chat_members cm
      using public.team_members tm
      where cm.chat_id = v_chat
        and cm.user_id = tm.user_id
        and tm.team_id = p_team_id
        and private.stage13_5_is_student_account(tm.user_id)
        and not exists (
          select 1
          from public.student_enrollments se
          where se.user_id = tm.user_id
            and se.group_id = v_group_id
            and se.status = 'active'
            and se.ended_at is null
        );
    end if;

    delete from public.team_members tm
    where tm.team_id = p_team_id
      and private.stage13_5_is_student_account(tm.user_id)
      and not exists (
        select 1
        from public.student_enrollments se
        where se.user_id = tm.user_id
          and se.group_id = v_group_id
          and se.status = 'active'
          and se.ended_at is null
      );

    insert into public.team_members(team_id, user_id, role)
    select p_team_id, se.user_id, 'member'
    from public.student_enrollments se
    where se.group_id = v_group_id
      and se.status = 'active'
      and se.ended_at is null
      and not exists (
        select 1
        from public.team_members tm
        where tm.team_id = p_team_id and tm.user_id = se.user_id
      )
    on conflict do nothing;
  end if;

  if v_chat is not null then
    insert into public.chat_members(chat_id, user_id, role_in_chat)
    select v_chat, tm.user_id, 'member'
    from public.team_members tm
    where tm.team_id = p_team_id
      and not exists (
        select 1
        from public.chat_members cm
        where cm.chat_id = v_chat and cm.user_id = tm.user_id
      )
    on conflict do nothing;
  end if;

  return v_created_chat;
end;
$$;

revoke all on function private.stage13_8_ensure_subject_chat_and_members(uuid)
  from public, anon, authenticated;

create or replace function private.stage13_8_term_counts(p_term_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_year uuid;
  v_semester integer;
  v_groups integer := 0;
  v_expected_subjects integer := 0;
  v_existing_subjects integer := 0;
  v_missing_subjects integer := 0;
  v_existing_chats integer := 0;
  v_missing_chats integer := 0;
  v_ready_chats integer := 0;
begin
  select academic_year_id, term_in_year
  into v_year, v_semester
  from public.academic_terms
  where id = p_term_id;

  if v_year is null then
    raise exception 'term_not_found' using errcode = 'P0002';
  end if;

  select count(*)::integer into v_groups
  from public.groups g
  where exists (
    select 1
    from public.student_enrollments se
    where se.group_id = g.id and se.status = 'active' and se.ended_at is null
  );

  if to_regclass('public.curriculum_subjects') is not null
     and to_regclass('public.subject_offerings') is not null then
    select count(*)::integer into v_expected_subjects
    from public.groups g
    join public.curriculum_subjects cs
      on cs.semester_number = private.stage13_8_group_semester(g.id, p_term_id, v_semester)
    where exists (
      select 1
      from public.student_enrollments se
      where se.group_id = g.id and se.status = 'active' and se.ended_at is null
    );

    select count(*)::integer into v_existing_subjects
    from public.subject_offerings so
    where so.academic_term_id = p_term_id
      and so.status = 'active';

    select count(*)::integer into v_missing_subjects
    from public.groups g
    join public.curriculum_subjects cs
      on cs.semester_number = private.stage13_8_group_semester(g.id, p_term_id, v_semester)
    where exists (
      select 1
      from public.student_enrollments se
      where se.group_id = g.id and se.status = 'active' and se.ended_at is null
    )
      and not exists (
        select 1
        from public.subject_offerings so
        where so.group_id = g.id
          and so.subject_id = cs.subject_id
          and so.academic_term_id = p_term_id
      );

    select count(*)::integer into v_existing_chats
    from public.teams t
    join public.chats c on c.team_id = t.id and c.type = 'team_main'
    where t.academic_term_id = p_term_id
      and t.kind = 'subject';

    select count(*)::integer into v_missing_chats
    from public.subject_offerings so
    where so.academic_term_id = p_term_id
      and so.status = 'active'
      and (
        not exists (
          select 1 from public.teams t where t.subject_offering_id = so.id and t.kind = 'subject'
        )
        or exists (
          select 1
          from public.teams t
          where t.subject_offering_id = so.id
            and t.kind = 'subject'
            and not exists (
              select 1 from public.chats c where c.team_id = t.id and c.type = 'team_main'
            )
        )
        or exists (
          select 1
          from public.teams t
          where t.subject_offering_id = so.id
            and t.kind = 'subject'
            and not exists (
              select 1
              from public.team_members tm
              join public.student_enrollments se
                on se.user_id = tm.user_id
               and se.group_id = so.group_id
               and se.status = 'active'
               and se.ended_at is null
              where tm.team_id = t.id
            )
            and exists (
              select 1
              from public.student_enrollments se
              where se.group_id = so.group_id
                and se.status = 'active'
                and se.ended_at is null
            )
        )
      );

    -- Also count offerings that will be created and still need chats.
    v_missing_chats := v_missing_chats + v_missing_subjects;

    select count(*)::integer into v_ready_chats
    from public.teams t
    join public.chats c on c.team_id = t.id and c.type = 'team_main'
    where t.academic_term_id = p_term_id
      and t.kind = 'subject'
      and exists (select 1 from public.team_members tm where tm.team_id = t.id);
  end if;

  return jsonb_build_object(
    'term_id', p_term_id,
    'groups_count', v_groups,
    'subjects_count', v_existing_subjects,
    'subject_chats_count', v_existing_chats,
    'ready_subject_chats_count', v_ready_chats,
    'expected_subjects', v_expected_subjects,
    'missing_subjects', v_missing_subjects,
    'missing_subject_chats', v_missing_chats,
    'readiness_percent', case
      when v_expected_subjects <= 0 then 100
      else greatest(
        0,
        least(
          100,
          round(
            100.0 * (
              (v_expected_subjects - v_missing_subjects)
              + (v_expected_subjects - least(v_missing_chats, v_expected_subjects))
            ) / (v_expected_subjects * 2.0)
          )::integer
        )
      )
    end
  );
end;
$$;

revoke all on function private.stage13_8_term_counts(uuid) from public, anon, authenticated;

create or replace function private.stage13_8_transition_blockers(p_term_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_current public.academic_terms%rowtype;
  v_target public.academic_terms%rowtype;
  v_next public.academic_terms%rowtype;
  v_current_count integer := 0;
  v_counts jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_ambiguous boolean := false;
begin
  select count(*)::integer into v_current_count
  from public.academic_terms
  where is_current = true;

  if v_current_count <> 1 then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'current_not_unique',
      'message', 'Должен существовать ровно один текущий семестр'
    ));
  end if;

  v_current := private.stage13_8_current_term();
  if v_current.id is null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'current_missing',
      'message', 'Текущий семестр не найден'
    ));
    return jsonb_build_object('blockers', v_blockers, 'ok', false);
  end if;

  select * into v_target from public.academic_terms where id = p_term_id;
  if not found then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'term_not_found',
      'message', 'Целевой семестр не найден'
    ));
    return jsonb_build_object('blockers', v_blockers, 'ok', false);
  end if;

  if v_target.starts_on is null or v_target.ends_on is null or v_target.ends_on < v_target.starts_on then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'invalid_dates',
      'message', 'У целевого семестра некорректные даты'
    ));
  end if;

  if v_target.starts_on <= v_current.starts_on
     or v_target.term_sequence <= v_current.term_sequence then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'not_forward',
      'message', 'Переход допускается только вперёд'
    ));
  end if;

  if v_target.starts_on <= v_current.ends_on then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'overlapping_term',
      'message', 'Новый семестр должен начинаться после окончания текущего'
    ));
  end if;

  v_next := private.stage13_8_nearest_next_term(v_current.term_sequence);
  if v_next.id is null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'next_missing',
      'message', 'Следующий семестр ещё не создан'
    ));
  elsif v_next.id is distinct from v_target.id then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'not_nearest_next',
      'message', 'Можно активировать только ближайший следующий семестр',
      'nearest_next_id', v_next.id,
      'nearest_next_name', v_next.name
    ));
  end if;

  if not exists (select 1 from public.academic_years ay where ay.id = v_target.academic_year_id) then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'year_missing',
      'message', 'У целевого семестра отсутствует учебный год'
    ));
  end if;

  v_counts := private.stage13_8_term_counts(p_term_id);
  if coalesce((v_counts->>'expected_subjects')::integer, 0) = 0 then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'curriculum_empty',
      'message', 'Нет учебного плана для подготовки предметов нового семестра'
    ));
  end if;

  if to_regclass('public.group_term_semesters') is not null then
    execute $q$
      select exists (
        select 1
        from public.groups g
        where exists (
          select 1 from public.student_enrollments se
          where se.group_id = g.id and se.status = 'active' and se.ended_at is null
        )
          and (
            select count(*)
            from public.group_term_semesters gts
            where gts.group_id = g.id and gts.academic_term_id = $1
          ) > 1
      )
    $q$ into v_ambiguous using p_term_id;
    if v_ambiguous then
      v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
        'code', 'ambiguous_group_term_mapping',
        'message', 'У группы несколько semester mapping для целевого периода'
      ));
    end if;
  end if;

  if exists (
    select 1
    from public.subject_offerings so
    where so.academic_term_id = p_term_id
    group by so.group_id, so.subject_id
    having count(*) > 1
  ) then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'duplicate_offerings',
      'message', 'Найдены дубликаты предметов в целевом периоде'
    ));
  end if;

  if exists (
    select 1
    from public.teams t
    where t.academic_term_id = p_term_id
      and t.kind = 'subject'
      and t.subject_offering_id is not null
    group by t.subject_offering_id
    having count(*) > 1
  ) then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'duplicate_subject_teams',
      'message', 'Найдены дубликаты предметных чатов в целевом периоде'
    ));
  end if;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_blockers) = 0,
    'blockers', v_blockers,
    'current_term_id', v_current.id,
    'current_term_name', v_current.name,
    'target_term_id', v_target.id,
    'target_term_name', v_target.name,
    'counts', v_counts
  );
end;
$$;

revoke all on function private.stage13_8_transition_blockers(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Public read / readiness RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_terms()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_current public.academic_terms%rowtype;
begin
  if not (
    private.stage13_5_can('terms.manage')
    or private.stage13_5_can('academic.read')
    or private.stage13_5_can('students.read')
  ) then
    return '[]'::jsonb;
  end if;

  v_current := private.stage13_8_current_term();

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', t.id,
          'academic_year_id', t.academic_year_id,
          'name', coalesce(t.name, ay.name || ' · ' || t.term_in_year::text),
          'term_in_year', t.term_in_year,
          'term_sequence', t.term_sequence,
          'is_current', coalesce(t.is_current, false),
          'lifecycle', private.stage13_8_lifecycle(
            t.is_current, t.term_sequence, v_current.term_sequence
          ),
          'starts_on', t.starts_on,
          'ends_on', t.ends_on,
          'year_name', ay.name,
          'auto_activation_enabled', coalesce(t.auto_activation_enabled, false),
          'is_nearest_next', (
            v_current.id is not null
            and t.id = (
              select n.id
              from public.academic_terms n
              where n.term_sequence > v_current.term_sequence
              order by n.term_sequence
              limit 1
            )
          )
        )
        order by t.term_sequence nulls last, t.starts_on nulls last
      )
      from public.academic_terms t
      left join public.academic_years ay on ay.id = t.academic_year_id
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.admin_term_readiness(p_term_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_current public.academic_terms%rowtype;
  v_next public.academic_terms%rowtype;
  v_term public.academic_terms%rowtype;
  v_counts jsonb;
  v_blockers jsonb;
  v_days_to_start integer;
begin
  perform private.stage13_8_require_terms_manage();

  v_current := private.stage13_8_current_term();
  if v_current.id is null then
    raise exception 'current_term_missing' using errcode = 'P0001';
  end if;

  if p_term_id is null then
    v_next := private.stage13_8_nearest_next_term(v_current.term_sequence);
    if v_next.id is null then
      v_term := v_current;
    else
      v_term := v_next;
    end if;
  else
    select * into v_term from public.academic_terms where id = p_term_id;
    if not found then
      raise exception 'term_not_found' using errcode = 'P0002';
    end if;
  end if;

  v_counts := private.stage13_8_term_counts(v_term.id);
  v_blockers := private.stage13_8_transition_blockers(v_term.id);
  v_days_to_start := (v_term.starts_on - (timezone('utc', now()))::date);

  return jsonb_build_object(
    'term_id', v_term.id,
    'term_name', v_term.name,
    'lifecycle', private.stage13_8_lifecycle(
      v_term.is_current, v_term.term_sequence, v_current.term_sequence
    ),
    'starts_on', v_term.starts_on,
    'ends_on', v_term.ends_on,
    'days_to_start', v_days_to_start,
    'approaching', v_days_to_start is not null and v_days_to_start <= 45 and v_days_to_start >= -14,
    'automation_active', false,
    'auto_activation_enabled', coalesce(v_term.auto_activation_enabled, false),
    'notification', case
      when v_term.id = v_current.id then null
      else format(
        '%s подготовлена на %s%%. Не хватает %s предметов и %s предметных чатов.',
        v_term.name,
        coalesce(v_counts->>'readiness_percent', '0'),
        coalesce(v_counts->>'missing_subjects', '0'),
        coalesce(v_counts->>'missing_subject_chats', '0')
      )
    end,
    'counts', v_counts,
    'transition', v_blockers
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) Safe backfill (never changes current, never archives)
-- ---------------------------------------------------------------------------
create or replace function public.admin_term_backfill_dry_run(p_term_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_counts jsonb;
  v_current public.academic_terms%rowtype;
  v_term public.academic_terms%rowtype;
begin
  perform private.stage13_8_require_terms_manage();

  select * into v_term from public.academic_terms where id = p_term_id;
  if not found then
    raise exception 'term_not_found' using errcode = 'P0002';
  end if;

  v_current := private.stage13_8_current_term();
  v_counts := private.stage13_8_term_counts(p_term_id);

  return jsonb_build_object(
    'term_id', p_term_id,
    'term_name', v_term.name,
    'lifecycle', private.stage13_8_lifecycle(
      v_term.is_current, v_term.term_sequence, v_current.term_sequence
    ),
    'groups_count', (v_counts->>'groups_count')::integer,
    'missing_subjects', (v_counts->>'missing_subjects')::integer,
    'missing_subject_chats', (v_counts->>'missing_subject_chats')::integer,
    'subjects_count', (v_counts->>'subjects_count')::integer,
    'subject_chats_count', (v_counts->>'subject_chats_count')::integer,
    'readiness_percent', (v_counts->>'readiness_percent')::integer,
    'current_unchanged', true,
    'chats_not_archived', true,
    'message', 'Текущий семестр и действующие чаты не изменятся'
  );
end;
$$;

create or replace function public.admin_term_backfill(p_term_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  dry jsonb;
  v_payload_hash text;
  b uuid;
  created_subjects integer := 0;
  created_teams integer := 0;
  created_chats integer := 0;
  synced_members integer := 0;
  synced_spaces integer := 0;
  v_year uuid;
  v_semester integer;
  v_before_current uuid;
  v_after_current uuid;
  v_archive_before integer;
  v_archive_after integer;
  v_counts_after jsonb;
  g record;
  cs record;
  so_id uuid;
  v_team_id uuid;
  chat_before boolean;
  v_had_prior_batch boolean := false;
begin
  perform private.stage13_8_require_terms_manage();
  perform private.stage13_8_acquire_lifecycle_lock();

  select id into v_before_current from public.academic_terms where is_current limit 1;
  select count(*)::integer into v_archive_before from public.chat_academic_archives;

  dry := public.admin_term_backfill_dry_run(p_term_id);
  -- Journal hash is per-run timestamped so prior batches never skip reconciliation.
  v_payload_hash := md5(
    p_term_id::text || ':term_backfill:v2:' || clock_timestamp()::text || ':' || auth.uid()::text
  );

  select exists (
    select 1
    from public.admin_term_ops_batches tb
    where tb.operation = 'term_backfill'
      and tb.status = 'applied'
      and tb.summary->>'term_id' = p_term_id::text
  ) into v_had_prior_batch;

  insert into public.admin_term_ops_batches(created_by, operation, status, payload_hash, summary)
  values (
    auth.uid(),
    'term_backfill',
    'applied',
    v_payload_hash,
    dry || jsonb_build_object('payload_hash', v_payload_hash)
  )
  returning id into b;

  select academic_year_id, term_in_year into v_year, v_semester
  from public.academic_terms
  where id = p_term_id;

  if to_regclass('public.curriculum_subjects') is not null then
    for g in
      select gr.id, gr.name
      from public.groups gr
      where exists (
        select 1
        from public.student_enrollments se
        where se.group_id = gr.id and se.status = 'active' and se.ended_at is null
      )
    loop
      for cs in
        select *
        from public.curriculum_subjects csub
        where csub.semester_number = private.stage13_8_group_semester(
          g.id, p_term_id, v_semester
        )
      loop
        select so.id into so_id
        from public.subject_offerings so
        where so.group_id = g.id
          and so.subject_id = cs.subject_id
          and so.academic_term_id = p_term_id
        limit 1;

        if so_id is null then
          insert into public.subject_offerings(
            subject_id, curriculum_subject_id, group_id, academic_year_id,
            academic_term_id, semester_number, display_name, status
          ) values (
            cs.subject_id, cs.id, g.id, v_year, p_term_id, cs.semester_number,
            coalesce(cs.display_name, cs.raw_subject_name, 'Предмет'), 'active'
          )
          on conflict do nothing
          returning id into so_id;

          if so_id is not null then
            created_subjects := created_subjects + 1;
          else
            select so.id into so_id
            from public.subject_offerings so
            where so.group_id = g.id
              and so.subject_id = cs.subject_id
              and so.academic_term_id = p_term_id
            limit 1;
          end if;
        end if;

        if so_id is null then
          continue;
        end if;

        select t.id into v_team_id
        from public.teams t
        where t.subject_offering_id = so_id and t.kind = 'subject'
        limit 1;

        if v_team_id is null then
          insert into public.teams(
            name, description, teacher, icon, group_name, group_id, subject_id,
            subject_offering_id, academic_year_id, academic_term_id, semester_number, kind
          )
          select
            coalesce(so.display_name, 'Предмет'),
            '',
            '',
            '',
            g.name,
            so.group_id,
            so.subject_id,
            so.id,
            so.academic_year_id,
            so.academic_term_id,
            so.semester_number,
            'subject'
          from public.subject_offerings so
          where so.id = so_id
          returning id into v_team_id;

          if v_team_id is not null then
            created_teams := created_teams + 1;
          end if;
        end if;

        if v_team_id is not null then
          select exists (
            select 1 from public.chats c where c.team_id = v_team_id and c.type = 'team_main'
          ) into chat_before;

          perform private.stage13_8_ensure_subject_chat_and_members(v_team_id);

          if not chat_before
             and exists (
               select 1 from public.chats c where c.team_id = v_team_id and c.type = 'team_main'
             ) then
            created_chats := created_chats + 1;
          end if;

          synced_members := synced_members + 1;
        end if;
      end loop;

      perform public.admin_ensure_group_space_for_group(g.id);
      synced_spaces := synced_spaces + 1;
    end loop;
  end if;

  select id into v_after_current from public.academic_terms where is_current limit 1;
  select count(*)::integer into v_archive_after from public.chat_academic_archives;
  v_counts_after := private.stage13_8_term_counts(p_term_id);

  if v_after_current is distinct from v_before_current then
    raise exception 'backfill_changed_current' using errcode = 'P0001';
  end if;
  if v_archive_after <> v_archive_before then
    raise exception 'backfill_archived_chats' using errcode = 'P0001';
  end if;

  update public.admin_term_ops_batches
  set summary = dry || jsonb_build_object(
    'payload_hash', v_payload_hash,
    'term_id', p_term_id,
    'created_subjects', created_subjects,
    'created_teams', created_teams,
    'created_subject_chats', created_chats,
    'synced_membership_teams', synced_members,
    'synced_group_spaces', synced_spaces,
    'counts_after', v_counts_after,
    'current_unchanged', true,
    'chats_not_archived', true
  )
  where id = b;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'term.backfill',
      'academic_term',
      p_term_id::text,
      jsonb_build_object(
        'batch_id', b,
        'created_subjects', created_subjects,
        'created_subject_chats', created_chats,
        'current_unchanged', true,
        'reconciled', true
      )
    );
  end if;

  return jsonb_build_object(
    'batch_id', b,
    'idempotent_replay', v_had_prior_batch
      and created_subjects = 0
      and created_teams = 0
      and created_chats = 0,
    'created_subjects', created_subjects,
    'created_teams', created_teams,
    'created_subject_chats', created_chats,
    'synced_group_spaces', synced_spaces,
    'missing_subjects_after', (v_counts_after->>'missing_subjects')::integer,
    'missing_subject_chats_after', (v_counts_after->>'missing_subject_chats')::integer,
    'current_unchanged', true,
    'chats_not_archived', true
  );
end;
$$;

-- Compatibility wrappers for Stage 13.5 names.
create or replace function public.admin_prepare_term_dry_run(p_term_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  dry jsonb;
begin
  dry := public.admin_term_backfill_dry_run(p_term_id);
  return dry || jsonb_build_object(
    'missing_offerings', dry->'missing_subjects',
    'missing_teams', dry->'missing_subject_chats',
    'academic_year_id', (select academic_year_id from public.academic_terms where id = p_term_id)
  );
end;
$$;

create or replace function public.admin_prepare_term_apply(
  p_term_id uuid,
  p_set_current boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if coalesce(p_set_current, false) then
    raise exception 'set_current_forbidden_use_admin_start_next_term'
      using errcode = 'P0001';
  end if;

  result := public.admin_term_backfill(p_term_id);
  return result || jsonb_build_object(
    'created_offerings', result->'created_subjects',
    'created_teams', result->'created_teams',
    'set_current', false
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) Forward-only transition
-- ---------------------------------------------------------------------------
create or replace function public.admin_start_next_term_dry_run(p_term_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current public.academic_terms%rowtype;
  v_target public.academic_terms%rowtype;
  v_check jsonb;
  v_archive_count integer := 0;
  v_group_space_count integer := 0;
begin
  perform private.stage13_8_require_terms_manage();
  perform private.stage13_8_acquire_lifecycle_lock();

  v_check := private.stage13_8_transition_blockers(p_term_id);
  v_current := private.stage13_8_current_term();
  select * into v_target from public.academic_terms where id = p_term_id;

  if v_current.id is not null and v_target.id = v_current.id then
    return jsonb_build_object(
      'idempotent_replay', true,
      'ok', true,
      'current_term_id', v_current.id,
      'current_term_name', v_current.name,
      'new_term_id', v_target.id,
      'new_term_name', v_target.name,
      'archivable_subject_chats', 0,
      'group_space_chats_preserved', true,
      'automation_active', false
    );
  end if;

  if v_current.id is not null then
    select count(*)::integer into v_archive_count
    from public.chats c
    join public.teams t on t.id = c.team_id
    left join public.subject_offerings so
      on so.id = coalesce(t.subject_offering_id, c.subject_offering_id)
    where c.type = 'team_main'
      and t.kind <> 'group_space'
      and coalesce(t.academic_term_id, so.academic_term_id) = v_current.id;

    select count(*)::integer into v_group_space_count
    from public.chats c
    join public.teams t on t.id = c.team_id
    where c.type = 'team_main' and t.kind = 'group_space';
  end if;

  return jsonb_build_object(
    'idempotent_replay', false,
    'ok', coalesce((v_check->>'ok')::boolean, false),
    'blockers', coalesce(v_check->'blockers', '[]'::jsonb),
    'current_term_id', v_current.id,
    'current_term_name', v_current.name,
    'new_term_id', v_target.id,
    'new_term_name', v_target.name,
    'archivable_subject_chats', v_archive_count,
    'group_space_chats_preserved', true,
    'group_space_chats_count', v_group_space_count,
    'will_create_subjects', coalesce((v_check->'counts'->>'missing_subjects')::integer, 0),
    'will_create_subject_chats', coalesce((v_check->'counts'->>'missing_subject_chats')::integer, 0),
    'readiness_percent', coalesce((v_check->'counts'->>'readiness_percent')::integer, 0),
    'schedule_context_switches', true,
    'automation_active', false,
    'confirm_name_required', v_target.name
  );
end;
$$;

create or replace function public.admin_start_next_term(
  p_term_id uuid,
  p_confirm_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current public.academic_terms%rowtype;
  v_target public.academic_terms%rowtype;
  v_check jsonb;
  dry jsonb;
  backfill jsonb;
  v_counts jsonb;
  v_archived integer := 0;
  v_payload_hash text;
  b uuid;
  v_group_space_archived integer := 0;
begin
  perform private.stage13_8_require_terms_manage();
  perform private.stage13_8_acquire_lifecycle_lock();

  if (select count(*)::integer from public.academic_terms where is_current = true) <> 1 then
    raise exception 'current_not_unique' using errcode = 'P0001';
  end if;

  v_current := private.stage13_8_current_term();
  select * into v_target from public.academic_terms where id = p_term_id;
  if not found then
    raise exception 'term_not_found' using errcode = 'P0002';
  end if;

  if v_target.is_current then
    return jsonb_build_object(
      'idempotent_replay', true,
      'new_term_id', v_target.id,
      'new_term_name', v_target.name,
      'archived_subject_chats', 0,
      'group_space_preserved', true
    );
  end if;

  v_check := private.stage13_8_transition_blockers(p_term_id);
  if not coalesce((v_check->>'ok')::boolean, false) then
    raise exception 'term_transition_blocked: %', v_check->>'blockers'
      using errcode = 'P0001';
  end if;

  if btrim(coalesce(p_confirm_name, '')) is distinct from v_target.name then
    raise exception 'confirm_name_mismatch' using errcode = '22023';
  end if;

  -- Preview without nested lock acquisition (already held).
  dry := jsonb_build_object(
    'ok', true,
    'current_term_id', v_current.id,
    'current_term_name', v_current.name,
    'new_term_id', v_target.id,
    'new_term_name', v_target.name,
    'will_create_subjects', coalesce((v_check->'counts'->>'missing_subjects')::integer, 0),
    'will_create_subject_chats', coalesce((v_check->'counts'->>'missing_subject_chats')::integer, 0),
    'readiness_percent', coalesce((v_check->'counts'->>'readiness_percent')::integer, 0),
    'confirm_name_required', v_target.name,
    'automation_active', false
  );
  v_payload_hash := md5(
    v_current.id::text || '->' || p_term_id::text || ':start_next_term:v1'
  );

  select tb.id into b
  from public.admin_term_ops_batches tb
  where tb.operation = 'term_start_next'
    and tb.status = 'applied'
    and tb.payload_hash = v_payload_hash
  order by tb.created_at desc
  limit 1;

  if b is not null then
    return jsonb_build_object(
      'batch_id', b,
      'idempotent_replay', true,
      'summary', (select summary from public.admin_term_ops_batches where id = b)
    );
  end if;

  insert into public.admin_term_ops_batches(created_by, operation, status, payload_hash, summary)
  values (
    auth.uid(),
    'term_start_next',
    'applied',
    v_payload_hash,
    dry || jsonb_build_object('payload_hash', v_payload_hash)
  )
  returning id into b;

  -- Create missing data for the new term before flipping current.
  -- Nested call shares the same xact advisory lock.
  backfill := public.admin_term_backfill(p_term_id);

  v_counts := private.stage13_8_term_counts(p_term_id);
  v_check := private.stage13_8_transition_blockers(p_term_id);
  if coalesce((v_counts->>'missing_subjects')::integer, 0) > 0
     or coalesce((v_counts->>'missing_subject_chats')::integer, 0) > 0
     or not coalesce((v_check->>'ok')::boolean, false)
  then
    raise exception 'term_not_ready_after_backfill: %', v_counts
      using errcode = 'P0001';
  end if;

  perform set_config('private.allow_term_current_flip', '1', true);

  update public.academic_terms
  set is_current = false
  where id = v_current.id;

  update public.academic_terms
  set is_current = true
  where id = p_term_id;

  perform set_config('private.allow_term_current_flip', '0', true);

  -- Archive only the previous current term's subject chats.
  v_archived := public.archive_academic_chats_for_term(v_current.id);

  -- Safety: group_space must never be archived by this operation.
  select count(*)::integer into v_group_space_archived
  from public.chat_academic_archives caa
  join public.chats c on c.id = caa.chat_id
  join public.teams t on t.id = c.team_id
  where caa.academic_term_id = v_current.id
    and t.kind = 'group_space';

  if v_group_space_archived > 0 then
    raise exception 'group_space_archive_forbidden' using errcode = 'P0001';
  end if;

  if (select count(*) from public.academic_terms where is_current) <> 1 then
    raise exception 'current_invariant_broken' using errcode = 'P0001';
  end if;

  update public.admin_term_ops_batches
  set summary = dry || jsonb_build_object(
    'payload_hash', v_payload_hash,
    'previous_term_id', v_current.id,
    'previous_term_name', v_current.name,
    'new_term_id', v_target.id,
    'new_term_name', v_target.name,
    'archived_subject_chats', v_archived,
    'backfill', backfill,
    'group_space_preserved', true
  )
  where id = b;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'term.start_next',
      'academic_term',
      p_term_id::text,
      jsonb_build_object(
        'batch_id', b,
        'previous_term_id', v_current.id,
        'previous_term_name', v_current.name,
        'new_term_id', v_target.id,
        'new_term_name', v_target.name,
        'archived_subject_chats', v_archived,
        'created_subjects', backfill->'created_subjects',
        'created_subject_chats', backfill->'created_subject_chats',
        'readiness', dry->'readiness_percent',
        'actor', auth.uid()
      )
    );
  end if;

  return jsonb_build_object(
    'batch_id', b,
    'idempotent_replay', false,
    'previous_term_id', v_current.id,
    'previous_term_name', v_current.name,
    'new_term_id', v_target.id,
    'new_term_name', v_target.name,
    'archived_subject_chats', v_archived,
    'created_subjects', backfill->'created_subjects',
    'created_subject_chats', backfill->'created_subject_chats',
    'group_space_preserved', true
  );
end;
$$;

-- Old direct setter is no longer a safe public path.
create or replace function public.admin_set_current_term(p_term_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.stage13_8_require_terms_manage();
  raise exception 'use_admin_start_next_term'
    using errcode = 'P0001',
          hint = 'Переход на новый семестр только через admin_start_next_term';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) Grants
-- ---------------------------------------------------------------------------
revoke all on function
  public.admin_list_terms(),
  public.admin_term_readiness(uuid),
  public.admin_term_backfill_dry_run(uuid),
  public.admin_term_backfill(uuid),
  public.admin_prepare_term_dry_run(uuid),
  public.admin_prepare_term_apply(uuid, boolean),
  public.admin_start_next_term_dry_run(uuid),
  public.admin_start_next_term(uuid, text),
  public.admin_set_current_term(uuid)
from public, anon;

grant execute on function
  public.admin_list_terms(),
  public.admin_term_readiness(uuid),
  public.admin_term_backfill_dry_run(uuid),
  public.admin_term_backfill(uuid),
  public.admin_prepare_term_dry_run(uuid),
  public.admin_prepare_term_apply(uuid, boolean),
  public.admin_start_next_term_dry_run(uuid),
  public.admin_start_next_term(uuid, text),
  public.admin_set_current_term(uuid)
to authenticated, service_role;

commit;
