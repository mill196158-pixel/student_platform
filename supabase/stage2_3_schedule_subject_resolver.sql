-- Stage 2.3: schedule subject resolver/linker and parser test seed.
-- This is not a table migration. It creates/replaces functions and adds
-- clearly marked dev/test data for parser-link verification.

begin;

create or replace function public.f_norm_schedule_subject(t text)
returns text
language sql
immutable
as $$
  with raw as (
    select lower(trim(coalesce(t, ''))) as s
  ),
  without_teams as (
    select regexp_replace(
      s,
      '\s+(?:teams?|команда|код\s+команды)\s+[[:alnum:]_-]+(?:\s+[[:alnum:]_-]+)?\s*$',
      '',
      'gi'
    ) as s
    from raw
  ),
  title_norm as (
    select regexp_replace(public.f_norm_title(s), '[()]', ' ', 'g') as s
    from without_teams
  ),
  no_trailing_type_1 as (
    select regexp_replace(
      s,
      '\s+(?:практическое\s+занятие|лабораторная|семинар|практика|лекция|экзамен|зач[её]т|сем|лаб|пр|л)\s*$',
      '',
      'gi'
    ) as s
    from title_norm
  ),
  no_trailing_type_2 as (
    select regexp_replace(
      s,
      '\s+(?:практическое\s+занятие|лабораторная|семинар|практика|лекция|экзамен|зач[её]т|сем|лаб|пр|л)\s*$',
      '',
      'gi'
    ) as s
    from no_trailing_type_1
  )
  select trim(regexp_replace(s, '\s+', ' ', 'g'))
  from no_trailing_type_2
$$;

create or replace function public.resolve_subject_offering_for_schedule(
  p_group_id uuid,
  p_raw_subject text,
  p_lesson_date date default null,
  p_semester_number integer default null
)
returns table (
  subject_id uuid,
  subject_offering_id uuid,
  match_status text,
  normalized_input text,
  matched_alias text,
  candidates_count integer,
  reason text
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_normalized text;
  v_semester integer;
  v_academic_term_id uuid;
  v_academic_year_id uuid;
begin
  v_normalized := public.f_norm_schedule_subject(p_raw_subject);

  if p_group_id is null then
    return query
    select null::uuid, null::uuid, 'no_group'::text, v_normalized,
           null::text, 0::integer, 'group_id is required'::text;
    return;
  end if;

  if nullif(v_normalized, '') is null then
    return query
    select null::uuid, null::uuid, 'not_found'::text, v_normalized,
           null::text, 0::integer, 'empty normalized subject'::text;
    return;
  end if;

  if p_semester_number is not null then
    v_semester := p_semester_number;
  elsif p_lesson_date is not null then
    select
      gts.semester_number,
      gts.academic_term_id,
      gts.academic_year_id
    into v_semester, v_academic_term_id, v_academic_year_id
    from public.group_term_semesters gts
    join public.academic_terms at on at.id = gts.academic_term_id
    where gts.group_id = p_group_id
      and p_lesson_date >= at.starts_on
      and p_lesson_date <= at.ends_on
    order by at.is_current desc, at.starts_on desc
    limit 1;
  end if;

  if p_semester_number is not null then
    select
      gts.academic_term_id,
      gts.academic_year_id
    into v_academic_term_id, v_academic_year_id
    from public.group_term_semesters gts
    where gts.group_id = p_group_id
      and gts.semester_number = p_semester_number
    order by gts.created_at desc
    limit 1;
  end if;

  if v_semester is null then
    return query
    select null::uuid, null::uuid, 'no_term'::text, v_normalized,
           null::text, 0::integer, 'semester could not be resolved'::text;
    return;
  end if;

  return query
  with raw_candidate_matches as (
    select
      so.subject_id,
      so.id as subject_offering_id,
      coalesce(sa.alias, sc.canonical_name, so.display_name) as matched_alias
    from public.subject_offerings so
    join public.subject_catalog sc on sc.id = so.subject_id
    left join public.subject_aliases sa on sa.subject_id = sc.id
    left join public.curriculum_subjects cs on cs.id = so.curriculum_subject_id
    where so.group_id = p_group_id
      and so.semester_number = v_semester
      and (v_academic_term_id is null or so.academic_term_id = v_academic_term_id)
      and (
        public.f_norm_schedule_subject(sc.canonical_name) = v_normalized
        or public.f_norm_schedule_subject(sc.normalized_name) = v_normalized
        or public.f_norm_schedule_subject(so.display_name) = v_normalized
        or public.f_norm_schedule_subject(cs.display_name) = v_normalized
        or public.f_norm_schedule_subject(cs.raw_subject_name) = v_normalized
        or public.f_norm_schedule_subject(sa.alias) = v_normalized
        or public.f_norm_schedule_subject(sa.normalized_alias) = v_normalized
      )
  ),
  candidate_matches as (
    select
      rcm.subject_id,
      rcm.subject_offering_id,
      min(rcm.matched_alias) as matched_alias
    from raw_candidate_matches
    group by rcm.subject_id, rcm.subject_offering_id
  ),
  counts as (
    select count(*)::integer as cnt
    from candidate_matches
  )
  select
    case when counts.cnt = 1 then cm.subject_id else null::uuid end,
    case when counts.cnt = 1 then cm.subject_offering_id else null::uuid end,
    case
      when counts.cnt = 1 then 'matched'
      when counts.cnt = 0 then 'not_found'
      else 'ambiguous'
    end::text,
    v_normalized,
    case when counts.cnt = 1 then cm.matched_alias else null::text end,
    counts.cnt,
    case
      when counts.cnt = 1 then 'single subject_offering match'
      when counts.cnt = 0 then 'no subject_offering matched normalized input'
      else 'multiple subject_offerings matched normalized input'
    end::text
  from counts
  left join candidate_matches cm on counts.cnt = 1;
end;
$$;

create or replace function public.link_lesson_subject_from_schedule(
  p_lesson_id uuid
)
returns table (
  lesson_id uuid,
  match_status text,
  subject_id uuid,
  subject_offering_id uuid,
  reason text
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_lesson record;
  v_res record;
begin
  select *
  into v_lesson
  from public.lessons
  where id = p_lesson_id;

  if not found then
    return query
    select p_lesson_id, 'not_found'::text, null::uuid, null::uuid,
           'lesson not found'::text;
    return;
  end if;

  select *
  into v_res
  from public.resolve_subject_offering_for_schedule(
    v_lesson.group_id,
    coalesce(v_lesson.raw_subject_name, v_lesson.subject),
    v_lesson.date,
    v_lesson.semester_number
  )
  limit 1;

  if v_res.match_status = 'matched' then
    update public.lessons
    set subject_id = v_res.subject_id,
        subject_offering_id = v_res.subject_offering_id,
        normalized_subject_name = v_res.normalized_input,
        alias_match_status = 'matched'
    where id = p_lesson_id;
  elsif v_res.match_status = 'ambiguous' then
    update public.lessons
    set subject_id = null,
        subject_offering_id = null,
        normalized_subject_name = v_res.normalized_input,
        alias_match_status = 'ambiguous'
    where id = p_lesson_id;
  else
    -- lessons.alias_match_status currently allows only:
    -- matched, pending, ambiguous, ignored. It does not allow not_found/no_term.
    update public.lessons
    set subject_id = null,
        subject_offering_id = null,
        normalized_subject_name = v_res.normalized_input,
        alias_match_status = 'pending'
    where id = p_lesson_id;
  end if;

  return query
  select p_lesson_id, v_res.match_status, v_res.subject_id,
         v_res.subject_offering_id, v_res.reason;
end;
$$;

revoke all on function public.link_lesson_subject_from_schedule(uuid) from anon, authenticated;
revoke all on function public.resolve_subject_offering_for_schedule(uuid, text, date, integer) from anon, authenticated;
grant execute on function public.link_lesson_subject_from_schedule(uuid) to service_role;
grant execute on function public.resolve_subject_offering_for_schedule(uuid, text, date, integer) to service_role;

do $$
declare
  v_marker constant text := 'stage2_3_schedule_subject_resolver';
  v_year_id uuid;
  v_term_id uuid;
  v_semester int;
  v_subject_id uuid;
  v_curriculum_subject_id uuid;
  v_subject_offering_id uuid;
  v_team_id uuid;
  v_chat_id uuid;
  v_lesson_id uuid;
  r record;
  a record;
  l record;
begin
  for r in
    select *
    from (
      values
        ('1-См(ВВ)-2'::text, 'Тест парсинга пары'::text,     'PARSE-1'::text, 'Тестовый преподаватель парсинга 1'::text),
        ('2-См(ВВ)-2'::text, 'Проверка парсинга пары'::text, 'PARSE-A'::text, 'Тестовый преподаватель парсинга 2'::text)
    ) as seed(group_name, subject_name, teams_code, teacher_name)
  loop
    select
      gts.academic_year_id,
      gts.academic_term_id,
      gts.semester_number
    into v_year_id, v_term_id, v_semester
    from public.groups g
    join public.group_term_semesters gts on gts.group_id = g.id
    join public.academic_terms at on at.id = gts.academic_term_id
    where g.name = r.group_name
      and at.is_current = true
    order by gts.semester_number desc
    limit 1;

    if v_year_id is null then
      raise exception 'No current academic term found for group %', r.group_name;
    end if;

    insert into public.subject_catalog (canonical_name, normalized_name, description)
    values (r.subject_name, public.f_norm_title(r.subject_name), v_marker)
    on conflict (normalized_name) do update
      set canonical_name = excluded.canonical_name,
          description = excluded.description,
          updated_at = now();

    select id into v_subject_id
    from public.subject_catalog
    where normalized_name = public.f_norm_title(r.subject_name);

    for a in
      select *
      from (
        values
          (r.subject_name),
          (r.subject_name || ' (сем.)'),
          (r.subject_name || ' семинар'),
          (r.subject_name || ', практика'),
          (r.subject_name || ' Teams ' || r.teams_code),
          (r.subject_name || ', практика Teams ' || r.teams_code)
      ) as aliases(alias)
    loop
      insert into public.subject_aliases (subject_id, alias, normalized_alias, source)
      values (v_subject_id, a.alias, public.f_norm_title(a.alias), v_marker)
      on conflict (normalized_alias) do update
        set subject_id = excluded.subject_id,
            alias = excluded.alias,
            source = excluded.source;
    end loop;

    select id into v_curriculum_subject_id
    from public.curriculum_subjects
    where subject_id = v_subject_id
      and raw_subject_name = r.subject_name
      and display_name = r.subject_name
      and semester_number = v_semester
      and subject_index = 'STAGE2.3-TEST-' || public.f_norm_title(r.subject_name)
    limit 1;

    if v_curriculum_subject_id is null then
      insert into public.curriculum_subjects (
        subject_id,
        raw_subject_name,
        display_name,
        semester_number,
        hours_total,
        credits,
        subject_index,
        block_name,
        control_form,
        department,
        subject_type,
        subject_kind,
        is_elective
      )
      values (
        v_subject_id,
        r.subject_name,
        r.subject_name,
        v_semester,
        0,
        0,
        'STAGE2.3-TEST-' || public.f_norm_title(r.subject_name),
        'Stage 2.3 parser resolver seed',
        'test',
        'dev',
        'dev_test',
        'dev_test',
        false
      )
      returning id into v_curriculum_subject_id;
    end if;

    select so.id into v_subject_offering_id
    from public.subject_offerings so
    join public.groups g on g.id = so.group_id
    where g.name = r.group_name
      and so.subject_id = v_subject_id
      and so.curriculum_subject_id = v_curriculum_subject_id
      and so.academic_year_id = v_year_id
      and so.academic_term_id = v_term_id
      and so.semester_number = v_semester
    limit 1;

    if v_subject_offering_id is null then
      insert into public.subject_offerings (
        subject_id,
        curriculum_subject_id,
        group_id,
        academic_year_id,
        academic_term_id,
        semester_number,
        display_name,
        status
      )
      select
        v_subject_id,
        v_curriculum_subject_id,
        g.id,
        v_year_id,
        v_term_id,
        v_semester,
        r.subject_name,
        'active'
      from public.groups g
      where g.name = r.group_name
      returning id into v_subject_offering_id;
    end if;

    select id into v_team_id
    from public.teams
    where subject_offering_id = v_subject_offering_id
    limit 1;

    if v_team_id is null then
      insert into public.teams (
        name,
        description,
        teacher,
        icon,
        group_name,
        group_id,
        subject_id,
        subject_offering_id,
        academic_year_id,
        academic_term_id,
        semester_number
      )
      select
        r.subject_name,
        'Stage 2.3 test team seed: ' || v_marker,
        r.teacher_name,
        'school',
        g.name,
        g.id,
        v_subject_id,
        v_subject_offering_id,
        v_year_id,
        v_term_id,
        v_semester
      from public.groups g
      where g.name = r.group_name
      returning id into v_team_id;
    end if;

    select id into v_chat_id
    from public.chats
    where team_id = v_team_id
      and type = 'team_main'
    limit 1;

    if v_chat_id is null then
      insert into public.chats (team_id, type, subject_offering_id)
      values (v_team_id, 'team_main', v_subject_offering_id)
      on conflict do nothing;
    end if;

    update public.chats
    set subject_offering_id = v_subject_offering_id
    where team_id = v_team_id
      and type = 'team_main'
      and subject_offering_id is null;

    insert into public.team_members (team_id, user_id, role)
    select v_team_id, se.user_id, 'member'
    from public.groups g
    join public.student_enrollments se
      on se.group_id = g.id
     and se.status = 'active'
     and se.ended_at is null
    where g.name = r.group_name
    on conflict do nothing;

    select id into v_chat_id
    from public.chats
    where team_id = v_team_id
      and type = 'team_main'
    limit 1;

    if v_chat_id is not null then
      insert into public.chat_members (chat_id, user_id, role_in_chat)
      select v_chat_id, se.user_id, 'member'
      from public.groups g
      join public.student_enrollments se
        on se.group_id = g.id
       and se.status = 'active'
       and se.ended_at is null
      where g.name = r.group_name
      on conflict do nothing;
    end if;

    for l in
      select *
      from (
        values
          ('1-См(ВВ)-2'::text, 'Тест парсинга пары'::text,     date '2026-06-23', 'ВТ'::text, 1, time '09:00', time '10:30', 'Тест парсинга пары (сем.)'::text,                        'Тестовая аудитория 301'::text, 'Тестовый преподаватель парсинга 1'::text),
          ('1-См(ВВ)-2'::text, 'Тест парсинга пары'::text,     date '2026-06-23', 'ВТ'::text, 2, time '10:40', time '12:10', 'Тест парсинга пары, практика Teams PARSE-1'::text,       'Teams PARSE-1'::text,           'Тестовый преподаватель парсинга 1'::text),
          ('2-См(ВВ)-2'::text, 'Проверка парсинга пары'::text, date '2026-06-23', 'ВТ'::text, 1, time '09:00', time '10:30', 'Проверка парсинга пары (сем.)'::text,                    'Тестовая аудитория 401'::text, 'Тестовый преподаватель парсинга 2'::text),
          ('2-См(ВВ)-2'::text, 'Проверка парсинга пары'::text, date '2026-06-23', 'ВТ'::text, 2, time '10:40', time '12:10', 'Проверка парсинга пары, практика Teams PARSE-A'::text,   'Teams PARSE-A'::text,           'Тестовый преподаватель парсинга 2'::text)
      ) as lessons(group_name, subject_name, lesson_date, day_code, pair_num, time_start, time_end, raw_title, room, teacher)
      where lessons.group_name = r.group_name
        and lessons.subject_name = r.subject_name
    loop
      select existing.id into v_lesson_id
      from public.lessons existing
      join public.groups g on g.id = existing.group_id
      where g.name = l.group_name
        and existing.date = l.lesson_date
        and existing.pair_num = l.pair_num
        and existing.time_start = l.time_start
        and existing.time_end = l.time_end
        and existing.subject = l.raw_title
      limit 1;

      if v_lesson_id is null then
        insert into public.lessons (
          group_id,
          week,
          day,
          date,
          pair_num,
          time_start,
          time_end,
          subject,
          room,
          teacher,
          subject_id,
          subject_offering_id,
          academic_year_id,
          academic_term_id,
          semester_number,
          raw_subject_name,
          normalized_subject_name,
          alias_match_status
        )
        select
          g.id,
          1,
          l.day_code,
          l.lesson_date,
          l.pair_num,
          l.time_start,
          l.time_end,
          l.raw_title,
          l.room,
          l.teacher,
          null,
          null,
          v_year_id,
          v_term_id,
          v_semester,
          l.raw_title,
          null,
          'pending'
        from public.groups g
        where g.name = l.group_name
        returning id into v_lesson_id;
      end if;

      perform *
      from public.link_lesson_subject_from_schedule(v_lesson_id);
    end loop;
  end loop;
end $$;

commit;

-- Control checks.
select *
from public.resolve_subject_offering_for_schedule(
  'a652632a-1d95-495f-abdc-23eda79ee7a1',
  'Тест парсинга пары (сем.)',
  '2026-06-23',
  4
);

select *
from public.resolve_subject_offering_for_schedule(
  'a652632a-1d95-495f-abdc-23eda79ee7a1',
  'Тест парсинга пары, практика Teams PARSE-1',
  '2026-06-23',
  4
);

select *
from public.resolve_subject_offering_for_schedule(
  '09f0c211-9570-43cf-8417-366a83c536d6',
  'Проверка парсинга пары (сем.)',
  '2026-06-23',
  4
);

select *
from public.resolve_subject_offering_for_schedule(
  '09f0c211-9570-43cf-8417-366a83c536d6',
  'Проверка парсинга пары, практика Teams PARSE-A',
  '2026-06-23',
  4
);

select
  g.name as group_name,
  l.id,
  l.date,
  l.pair_num,
  l.time_start,
  l.subject,
  l.subject_id,
  l.subject_offering_id,
  l.alias_match_status
from public.lessons l
join public.groups g on g.id = l.group_id
where l.date = '2026-06-23'
  and l.subject ilike '%парсинга пары%'
order by g.name, l.time_start;
